# Weryfikacja NetUnstick — 27–29 września 2026

Host: macOS 25.6.0, Apple Silicon arm64, Xcode 27.0, Swift 6.4. Komendy `xcodebuild` wykonano z katalogu repozytorium, a `swift test` z `Packages/NetUnstickKit`. Naprawy systemu hosta nie były wykonywane. Testy napraw używały wyłącznie wstrzykniętych granic systemowych. Logi i wyniki `.xcresult` są lokalnymi produktami testów ignorowanymi przez Git; podane komendy pozwalają je odtworzyć.

## Build i pakowanie

| Sprawdzenie | Wynik |
| --- | --- |
| `xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath Artifacts/DerivedData CODE_SIGNING_ALLOWED=NO clean build` | Kod 0, `BUILD SUCCEEDED`. Ponowny build w głównym katalogu repozytorium przeszedł 28 września. |
| `xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath Artifacts/SignedDerivedData CODE_SIGNING_ALLOWED=YES build` | Kod 0, `BUILD SUCCEEDED`. |
| `xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -showBuildSettings` | `ARCHS = arm64`, `MACOSX_DEPLOYMENT_TARGET = 14.0`, `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. `file` potwierdził Mach-O arm64. `Info.plist` wskazuje `AppIcon`, deklaruje tylko `_airplay._tcp` i `_raop._tcp` oraz `NSLocalNetworkUsageDescription`; nie ma `LSUIElement`, a aplikacja otwiera zwykłe okno. |
| `NetUnstick/TestSupport/check-helper-bundle.sh` na obu zbudowanych aplikacjach; podpisany wariant z `--require-stable-signing` | Kod 0. Helper arm64, LaunchDaemon plist, usługa XPC i wymaganie podpisu klienta są osadzone; zgodność podpisów app/helper potwierdzona. Nie rejestrowano helpera na hoście. |

## Testy

| Komenda / obszar | Wynik |
| --- | --- |
| `TMPDIR="$PWD/../../Artifacts/tmp" swift test` | 20 testów Repair, 42 Network, 11 Core; 0 błędów. Trzy testy środowiskowe pominięte przez warunki testów. Pełny pakiet przeszedł ponownie 28 września. |
| `xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath Artifacts/DerivedData -parallel-testing-enabled NO -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | 10 testów integracji i prezentacji, 0 błędów; ponownie przeszły 28 września. |
| `xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath Artifacts/UITestDerivedData -parallel-testing-enabled NO -only-testing:NetUnstickUITests CODE_SIGNING_ALLOWED=YES test` | Kod 0, 9 testów, 0 błędów; pełny przepływ i 11 załączników wizualnych. Ponowny przebieg w głównym katalogu repozytorium przeszedł 28 września. |
| `NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter ReadOnlySmokeTests` | Kod 0, 1 test przeszedł; powstał wyłącznie zredagowany JSON w `.build`. |
| `NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter HostDiagnosisSmokeTests` | Kod 0, 1 test przeszedł; kolektor i checki obserwowały host bez zmian. |
| `NETUNSTICK_BONJOUR_LIVE=1 swift test --filter BonjourDiscoveryTests/testLocalAdvertiserHarness` | 28 września: kod 0, 1 test przeszedł, 0 pominiętych. Lokalny `NWListener` osiągnął stan `ready`, kontrolny `NWBrowser` odnalazł usługę testową o unikatowej nazwie, a `SystemBonjourBrowser` wykrył typ `_airplay._tcp`. Poprzednia próba z 27 września była pominięta po `POSIX EINVAL (22)`; błąd ustąpił po dodaniu brakującego `newConnectionHandler` do testowego listenera. Test nie dowodzi wykrycia zewnętrznego odbiornika AirPlay. |

## Macierz granic systemowych

