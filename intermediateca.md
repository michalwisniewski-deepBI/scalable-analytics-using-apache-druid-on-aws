# Intermediate CA for Ubuntu 22.04 FIPS

Ten dokument opisuje pierwszy etap migracji TLS dla Druid na Ubuntu 22.04 z FIPS:

- intermediate CA jest generowany ręcznie poza repo,
- podpis intermediate CA odbywa się ręcznie przy użyciu istniejącego root CA,
- wynikowy bundle PEM jest pakowany do `tar.gz`,
- bundle trafia do AWS Secrets Manager jako `SecretBinary`,
- w pierwszej fazie identyfikator secreta będzie zahardcodowany w kodzie.

## Założenia

- Root CA już istnieje i masz do niego:
  - `ca.cert.pem`
  - `ca.key.pem`
- Root CA private key działa na Ubuntu 20.04 FIPS, ale nie nadaje się do użycia na Ubuntu 22.04 FIPS.
- Intermediate CA ma być wygenerowany na Ubuntu 22.04 FIPS.
- W pierwszej fazie secret w AWS będzie zawierał:
  - `ca.cert.pem`
  - `druid-int22.cert.pem`
  - `druid-int22.key.pem`
- Plik `druid-int22.key.pem` będzie niezaszyfrowany PEM tylko do pierwszych testów.

## Nazewnictwo

Przyjmujemy poniższe nazwy:

- root cert: `ca.cert.pem`
- root key: `ca.key.pem`
- intermediate key: `druid-int22.key.pem`
- intermediate csr: `druid-int22.csr.pem`
- intermediate cert: `druid-int22.cert.pem`
- extension file: `intermediate.ext`
- bundle: `druid-int22-ca-bundle.tar.gz`

## Etap 1: wygenerowanie intermediate CA na Ubuntu 22.04 FIPS

Wykonaj te kroki na maszynie z Ubuntu 22.04 i aktywnym FIPS.

### 1. Potwierdź FIPS

```bash
openssl version
openssl list -providers
```

Oczekujesz aktywnego providera `fips`.

### 2. Ustaw argumenty OpenSSL

```bash
OPENSSL_ARGS=(-provider fips -provider base)
```

### 3. Wygeneruj klucz intermediate CA

```bash
openssl genpkey \
  "${OPENSSL_ARGS[@]}" \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:2048 \
  -out druid-int22.key.pem
```

### 4. Zweryfikuj klucz intermediate

```bash
openssl pkey \
  "${OPENSSL_ARGS[@]}" \
  -in druid-int22.key.pem \
  -noout \
  -check
```

Oczekujesz wyniku równoważnego `Key is valid`.

### 5. Utwórz CSR intermediate

```bash
openssl req \
  "${OPENSSL_ARGS[@]}" \
  -new \
  -sha256 \
  -key druid-int22.key.pem \
  -out druid-int22.csr.pem \
  -subj "/CN=Druid Ubuntu 22.04 FIPS Intermediate CA"
```

### 6. Przygotuj plik rozszerzeń CA

```bash
cat > intermediate.ext <<'EOF'
basicConstraints=critical,CA:true,pathlen:0
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
```

### 7. Przenieś do podpisania

Przenieś na host Ubuntu 20.04 FIPS:

- `druid-int22.csr.pem`
- `intermediate.ext`

Nie przenoś root private key na Ubuntu 22.04.

## Etap 2: podpisanie intermediate CA na Ubuntu 20.04 FIPS

Wykonaj te kroki na maszynie z Ubuntu 20.04 FIPS, gdzie działa dotychczasowy `ca.key.pem`.

### 1. Ustaw argumenty OpenSSL

```bash
OPENSSL_ARGS=(-provider fips -provider base)
```

### 2. Zweryfikuj root CA

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

### 3. Podpisz intermediate CSR root CA

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

### 4. Zweryfikuj intermediate cert względem root CA

```bash
openssl verify \
  "${OPENSSL_ARGS[@]}" \
  -CAfile ca.cert.pem \
  druid-int22.cert.pem
```

### 5. Sprawdź subject i issuer

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

## Etap 3: walidacja pary intermediate cert + key

Po podpisaniu wróć z plikiem `druid-int22.cert.pem` na host Ubuntu 22.04 FIPS i zweryfikuj zgodność z kluczem.

### 1. Sprawdź cert

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

### 2. Sprawdź, że cert i key do siebie pasują

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

### 3. Zbuduj chain testowy

```bash
cat druid-int22.cert.pem ca.cert.pem > ca-chain.pem
```

## Etap 4: spakowanie bundle do `tar.gz`

W katalogu z trzema plikami wykonaj:

```bash
tar -czf druid-int22-ca-bundle.tar.gz \
  ca.cert.pem \
  druid-int22.cert.pem \
  druid-int22.key.pem
```

### Weryfikacja zawartości archiwum

```bash
tar -tzf druid-int22-ca-bundle.tar.gz
```

Oczekiwana zawartość:

```text
ca.cert.pem
druid-int22.cert.pem
druid-int22.key.pem
```

## Etap 5: utworzenie secreta w AWS Secrets Manager

### Opcja A: nowy secret

```bash
aws secretsmanager create-secret \
  --name "druid/tls/intermediate-ubuntu2204-fips" \
  --description "Druid Ubuntu 22.04 FIPS intermediate CA bundle" \
  --secret-binary fileb://druid-int22-ca-bundle.tar.gz
```

### Opcja B: aktualizacja istniejącego secreta

```bash
aws secretsmanager put-secret-value \
  --secret-id "druid/tls/intermediate-ubuntu2204-fips" \
  --secret-binary fileb://druid-int22-ca-bundle.tar.gz
```

### Pobranie ARN/ID secreta

```bash
aws secretsmanager describe-secret \
  --secret-id "druid/tls/intermediate-ubuntu2204-fips"
```

Zapisz:

- `ARN`
- `Name`

W pierwszej fazie jeden z tych identyfikatorów będzie zahardcodowany w repo.

## Etap 6: test odczytu secreta

```bash
aws secretsmanager get-secret-value \
  --secret-id "druid/tls/intermediate-ubuntu2204-fips" \
  --query SecretBinary \
  --output text \
  | base64 --decode > downloaded-druid-int22-ca-bundle.tar.gz
```

Rozpakowanie:

```bash
mkdir -p downloaded-bundle
tar -xzf downloaded-druid-int22-ca-bundle.tar.gz -C downloaded-bundle
find downloaded-bundle -maxdepth 1 -type f | sort
```

## Oczekiwany stan końcowy dla fazy 1

Secret w AWS ma zawierać:

- `ca.cert.pem`
- `druid-int22.cert.pem`
- `druid-int22.key.pem`

Repozytorium po zmianach ma:

- pobierać ten bundle z AWS Secrets Manager,
- budować leaf cert na node,
- tworzyć `keystore.bcfks`,
- tworzyć `truststore.bcfks`,
- nie używać `ca.p12`,
- nie używać `openssl pkcs12`,
- nie używać root `ca.key.pem` na Ubuntu 22.04.

## Uwagi operacyjne

- Faza 1 świadomie rozprowadza intermediate private key na instancje. To jest akceptowany kompromis testowy, ale nie docelowy model bezpieczeństwa.
- Docelowo signing leaf certów powinien być centralny, bez kopiowania intermediate private key na node.
- Dla rolling upgrade trzeba najpierw zaktualizować truststore na starych node'ach tak, aby ufały także `druid-int22.cert.pem`.
