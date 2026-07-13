# Debug Note 2026-07-10

## Cel bieżącej sesji

Diagnoza problemu po zmianach TLS dla Ubuntu 22.04 FIPS z użyciem:

- ręcznie utworzonego secreta `druid/tls/intermediate-ubuntu2204-fips`
- intermediate CA
- aktywnego skryptu `setup_tls_certificates2204fips.sh`

## Zmiany wprowadzone w repo podczas tej sesji

### 1. Skrypt TLS 22.04 FIPS

Plik:

- [source/lib/uploads/scripts/setup_tls_certificates2204fips.sh](/home/michalwisniewski/druid-adc202-git/source/lib/uploads/scripts/setup_tls_certificates2204fips.sh:1)

Stan:

- skrypt został przepisany na model `tar.gz` zawierający:
  - `ca.cert.pem`
  - `druid-int22.cert.pem`
  - `druid-int22.key.pem`
- aktywny wariant końcowo tworzy:
  - `keystore.jks`
  - `truststore.jks`
- w skrypcie zahardcodowano tymczasowo:

```bash
TLS_CERTIFICATE_SECRET_NAME_PEM="druid/tls/intermediate-ubuntu2204-fips"
```

czyli skrypt ignoruje drugi argument i zawsze pobiera ten secret.

### 2. Kopia wariantu BCFKS

Plik:

- [source/lib/uploads/scripts/setup_tls_certificates2204fips.bcfks.sh](/home/michalwisniewski/druid-adc202-git/source/lib/uploads/scripts/setup_tls_certificates2204fips.bcfks.sh:1)

Stan:

- zachowano kopię wcześniejszego wariantu `BCFKS`.

### 3. Uprawnienia IAM w CDK

Plik:

- [source/lib/stacks/druidEc2Stack.ts](/home/michalwisniewski/druid-adc202-git/source/lib/stacks/druidEc2Stack.ts:1)

Stan:

- dodano import ręcznie utworzonego secreta:
  - `druid/tls/intermediate-ubuntu2204-fips`
- rola EC2 dostaje dodatkowy `grantRead` do tego secreta,
- ale aktywne `TLS_CERTIFICATE_SECRET_NAME_PEM` w przepływie CDK nadal nie zostało globalnie przełączone na ten secret.

To znaczy:

- IAM do ręcznego secreta jest przygotowany,
- wybór właściwego secreta dla 22.04 FIPS został wymuszony lokalnie w shell skrypcie, nie w całym przepływie CDK.

## Utworzony secret

Secret został utworzony ręcznie:

- `Name`: `druid/tls/intermediate-ubuntu2204-fips`
- `ARN`: `arn:aws:secretsmanager:eu-central-1:041730370758:secret:druid/tls/intermediate-ubuntu2204-fips-510B99`

## Wyniki diagnostyki TLS

### 1. Keystore na nodzie 22.04 FIPS

Sprawdzenie `keytool -list -v` dla `keystore.jks` wykazało:

- alias `druid`
- `Entry type: PrivateKeyEntry`
- `Certificate chain length: 3`
- chain:
  - leaf: `CN=ip-10-120-30-194.eu-central-1.compute.internal`
  - intermediate: `CN=Druid Ubuntu 22.04 FIPS Intermediate CA, O=YourOrg`
  - root: `CN=Druid Internal CA`

SAN poprawne:

- DNS host FQDN
- DNS short hostname
- IP prywatne

### 2. Truststore na nodzie 22.04 FIPS

Sprawdzenie `truststore.jks` wykazało dwa aliasy:

- `druid-int-ca`
- `root-ca`

### 3. Test lokalny TLS na porcie overlorda

`openssl s_client` bez `CAfile` zwracał:

- `self-signed certificate in certificate chain`

To zostało uznane za normalne dla prywatnego CA.

Po eksporcie certów z `truststore.jks` do:

- `/tmp/root-ca.pem`
- `/tmp/druid-int-ca.pem`
- `/tmp/ca-chain.pem`

test:

```bash
openssl s_client -connect 127.0.0.1:8290 -servername ip-10-120-30-194.eu-central-1.compute.internal -CAfile /tmp/ca-chain.pem -verify_return_error
```

zwrócił:

- `Verification: OK`
- `Verify return code: 0 (ok)`

### 4. Test coordinator -> historical

Coordinator widzi historical:

```json
["ip-10-120-18-184.eu-central-1.compute.internal:8283"]
```

oraz:

```json
{"host":"ip-10-120-18-184.eu-central-1.compute.internal:8283","tier":"_default_tier","type":"historical","priority":0,"currSize":0,"maxSize":107374182400}
```

Test TLS z noda master do historical:

```bash
openssl s_client -connect ip-10-120-18-184.eu-central-1.compute.internal:8283 -servername ip-10-120-18-184.eu-central-1.compute.internal -CAfile /tmp/ca-chain.pem -verify_return_error
```

zwrócił:

- `Verification: OK`
- `Verify return code: 0 (ok)`

Test HTTP po TLS:

```bash
curl -v --cacert /tmp/ca-chain.pem -u "${DRUID_INTERNAL_CLIENT_USERNAME}:${DRUID_INTERNAL_CLIENT_PASSWORD}" https://ip-10-120-18-184.eu-central-1.compute.internal:8283/status
```

zwrócił:

- `SSL certificate verify ok.`
- HTTP `200 OK`

## Logi i obserwacje

### 1. Coordinator

W `coordinator.log` widać:

- coordinator działa
- historical jest widoczny
- `Tier[_default_tier] is serving [0] ... across [1] historicals`
- `Initialized run params ... with [0] used segments in [0] datasources`

To oznacza:

- coordinator widzi historical,
- ale aktualnie nie ma żadnych używanych segmentów do serwowania.

### 2. Brak błędów PKIX

Szukania po logach nie pokazały błędów typu:

- `PKIX`
- `SunCertPathBuilderException`
- `SSLHandshakeException`
- `ValidatorException`
- `unable to find valid certification path`

### 3. `Host does not match SNI`

W logach coordinatora występuje:

- `400: Host does not match SNI`

Wniosek z sesji:

- nie wygląda to na główną przyczynę problemu klastra,
- najpewniej jest efektem testów lub odpytania endpointu z niespójnym `Host` i `SNI`.

## Aktualny wniosek

Na koniec tej sesji najważniejszy wniosek był taki:

- problem nie wygląda już na problem TLS między coordinator a historical,
- chain, truststore i handshake działają poprawnie,
- coordinator widzi historical po HTTPS,
- ale klaster nadal nie ma segmentów:
  - `0 used segments`
  - `0 datasources`

Czyli aktualny problem wygląda bardziej na:

- brak danych / brak załadowanych segmentów / inny etap inicjalizacji klastra,
- a nie na błąd zaufania TLS w ścieżce coordinator <-> historical.

## Dodatkowa hipoteza po analizie deploymentu ALB

Z kodu deploymentu wynika:

- używany jest `ApplicationLoadBalancer`,
- ALB forwarduje ruch tylko do `query` nodes,
- target group używa:
  - `port: 8888`
  - `protocol: HTTPS`
  - `healthCheck.path: /status/health`

Źródła:

- [source/lib/stacks/druidEc2Stack.ts](/home/michalwisniewski/druid-adc202-git/source/lib/stacks/druidEc2Stack.ts:122)
- [source/lib/stacks/druidEc2Stack.ts](/home/michalwisniewski/druid-adc202-git/source/lib/stacks/druidEc2Stack.ts:823)
- [source/lib/stacks/druidEc2Stack.ts](/home/michalwisniewski/druid-adc202-git/source/lib/stacks/druidEc2Stack.ts:1031)

Wniosek pomocniczy:

- wcześniejsza diagnostyka TLS dotyczyła głównie portów wewnętrznych typu:
  - `8281`
  - `8283`
  - `8290`
- to nie jest jeszcze pełna diagnostyka ścieżki Web GUI przez load balancer.

Najbardziej prawdopodobna następna hipoteza:

- wewnętrzna komunikacja Druid <-> Druid działa,
- a problem GUI może siedzieć na ścieżce:
  - `client -> ALB`
  - `ALB -> query node :8888`

## Kluczowa obserwacja różnicowa 20.04 vs 22.04

Użytkownik potwierdził istotną rzecz operacyjną:

- gdy był co najmniej jeden `query` node na Ubuntu 20.04 FIPS,
- komunikacja działała,
- przez ten `query` node Web GUI za load balancerem pokazywało wszystkie nody klastra.

Wniosek:

- problem najpewniej nie jest już ogólnym problemem `internal TLS`,
- problem jest bardzo prawdopodobnie specyficzny dla `query` node na Ubuntu 22.04 FIPS,
- to dodatkowo wzmacnia hipotezę, że trzeba diagnozować przede wszystkim:
  - `query node :8888`
  - health check ALB
  - `Host` / `SNI`
  - zachowanie Jetty/Druid na query tier

Dodatkowa uwaga operacyjna:

- użytkownik nie ma praktycznej ścieżki do sprawdzenia Web GUI z pominięciem load balancera,
- dlatego dla problemu GUI kluczowa jest diagnostyka dokładnie tej ścieżki, która działa w produkcyjnym ruchu:
  - `client -> ALB -> query node :8888`
- skoro analogiczny dostęp działał wcześniej przy `query` node na Ubuntu 20.04 FIPS, to porównanie `20.04 vs 22.04` na query tier powinno być pierwszym krokiem kolejnej sesji.

Priorytet diagnostyki na kolejną sesję:

1. query node na Ubuntu 22.04 FIPS
2. ścieżka `ALB -> query node :8888`
3. health check `/status/health`
4. dopiero potem inne hipotezy

Rzeczy do sprawdzenia w kolejnej sesji pod ALB:

- [ ] czy query node lokalnie odpowiada poprawnie na `https://<query-host>:8888/status/health`
- [ ] jaki cert wystawia query node na porcie `8888`
- [ ] czy `Host` / `SNI` są zgodne przy ruchu do query node
- [ ] czy target group ALB widzi query node jako `healthy`
- [ ] czy problem z GUI nie wynika z rozjazdu `Host` header i `SNI` na wejściu przez LB

## Rzeczy do sprawdzenia w kolejnej sesji

1. Logi na nodzie `historical`:

- [ ] `tail -n 120 /home/druid-cluster/apache-druid/log/historical.log`

2. Czy inne role niż historical też poprawnie startują:

- [ ] broker
- [ ] router
- [ ] middleManager

3. Czy problem dotyczy tylko braku segmentów:

- [ ] sprawdzić, czy były ingestowane jakiekolwiek datasourcy
- [ ] sprawdzić status ingestion tasks
- [ ] sprawdzić metadata store pod kątem segmentów

4. Jeśli wrócimy do tematu TLS:

- [ ] rozważyć usunięcie tymczasowego hardcode secreta w skrypcie
- [ ] wrócić do bardziej czystego wyboru secreta przez TS/CDK

5. Jeśli wrócimy do tematu GUI / ALB:

- [ ] sprawdzić query node na porcie `8888`
- [ ] sprawdzić health check ALB `/status/health`
- [ ] sprawdzić czy targety w target group są healthy
- [ ] porównać zachowanie query node 20.04 FIPS vs 22.04 FIPS
