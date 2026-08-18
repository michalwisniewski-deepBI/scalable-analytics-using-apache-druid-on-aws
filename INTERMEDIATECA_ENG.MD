# Intermediate CA for Ubuntu 22.04 FIPS

This document describes the first stage of the TLS migration for Druid on Ubuntu 22.04 with FIPS:

- the intermediate CA is generated manually outside the repository,
- the intermediate CA is signed manually using the existing root CA,
- the resulting PEM bundle is packaged into `tar.gz`,
- the bundle is uploaded to AWS Secrets Manager as `SecretBinary`,
- in the first phase, the secret identifier will be hardcoded in the code.

## Assumptions

- The Root CA already exists as `ca.p12`.
- The Root CA private key works on Ubuntu 20.04 FIPS, but it is not suitable for use on Ubuntu 22.04 FIPS.
- On Ubuntu 20.04 FIPS, you extract `ca.p12` into:
  - `ca.cert.pem`
  - `ca.key.pem`
- On Ubuntu 22.04 FIPS, you transfer only `ca.cert.pem`.
- The Intermediate CA is to be generated on Ubuntu 22.04 FIPS.
- In the first phase, the secret in AWS will contain:
  - `ca.cert.pem`
  - `druid-int22.cert.pem`
  - `druid-int22.key.pem`
- The `druid-int22.key.pem` file will be an unencrypted PEM only for the initial tests.

## Naming

We use the following names:

- root cert: `ca.cert.pem`
- root key: `ca.key.pem`
- intermediate key: `druid-int22.key.pem`
- intermediate csr: `druid-int22.csr.pem`
- intermediate cert: `druid-int22.cert.pem`
- extension file: `intermediate.ext`
- bundle: `druid-int22-ca-bundle.tar.gz`

## Stage 1: generate the intermediate CA on Ubuntu 22.04 FIPS

Perform these steps on a machine running Ubuntu 22.04 with FIPS enabled.

### 1. Confirm FIPS

```bash
openssl version
openssl list -providers
```

You expect the `fips` provider to be active.

### 2. Set OpenSSL arguments

```bash
OPENSSL_ARGS=(-provider fips -provider base)
```

### 3. Generate the intermediate CA key

```bash
openssl genpkey \
  "${OPENSSL_ARGS[@]}" \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:2048 \
  -out druid-int22.key.pem
```

### 4. Verify the intermediate key

```bash
openssl pkey \
  "${OPENSSL_ARGS[@]}" \
  -in druid-int22.key.pem \
  -noout \
  -check
```

You expect output equivalent to `Key is valid`.

### 5. Create the intermediate CSR

```bash
openssl req \
  "${OPENSSL_ARGS[@]}" \
  -new \
  -sha256 \
  -key druid-int22.key.pem \
  -out druid-int22.csr.pem \
  -subj "/CN=Druid Ubuntu 22.04 FIPS Intermediate CA"
```

### 6. Prepare the CA extensions file

```bash
cat > intermediate.ext <<'EOF'
basicConstraints=critical,CA:true,pathlen:0
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
```

### 7. Transfer for signing

Transfer to the Ubuntu 20.04 FIPS host:

- `druid-int22.csr.pem`
- `intermediate.ext`

Do not transfer the root private key to Ubuntu 22.04.

## Stage 2: sign the intermediate CA on Ubuntu 20.04 FIPS

Perform these steps on the Ubuntu 20.04 FIPS machine where you extract `ca.p12` and where the resulting `ca.key.pem` works.

### 1. Set OpenSSL arguments

```bash
OPENSSL_ARGS=(-provider fips -provider base)
```

### 2. Extract the Root CA from `ca.p12`

```bash
openssl pkcs12 \
  "${OPENSSL_ARGS[@]}" \
  -in ca.p12 \
  -clcerts \
  -nokeys \
  -out ca.cert.pem \
  -passin pass:changeit

openssl pkcs12 \
  "${OPENSSL_ARGS[@]}" \
  -in ca.p12 \
  -nocerts \
  -nodes \
  -out ca.key.pem \
  -passin pass:changeit
```

After extraction, transfer `ca.cert.pem` to the Ubuntu 22.04 FIPS host.

### 3. Verify the Root CA

```bash
openssl x509 \
  "${OPENSSL_ARGS[@]}" \
  -in ca.cert.pem \
  -noout \
  -subject \
  -issuer \
  -dates

openssl pkey \
  "${OPENSSL_ARGS[@]}" \
  -in ca.key.pem \
  -noout \
  -check
```

### 4. Sign the intermediate CSR with the Root CA

