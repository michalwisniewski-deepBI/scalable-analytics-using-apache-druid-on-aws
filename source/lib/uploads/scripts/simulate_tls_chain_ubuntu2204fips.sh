#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tls_san_utils.sh"

usage() {
    cat <<'EOF'
Usage:
  simulate_tls_chain_ubuntu2204fips.sh OUTPUT_DIR [DAYS_VALID]

Generates a local TLS hierarchy on Ubuntu 22.04 with FIPS enabled:
  - root CA key/cert
  - intermediate CA key/cert
  - leaf host key/cert for hostname -f

Outputs:
  ca.key.pem
  ca.cert.pem
  druid-int22.key.pem
  druid-int22.cert.pem
  druid-host.key.pem
  druid-host.csr.pem
  druid-host.cert.pem
  druid-host-chain.pem
  ca-chain.pem
  druid-int22-ca-bundle.tar.gz
  leaf.ext

Example:
  ./simulate_tls_chain_ubuntu2204fips.sh /tmp/druid-tls-lab 365
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    exit 1
fi

OUTPUT_DIR="$1"
DAYS_VALID="${2:-365}"
OPENSSL_ARGS=(-provider fips -provider base)

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

for required_cmd in openssl hostname awk ip tar; do
    require_cmd "$required_cmd"
done

HOST_FQDN="$(hostname -f)"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
HOST_NAME="$(hostname)"
LOCAL_IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

rm -f \
    ca.key.pem \
    ca.cert.pem \
    ca.cert.srl \
    druid-int22.key.pem \
    druid-int22.csr.pem \
    druid-int22.cert.pem \
    druid-host.key.pem \
    druid-host.csr.pem \
    druid-host.cert.pem \
    druid-host-chain.pem \
    ca-chain.pem \
    druid-int22-ca-bundle.tar.gz \
    leaf.ext \
    intermediate.ext

extra_hostnames=()
for candidate in "$HOST_SHORT" "$HOST_NAME"; do
    if [ -n "$candidate" ] && [ "$candidate" != "$HOST_FQDN" ]; then
        extra_hostnames+=("$candidate")
    fi
done

build_san_entries "$HOST_FQDN" "$HOST_SHORT" "$LOCAL_IPV4" "${extra_hostnames[@]}"

cat > intermediate.ext <<'EOF'
basicConstraints=critical,CA:true,pathlen:0
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

cat > leaf.ext <<EOF
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer

[alt_names]
$ALT_NAMES
EOF

echo "Generating root CA for Ubuntu 22.04 FIPS..."
openssl genpkey "${OPENSSL_ARGS[@]}" \
    -algorithm RSA \
    -pkeyopt rsa_keygen_bits:2048 \
    -out ca.key.pem

openssl req "${OPENSSL_ARGS[@]}" \
    -x509 \
    -new \
    -key ca.key.pem \
    -sha256 \
    -days "$DAYS_VALID" \
    -subj "/CN=Druid Internal CA/O=YourOrg" \
    -out ca.cert.pem

echo "Generating intermediate CA..."
openssl genpkey "${OPENSSL_ARGS[@]}" \
    -algorithm RSA \
    -pkeyopt rsa_keygen_bits:2048 \
    -out druid-int22.key.pem

openssl req "${OPENSSL_ARGS[@]}" \
    -new \
    -key druid-int22.key.pem \
    -sha256 \
    -subj "/CN=Druid Ubuntu 22.04 FIPS Intermediate CA/O=YourOrg" \
    -out druid-int22.csr.pem

openssl x509 -req \
    "${OPENSSL_ARGS[@]}" \
    -in druid-int22.csr.pem \
    -CA ca.cert.pem \
    -CAkey ca.key.pem \
    -CAcreateserial \
    -days "$DAYS_VALID" \
    -sha256 \
    -extfile intermediate.ext \
    -out druid-int22.cert.pem

echo "Generating leaf key and certificate for $HOST_FQDN..."
openssl genpkey "${OPENSSL_ARGS[@]}" \
    -algorithm RSA \
    -pkeyopt rsa_keygen_bits:2048 \
    -out druid-host.key.pem

openssl req "${OPENSSL_ARGS[@]}" \
    -new \
    -key druid-host.key.pem \
    -sha256 \
    -subj "/CN=$HOST_FQDN" \
    -out druid-host.csr.pem

SERIAL_HEX="$(openssl rand "${OPENSSL_ARGS[@]}" -hex 16)"

openssl x509 -req \
    "${OPENSSL_ARGS[@]}" \
    -in druid-host.csr.pem \
    -CA druid-int22.cert.pem \
    -CAkey druid-int22.key.pem \
    -set_serial "0x$SERIAL_HEX" \
    -days "$DAYS_VALID" \
    -sha256 \
    -extfile leaf.ext \
    -out druid-host.cert.pem

cat druid-int22.cert.pem ca.cert.pem > ca-chain.pem
cat druid-host.cert.pem druid-int22.cert.pem ca.cert.pem > druid-host-chain.pem

tar -czf druid-int22-ca-bundle.tar.gz \
    ca.cert.pem \
    druid-int22.cert.pem \
    druid-int22.key.pem

echo "Validating generated materials..."
openssl pkey "${OPENSSL_ARGS[@]}" -in ca.key.pem -noout -check
openssl pkey "${OPENSSL_ARGS[@]}" -in druid-int22.key.pem -noout -check
openssl pkey "${OPENSSL_ARGS[@]}" -in druid-host.key.pem -noout -check

openssl verify "${OPENSSL_ARGS[@]}" \
    -CAfile ca.cert.pem \
    druid-int22.cert.pem

openssl verify "${OPENSSL_ARGS[@]}" \
    -CAfile ca-chain.pem \
    druid-host.cert.pem

echo
echo "Generated files in: $OUTPUT_DIR"
echo "Host FQDN: $HOST_FQDN"
echo "Host short name: $HOST_SHORT"
if [ -n "$LOCAL_IPV4" ]; then
    echo "Host IPv4: $LOCAL_IPV4"
fi
echo
echo "Inspect leaf certificate:"
echo "  openssl x509 ${OPENSSL_ARGS[*]} -in $OUTPUT_DIR/druid-host.cert.pem -noout -subject -issuer -text"
echo
echo "Test verification:"
echo "  openssl verify ${OPENSSL_ARGS[*]} -CAfile $OUTPUT_DIR/ca-chain.pem $OUTPUT_DIR/druid-host.cert.pem"
