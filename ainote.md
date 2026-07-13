# AI Note: Apache Druid TLS migration for Ubuntu 22.04 FIPS

## Goal

Adapt the Apache Druid AWS deployment repository so that TLS bootstrap works on Ubuntu 22.04 with FIPS enabled.

The target design is to stop using the original/root CA private key on Ubuntu 22.04 FIPS. Instead, use a manually generated intermediate CA whose private key was generated on Ubuntu 22.04 FIPS and whose certificate was signed by the original/root CA.

The first test version will store the intermediate CA material in AWS Secrets Manager as PEM files, not as PKCS#12/P12.

---

## Background

The current solution bootstraps TLS certificates on EC2 instances from CA material stored in AWS Secrets Manager. The original model used either:

```text
ca.cert.pem
ca.key.pem
```

or a PKCS#12 bundle:

```text
ca.p12
```

On Ubuntu 20.04 FIPS, the original CA private key validates successfully:

```bash
openssl pkey -in ca.key.pem -noout -check
# Key is valid
```

On Ubuntu 22.04 FIPS, the same file, with the same `sha256sum`, fails validation:

```bash
openssl pkey \
  -provider fips \
  -provider base \
  -in ca.key.pem \
  -noout \
  -check
```

Observed error:

```text
Key is invalid
rsa_sp800_56b_check_keypair:invalid keypair
```

Conclusion: this is not a file transfer or PEM export issue. The same original CA key is accepted by the older Ubuntu 20.04 FIPS/OpenSSL stack but rejected by Ubuntu 22.04 FIPS/OpenSSL 3 FIPS validation.

Additionally, runtime `openssl pkcs12 -export` on Ubuntu 22.04 FIPS fails in the FIPS provider path with:

```text
Error creating PKCS12 MAC; no PKCS12KDF support?
Algorithm (PKCS12KDF : 0), Properties (<null>)
```

This does not mean Ubuntu 22.04 cannot handle PKCS#12 in all modes. The specific problem is that OpenSSL 3 FIPS provider does not expose the PKCS#12 KDF needed for normal PKCS#12 MAC generation in this workflow.

For this repository migration, do not use P12 for the CA material on Ubuntu 22.04 FIPS.

---

## Selected solution

Do not copy or use the original/root `ca.key.pem` on Ubuntu 22.04 FIPS.

Create a new intermediate CA:

```text
druid-int22.key.pem
druid-int22.cert.pem
```

The intermediate CA private key is generated on Ubuntu 22.04 FIPS, so it passes local OpenSSL FIPS validation. The intermediate CA certificate is signed by the original/root CA on Ubuntu 20.04 FIPS, where the original CA private key still works.

Target certificate chain:

```text
Original Root CA
  ca.cert.pem
    |
    +-- Druid Ubuntu 22.04 FIPS Intermediate CA
          druid-int22.cert.pem
          druid-int22.key.pem
            |
            +-- per-EC2 Druid leaf certificate
```

New Ubuntu 22.04 FIPS EC2 instances need the following materials:

```text
ca.cert.pem              # public root/original CA certificate
druid-int22.cert.pem     # intermediate CA certificate
druid-int22.key.pem      # intermediate CA private key, PEM, unencrypted for first test version
```

The startup script should generate:

```text
keystore.bcfks
truststore.bcfks
```

---

## AWS Secrets Manager format

For the first test version, store PEM material in AWS Secrets Manager, not encrypted.

Recommended `SecretBinary` format: a `tar.gz` archive containing exactly these files:

```text
ca.cert.pem
druid-int22.cert.pem
druid-int22.key.pem
```

Example bundle creation:

```bash
tar -czf druid-int22-ca-bundle.tar.gz \
  ca.cert.pem \
  druid-int22.cert.pem \
  druid-int22.key.pem
```

Example secret update:

```bash
aws secretsmanager put-secret-value \
  --secret-id "<TLS_SECRET_NAME_OR_ARN>" \
  --secret-binary fileb://druid-int22-ca-bundle.tar.gz
```

A different format is acceptable, for example concatenated PEM or JSON `SecretString`, but the startup script must reliably reconstruct the same three files.

`tar.gz` is preferred for the first implementation because it avoids fragile PEM parsing.

---

## Repository changes required

### 1. Replace or add a TLS bootstrap script

Modify the existing script, likely:

```text
source/lib/uploads/scripts/setup_tls_certificates.sh
```

or add a new Ubuntu 22.04 FIPS-specific variant, for example:

```text
source/lib/uploads/scripts/setup_tls_certificates2204fips.sh
```

The new script must not run:

```bash
openssl pkcs12 ...
```

The new script must not use the original/root `ca.key.pem`.

Instead, the script should:

1. Download the AWS Secrets Manager secret.
2. Decode and unpack the PEM bundle.
3. Validate:
   - `ca.cert.pem`
   - `druid-int22.cert.pem`
   - `druid-int22.key.pem`
