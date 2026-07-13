# Plan migracji TLS do intermediate PEM dla Ubuntu 22.04 FIPS

Ten dokument opisuje plan dalszych zmian dla aktualnego brancha `ADC202`. Ten branch ma częściowo wdrożoną obsługę Ubuntu 22.04 FIPS, ale nadal nie realizuje docelowego modelu:

- ręcznie przygotowany intermediate CA,
- bundle `tar.gz` w AWS Secrets Manager,
- leaf podpisywany przez intermediate,
- truststore zawierający root + intermediate,
- zgodność z rolling upgrade starego klastra.

Na tym etapie dokument pełni rolę:

- zaktualizowanej analizy stanu bieżącego,
- checklisty implementacyjnej,
- planu krok po kroku do późniejszego wdrożenia i weryfikacji,
- punktu wznowienia prac bez historii chatu.

## Cel

Dostosować obecną ścieżkę TLS dla Druid EC2 tak, aby:

- przestała korzystać z self-generated CA tworzonego przez obecną Lambdę,
- przestała używać PEM bundle w formacie `cert + encrypted key`,
- zaczęła używać ręcznie przygotowanego bundle `tar.gz` z:
  - `ca.cert.pem`
  - `druid-int22.cert.pem`
  - `druid-int22.key.pem`
- generowała leaf certificate na node i podpisywała go intermediate CA,
- tworzyła `keystore.bcfks` i `truststore.bcfks`,
- aktualizowała konfigurację Druid tak, by rzeczywiście używał `BCFKS`,
- pozwalała przeprowadzić rolling upgrade klastra do Ubuntu 22.04 FIPS.

## Aktualny stan brancha `ADC202`

### Co już jest

Status: `DONE`

Na tym branchu są już wdrożone elementy, których wcześniej nie było:

- osobna ścieżka bootstrap dla Ubuntu 22.04 FIPS w [source/lib/uploads/scripts/setup_tls_certificates2204fips.sh](/home/michalwisniewski/druid-adc202-git/source/lib/uploads/scripts/setup_tls_certificates2204fips.sh:1),
- warunkowe przełączenie skryptów w [source/lib/config/user_data/common_user_data](/home/michalwisniewski/druid-adc202-git/source/lib/config/user_data/common_user_data:97),
- drugi secret PEM obok legacy PKCS#12 w [source/lib/constructs/internalCertificateAuthority.ts](/home/michalwisniewski/druid-adc202-git/source/lib/constructs/internalCertificateAuthority.ts:23),
- generator TypeScript zapisujący dwa sekrety w [source/lib/lambdas/certificateGenerator.ts](/home/michalwisniewski/druid-adc202-git/source/lib/lambdas/certificateGenerator.ts:32),
- przekazywanie dwóch secret names do user-data w [source/lib/stacks/druidEc2Stack.ts](/home/michalwisniewski/druid-adc202-git/source/lib/stacks/druidEc2Stack.ts:196) i [source/lib/constructs/druidAutoScalingGroup.ts](/home/michalwisniewski/druid-adc202-git/source/lib/constructs/druidAutoScalingGroup.ts:200),
- generowanie `keystore.bcfks` i `truststore.bcfks` przez nowy skrypt 22.04.

### Co jest nadal błędne względem celu

Status: `OPEN`

Obecna implementacja 22.04 FIPS nadal nie spełnia wymagań dla intermediate CA:

- secret PEM jest nadal generowany automatycznie przez Lambdę, a nie dostarczany ręcznie,
- secret PEM ma zły format: `cert + encrypted private key`, a nie `tar.gz`,
- skrypt 22.04 podpisuje leaf bezpośrednio CA z secreta, bez intermediate chain,
- truststore 22.04 zawiera tylko jeden cert CA, a nie root + intermediate,
- runtime Druid nadal wskazuje `jks`, mimo że skrypt 22.04 buduje `bcfks`,
- cały flow EC2 nadal zależy od `InternalCertificateAuthority`, zamiast od zewnętrznego, ręcznie przygotowanego secreta przekazywanego przez TS/CDK.

## Założenia dla fazy 1

- `TLS_CERTIFICATE_SECRET_NAME_PEM` zostaje w interfejsie.
- Secret będzie istniał wcześniej i zostanie przygotowany ręcznie według [intermediateca.md](/home/michalwisniewski/druid-adc202-git/intermediateca.md:1).
- Secret będzie przechowywał `SecretBinary` w formacie `tar.gz`.
- Bundle będzie zawierał dokładnie:
  - `ca.cert.pem`
  - `druid-int22.cert.pem`
  - `druid-int22.key.pem`