```bash
SERIAL_HEX=$(openssl rand "${OPENSSL_ARGS[@]}" -hex 16)

openssl x509 -req \
  "${OPENSSL_ARGS[@]}" \
  -in druid-int22.csr.pem \
  -CA ca.cert.pem \
  -CAkey ca.key.pem \
  -set_serial "0x$SERIAL_HEX" \
  -out druid-int22.cert.pem \
  -days 3650 \
  -sha256 \
  -extfile intermediate.ext
```

### 5. Verify the intermediate cert against the Root CA

```bash
openssl verify \
  "${OPENSSL_ARGS[@]}" \
  -CAfile ca.cert.pem \
  druid-int22.cert.pem
```

### 6. Check subject and issuer

```bash
openssl x509 \
  "${OPENSSL_ARGS[@]}" \
  -in druid-int22.cert.pem \
  -noout \
  -subject \
  -issuer \
  -dates \
  -text
```

## Stage 3: validate the intermediate cert + key pair

After signing, return with the `druid-int22.cert.pem` file to the Ubuntu 22.04 FIPS host and verify that it matches the key.

### 1. Check the cert

```bash
OPENSSL_ARGS=(-provider fips -provider base)

openssl x509 \
  "${OPENSSL_ARGS[@]}" \
  -in druid-int22.cert.pem \
  -noout \
  -subject \
  -issuer \
  -dates
```

### 2. Check that the cert and key match

```bash
CERT_PUB_SHA=$(
  openssl x509 "${OPENSSL_ARGS[@]}" \
    -in druid-int22.cert.pem \
    -noout \
    -pubkey \
  | openssl pkey "${OPENSSL_ARGS[@]}" \
      -pubin \
      -outform DER \
  | openssl sha256 \
  | awk '{print $2}'
)

KEY_PUB_SHA=$(
  openssl pkey "${OPENSSL_ARGS[@]}" \
    -in druid-int22.key.pem \
    -pubout \
    -outform DER \
  | openssl sha256 \
  | awk '{print $2}'
)

echo "$CERT_PUB_SHA"
echo "$KEY_PUB_SHA"
test "$CERT_PUB_SHA" = "$KEY_PUB_SHA"
```

### 3. Build a test chain

```bash
cat druid-int22.cert.pem ca.cert.pem > ca-chain.pem
```

## Stage 4: package the bundle into `tar.gz`

In the directory containing the three files, run:

```bash
tar -czf druid-int22-ca-bundle.tar.gz \
  ca.cert.pem \
  druid-int22.cert.pem \
  druid-int22.key.pem
```

### Verify the archive contents

```bash
tar -tzf druid-int22-ca-bundle.tar.gz
```

Expected contents:

```text
ca.cert.pem
druid-int22.cert.pem
druid-int22.key.pem
```

## Stage 5: create the secret in AWS Secrets Manager

### Option A: new secret

```bash
aws secretsmanager create-secret \
  --name "druid/tls/intermediate-ubuntu2204-fips" \
  --description "Druid Ubuntu 22.04 FIPS intermediate CA bundle" \
  --secret-binary fileb://druid-int22-ca-bundle.tar.gz
```

### Option B: update an existing secret

```bash
aws secretsmanager put-secret-value \
  --secret-id "druid/tls/intermediate-ubuntu2204-fips" \
  --secret-binary fileb://druid-int22-ca-bundle.tar.gz
```

### Retrieve the secret ARN/ID

```bash
aws secretsmanager describe-secret \
  --secret-id "druid/tls/intermediate-ubuntu2204-fips"
```

Save:

- `ARN`
- `Name`

In the first phase, one of these identifiers will be hardcoded in the repository.

## Stage 6: test reading the secret

```bash
aws secretsmanager get-secret-value \
  --secret-id "druid/tls/intermediate-ubuntu2204-fips" \
  --query SecretBinary \
  --output text \
  | base64 --decode > downloaded-druid-int22-ca-bundle.tar.gz
```

Unpack:

```bash
mkdir -p downloaded-bundle
tar -xzf downloaded-druid-int22-ca-bundle.tar.gz -C downloaded-bundle
find downloaded-bundle -maxdepth 1 -type f | sort
```

## Expected final state for phase 1

The secret in AWS is expected to contain:

- `ca.cert.pem`
- `druid-int22.cert.pem`
- `druid-int22.key.pem`

After the changes, the repository is expected to:

- fetch this bundle from AWS Secrets Manager,
- build the leaf cert on the node,
- create `keystore.bcfks`,
- create `truststore.bcfks`,
- not use `ca.p12`,
- not use `openssl pkcs12`,
- not use the root `ca.key.pem` on Ubuntu 22.04.

## Operational notes

- Phase 1 deliberately distributes the intermediate private key to instances. This is an accepted testing compromise, but not the target security model.
- Ultimately, leaf cert signing should be centralized, without copying the intermediate private key to the node.
- For a rolling upgrade, you first need to update the truststore on the old nodes so they also trust `druid-int22.cert.pem`.