| ID | Scenariusz | Dowód deterministyczny |
| --- | --- | --- |
| V-01 | Zdrowa sieć | `DiagnosisEngineTests.testHealthySnapshotHasNoCandidates`, `CompositionIntegrationTests.testRealCompositionStreamsChecksPersistsSessionAndRedactsReport`, XCUITest `testRealCompositionWithFakeSystemBoundary`. |
| V-02 | DNS residue | `DiagnosticChecksTests.testRouteLeaseProxyAndResolverDecisionTable`, `FortinetScenarioTests.testResidueAndInfrastructureNeedComparison`, XCUITest `dns-residue`. Po usunięciu globalnego flush dostępne jest odczytowe ponowienie sprawdzenia i wskazówka administratora. |
| V-03 | Stale local route | `DiagnosticChecksTests.testRouteLeaseProxyAndResolverDecisionTable`, `RepairCatalogTests.testMissingTunnelRouteIsUnknownAndCannotCrossHelperPolicy`, `testDisconnectedTunnelShadowingLANOffersOneConfirmedRepair`, `RepairPolicyTests.testDisconnectedVPNAllowsOnlyProvenSingleLocalTunnelRoute`, `PrivilegedExecutorTests.testResidualUnscopedTunnelRouteUsesExactUnscopedDeleteAndRequiresObservation`, `RepairHarnessTests.testResidualRouteRepairRequiresRemovalAndRecheckDespiteTunnelSignal`. Tylko jedna nieskopowana trasa, nakładająca się na aktywną sieć lokalną po potwierdzonym rozłączeniu usług VPN, może być kandydatem. |
| V-04 | Bonjour permission denied / zero urządzeń | `BonjourDiscoveryTests.testPermissionAndBrowserFailuresStayDistinct`, `testCountsOnlyAndNoServicesIsInconclusive`, XCUITest `testDeniedBonjourAndMissingReceiverAreEnvironmentOutcomes`. |
| V-05 | Fortinet managed policy | `FortinetScenarioTests.testSplitFullAndLocalLANBlockedRemainHypotheses`, `RepairCatalogTests.testVPNAndProxyDoNotOfferChanges`; wyłącznie wskazówka kontaktu z administratorem. |
| V-06 | VPN active / unknown | `RepairHarnessTests.testOutcomeMatrixUsesOnlyFakes`, `CompositionIntegrationTests.testStaleCandidateCannotChangeNetworkAfterVPNBecomesActiveOrUnknown`; zwykłe akcje nie wywołują helpera. Wyjątek V-03 wymaga dodatkowego dowodu rozłączenia usługi VPN i dokładnej, niezmienionej trasy. |
| V-07 | Helper approval / denied | `PrivilegedRequestClientTests.testSuccessDisconnectPermissionAndTimeout`, `RepairHarnessTests.testOutcomeMatrixUsesOnlyFakes`, XCUITest ustawień i odmowy. Bez oczekiwania na systemowe zatwierdzenie. |
| V-08 | Exit 0 + nieudany recheck / sukces po rechecku | `RepairHarnessTests.testOutcomeMatrixUsesOnlyFakes`, `testReadOnlyRetryAndDHCPRecheckAndHelperBoundary`, `CompositionIntegrationTests.testConfirmedPrivilegedPlanPersistsOnlyRecheckedSuccess`. |
| V-09 | Timeout / anulowanie | `RepairHarnessTests.testOutcomeMatrixUsesOnlyFakes`, `DiagnosticChecksTests.testConcurrentCancellationReturnsCancelled`, XCUITest `testCancelAndKeyboardShortcut`. |
| V-10 | Eksport po redakcji | `PrivacyAndStoreTests.testSensitiveValuesAbsentFromLoggableAndExportedText` sprawdza Logger record, podgląd, UTF-8 i plik sesji dla fikcyjnych SSID, Apple TV, IP publicznego/prywatnego, domeny, ścieżki, tokenu i stdout; XCUITest sprawdza podgląd i standardowy dialog zapisu. |

## Audyt bezpieczeństwa i prywatności

Przegląd wszystkich miejsc użycia `Process()` w źródłach Swift wykazał stałe ścieżki programów i tablice argumentów, bez `/bin/sh`, `/bin/zsh`, `system()` lub `popen()`. Kolektor używa poleceń tylko odczytowych; helper dopuszcza jedynie dokładną składnię usunięcia jednej zweryfikowanej trasy oraz API `SCNetworkInterfaceForceConfigurationRefresh` dla pojedynczego interfejsu DHCP. Żądanie globalnego czyszczenia cache pozostało w wersjonowanym enumie XPC dla zgodności dekodowania, ale `RepairPolicy` odrzuca je; kod nie wykonuje `dscacheutil`, `killall` ani restartu mDNSResponder. Walidacja VPN jest ponawiana przed zmianą. Testy dowodzą limitu czasu, wyjścia i braku pętli ponawiania.

