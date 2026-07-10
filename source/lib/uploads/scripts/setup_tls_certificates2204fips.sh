#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tls_san_utils.sh"

# TLS bootstrap for Ubuntu 22.04 with FIPS enabled.
# Expects Secrets Manager SecretBinary: tar.gz bundle containing:
# - ca.cert.pem
# - druid-int22.cert.pem
# - druid-int22.key.pem
#
# usage: setup_tls_certificates2204fips.sh TLS_CERT_HOME TLS_CERTIFICATE_SECRET_NAME_PEM TLS_KEYSTORE_PASSWORD

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 TLS_CERT_HOME TLS_CERTIFICATE_SECRET_NAME_PEM TLS_KEYSTORE_PASSWORD"
    exit 1
fi

TLS_CERT_HOME="$1"
#TLS_CERTIFICATE_SECRET_NAME_PEM="$2"
TLS_CERTIFICATE_SECRET_NAME_PEM="druid/tls/intermediate-ubuntu2204-fips"
TLS_KEYSTORE_PASSWORD="$3"

OPENSSL_ARGS=(-provider fips -provider base)
BC_LIB_DIR="/opt/service/dependencies"
DRUID_SECURITY_DIR="/home/druid-cluster/apache-druid/conf/druid"
DRUID_JAVA_SECURITY_FILE="$DRUID_SECURITY_DIR/bcfips-java.security"
BCFIPS_VERSION="2.1.2"
BCTLS_VERSION="2.1.22"
BCUTIL_VERSION="2.1.5"
BCFIPS_JAR="$BC_LIB_DIR/bc-fips-${BCFIPS_VERSION}.jar"
BCTLS_JAR="$BC_LIB_DIR/bctls-fips-${BCTLS_VERSION}.jar"
BCUTIL_JAR="$BC_LIB_DIR/bcutil-fips-${BCUTIL_VERSION}.jar"
BCFIPS_URL="https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/${BCFIPS_VERSION}/bc-fips-${BCFIPS_VERSION}.jar"
BCTLS_URL="https://repo1.maven.org/maven2/org/bouncycastle/bctls-fips/${BCTLS_VERSION}/bctls-fips-${BCTLS_VERSION}.jar"
BCUTIL_URL="https://repo1.maven.org/maven2/org/bouncycastle/bcutil-fips/${BCUTIL_VERSION}/bcutil-fips-${BCUTIL_VERSION}.jar"
BCFIPS_CLASS="org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider"
KEYTOOL_PROVIDER_ARGS=(
    -providerclass "$BCFIPS_CLASS"
    -providerpath "$BCFIPS_JAR"
)

BUNDLE_FILE="$TLS_CERT_HOME/druid-int22-ca-bundle.tar.gz"
LEAF_EXT_FILE="$TLS_CERT_HOME/leaf.ext"
CA_CHAIN_FILE="$TLS_CERT_HOME/ca-chain.pem"
DRUID_CHAIN_FILE="$TLS_CERT_HOME/druid-chain.pem"

