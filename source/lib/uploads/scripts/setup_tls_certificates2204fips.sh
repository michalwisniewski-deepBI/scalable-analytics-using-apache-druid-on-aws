#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

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
TLS_CERTIFICATE_SECRET_NAME_PEM="$2"
TLS_KEYSTORE_PASSWORD="$3"

OPENSSL_ARGS=(-provider fips -provider base)

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

mkdir -p "$TLS_CERT_HOME"
cd "$TLS_CERT_HOME"

rm -f keystore.jks truststore.jks

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

SAN_KEYTOOL="SAN=dns:$HOSTNAME"
ALT_NAMES="DNS.1=$HOSTNAME"
ALT_INDEX=2
IP_INDEX=1

if [ -n "$LOCAL_HOSTNAME" ] && [ "$LOCAL_HOSTNAME" != "$HOSTNAME" ]; then
    SAN_KEYTOOL="$SAN_KEYTOOL,dns:$LOCAL_HOSTNAME"
    ALT_NAMES="$ALT_NAMES
DNS.$ALT_INDEX=$LOCAL_HOSTNAME"
    ALT_INDEX=$((ALT_INDEX + 1))
fi

if [ -n "$LOCAL_IPV4" ]; then
    SAN_KEYTOOL="$SAN_KEYTOOL,ip:$LOCAL_IPV4"
    ALT_NAMES="$ALT_NAMES
IP.$IP_INDEX=$LOCAL_IPV4"
fi

keytool -genkeypair \
    -alias druid \
    -keyalg RSA \
    -keysize 2048 \
    -sigalg SHA256withRSA \
    -keystore keystore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -keypass "$TLS_KEYSTORE_PASSWORD" \
    -dname "CN=$HOSTNAME" \
    -validity 365 \
    -ext "KU=digitalSignature,keyEncipherment" \
    -ext "EKU=serverAuth,clientAuth" \
    -ext "$SAN_KEYTOOL" \
    -noprompt

keytool -certreq \
    -alias druid \
    -keystore keystore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -file druid.csr \
    -sigalg SHA256withRSA \
    -ext "KU=digitalSignature,keyEncipherment" \
    -ext "EKU=serverAuth,clientAuth" \
    -ext "$SAN_KEYTOOL"

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
    -keystore keystore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -noprompt

keytool -importcert \
    -alias druid-int-ca \
    -file druid-int22.cert.pem \
    -keystore keystore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -noprompt

keytool -importcert \
    -alias druid \
    -file "$DRUID_CHAIN_FILE" \
    -keystore keystore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -noprompt

keytool -importcert \
    -alias root-ca \
    -file ca.cert.pem \
    -keystore truststore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -noprompt

keytool -importcert \
    -alias druid-int-ca \
    -file druid-int22.cert.pem \
    -keystore truststore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" \
    -noprompt

keytool -list -v \
    -keystore keystore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" >/dev/null

keytool -list \
    -keystore truststore.jks \
    -storetype JKS \
    -storepass "$TLS_KEYSTORE_PASSWORD" >/dev/null