Fixture prywatności przechodzi przez typowaną redakcję, magazyn sesji, renderer podglądu/eksportu i tekst rekordu Logger. UI szczegółów technicznych bierze wyłącznie `SafeEvidence` oraz stabilne kody błędów; XCUITest sprawdza brak przykładowej domeny i IP. Skan repozytorium nie wykazał poświadczeń ani prywatnych eksportów; wystąpienia wzorców typu `token` w testach są fikcyjnymi wartościami sprawdzającymi redakcję. Telemetrii i wysyłki w tle nie ma.

## UI, ikona i ograniczenia środowiskowe

XCUITest używa samokończącego się harnessu: uruchamia aplikację Debug z deterministycznym scenariuszem, otwiera standardowe okno także po przywróceniu przez macOS sesji bez okna, sprawdza identyfikatory dostępności, nawigację klawiaturą, diagnostykę, potwierdzenie, recheck, aktywność, podgląd i dialog zapisu, a następnie kończy proces. Załączniki XCTest dokumentują główne ekrany w jasnym/ciemnym motywie, zwiększonym kontraście, dużym tekście i z wyłączonymi animacjami transakcji SwiftUI. Ten ostatni tryb jest deterministyczną flagą Debug; systemowego ustawienia Reduce Motion nie zmieniano. Wizualną inspekcję załączników i `Artifacts/Verification/ui-contact-sheet.png` wykonano; duży tekst zmienia rozmiar i zawijanie treści, bez nakładania kontrolek. Zbudowana aplikacja z AppIcon została uruchomiona w GUI, a natywne zrzuty Dock i Findera wykonane i obejrzane: `Artifacts/Verification/dock-icon.png`, `Artifacts/Verification/finder-icon.png`. Testy zasobu ikony sprawdzają rozmiary i sylwetkę; `Design/AppIcon/Generated/ContactSheet.png` pokazuje warianty.

Do 28 września live naprawa, rzeczywista rejestracja helpera oraz zatwierdzenie administratora nie były testowane. Bez rzeczywistego porównania przed/po żadnej naprawy nie nazywamy potwierdzoną skuteczną naprawą. Live Bonjour z lokalną usługą testową przeszedł 28 września po naprawie konfiguracji testowego listenera; nadal nie potwierdza obecności ani działania zewnętrznego odbiornika AirPlay. Zgody na nagrywanie ekranu i dostępność procesu uruchamiającego były nadane; zrzuty natywne powstały poprawnie.

## Obserwacja hosta i próba naprawy — 29 września 2026

Po rozłączeniu FortiClient skonfigurowana usługa VPN zgłaszała `disconnected`, lecz tablica tras zawierała nieskopowane (`UGSc`, bez flagi `I`) trasy lokalnej podsieci przez `utun4`. Odkryty Mac Studio był osiągalny na kontrolowanych portach TCP po wymuszeniu fizycznego interfejsu `en0`, a te same próby bez wymuszenia interfejsu kończyły się limitem czasu. To wskazuje na konflikt tras; samo wykrycie usługi Bonjour nie stanowiło dowodu połączenia. Odczytowy test `NETUNSTICK_ROUTE_LIVE=1` przeszedł przed zmianą obsługi flagi zakresu trasy. Po tej zmianie ponowiony test zawisł w procesie XCTest i został przerwany bez wyniku; bezpośredni odczyt `netstat` nadal pokazał nieskopowaną trasę. Testy deterministyczne parsera, kwalifikacji trasy, polecenia helpera i sprawdzenia po naprawie przeszły. Podpisany build macOS oraz `check-helper-bundle.sh --require-stable-signing` zakończyły się kodem 0.

Sterownik pulpitu `abc-desktop` uruchomił podpisaną aplikację i odczytał jej okno oraz obraz. Diagnostyka w aplikacji wskazała `localRouteViaTunnel` i jednego kandydata do naprawy. W arkuszu potwierdzenia sterownik nie potrafił przypisać aktywnego okna do drzewa dostępności (`Nie można jednoznacznie powiązać okna z drzewem dostępności`), dlatego kliknięcie wykonania nie doszło do skutku. Helpera nie zarejestrowano, trasy nie zmieniono i nie wykonano testu Mac Studio po naprawie. Kwalifikacja kandydata oraz testy z atrapą helpera nie dowodzą jeszcze skuteczności rzeczywistej naprawy.