- Nie projektujemy jeszcze centralnego signera.
- Nie wdrażamy jeszcze zmian w repo, tylko przygotowujemy spójny plan i komendy operacyjne.

## Ustalenie obowiązujące dla fazy 1

Status: `LOCKED`

Po doprecyzowaniu zakresu przyjmujemy:

- w fazie 1 nie hardcodujemy secret ID w `setup_tls_certificates2204fips.sh`,
- zachowujemy istniejący kontrakt:
  - TS/CDK przekazuje nazwę lub ARN secreta,
  - user-data przekazuje go do skryptu,
  - skrypt pobiera secret z AWS Secrets Manager,
- zmieniamy tylko:
  - źródło secretu PEM,
  - format secreta,
  - logikę skryptu 22.04 FIPS,
  - runtime TLS po stronie Druid.

Powód:

- pozwala to szybko uruchomić fazę 1,
- nie psuje przyszłej fazy 2,
- upraszcza powrót do modelu generowanego przez TS.

## Pliki i obszary objęte zmianą

### 1. Skrypt TLS dla Ubuntu 22.04 FIPS

Status: `TODO`

Plik główny:

- [source/lib/uploads/scripts/setup_tls_certificates2204fips.sh](/home/michalwisniewski/druid-adc202-git/source/lib/uploads/scripts/setup_tls_certificates2204fips.sh:1)

Co jest teraz:

- pobiera `SecretBinary` i zapisuje go jako pojedynczy blob,
- wyciąga z niego `ca.key` i `ca.cert.pem`,
- podpisuje leaf bezpośrednio tym CA,
- importuje tylko jeden CA do truststore.

Co trzeba zmienić:

- pobierać `SecretBinary` jako `tar.gz`,
- rozpakować trzy pliki:
  - `ca.cert.pem`
  - `druid-int22.cert.pem`
  - `druid-int22.key.pem`
- zwalidować wszystkie trzy pliki,
- pobierać też `LOCAL_HOSTNAME` i `LOCAL_IPV4` z IMDSv2,
- generować leaf keypair z SAN,
- generować CSR,
- podpisać leaf przez `druid-int22.key.pem` i `druid-int22.cert.pem`,
- zbudować chain:
  - leaf
  - intermediate
  - root
- utworzyć `keystore.bcfks` z aliasem `druid`,
- utworzyć `truststore.bcfks` z aliasami:
  - `root-ca`
  - `druid-int-ca`
- wyczyścić private key material po imporcie.

Najważniejsza zmiana semantyczna:

- nie używać już root `ca.key.pem` na node,
- nie używać formatu `cert + encrypted key`,
- używać intermediate CA jako podpisującego leaf.

### 2. User data bootstrap

Status: `PARTIAL`

Plik:

- [source/lib/config/user_data/common_user_data](/home/michalwisniewski/druid-adc202-git/source/lib/config/user_data/common_user_data:97)

Co już jest:

- istnieje poprawny rozjazd między:
  - Ubuntu 22.04 FIPS
  - resztą hostów

Co trzeba zmienić:

- podmienić źródło secretu PEM na ręcznie utworzony secret, ale bez zmiany interfejsu parametru,
- sprawdzić, czy interfejs skryptu ma dalej przyjmować secret name jako parametr,
- nie usuwać `TLS_CERTIFICATE_SECRET_NAME_PEM` w fazie 1.

Rekomendacja dla fazy 1:

- zostawić branching w user-data,
- nie przebudowywać logiki wykrywania OS/FIPS,
- ograniczyć zmiany do źródła secretu i semantyki skryptu 22.04.

### 3. Druid runtime TLS config

Status: `TODO`

Plik:

- [source/lib/uploads/config/_common/common.runtime.properties](/home/michalwisniewski/druid-adc202-git/source/lib/uploads/config/_common/common.runtime.properties:32)

Problem:

- konfiguracja runtime nadal wskazuje:
  - `keyStoreType=jks`
  - `trustStoreType=jks`
  - `keystore.jks`
  - `truststore.jks`

To jest niespójne z obecnym skryptem 22.04, który tworzy `bcfks`.

Co trzeba zmienić:

- `keyStoreType=BCFKS`
- `trustStoreType=BCFKS`
- ścieżki na `keystore.bcfks` i `truststore.bcfks`
- potwierdzić, czy trzeba dopisać konfigurację JVM/Druid, aby runtime potrafił otworzyć `BCFKS`.

Otwarte ryzyko:

- sam `keytool` nie wystarczy, jeśli proces Druid/JVM nie ma poprawnie skonfigurowanego providera BC FIPS.