cleanup() {
    rm -f \
        "$BUNDLE_FILE" \
        "$LEAF_EXT_FILE" \
        "$CA_CHAIN_FILE" \
        "$DRUID_CHAIN_FILE" \
        "$TLS_CERT_HOME/druid.csr" \
        "$TLS_CERT_HOME/druid.pem" \
        "$TLS_CERT_HOME/druid-int22.key.pem" \
        "$TLS_CERT_HOME/druid-int22.cert.pem" \
        "$TLS_CERT_HOME/ca.cert.pem" \
        "$TLS_CERT_HOME"/*.srl
}

#trap cleanup EXIT

mkdir -p "$BC_LIB_DIR" "$DRUID_SECURITY_DIR"
rm -f "$BCFIPS_JAR"
rm -f "$BCTLS_JAR"
rm -f "$BCUTIL_JAR"
wget -q -O "$BCFIPS_JAR" "$BCFIPS_URL"
wget -q -O "$BCTLS_JAR" "$BCTLS_URL"
wget -q -O "$BCUTIL_JAR" "$BCUTIL_URL"

cat > "$DRUID_JAVA_SECURITY_FILE" <<EOF
security.provider.1=org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider C:HYBRID;DEFRND[local];ENABLE{ALL};
security.provider.2=org.bouncycastle.jsse.provider.BouncyCastleJsseProvider fips:BCFIPS
security.provider.3=SUN
securerandom.strongAlgorithms=NativePRNGBlocking:SUN
securerandom.source=file:/dev/random
EOF

TOKEN=$(curl -fsS -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
HOSTNAME=$(curl -fsS \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/hostname)
LOCAL_HOSTNAME=$(curl -fsS \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/local-hostname || true)
LOCAL_IPV4=$(curl -fsS \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/local-ipv4 || true)

if [ ! -s "$BCFIPS_JAR" ]; then
    echo "Missing BCFIPS jar: $BCFIPS_JAR"
    exit 1
fi

if [ ! -s "$BCTLS_JAR" ]; then
    echo "Missing BCTLS jar: $BCTLS_JAR"
    exit 1
fi

if [ ! -s "$BCUTIL_JAR" ]; then
    echo "Missing BCUTIL jar: $BCUTIL_JAR"
    exit 1
fi

mkdir -p "$TLS_CERT_HOME"
cd "$TLS_CERT_HOME"

rm -f keystore.bcfks truststore.bcfks

aws secretsmanager get-secret-value \
    --secret-id "$TLS_CERTIFICATE_SECRET_NAME_PEM" \
    --output text \
    --query SecretBinary | base64 --decode > "$BUNDLE_FILE"

tar -xzf "$BUNDLE_FILE" -C "$TLS_CERT_HOME"

for required_file in ca.cert.pem druid-int22.cert.pem druid-int22.key.pem; do
    if [ ! -f "$TLS_CERT_HOME/$required_file" ]; then
        echo "Missing file in CA bundle: $required_file"
        exit 1
    fi
done

openssl x509 "${OPENSSL_ARGS[@]}" \
    -in ca.cert.pem \
    -noout \
    -subject \
    -issuer \
    -dates

openssl x509 "${OPENSSL_ARGS[@]}" \
    -in druid-int22.cert.pem \
    -noout \
    -subject \
    -issuer \
    -dates

openssl pkey "${OPENSSL_ARGS[@]}" \
    -in druid-int22.key.pem \
    -noout \
    -check

openssl verify "${OPENSSL_ARGS[@]}" \
    -CAfile ca.cert.pem \
    druid-int22.cert.pem

CERT_PUB_SHA=$(
    openssl x509 "${OPENSSL_ARGS[@]}" \
        -in druid-int22.cert.pem \
        -noout \
        -pubkey |
        openssl pkey "${OPENSSL_ARGS[@]}" \
            -pubin \
            -outform DER |
        openssl sha256 |
        awk '{print $2}'
)

KEY_PUB_SHA=$(
    openssl pkey "${OPENSSL_ARGS[@]}" \
        -in druid-int22.key.pem \
        -pubout \
        -outform DER |
        openssl sha256 |
        awk '{print $2}'
)

if [ "$CERT_PUB_SHA" != "$KEY_PUB_SHA" ]; then
    echo "Intermediate CA certificate does not match intermediate CA private key"
    exit 1
fi

extra_hostnames=()
for candidate in "$HOSTNAME" "$LOCAL_HOSTNAME" "$(hostname 2>/dev/null || true)" "$(hostname -s 2>/dev/null || true)" "$(hostname -f 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ "$candidate" != "$HOSTNAME" ] && [ "$candidate" != "$LOCAL_HOSTNAME" ]; then
        extra_hostnames+=("$candidate")
    fi
done

build_san_entries "$HOSTNAME" "$LOCAL_HOSTNAME" "$LOCAL_IPV4" "${extra_hostnames[@]}"
SAN_KEYTOOL="$SAN_KEYTOOL"
ALT_NAMES="$ALT_NAMES"

keytool -genkeypair \
    -alias druid \
    -keyalg RSA \
    -keysize 2048 \
    -sigalg SHA256withRSA \
    -keystore keystore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -keypass "$TLS_KEYSTORE_PASSWORD" \
    -dname "CN=$HOSTNAME" \
    -validity 365 \
    -ext "KU=digitalSignature,keyEncipherment" \
    -ext "EKU=serverAuth,clientAuth" \
    -ext "$SAN_KEYTOOL" \
    "${KEYTOOL_PROVIDER_ARGS[@]}" \
    -noprompt

keytool -certreq \
    -alias druid \
    -keystore keystore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -file druid.csr \
    -sigalg SHA256withRSA \
    -ext "KU=digitalSignature,keyEncipherment" \
    -ext "EKU=serverAuth,clientAuth" \
    -ext "$SAN_KEYTOOL" \
    "${KEYTOOL_PROVIDER_ARGS[@]}"

cat > "$LEAF_EXT_FILE" <<EOF
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names

[alt_names]
$ALT_NAMES
EOF

SERIAL_HEX=$(openssl rand "${OPENSSL_ARGS[@]}" -hex 16)

openssl x509 -req \
    "${OPENSSL_ARGS[@]}" \
    -in druid.csr \
    -CA druid-int22.cert.pem \
    -CAkey druid-int22.key.pem \
    -set_serial "0x$SERIAL_HEX" \
    -out druid.pem \
    -days 365 \
    -sha256 \
    -extfile "$LEAF_EXT_FILE"

cat druid-int22.cert.pem ca.cert.pem > "$CA_CHAIN_FILE"
cat druid.pem druid-int22.cert.pem ca.cert.pem > "$DRUID_CHAIN_FILE"

openssl verify "${OPENSSL_ARGS[@]}" \
    -CAfile "$CA_CHAIN_FILE" \
    druid.pem

keytool -importcert \
    -alias root-ca \
    -file ca.cert.pem \
    -keystore keystore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    "${KEYTOOL_PROVIDER_ARGS[@]}" \
    -noprompt

keytool -importcert \
    -alias druid-int-ca \
    -file druid-int22.cert.pem \
    -keystore keystore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    "${KEYTOOL_PROVIDER_ARGS[@]}" \
    -noprompt

keytool -importcert \
    -alias druid \
    -file "$DRUID_CHAIN_FILE" \
    -keystore keystore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    "${KEYTOOL_PROVIDER_ARGS[@]}" \
    -noprompt

keytool -importcert \
    -alias root-ca \
    -file ca.cert.pem \
    -keystore truststore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    "${KEYTOOL_PROVIDER_ARGS[@]}" \
    -noprompt

keytool -importcert \
    -alias druid-int-ca \
    -file druid-int22.cert.pem \
    -keystore truststore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    "${KEYTOOL_PROVIDER_ARGS[@]}" \
    -noprompt

keytool -list -v \
    -keystore keystore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    "${KEYTOOL_PROVIDER_ARGS[@]}" >/dev/null

keytool -list \
    -keystore truststore.bcfks \
    -storetype BCFKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    "${KEYTOOL_PROVIDER_ARGS[@]}" >/dev/null