4. Generate a per-node Druid leaf keypair.
5. Generate a CSR for the Druid node.
6. Sign the CSR with `druid-int22.key.pem` and `druid-int22.cert.pem`.
7. Build a certificate chain:
   - leaf certificate
   - intermediate CA certificate
   - root CA certificate
8. Create `keystore.bcfks` with alias `druid` as a `PrivateKeyEntry`.
9. Create `truststore.bcfks` containing both root and intermediate CA certificates.
10. Clean up PEM private key material from disk after keystore/truststore generation.

---

## FIPS/OpenSSL conventions

Use OpenSSL with FIPS and base providers:

```bash
OPENSSL_ARGS=(-provider fips -provider base)
```

Example validation commands:

```bash
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
```

Verify the intermediate certificate was signed by the root/original CA:

```bash
openssl verify "${OPENSSL_ARGS[@]}" \
  -CAfile ca.cert.pem \
  druid-int22.cert.pem
```

Verify the intermediate private key matches the intermediate certificate:

```bash
CERT_PUB_SHA=$( \
  openssl x509 "${OPENSSL_ARGS[@]}" \
    -in druid-int22.cert.pem \
    -noout \
    -pubkey \
  | openssl pkey "${OPENSSL_ARGS[@]}" \
      -pubin \
      -outform DER \
  | openssl sha256 \
  | awk '{print $2}' \
)

KEY_PUB_SHA=$( \
  openssl pkey "${OPENSSL_ARGS[@]}" \
    -in druid-int22.key.pem \
    -pubout \
    -outform DER \
  | openssl sha256 \
  | awk '{print $2}' \
)

if [ "$CERT_PUB_SHA" != "$KEY_PUB_SHA" ]; then
  echo "Intermediate CA certificate does not match intermediate CA private key"
  exit 1
fi
```

---

## BCFKS keystore/truststore requirements

Use Bouncy Castle FIPS BCFKS stores:

```text
keystore.bcfks
truststore.bcfks
```

Do not generate or use these in the Ubuntu 22.04 FIPS path:

```text
keystore.jks
truststore.jks
druid.p12
ca.p12
```

Expected Bouncy Castle FIPS provider settings:

```bash
BCFIPS_JAR="/opt/service/dependencies/bc-fips-2.1.2.jar"
BCFIPS_CLASS="org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider"

KEYTOOL_PROVIDER_ARGS=(
  -providerclass "$BCFIPS_CLASS"
  -providerpath "$BCFIPS_JAR"
)
```

Before using the provider, validate that the jar exists:

```bash
if [ ! -f "$BCFIPS_JAR" ]; then
  echo "Missing BCFIPS jar: $BCFIPS_JAR"
  exit 1
fi
```

---

## Leaf certificate generation

The Druid node leaf certificate must include SAN. Do not rely only on `CN`.

Collect instance identity from IMDSv2:

```bash
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
```

Generate the Druid node keypair directly inside BCFKS:

```bash
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
  -ext "SAN=dns:$HOSTNAME,dns:$LOCAL_HOSTNAME,ip:$LOCAL_IPV4" \
  "${KEYTOOL_PROVIDER_ARGS[@]}" \
  -noprompt
```

Generate the CSR:

```bash
keytool -certreq \
  -alias druid \
  -keystore keystore.bcfks \
  -storetype BCFKS \
  -storepass "$TLS_KEYSTORE_PASSWORD" \
  -file druid.csr \
  -sigalg SHA256withRSA \
  -ext "KU=digitalSignature,keyEncipherment" \
  -ext "EKU=serverAuth,clientAuth" \
  -ext "SAN=dns:$HOSTNAME,dns:$LOCAL_HOSTNAME,ip:$LOCAL_IPV4" \
  "${KEYTOOL_PROVIDER_ARGS[@]}"
```

Create a leaf certificate extension file:

```bash
cat > leaf.ext <<'EOF'
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=${HOSTNAME}
DNS.2=${LOCAL_HOSTNAME}
IP.1=${LOCAL_IPV4}
EOF
```

Sign the CSR with the intermediate CA:

```bash
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
  -extfile leaf.ext
```

Build the chain:

```bash
cat druid-int22.cert.pem ca.cert.pem > ca-chain.pem
cat druid.pem druid-int22.cert.pem ca.cert.pem > druid-chain.pem
```

Verify the leaf:

```bash
openssl verify "${OPENSSL_ARGS[@]}" \
  -CAfile ca-chain.pem \
  druid.pem
```

---

## Import certificate chain into keystore

Import root and intermediate CA certificates into the keystore as certificate entries:

```bash
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
```

Then replace the self-signed certificate under alias `druid` with the signed certificate chain:

```bash
keytool -importcert \
  -alias druid \
  -file druid-chain.pem \
  -keystore keystore.bcfks \
  -storetype BCFKS \
  -storepass "$TLS_KEYSTORE_PASSWORD" \
  "${KEYTOOL_PROVIDER_ARGS[@]}" \
  -noprompt
```

Final expected state:

```text
Alias name: druid
Entry type: PrivateKeyEntry
Certificate chain length: 3
```

Certificate chain under `druid`:

```text
leaf EC2 certificate
druid-int22.cert.pem
ca.cert.pem
```

---

## Create truststore

The truststore must contain both the root/original CA and the intermediate CA:

```bash
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
```

Expected truststore aliases:

```text
root-ca
druid-int-ca
```

---

## Druid runtime configuration

Update Druid config, likely in `common.runtime.properties` or the repository template that produces it.

Use BCFKS instead of JKS:

```properties
druid.server.https.keyStorePath=/home/druid-cluster/apache-druid/tls-certificates/keystore.bcfks
druid.server.https.keyStoreType=BCFKS
druid.server.https.certAlias=druid
druid.server.https.keyStorePassword=<password>

druid.server.https.trustStorePath=/home/druid-cluster/apache-druid/tls-certificates/truststore.bcfks
druid.server.https.trustStoreType=BCFKS
druid.server.https.trustStorePassword=<password>
```

Make sure Druid/JVM runtime can load the Bouncy Castle FIPS provider. Creating the BCFKS file with `keytool` is not enough if the Druid JVM cannot open BCFKS at runtime.

---

## Rolling update and mixed-cluster compatibility

Before introducing new Ubuntu 22.04 FIPS nodes, add the new intermediate certificate to the truststore of the old cluster nodes.

Old node state before migration:

```text
keystore: leaf certificate signed directly by ca.cert.pem
truststore: ca.cert.pem
```

Required transitional state:

```text
old node keystore: leaf signed by ca.cert.pem
old node truststore: ca.cert.pem + druid-int22.cert.pem

new node keystore: leaf signed by druid-int22.cert.pem, chain leaf + intermediate + root
new node truststore: ca.cert.pem + druid-int22.cert.pem
```

This allows communication in all combinations:

```text
old -> old: trusted by root CA
old -> new: trusted by intermediate/root chain
new -> old: trusted by root CA
new -> new: trusted by intermediate/root chain
```

After updating old truststores, restart Druid processes on old nodes. JVMs usually do not reload truststores dynamically.

---

## Validation commands on a new node

List the BCFKS keystore:

```bash
keytool -list -v \
  -keystore /home/druid-cluster/apache-druid/tls-certificates/keystore.bcfks \
  -storetype BCFKS \
  -storepass "$TLS_KEYSTORE_PASSWORD" \
  -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
  -providerpath /opt/service/dependencies/bc-fips-2.1.2.jar
```

Expected alias:

```text
Alias name: druid
Entry type: PrivateKeyEntry
Certificate chain length: 3
```

List truststore:

```bash
keytool -list \
  -keystore /home/druid-cluster/apache-druid/tls-certificates/truststore.bcfks \
  -storetype BCFKS \
  -storepass "$TLS_KEYSTORE_PASSWORD" \
  -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
  -providerpath /opt/service/dependencies/bc-fips-2.1.2.jar
```

Expected aliases:

```text
root-ca
druid-int-ca
```

OpenSSL chain verification:

```bash
cat druid-int22.cert.pem ca.cert.pem > ca-chain.pem

openssl verify \
  -provider fips \
  -provider base \
  -CAfile ca-chain.pem \
  druid.pem
```

Druid log search:

```bash
grep -R "SSL\|TLS\|certificate\|PKIX\|handshake" \
  /home/druid-cluster/apache-druid/log \
  /var/log/supervisor \
  2>/dev/null
```

Look specifically for:

```text
PKIX path building failed
certificate_unknown
bad_certificate
handshake_failure
unable to find valid certification path
```

---

## Security note

The first test version stores `druid-int22.key.pem` in AWS Secrets Manager as unencrypted PEM and downloads it to every EC2 instance during bootstrap.

This matches the repository's current CA-on-node signing model, but it is not ideal as a long-term security architecture because the intermediate CA private key is distributed to all Druid instances.

Better long-term design:

```text
EC2 generates leaf private key and CSR locally.
CSR is signed by a central signer, AWS Private CA, HSM-backed signer, or Lambda signer.
The intermediate CA private key never lands on EC2 nodes.
```

---

## Minimal task summary for the implementing agent

Modify the repository so that Ubuntu 22.04 FIPS TLS bootstrap:

1. Does not use `ca.p12`.
2. Does not use the original/root `ca.key.pem`.
3. Downloads a PEM bundle from AWS Secrets Manager containing:
   - `ca.cert.pem`
   - `druid-int22.cert.pem`
   - `druid-int22.key.pem`
4. Generates per-node Druid leaf keypair and CSR.
5. Signs the CSR using `druid-int22.key.pem` and `druid-int22.cert.pem`.
6. Creates `keystore.bcfks` with alias `druid` and chain:
   - leaf
   - intermediate
   - root
7. Creates `truststore.bcfks` containing:
   - root CA
   - intermediate CA
8. Updates Druid configuration to use:
   - `keyStoreType=BCFKS`
   - `trustStoreType=BCFKS`
9. Ensures old nodes trust `druid-int22.cert.pem` before rolling replacement.
10. Cleans up PEM files and private key material after generating the stores.