### 4. Ścieżka CDK dla secretów TLS

Status: `TODO`

Pliki:

- [source/lib/constructs/internalCertificateAuthority.ts](/home/michalwisniewski/druid-adc202-git/source/lib/constructs/internalCertificateAuthority.ts:23)
- [source/lib/lambdas/certificateGenerator.ts](/home/michalwisniewski/druid-adc202-git/source/lib/lambdas/certificateGenerator.ts:24)
- [source/lib/stacks/druidEc2Stack.ts](/home/michalwisniewski/druid-adc202-git/source/lib/stacks/druidEc2Stack.ts:78)

Co już jest:

- dual-secret flow:
  - legacy PKCS#12,
  - nowy secret PEM

Co trzeba zmienić:

- odłączyć PEM flow od `InternalCertificateAuthority`,
- przestać generować PEM secret przez `certificateGenerator.ts`,
- zamiast tego podpiąć istniejący, ręcznie utworzony secret z AWS,
- nadal wypełniać `TLS_CERTIFICATE_SECRET_NAME_PEM`, ale już z ręcznie przygotowanego secreta,
- zostawić legacy PKCS#12 flow tylko dla starych hostów, jeśli nadal jest potrzebny.

Rekomendacja:

- nie usuwać od razu całego `InternalCertificateAuthority`,
- odłączyć od niego tylko ścieżkę 22.04 FIPS,
- zachować stary `TlsCertificate` dla legacy flow,
- usunąć lub zdeprecjonować `TlsCertificatePem` dopiero po zakończeniu fazy 1.

### 5. Generator TypeScript dla PEM secreta

Status: `TODO`

Plik:

- [source/lib/lambdas/certificateGenerator.ts](/home/michalwisniewski/druid-adc202-git/source/lib/lambdas/certificateGenerator.ts:32)

Co jest teraz:

- Lambda generuje:
  - PKCS#12 secret,
  - PEM bundle typu `cert + encrypted private key`

Co trzeba zmienić:

- przestać używać tego generatora dla ścieżki 22.04,
- nie nadpisywać ręcznie przygotowanego secreta intermediate CA,
- zaktualizować lub uprościć testy, bo obecny model testuje już niewłaściwy kontrakt.

### 6. IAM i dostęp do secreta

Status: `TODO`

Plik startowy:

- [source/lib/stacks/druidEc2Stack.ts](/home/michalwisniewski/druid-adc202-git/source/lib/stacks/druidEc2Stack.ts:104)

Co trzeba zmienić:

- upewnić się, że role EC2 mają `grantRead` do ręcznie utworzonego secreta,
- jeśli secret będzie importowany przez `fromSecretNameV2` lub `fromSecretCompleteArn`, jawnie nadać odczyt,
- sprawdzić, czy stary secret PEM generowany przez custom resource nie zostawia zbędnych uprawnień i zasobów.

## Komendy AWS do nadania dostępu dla EC2 do ręcznie utworzonego secreta

Status: `READY FOR MANUAL EXECUTION`

Te komendy są operacyjne i nie wymagają jeszcze zmian w repo.

### Wariant A: znasz nazwę roli EC2

1. Ustaw zmienne:

```bash
export AWS_REGION="<REGION>"
export SECRET_ARN="<SECRET_ARN>"
export ROLE_NAME="<EC2_INSTANCE_ROLE_NAME>"
export POLICY_NAME="AllowReadDruidIntermediateCaSecret"
```

2. Utwórz policy document:

```bash
cat > /tmp/druid-secret-read-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowReadSpecificSecret",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "__SECRET_ARN__"
    }
  ]
}
EOF
```

3. Podmień ARN:

```bash
sed -i "s|__SECRET_ARN__|$SECRET_ARN|g" /tmp/druid-secret-read-policy.json
```

4. Podepnij inline policy do roli:

```bash
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file:///tmp/druid-secret-read-policy.json \
  --region "$AWS_REGION"
```

5. Zweryfikuj:

```bash
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --region "$AWS_REGION"
```

### Wariant B: znasz stack, ale nie znasz nazwy roli

1. Ustaw zmienne:

```bash
export AWS_REGION="<REGION>"
export STACK_NAME="<CDK_STACK_NAME>"
export SECRET_ARN="<SECRET_ARN>"
```

2. Pobierz nazwę roli:

```bash
export ROLE_NAME="$(
  aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query "StackResources[?LogicalResourceId=='EC2InstanceRole'].PhysicalResourceId" \
    --output text
)"
```

3. Sprawdź wynik:

```bash
echo "$ROLE_NAME"
```

4. Następnie wykonaj kroki z wariantu A.

### Wariant C: chcesz sprawdzić, czy rola już ma dostęp

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>" \
  --action-names secretsmanager:GetSecretValue secretsmanager:DescribeSecret \
  --resource-arns "<SECRET_ARN>" \
  --region "<REGION>"
```

### Uwaga

To jest obejście operacyjne na fazę 1. Docelowo uprawnienie ma być nadawane przez CDK.

### 7. Rolling upgrade compatibility

Status: `TODO`

To jest nadal najważniejszy aspekt architektoniczny.

Docelowy stan:

- stare nody:
  - leaf podpisany przez root CA albo legacy CA,
  - truststore zawiera root CA i nowy intermediate CA
- nowe nody:
  - leaf podpisany przez intermediate CA,
  - keystore zawiera chain leaf + intermediate + root,
  - truststore zawiera root + intermediate

Wymagania praktyczne:

- zanim nowe nody 22.04 wejdą do klastra, stare nody muszą zaufać `druid-int22.cert.pem`,
- rolling upgrade może wymagać etapu przejściowego dla starych nodów,
- trzeba rozstrzygnąć, czy stare nody dostają:
  - tylko rozszerzony truststore,
  - czy także część nowych zmian runtime.

Najważniejsze ryzyko:

- obecne repo ma osobny skrypt 22.04, ale nie ma jeszcze strategii przejściowej dla wzajemnego trust między starymi i nowymi nodami.

### 8. Testy i weryfikacja

Status: `TODO`

Na tym etapie nie uruchamiamy testów, ale plan weryfikacji powinien objąć:

- poprawność rozpakowania `tar.gz`,
- walidację root/intermediate/intermediate-key,
- poprawność chain w `keystore.bcfks`,
- obecność `root-ca` i `druid-int-ca` w `truststore.bcfks`,
- zgodność runtime Druid z `BCFKS`,
- handshake:
  - old -> new
  - new -> old
  - new -> new
- logi Druid i supervisor pod kątem błędów `PKIX`, `certificate_unknown`, `handshake_failure`.

## Kolejność wdrożenia

### Etap A. Przygotowanie materiału CA

Status: `READY`

Kroki:

- wygenerować intermediate CA na Ubuntu 22.04 FIPS,
- podpisać go root CA na Ubuntu 20.04 FIPS,
- spakować bundle,
- umieścić bundle w AWS Secrets Manager.

Instrukcja operacyjna:

- [intermediateca.md](/home/michalwisniewski/druid-adc202-git/intermediateca.md:1)

### Etap B. Przerobienie istniejącej ścieżki 22.04 FIPS

Status: `TODO`

Kroki:

- przepisać `setup_tls_certificates2204fips.sh` na `tar.gz + intermediate + chain`,
- przestać używać `cert + encrypted key`,
- zapewnić root + intermediate w truststore,
- dodać SAN do leaf certów,
- utrzymać zgodność z FIPS provider flow.

### Etap C. Odłączenie auto-generated PEM secreta

Status: `TODO`

Kroki:

- odłączyć `TlsCertificatePem` od EC2 22.04 flow,
- wstawić ręcznie utworzony secret jako źródło `TLS_CERTIFICATE_SECRET_NAME_PEM`,
- nadać `grantRead`,
- przestać polegać na Lambdzie dla secretu PEM.

### Etap D. Spójność runtime Druid

Status: `TODO`

Kroki:

- zmienić runtime config z `JKS` na `BCFKS`,
- sprawdzić wymagania providera BC FIPS po stronie JVM,
- potwierdzić, że Druid naprawdę uruchomi się z tym store formatem.

### Etap E. Plan przejściowy dla rolling upgrade

Status: `TODO`

Kroki:

- przygotować trust do intermediate na starych node'ach,
- określić kolejność restartów lub wymiany node'ów,
- sprawdzić kompatybilność mieszanej grupy starych i nowych hostów.

### Etap F. Weryfikacja

Status: `TODO`

Kroki:

- zweryfikować store'y i chain na nowym node,
- przejrzeć logi,
- zrobić test w środowisku nieprodukcyjnym,
- dopiero potem przejść do rolling replacement.

## Minimalny zakres zmian w kodzie przy wdrożeniu

Na tym branchu minimalny zakres zmian nieco się zmienił. Najważniejsze pliki to teraz:

- [source/lib/uploads/scripts/setup_tls_certificates2204fips.sh](/home/michalwisniewski/druid-adc202-git/source/lib/uploads/scripts/setup_tls_certificates2204fips.sh:1)
- [source/lib/uploads/config/_common/common.runtime.properties](/home/michalwisniewski/druid-adc202-git/source/lib/uploads/config/_common/common.runtime.properties:32)
- [source/lib/stacks/druidEc2Stack.ts](/home/michalwisniewski/druid-adc202-git/source/lib/stacks/druidEc2Stack.ts:78)

Prawdopodobnie także:

- [source/lib/config/user_data/common_user_data](/home/michalwisniewski/druid-adc202-git/source/lib/config/user_data/common_user_data:97)
- [source/lib/constructs/internalCertificateAuthority.ts](/home/michalwisniewski/druid-adc202-git/source/lib/constructs/internalCertificateAuthority.ts:23)
- [source/lib/lambdas/certificateGenerator.ts](/home/michalwisniewski/druid-adc202-git/source/lib/lambdas/certificateGenerator.ts:24)
- [source/lib/lambdas/certificateGenerator.test.ts](/home/michalwisniewski/druid-adc202-git/source/lib/lambdas/certificateGenerator.test.ts:1)

Legacy plik [source/lib/uploads/scripts/setup_tls_certificates.sh](/home/michalwisniewski/druid-adc202-git/source/lib/uploads/scripts/setup_tls_certificates.sh:1) nadal może wymagać korekty, ale nie jest już głównym punktem wejścia dla Ubuntu 22.04 FIPS.

## Decyzje do potwierdzenia przed implementacją

Status: `OPEN`

1. Jaka dokładnie nazwa lub ARN ręcznie utworzonego secreta ma zostać użyta w fazie 1.
2. Czy `TlsCertificatePem` ma zostać całkiem usunięty, czy tylko odłączony od ścieżki 22.04 po zakończeniu fazy 1.
3. Gdzie dokładnie na instancji znajduje się `bc-fips-2.1.2.jar`.
4. Czy Druid/JVM wymaga dodatkowej konfiguracji providera do odczytu `BCFKS`.
5. Jak dokładnie ma wyglądać etap przejściowy dla starych nodów w rolling upgrade.
6. Czy stary truststore ma być aktualizowany jeszcze w `JKS`, czy również przenoszony na `BCFKS`.

## Ocena spójności po przygotowaniu planu

Status: `CONSISTENT WITH ONE IMPORTANT OPEN RISK`

Całość jest spójna, jeśli przyjmujemy następujący model fazy 1:

- ręcznie tworzony secret istnieje wcześniej,
- jego nazwa lub ARN jest nadal przekazywana przez `TLS_CERTIFICATE_SECRET_NAME_PEM`,
- nowy skrypt 22.04 pobiera `tar.gz` i pracuje na root + intermediate + intermediate key,
- legacy flow dla starych hostów nadal działa niezależnie,
- runtime Druid zostanie doprowadzony do zgodności z `BCFKS`.

To jest spójne, bo:

- nie zrywa obecnego interfejsu między TS, user-data i skryptem shell,
- pozwala szybko podmienić tylko źródło secreta i logikę 22.04,
- nie blokuje późniejszej fazy 2 z pełnym generowaniem przez TS.

Najważniejsze otwarte ryzyko:

- nadal nie ma potwierdzenia, że runtime Java/Druid na hostach 22.04 poprawnie otworzy `BCFKS` bez dodatkowej konfiguracji providera BC FIPS.

Wniosek:

- plan jest spójny architektonicznie,
- największy punkt ryzyka nie dotyczy modelu secreta, tylko integracji `BCFKS` z runtime JVM/Druid.

## Checklist do odhaczania później

- [x] Opisać ręczną procedurę wygenerowania i podpisania intermediate CA.
- [x] Opisać pakowanie do `tar.gz` i wrzucenie do AWS Secrets Manager.
- [x] Zaktualizować plan pod realny stan brancha `ADC202`.
- [x] Ustalić, że w fazie 1 zachowujemy `TLS_CERTIFICATE_SECRET_NAME_PEM`.
- [x] Dopisać operacyjne komendy AWS do nadania dostępu do secreta.
- [ ] Przepisać `setup_tls_certificates2204fips.sh` na model intermediate bundle.
- [ ] Zmienić runtime Druid z `JKS` na `BCFKS`.
- [ ] Odłączyć auto-generated PEM secret od ścieżki EC2 22.04.
- [ ] Uzupełnić uprawnienia IAM dla ręcznego secreta.
- [ ] Przygotować plan przejściowy dla rolling upgrade.
- [ ] Wykonać testy i walidację środowiskową.
