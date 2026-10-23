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

## Naprawa na żywo — 29 września 2026, wieczór

Stan wyjściowy hosta: skonfigurowana usługa VPN FortiClient zgłaszała `disconnected`, ale dwa osierocone procesy `fct_tunnel_ctl` (uruchomione 26 i 28 września) trzymały dwa interfejsy `utun` z adresami routowalnymi, a tablica tras zawierała osiem nieskopowanych wpisów `UGSc` przez starszy z nich: binarny podział lokalnej sieci `/24` z wyłączoną bramą (`/32`, `/31`, `/30`, `/29`, `/28`, `/27`, `/26`, `/25`). Internet działał; próby TCP do drugiego komputera Mac w sieci lokalnej (SMB, AFP, VNC, SSH) kończyły się limitem czasu, a `route get` do sąsiada wskazywał tunel. Trzynaście interfejsów `utun` z samym adresem link-local IPv6 należało do usług systemowych; dynamic store rejestrował ich stan IPv6, co poprzednia wersja detektora liczyła jako sygnał VPN.

Zmiany: wspólny parser prefiksów `IPPrefix` z formami skróconymi netstat; klasyfikacja tuneli `TunnelSignals` (systemowe `utun` bez znaczenia dla VPN); detektor VPN i kontrole liczą tylko trasy przekazujące, pomijają wpisy sklonowane, multicast i link-local; kontrola `local_subnet_route` wykrywa każdą bardziej szczegółową trasę przez interfejs niefizyczny wewnątrz połączonej sieci, mimo że własny wpis `/32` hosta pozostaje fizyczny; grupowa naprawa `removeStaleTunnelRoutes` (protokół helpera w wersji 2, limit 24 wpisów, zbiór musi być identyczny z zaobserwowanym); odczyt stanu usług VPN przez `scutil --nc list`; ograniczone czasowo obserwacje i logowanie faz w helperze; wyjście daemona po minucie bezczynności; przycisk „Wyrejestruj helper”; potwierdzenie naprawy jako panel w oknie zamiast arkusza; uruchamianie procesów potomnych przez źródło kqueue i `waitid`/`waitpid`.

| Krok | Wynik |
| --- | --- |
| `swift test` (pakiet, z `NETUNSTICK_READ_ONLY_SMOKE=1`) | Wszystkie zestawy przeszły; testy na żywo pomijane bez zmiennych. Test 48 równoległych krótkich poleceń przechodzi po przepisaniu wykonawcy procesów; wcześniej pełny zestaw zawieszał się w `Process.waitUntilExit` pod obciążeniem, próbka stosu pokazała oczekiwanie na `mach_msg` bez żyjącego potomka. |
| Build podpisany + `check-helper-bundle.sh --require-stable-signing` | `BUILD SUCCEEDED`, kontrola pakietu ok, pakiet skopiowany do `~/Applications`. |
| `-only-testing:NetUnstickUITests/PresentationUITests` | 9 testów, 0 błędów, z panelem potwierdzenia w oknie. |
| `-only-testing:NetUnstickPresentationTests` | 5 testów, 0 błędów. |
| Rejestracja helpera | `register()` dał stan wymagający zgody; użytkownik włączył element w Elementach logowania (jednorazowo). Baza elementów tła: daemon `enabled`; launchd uruchamia go na żądanie. Stary uchwyt `SMAppService` w procesie pokazywał nieaktualny stan do ponownego uruchomienia aplikacji; klient tworzy teraz uchwyt przy każdym zapytaniu. |
| Próba 1 (helper w wersji sprzed zmian) | Helper uruchomiony przez launchd nie odpowiedział: bez procesów potomnych, 0% CPU, po 70 s klient zgłosił `timedOut`, trasy bez zmian. Ten sam objaw co zawieszenie testów; przyczyną był zgubiony sygnał zakończenia potomka w `waitUntilExit`. |
| Próby 2 i 3 (harness XCUITest po identyfikatorze pakietu) | XCTest uruchomił kopię aplikacji z `Artifacts/UITestDerivedData` pod `Documents`; jej rejestracja trafiła do bazy elementów tła jako „pending authorization”, a macOS zabił helper przy starcie: `SIGKILL (Code Signature Invalid)`, `CODESIGNING` kod 4 „Launch Constraint Violation”, `launchctl` pokazywał `needs LWCR update`, kod wyjścia 78. Wniosek: daemon musi pochodzić z kopii zainstalowanej w katalogu Aplikacje użytkownika, a harness musi wskazywać ją ścieżką. |
| Próba 4 (harness ze ścieżką `~/Applications`) | Wyrejestrowanie usunęło zadanie z launchd, rejestracja utworzyła je bez nowej zgody (`Dostępny`). Diagnostyka zaproponowała „Usunięcie tras pozostałych po VPN (8)”, panel potwierdzenia wykonał naprawę: fazy `revalidate`, `fresh_vpn`, `before_snapshot`, `helper_request` (count 8), `settle`, `after_snapshot`, `recheck` (`healthy`), wynik `success`; UI: „Naprawiono — ponowny check potwierdził poprawę”. Test harnessu przeszedł w 15 s. |
| Stan po naprawie | Osiem wpisów przez tunel zniknęło; pozostał tylko własny wpis hosta tunelu. Połączona sieć `/24` na fizycznym interfejsie nienaruszona. `route get` do sąsiada wskazuje fizyczny interfejs. Ping do drugiego Maca 2/2. TCP: SMB 445, VNC 5900 i SSH 22 otwarte przez zwykły routing; AFP 548 odrzucone (usługa nieoferowana). Bez restartu komputera. |
| Diagnoza po naprawie | `local_subnet_route` zdrowy, `resolver_configuration` zdrowy, `interface_consistency` = `orphanedTunnel` (dwa pozostałe tunele klienta VPN z adresami, bez tras), VPN `unknown`/`residualTunnel`; wskazówka: zamknij i uruchom ponownie klienta VPN. Systemowe `utun` sklasyfikowane jako systemowe (13 z 15). |
| Helper po naprawie | Zakończył się kodem 0 po minucie bezczynności; `launchctl` pokazuje `not running`. |

Ograniczenia: aplikacja nie kończy procesów klienta VPN, więc osierocone tunele pozostają, a kolejna sesja VPN może ponownie zostawić trasy; naprawę należy wtedy powtórzyć. Rekord bazy elementów tła dla kopii z DerivedData pozostał w stanie oczekiwania na zgodę i nie jest używany. Łączność sprawdzono na poziomie ICMP i TCP, nie przez montowanie udziału w Finderze. Test `NETUNSTICK_ROUTE_LIVE=1` jest pomijany, gdy host nie ma już pozostałych tras.

## Prezentacja stanu po naprawie — 29 września 2026, późny wieczór

Po naprawie użytkownik zgłosił sprzeczny ekran: wszystkie kontrole „Bez problemu” poza `interface consistency` („Pozostał interfejs tunelowy bez aktywnego połączenia”), a nagłówek „Stan sieci nieznany”, linia „Stan VPN niepewny” i wynik „Rozłącz VPN lub potwierdź jego stan” mimo rozłączonej usługi VPN; pod przyciskiem wisiała surowa etykieta `success` z poprzedniej naprawy. Odtworzono to sterownikiem pulpitu na działającej aplikacji (diagnostyka uruchomiona przez most, drzewo dostępności potwierdziło te teksty).

Przyczyna: prezentacja traktowała każdy stan VPN inny niż `inactive` jak nieznany, a detektor celowo zwraca `unknown`/`residualTunnel` dla nieaktywnych interfejsów tunelowych pozostawionych przez klienta VPN. Zmiana: `PresentationStore` zna teraz stan skonfigurowanych usług VPN (`vpnServices`) z ostatniej obserwacji; gdy usługa zgłasza rozłączenie, przyczyną niepewności jest wyłącznie pozostały tunel, a jedyną nieudaną kontrolą jest `interface_consistency` z kodem `orphanedTunnel`, ekran pokazuje stan „Sieć działa, pozostały ślady VPN” z wynikiem i krokiem opisującym, że sieć lokalna działa, a zwykłe naprawy pozostają zablokowane do zniknięcia interfejsów. Linia stanu VPN nazywa przyczynę niepewności (pozostały tunel, zmiana ścieżki, niepełny odczyt, sprzeczne sygnały). Fazy naprawy są pokazywane po polsku w trakcie działania i znikają po wyniku; teksty „symulowane kontrole” zastąpiono neutralnymi.

| Sprawdzenie | Wynik |
| --- | --- |
| `PresentationStoreTests.testLeftoverTunnelAfterConfirmedDisconnectIsNotAnUnknownNetwork` | Przeszedł: usługa rozłączona + `residualTunnel` + jedyna nieudana kontrola `orphanedTunnel` daje stan `residual`; scenariusz `vpn-unknown` nadal daje `unknown`. Cały zestaw `NetUnstickPresentationTests`: 0 błędów. |
| Testy UI `testConfirmedRepairRequiresSuccessfulRecheck`, `testRealCompositionWithFakeSystemBoundary`, `testActiveAndUnknownVPNExplainBlockedChange`, `testNavigationDetailsRepairAndReport` | 4 testy, 0 błędów; po nieudanej naprawie nie zostaje surowa etykieta fazy. |
| Build podpisany, `check-helper-bundle.sh --require-stable-signing`, cdhash helpera | `BUILD SUCCEEDED`; cdhash helpera bez zmian, więc zadanie launchd pozostało ważne (`state = not running`, ostatni kod wyjścia 0). Nowa wersja zainstalowana w `~/Applications` i uruchomiona. |
| Diagnoza hosta (test dymny) | `vpnServices=disconnected`, VPN `unknown/residualTunnel`, jedyna nieudana kontrola `interface_consistency/orphanedTunnel` — dokładnie warunki, które nowa prezentacja mapuje na stan „Sieć działa, pozostały ślady VPN”. |

Ograniczenie: oględziny nowego nagłówka w oknie nie zostały wykonane przez sterownik pulpitu, bo użytkownik zatrzymał sterowanie klawiszem Escape; mapowanie warunków hosta na nowy stan potwierdza test jednostkowy z identycznymi wejściami.

## Dystrybucja DMG i aktualizacja w miejscu — 29 września 2026, noc

| Sprawdzenie | Wynik |
| --- | --- |
| `Tools/BuildDMG.sh` | Release arm64 z tożsamością „NetUnstick Local Code Signing”: `BUILD SUCCEEDED`, `check-helper-bundle.sh --require-stable-signing` ok, obraz `Artifacts/Distribution/NetUnstick-0.2.0-2.dmg` (UDZO, HFS+, skrót do `/Applications`) podpisany tą samą tożsamością; po zamontowaniu `codesign --verify --deep --strict` aplikacji i helpera przeszły, wersja z obrazu zgodna z buildem. |
| `swift test` (pakiet) | Wszystkie zestawy przeszły, w tym handshake helpera bez obserwacji i bez poleceń, odrzucenie handshake przez politykę napraw oraz limity czasu klienta. |
| `NetUnstickPresentationTests` | 11 testów, 0 błędów. Testy UI `testHelperApprovalAndLimitedEnvironmentRemainUsable` i `testKeyboardNavigationAndIdentifiers`: 0 błędów. |
| Aktualizacja w miejscu (`~/Applications`, Debug 0.1.0 build 1 → Release 0.2.0 build 2, inny cdhash helpera) | Przy pierwszym połączeniu po uruchomieniu launchd zabił nowy helper: `CODESIGNING` kod 4 „Launch Constraint Violation” (raport z 21:03:47). Aplikacja odświeżyła własną rejestrację: zadanie launchd ma teraz `parent bundle version = 2`, daemon uruchomił się i działał (`state = running`), a baza elementów tła nadal pokazuje `enabled, allowed` bez nowego pytania o zgodę. Użytkownik nie wykonał żadnego kroku. |

Wniosek: przy stałej tożsamości zgody TCC i zatwierdzenie elementu tła są zachowywane między aktualizacjami, a jedyny element wymagający odświeżenia (wymaganie kodu daemona w launchd) aplikacja odświeża sama przy starcie. Wpisy `Logger` aplikacji nie były widoczne w `log show` dla tego użytkownika; dowodem są raport awarii, stan zadania launchd i baza elementów tła.

## Ostylowany obraz instalacyjny — 29 września 2026, noc

`Tools/BuildDMG.sh --skip-build` złożył `Artifacts/Distribution/NetUnstick-0.2.0-2.dmg` z tłem 660×400 pt (1× i 2× w jednym TIFF), ikonami 128 pt, aplikacją w lewym polu, skrótem do `/Applications` w prawym, ukrytym paskiem narzędzi i ikoną aplikacji jako ikoną wolumenu; obraz jest podpisany i zweryfikowany po zamontowaniu (podpisy, wersja, `.DS_Store`, tło, ikona wolumenu). Zrzut okna Findera z gotowego obrazu: `Artifacts/Verification/dmg-window.png`.

Dwie pułapki ustalone doświadczalnie na obrazach próbnych: `hdiutil create -srcfolder` pomija plik `.VolumeIcon.icns` z katalogu źródłowego, a Finder podczas zapisywania układu (`open`, `update`) usuwa ten plik i czyści flagę własnej ikony wolumenu. Dlatego skrypt kopiuje ikonę i ustawia flagę dopiero po zakończeniu skryptu Findera, a przed odmontowaniem; po ponownym zamontowaniu plik, flaga i `.DS_Store` były obecne. Punkt montowania obrazu roboczego jest odczytywany z `hdiutil attach -plist`, bo tekstowe wyjście nie ma stabilnych separatorów. Okno ma wysokość 430 pt, żeby cały obraz tła był widoczny pod paskiem tytułu.

## Drugi Mac i spójność interfejsów; druga aktualizacja w miejscu — 29 września 2026, noc

Na drugim komputerze Mac (uruchomionym przez udostępnianie ekranu) diagnoza zgłosiła wyłącznie `interface_consistency` = `routingConflict` przy nieaktywnym VPN i bez kandydata naprawy. Udostępnianie ekranu nie ma tu znaczenia: aplikacja działa lokalnie na tamtym komputerze, a dla `routingConflict` katalog napraw celowo nie oferuje działania, tylko wskazówkę. Dawna reguła liczyła jako konflikt także kopie tras z flagą interfejsu, które macOS tworzy dla drugiego interfejsu w tej samej sieci (np. Ethernet i Wi‑Fi jednocześnie), co jest typowe dla komputera stacjonarnego. Zmiana: kopie oznaczone flagą interfejsu nie są porównywane; trasa przez nieaktywny tunel ma osobny kod `routeViaInactiveTunnel` ze wskazówką potwierdzenia rozłączenia VPN; `routingConflict` pozostaje dla tej samej sieci z nieskopowanymi wpisami przez różne interfejsy i ma czytelniejszy opis. Test `DiagnosticChecksTests.testSecondInterfaceOnTheSameNetworkIsNotARoutingConflict` obejmuje trzy przypadki. Stanu drugiego komputera nie badano z tego hosta; po instalacji buildu 4 diagnoza tam powinna przejść, jeśli przyczyną były dwa interfejsy w jednej sieci.

Druga aktualizacja w miejscu (`~/Applications`, Release 0.2.0 build 2 → build 3): pierwszy start helpera znów odrzucony przez launchd (raport z 21:26:07), ale tym razem odświeżenie rejestracji (wyrejestrowanie i natychmiastowa rejestracja) zakończyło się nowym wpisem aplikacji w bazie elementów tła w stanie „pending authorization”, daemon `enabled, disallowed`, zadanie launchd nieobecne; poprzednio ten sam ciąg przeszedł bez zgody. Wniosek: zbyt szybkie usunięcie i ponowne dodanie potrafi założyć nowy wpis oczekujący na zgodę. Build 4 rejestruje daemon najpierw ponownie w miejscu, a wyrejestrowanie wykonuje tylko jako zapas po odczekaniu na zniknięcie rejestracji (do 5 s). Testy pakietu i 11 testów prezentacji przeszły; obraz `NetUnstick-0.2.0-4.dmg` zbudowany i zweryfikowany. Skuteczność nowej procedury nie została jeszcze sprawdzona, bo wymaga wcześniejszego zatwierdzenia oczekującego wpisu przez administratora; pytanie o to pozostało bez odpowiedzi. Build 4 jest zainstalowany w `~/Applications` i po zatwierdzeniu wpisu wykona procedurę przy starcie.

## Macierz aktualizacji w miejscu i zgody elementu tła — 29 września 2026, noc

| Aktualizacja (`~/Applications`) | Helper | Wynik |
| --- | --- | --- |
| Debug 0.1.0 build 1 → Release 0.2.0 build 2 | inny cdhash | pierwszy start odrzucony, odświeżenie (wyrejestrowanie i rejestracja) przeszło bez zgody; helper działał |
| build 2 → build 3 | inny cdhash | odrzucony, odświeżenie założyło wpis „pending authorization”; wymagana zgoda (udzielona później przez użytkownika, po niej helper build 4 działał) |
| build 4 → build 5 | ten sam cdhash | brak odrzucenia, brak odświeżenia, zadanie launchd zachowało wersję pakietu 4, helper uruchomił się od razu |
| build 5 → build 6 | inny cdhash | odrzucony (raport 22:11:28), dwustopniowe odświeżenie z buildu 4 zakończyło się wpisem „pending authorization” i daemonem `disabled, disallowed`; wymagana zgoda |

Wniosek: przy tożsamości bez Team ID zgoda jest przypięta do binarki helpera, a nie do aplikacji ani wersji pakietu. Procedura w aplikacji nadal jest potrzebna, bo bez niej launchd nigdy nie przyjąłby nowego helpera, ale nie zastępuje zgody. `Tools/BuildDMG.sh` ostrzega przy wydaniu, gdy helper się zmienił. Stan tego hosta po eksperymencie: build 6 zainstalowany i uruchomiony, rejestracja oczekuje na zatwierdzenie w Elementach logowania.

## Kierunek Mac Studio → MacBook i test połączenia z urządzeniem — 29 września 2026, noc

Po instalacji buildu 6 na drugim komputerze Mac diagnoza tam była w całości zielona, ale Finder na tym komputerze pokazał „Błąd połączenia” przy MacBooku w sekcji Sieć, mimo że urządzenie było widoczne (Bonjour) i dostępna była opcja pokazania ekranu. Udostępnianie ekranu nie ma na to wpływu. Stan MacBooka jako serwera sprawdzony z tego hosta: `smbd` działa, port 445 nasłuchuje na IPv4 i IPv6, zapora wyłączona, tras po VPN brak, usługa `_smb._tcp` ogłaszana na fizycznym interfejsie z nazwą hosta rozwiązywaną do adresu w sieci lokalnej, folder publiczny z dostępem gościa. W tablicy połączeń nie było żadnej próby z drugiego komputera na port 445 ani wpisu w logu `smbd`, więc próby albo nie docierają, albo Finder pokazywał zapamiętany wynik; rozstrzyga „Połącz jako…” na drugim komputerze. Anomalia po naprawie: dla adresu drugiego komputera MacBook ma sklonowany wpis hosta przez bramę domyślną (flagi `GATEWAY, HOST, WASCLONED`), więc ruch wychodzi przez router zamiast bezpośrednio; TCP działa (SMB, VNC, SSH otwarte), a wpis wygasa samoczynnie lub po przełączeniu Wi‑Fi.

Dodana funkcja: karta „Test połączenia z urządzeniem” (`DeviceConnectionCheck`, `SystemDeviceConnectionProbe`) wykonuje odczytowe połączenie TCP z podaną nazwą lub adresem i portem, z limitem 5 s, i zwraca zamknięty kod: `reachable`, `refused`, `timedOut`, `unreachable`, `nameUnresolved`, `invalidInput`, `failed`, `cancelled`, z typem interfejsu i flagą ścieżki przez tunel; nazwa i port nie trafiają do wyniku, sesji ani raportu.

| Sprawdzenie | Wynik |
| --- | --- |
| `DeviceConnectionProbeTests` | lokalny listener: `reachable` na `loopback`; zamknięty port: `refused` (po poprawce stanów `waiting` Network.framework, które wcześniej dawały `timedOut`); nazwa `.invalid`: `nameUnresolved`; TEST-NET: `timedOut`/`unreachable`; wejścia z separatorami i znakami powłoki: `invalidInput`; JSON wyniku nie zawiera nazwy hosta ani portu. |
| `NETUNSTICK_DEVICE_LIVE` z tego hosta do drugiego komputera | port 445: `reachable`, Wi‑Fi, bez tunelu; port 5900: `reachable`; port 548: `refused` (usługa nieoferowana). |
| `NetUnstickPresentationTests` | 12 testów, 0 błędów (test publikacji wyniku bez nazwy hosta i odrzucenia błędnego wejścia przed sondą). |
| `PresentationUITests` | 9 testów, 0 błędów z nową kartą na ekranie Stan. |

Ten sam test uruchomiony na drugim komputerze w kierunku MacBooka (nazwa Bonjour MacBooka, port 445) rozstrzygnie, czy problem leży w sieci (`timedOut`/`unreachable`), w usłudze (`refused`) czy w logowaniu (`reachable`, a Finder wymaga „Połącz jako…”).

## Wynik testu urządzenia z drugiego komputera — 30 września 2026

Użytkownik uruchomił na drugim komputerze Mac (build 7) test połączenia w kierunku nazwy Bonjour MacBooka na portach 548 (AFP) i 80 (HTTP): oba `refused`, interfejs Wi‑Fi, bez tunelu. Odrzucenie oznacza, że pakiety docierają do MacBooka i odpowiedzi wracają, więc ścieżka sieciowa między komputerami działa w obu kierunkach; na MacBooku nie ma usług AFP ani HTTP, co jest prawidłowe. Wynik dla portu 445 nie został przekazany; to on rozstrzyga, czy „Błąd połączenia” w Finderze dotyczy usługi SMB, czy logowania. Na MacBooku w tym czasie nadal nie było żadnego połączenia przychodzącego na port 445 z drugiego komputera. Komunikaty wyniku doprecyzowano tak, by „osiągalne” i „odrzucone” mówiły wprost, że sieć działa; zmiana czeka na kolejne wydanie (numer buildu podniesiony do 8 bez budowy obrazu, żeby nie wymuszać kolejnej zgody na helper przy samej zmianie tekstów).

## Port 445 z drugiego komputera — 30 września 2026

Test z drugiego komputera Mac (build 7) w kierunku nazwy Bonjour MacBooka na porcie 445: `reachable`, interfejs Wi‑Fi, bez tunelu („Bez problemu”). Razem z wcześniejszymi wynikami `refused` dla 548 i 80 oznacza to, że ścieżka sieciowa i usługa SMB działają; „Błąd połączenia” w Finderze drugiego komputera dotyczy warstwy sesji SMB i logowania (próba automatyczna jako gość albo zapamiętane poświadczenia), a nie sieci. Rozwiązanie leży poza aplikacją: „Połącz jako…” z kontem MacBooka, a przy odrzuceniu hasła włączenie konta dla SMB w opcjach Udostępniania plików na MacBooku, bo macOS zapisuje hasło SMB dopiero po zaznaczeniu konta.

## Kontrola gotowości udostępniania plików — 30 września 2026, noc

Wynik `reachable` dla portu 445 wskazywał na logowanie SMB, a nie sieć. Na MacBooku potwierdzono odczytowo, że rekord konta nie ma wpisu `SMB-NT` (macOS zapisuje skrót hasła SMB dopiero po zaznaczeniu konta w opcjach Udostępniania plików), usługa SMB nasłuchuje, a jedyny punkt udostępniania ma dostęp gościa. Dodano dwunasty check `file_sharing_readiness` (`Sharing/FileSharingReadiness.swift`): połączenie TCP z `127.0.0.1:445`, `/usr/bin/dscl . -read /Users/<konto> AuthenticationAuthority` sprowadzone do jednej flagi obecności `SMB-NT`, `/usr/sbin/sharing -l` sprowadzone do liczby udziałów z włączonym SMB i liczby udziałów gościa. Wyjścia poleceń nie opuszczają sondy; do wyniku trafia kod i liczba. Kody: `healthy`, `sharingOff` i `noSharedFolders` (pominięcie), `dataIncomplete` (pominięcie, ponów), `accountNotEnabledForSMB` (awaria, krok: włącz konto dla SMB), `cancelled`. Prezentacja dostała stan „Sieć działa; ten Mac nie jest gotowy do udostępniania plików”, gdy wszystkie kontrole sieci przechodzą (także przy śladzie tunelu po potwierdzonym rozłączeniu), a zawodzi tylko ta jedna; inna awaria sieci zachowuje ostrożną prezentację. `RepairCatalog.safeNextSteps` mapuje ten kod na wskazówkę bez naprawy, bo zmiana wymaga hasła użytkownika.

| Komenda | Wynik |
| --- | --- |
| `swift test` (`Packages/NetUnstickKit`) | Repair 29 testów (1 pominięty), Network 63 (5 pominiętych), Core 11; 0 błędów. Nowe `FileSharingReadinessTests`: parser listy udziałów liczy tylko bloki SMB i ignoruje nazwy, rekord konta redukuje się do jednej flagi, tabela decyzji, wynik bez nazw i skrótów (`Kowalski`, `/Users`, `SMB-NT`, `SHA512` nieobecne w JSON), anulowanie. |
| `NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter 'FileSharingReadinessTests/testLiveHostObservationWhenExplicitlyRequested\|HostDiagnosisSmokeTests'` | Host MacBook: `listening=true account=false smbShared=1 guest=1 decision=accountNotEnabledForSMB`. Pełna diagnoza: 12 kontroli, `file_sharing_readiness=failure/accountNotEnabledForSMB`, `interface_consistency=failure/orphanedTunnel` (ślad FortiClient), pozostałe `success`/`skipped`. |
| `xcodebuild … -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | 14 testów (6 integracji kompozycji, 8 prezentacji), 0 błędów; nowe: konto bez hasła SMB daje stan „serwer niegotowy” z krokiem i bez kandydata naprawy, także przy śladzie tunelu; raport nie zawiera nazwy konta. |
| `Tools/BuildDMG.sh` | `Artifacts/Distribution/NetUnstick-0.2.0-8.dmg`, `BUILD SUCCEEDED`, podpis i weryfikacja z montowania OK. Skrypt ostrzegł, że binarka helpera zmieniła się (pakiet `NetUnstickNetwork` jest w helperze), więc po aktualizacji macOS poprosi raz o zatwierdzenie helpera. |
| Instalacja z DMG do `~/Applications` (`hdiutil attach -plist`, `ditto`, `codesign --verify --strict --deep`) i uruchomienie | Build 8 zainstalowany i uruchomiony na MacBooku; podpis poprawny. |
| `TEST_RUNNER_NETUNSTICK_LIVE_ACTION=diagnose xcodebuild … -derivedDataPath Artifacts/UITestDerivedData -only-testing:NetUnstickUITests/LiveRepairUITests/testLiveDiagnosis CODE_SIGNING_ALLOWED=YES test` | Nowa akcja harnessu klika „Uruchom diagnostykę” w zainstalowanej aplikacji i czeka na zniknięcie znacznika „Trwa diagnostyka…”. Odczyt z ekranu: stan „Sieć działa; ten Mac nie jest gotowy do udostępniania plików”, wynik o braku hasła SMB konta, krok z opcjami Udostępniania plików i „Połącz jako…”. Pierwsza wersja akcji czytała ekran za wcześnie (przycisk startu pozostaje w drzewie podczas pracy), stąd oczekiwanie na tekst wyniku. |

## Wynik `unreachable` z drugiego komputera i sonda per rodzina adresów — 30 września 2026, noc

Raport sesji z drugiego komputera Mac (build 8, sesja nieobecna w historii MacBooka) pokazał dwanaście kontroli (`file_sharing_readiness=skipped/noSharedFolders`, bo tam konto ma hasło SMB, a udziały nie są zdefiniowane) oraz test urządzenia w kierunku nazwy Bonjour MacBooka na porcie 445 zakończony `unreachable` po 4 ms, Wi‑Fi, bez tunelu — dwie godziny wcześniej ten sam test dał `reachable`. Odczyt na MacBooku: `dns-sd -G v4v6` dla własnej nazwy zwraca na Wi‑Fi adres IPv4, IPv6 link-local oraz IPv6 ULA (`fd…/64`, autoconf z ogłoszenia routera; `ndp -r` wskazuje jako router urządzenie w sieci lokalnej o nazwie pokoju, prawdopodobnie Apple TV/HomePod jako border router Thread); ta sama kwerenda dla nazwy drugiego komputera zwraca wyłącznie IPv4 („No Such Record” dla AAAA), więc drugi komputer nie ma IPv6. Cztery milisekundy to natychmiastowy błąd próby IPv6 (brak trasy lub adresu źródłowego), a sonda kończyła test na pierwszym stanie `.waiting` z rozstrzygającą przyczyną, zanim Network.framework spróbował IPv4. Ten sam mechanizm wyboru adresu może dotyczyć klienta SMB na drugim komputerze, więc „Błąd połączenia” w Finderze ma dwie niezależne przyczyny kandydackie: rozgłaszany adres IPv6 bez drogi i konto bez hasła SMB.

Sonda została przepisana: `DeviceNameResolver` rozwiązuje nazwę przez `getaddrinfo` (DNS, `/etc/hosts`, Bonjour) na osobnym wątku z limitem 3 s, a `SystemDeviceConnectionProbe` łączy się z każdym adresem osobno (do czterech na rodzinę, równolegle, w pozostałym budżecie czasu) i agreguje werdykty: odpowiedź urządzenia (osiągalne, odrzucone) wyprzedza ciszę (brak odpowiedzi, brak drogi). Wynik niesie kody `ipv4Result` i `ipv6Result` (nowe klucze evidence o zamkniętym słowniku; literał adresu jest odrzucany przez sanitizer i dekoder), a prezentacja objaśnia rozbieżność i podaje krok: IPv6 „Automatycznie” na tym komputerze albo „Tylko lokalne łącze” na tamtym.

| Komenda | Wynik |
| --- | --- |
| `swift test` (`Packages/NetUnstickKit`) | Network 66 testów (5 pominiętych), Core 12, Repair 29 (1 pominięty); 0 błędów. Nowe: nasłuch tylko na IPv4 loopback i nazwa `localhost` (::1 i 127.0.0.1) dają `reachable` ogółem, `ipv4=reachable`, `ipv6=refused`; agregacja preferuje odpowiedź urządzenia i limituje adresy na rodzinę; wynik kontroli niesie kody rodzin bez adresów; sanitizer odrzuca `fd00::1` i `fe80::1%en0` jako wartości. |
| `xcodebuild … -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | 15 testów (6 integracji, 9 prezentacji), 0 błędów; nowy test objaśnienia rozbieżnych rodzin („Po IPv4 …”, „Nazwa ma tylko adres IPv4.”). |
| `Tools/BuildDMG.sh` (build 9) | `Artifacts/Distribution/NetUnstick-0.2.0-9.dmg`, podpis i weryfikacja OK; helper zmienił cdhash, więc aktualizacja poprosi raz o zatwierdzenie. |
| Instalacja z DMG do `~/Applications` i uruchomienie | Build 9 działa na MacBooku, podpis poprawny (`codesign --verify --strict --deep`). |
| `TEST_RUNNER_NETUNSTICK_LIVE_ACTION=device TEST_RUNNER_NETUNSTICK_DEVICE=<nazwa drugiego Maca>.local:445 xcodebuild … -only-testing:NetUnstickUITests/LiveRepairUITests/testLiveDeviceTest CODE_SIGNING_ALLOWED=YES test` | Nowa akcja harnessu wpisuje nazwę i port, klika „Sprawdź połączenie” i czeka na odblokowanie przycisku. Z MacBooka do drugiego Maca: „Bez problemu … Nazwa ma tylko adres IPv4.”, `ipv4Result: reachable`, Wi‑Fi, bez tunelu — potwierdza, że drugi komputer nie rozgłasza IPv6. |
| ta sama akcja z własną nazwą Bonjour MacBooka | „Bez problemu … IPv4: osiągalne · IPv6: osiągalne.”, `ipv4Result: reachable`, `ipv6Result: reachable`, interfejs loopback — obie rodziny są testowane osobno. Rozbieżny wynik (IPv4 działa, IPv6 bez drogi) można zobaczyć dopiero z drugiego komputera po jego aktualizacji do buildu 9. |

## Drugi komputer po IPv4 dochodzi, MacBook odrzuca każde logowanie SMB — 30 września 2026, rano

Raport z drugiego komputera Mac (build 9) po nazwie Bonjour MacBooka: 445 `reachable` z `ipv4Result=reachable`, `ipv6Result=unreachable`; 548 i inne nienasłuchujące porty `refused` po IPv4. Sonda per rodzina potwierdziła w praktyce rozbieżność IPv6 i to, że ścieżka IPv4 oraz usługa SMB działają. Użytkownik zgłosił, że mimo to MacBook „blokuje dostęp”. Odczyt na MacBooku: rekord konta nadal bez `SMB-NT`; `sysadminctl -guestAccount status` → konto Gość wyłączone; brak rekordu `/Users/Guest` w katalogu; zapora aplikacji wyłączona; `smbd` uruchomiony przez launchd na porcie 445; dziennik `smbd` pusty także na poziomie info/debug; jedyny udział ma dostęp gościa na poziomie udziału. Rozstrzygający test lokalny: `/usr/bin/smbutil view -N //127.0.0.1` → „server rejected the authentication: Authentication error”, kod wyjścia 77. Serwer SMB MacBooka odrzuca więc sesję gościa, którą Finder drugiego komputera otwiera jako pierwszą, a logowanie kontem nie może się udać bez zapisanego hasła SMB: nie istnieje żadna działająca metoda logowania. To jest przyczyna „Błędu połączenia” i okna logowania na drugim komputerze, niezależna od sieci.

Kontrola `file_sharing_readiness` dostała tę samą anonimową sesję jako czwarte źródło (tylko kod wyjścia; 0 = goście przyjmowani, 77 = odrzucani, inne = nieznane) oraz kody `noLoginMethod` (awaria: goście odrzucani i konto bez hasła SMB) i `guestRejected` (sukces z wyjaśnieniem: konto działa, goście odrzucani, Finder pokaże „Błąd połączenia” do czasu „Połącz jako…”). Prezentacja stanu „serwer niegotowy” przy `noLoginMethod` wymienia obie brakujące metody i dodatkowy krok z Użytkownicy i grupy › Gość. Aplikacja nadal niczego tu nie zmienia, bo oba ustawienia wymagają hasła użytkownika.

| Komenda | Wynik |
| --- | --- |
| `swift test` (`Packages/NetUnstickKit`) | Network 67 testów (5 pominiętych), Core 12, Repair 29 (1 pominięty); 0 błędów. Nowe: tabela decyzji z sesją gościa (`guestRejected`, `noLoginMethod`, `accountNotEnabledForSMB` przy gościu przyjmowanym), klasyfikacja kodu wyjścia `smbutil` (0/77/inne), wynik kontroli dla `noLoginMethod` z krokiem włączenia konta. |
| `NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter FileSharingReadinessTests/testLiveHostObservationWhenExplicitlyRequested` | MacBook: `listening=true account=false smbShared=1 guest=1 decision=noLoginMethod` — sonda potwierdza lokalnie odrzucenie gościa i brak hasła SMB konta. |
| `xcodebuild … -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | 15 testów, 0 błędów; test stanu „serwer niegotowy” obejmuje `noLoginMethod` z tekstem o gościu i krokiem z Użytkownicy i grupy › Gość. |
| `Tools/BuildDMG.sh` (build 10) | Pierwsza próba przerwana, bo obraz buildu 9 był zamontowany z otwartym oknem Findera bez otwartych plików; po `hdiutil detach` `Artifacts/Distribution/NetUnstick-0.2.0-10.dmg`, podpis OK, helper znów zmienił cdhash. |
| Instalacja z DMG do `/Applications` (kopia uruchamiana przez użytkownika, build 9 → 10), usunięcie zdublowanej kopii z `~/Applications`, uruchomienie | Build 10 działa z `/Applications`, podpis poprawny; na MacBooku pozostała jedna kopia. |
| `TEST_RUNNER_NETUNSTICK_LIVE_ACTION=diagnose TEST_RUNNER_NETUNSTICK_APP_PATH=/Applications/NetUnstick.app xcodebuild … testLiveDiagnosis` | Nagłówek: „Sieć działa; ten Mac nie jest gotowy do udostępniania plików”; wynik: „…ten Mac odrzuca logowanie gościa, a Twoje konto nie ma zapisanego hasła SMB…”; krok z opcjami Udostępniania plików, Gościem i „Połącz jako…”. |

## Dochodzenie na obu komputerach i sonda sesji SMB — 30 września 2026, przedpołudnie

Sterując Mac Studio przez okno Udostępniania ekranu (most pulpitu przekazuje pojedyncze klawisze, ale nie tekst ani modyfikatory, więc skrypty odczytowe zostały zapisane na udziale domowym Mac Studio zamontowanym na MacBooku i uruchamiane krótkim `sh nu.sh`, a wyniki czytane z tego udziału) zebrano dowody rozstrzygające stronę blokady:

| Kierunek | Wynik | Znaczenie |
| --- | --- | --- |
| Mac Studio → własny loopback | `smbutil view -N` kod 77 (gość odrzucony) | klient SMB Studio wynegocjował sesję |
| MacBook → własny loopback i własny adres LAN | kod 77 | serwer SMB MacBooka działa i odrzuca tylko logowanie |
| Mac Studio → MacBook przez sieć | kod 68 „Socket is not connected”; jądro: TCP do 445 `ESTABLISHED` po 8 ms, klient zamyka sam po 0,15 s z 0 bajtami, bez RST; `(smbfs) SMB_TRAN_FATAL` | negocjacja SMB nigdy nie wychodzi z Mac Studio |
| Transport Studio↔MacBook | `nc` 445/5900/22 z danymi OK, `ping -D -s 1472` OK, zapis i odczyt 5 MB przez udział Mac Studio w 1,6 s | sieć i TCP sprawne |
| Filtr treści na gniazdach | Mac Studio: `net.cfil.active_count` 1, 10–11 gniazd; MacBook: 0 | filtr działa tylko na Mac Studio |
| Konfiguracja filtra na Mac Studio | `com.apple.ALF.ApplicationFirewall` `Enabled` true, `FilterSockets` true, zapora włączona (bez „blokuj wszystkie”, bez trybu ukrycia); wpisy `socketfilterfw … FilterDataProvider` w dzienniku; brak konfiguracji filtra NordVPN, Shield to rozszerzenie Endpoint Security | aktywnym filtrem jest wbudowana zapora macOS |
| Zapora na MacBooku | wyłączona, `net.cfil.active_count` 0 | dlatego kierunek MacBook → Mac Studio działa |

Wniosek: dwie niezależne przyczyny. Serwer SMB MacBooka odrzuca każde logowanie (konto bez hasła SMB, gość wyłączony), a klient SMB Mac Studio pod włączoną zaporą systemową (filtr treści na gniazdach) kończy sesję przed pierwszym bajtem. Zamykanie aplikacji FortiClient i NordVPN nic nie zmienia: ich rozszerzenia systemowe działają niezależnie od aplikacji, a i tak nie są aktywnym filtrem na Mac Studio. Krok rozstrzygający po stronie użytkownika: wyłączyć zaporę na Mac Studio i powtórzyć test; oczekiwany wynik `smbutil` to kod 77 zamiast 68, a w Finderze okno logowania zamiast „Błędu połączenia”. Pliki testowe usunięto z udziału; żadne ustawienie nie zostało zmienione.

Do NetUnstick dodano kontrolę `content_filter` i sondę sesji SMB w teście urządzenia (opis w README). Hipoteza o zaporze została następnie sfalsyfikowana (sekcja niżej), więc komunikat `sessionFailed` wskazuje niezgodność wersji SMB i obejście `protocol_vers_map=2`, a filtr treści jest tylko dopiskiem.

| Komenda | Wynik |
| --- | --- |
| `swift test` (`Packages/NetUnstickKit`) | Network 73 testów (6 pominiętych), Core 13, Repair 29 (1 pominięty); 0 błędów. Nowe: parser liczników `net.cfil` i stanu zapory, tabela decyzji filtra (zapora / inny program / nieznany), wynik kontroli bez awarii, klasyfikacja kodu wyjścia `smbutil` (0/77/68/inne), test urządzenia z sesją SMB (awaria i krok „wyłącz zaporę” przy aktywnym filtrze zapory, sukces i „Połącz jako…” przy odrzuconym gościu), sonda systemowa pyta klienta SMB tylko dla portu 445 i czyta filtr tylko po nieudanej sesji, klucze `smbResult`/`firewallStatus`/`contentFilterStatus` w sanitizerze i dekoderze. |
| `NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter 'ContentFilterTests/testLiveHost…\|FileSharingReadinessTests/testLiveHost…'` | MacBook: `active=0 attached=0 firewall=false decision=noFilter`; udostępnianie: `account=true guestLogin=false decision=guestRejected` — użytkownik włączył już konto dla SMB, goście nadal odrzucani. |
| `xcodebuild … -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | 16 testów (6 integracji, 10 prezentacji), 0 błędów; nowy test objaśnienia sesji SMB nazywa stronę blokady i krok zapory. |

## Rozstrzygnięcie: SMB 3 między macOS 27.0 a macOS 26.6 — 30 września 2026, południe

Po aktualizacji obu aplikacji do buildu 11 wykonano, za zgodą użytkownika, test z wyłączoną zaporą na Mac Studio (`socketfilterfw --setglobalstate off`, `net.cfil.active_count` spadł do 0): `smbutil view -N` do MacBooka nadal kończył się kodem 68 „Socket is not connected”, a MacBook zamykał połączenie jako pierwszy (TIME_WAIT po jego stronie). Hipoteza o zaporze upadła. Test rozdzielający: prosty nasłuch TCP na porcie 8445 MacBooka odebrał od klienta SMB Mac Studio komplet negocjacji (73 bajty, dialekty „NT LM 0.12”, „SMB 2.002”, „SMB 2.???”), więc klient i sieć są sprawne; do portu 445 ten sam klient dostawał 68. Wersje: MacBook macOS 26.6.2 (25G83), Mac Studio macOS 27.0 (26A428). Użytkownikowy `~/Library/Preferences/nsmb.conf` na Mac Studio z `protocol_vers_map=2` (tylko SMB 2) dał natychmiast kod 77 „server rejected the authentication” — sesja wynegocjowana, gość odrzucony, czyli dokładnie to, co MacBook odpowiada sobie lokalnie. Ustawienie utrwalono systemowo (`sudo sh nsmb.sh` → `/etc/nsmb.conf`), zaporę Mac Studio przywrócono (State = 1), a Finder na Mac Studio po „Połącz jako…” po raz pierwszy pokazał okno logowania do MacBooka zamiast „Błędu połączenia”. Wniosek: serwer smbd macOS 26.6 zamyka połączenie po negocjacji SMB 3 klienta macOS 27.0 (w dzienniku klienta `smb2_smb_add_negotiate_contexts: No compression algorithm enabled?` i `SMB_TRAN_FATAL`); kierunek odwrotny działa, bo starszy klient nie wysyła tych kontekstów. Docelowe rozwiązanie: aktualizacja MacBooka do macOS 27; do tego czasu klient ograniczony do SMB 2.

Sonda w aplikacji na Mac Studio (build 11) zwróciła dla portu 445 `smbResult: unknown` (kod wyjścia `smbutil` inny niż 0/77/68 albo przekroczenie czasu); w kodzie dodano kody `timedOut` i `otherExit` z komunikatami, komunikat `sessionFailed` przepisano na niezgodność wersji z obejściem `protocol_vers_map=2`, a krok `limitSMBToVersion2` zastąpił krok wyłączenia zapory. Pliki testowe z udziału usunięto; jedyne zmiany na Mac Studio to `/etc/nsmb.conf` (kopia zapasowa `/etc/nsmb.conf.netunstick-backup`, jeśli plik istniał) i przywrócona zapora.

| Komenda | Wynik |
| --- | --- |
| `swift test` (`Packages/NetUnstickKit`) po poprawce sondy SMB | Core 13, Network i Repair bez błędów (kod wyjścia 0); nowe przypadki: kody `timedOut`/`otherExit`, krok `limitSMBToVersion2` przy `sessionFailed`. |
| `xcodebuild … -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | 16 testów, 0 błędów; komunikat `sessionFailed` mówi o niezgodności wersji SMB i obejściu `protocol_vers_map=2`, a filtr treści jest dopiskiem. |
| `Tools/BuildDMG.sh` (build 12) | `Artifacts/Distribution/NetUnstick-0.2.0-12.dmg`; helper zmienił cdhash (jednorazowa zgoda po aktualizacji). Zainstalowany do `/Applications` na MacBooku; Mac Studio wymaga ręcznej aktualizacji z tego obrazu. |

## Naprawa tras LAN i odczytowa diagnoza — 14 października 2026

Przez sterownik `abc-desktop` uruchomiono natywną aplikację NetUnstick (`org.netunstick.NetUnstick`), wykonano diagnostykę i obejrzano jej wynik. Skonfigurowane usługi VPN zgłaszały `disconnected`; FortiClient pokazywał „Connect”, a ustawienia VPN macOS „Rozłączono”. Detektor nadal zwracał `active/tunnelRoute`, ponieważ tablica tras zawierała wpisy przez tunel. Spośród 13 kontroli `local_subnet_route` zakończył się `failure/localRouteViaTunnel`.

W ramach polecenia użytkownika zatwierdzono w interfejsie kandydata usuwającego wyłącznie osiem dokładnie wskazanych, nieskopowanych tras tunelowych nakładających się na aktywny LAN. Naprawa zwróciła `success` po porównaniu stanu przed i po oraz pomyślnym ponownym sprawdzeniu `local_subnet_route`. Następnie uruchomiono pełną diagnostykę przyciskiem w aplikacji i niezależny odczytowy `NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter HostDiagnosisSmokeTests`.

| Sprawdzenie po naprawie | Zaobserwowany wynik |
| --- | --- |
| Pełna diagnoza i `HostDiagnosisSmokeTests` | Test `PASS`; silnik diagnozy: `healthy`. Wszystkie osiem podstawowych kontroli sieci: `success`. |
| Bonjour | `success/servicesFound`. |
| Multicast i uprawnienie sieci lokalnej | `skipped/inconclusive`; wyniki nierozstrzygające nie potwierdzają problemu sieci. |
| Udostępnianie plików | `success/guestRejected`; usługa działa, logowanie gościa jest odrzucane. |
| Filtr treści | `noFilter`. |
| Pozostałe ślady VPN | Cztery nieskopowane trasy prywatne poza aktywnym LAN (`/32`, `/31`, `/30`, `/29`, z adresem jako bramą); detektor nadal `active/tunnelRoute`. |

Pozostałych czterech tras nie usuwano. Sygnał `active/tunnelRoute` nadal blokuje inne naprawy zmieniające sieć. Nie zmieniano polityk FortiClient/FortiGate, zabezpieczeń ani nie uruchamiano ponownie komputera. Dowody potwierdzają usunięcie konkretnego konfliktu tras LAN i zdrowy wynik wykonanych kontroli; nie dowodzą poprawności dowolnego połączenia zewnętrznego ani wszystkich urządzeń w sieci.

Mylące podsumowanie wynikało z prezentacji: mimo zdrowego wyniku kontroli sygnał VPN nadpisywał nagłówek etykietą nieznanego stanu sieci. Zapis zawiera jedynie kody, wyniki i liczby; pominięto nazwy hostów i kont, adresy, domeny oraz zrzuty ekranu.

Poprawkę prezentacji potwierdzono na tym samym hoście: `xcodebuild … -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` zakończył się `TEST SUCCEEDED` (25 testów, 0 błędów). Testy obejmują sprawną sieć z pozostałymi trasami, rzeczywistą awarię LAN, niepełne kontrole, aktywne/nieznane usługi VPN, odświeżenie po naprawie, zachowanie sesji naprawy, błąd pełnej diagnozy oraz anulowanie ze spóźnionym callbackiem.

Podpisany build Release zakończył się `BUILD SUCCEEDED`; `check-helper-bundle.sh --require-stable-signing` oraz `codesign --verify --deep --strict` przeszły. Zaktualizowano aplikację w `/Applications`, zachowując wcześniejszą kopię zapasową poza repozytorium i to samo wymaganie podpisu. Następnie przez `abc-desktop` uruchomiono tę kopię, kliknięto „Uruchom diagnostykę” i odczytano rzeczywisty obraz oraz drzewo dostępności: nagłówek „Sieć lokalna i internet działają”, osiem podstawowych kontroli „Bez problemu”, brak kandydata do dalszego usuwania tras i osobne wyjaśnienie blokady zmian ze względu na pozostałe trasy tunelowe. Okno pozostawiono otwarte z wynikiem i zwolniono sterowanie pulpitem. Nie odtwarzano ponownie konfliktu w rzeczywistej sieci; automatyczne odświeżenie po naprawie sprawdzono w testach z kontrolowaną granicą systemu.

## Helper, naprawa LAN i podpis Developer ID — 17 października 2026

Przez `abc-desktop` odtworzono błąd w otwartej aplikacji: kandydat obejmował osiem tras LAN, a wykonanie kończyło się `notRegistered` przed jakąkolwiek zmianą sieci. Rejestracja nie była dostępna w kontekście potwierdzenia, wynik miał ogólny następny krok, a instrukcje helpera były zastępowane przez `reviewDetails`, ponieważ nie należały do zamkniętej listy `NextStep`.

Aplikację i helper przełączono z lokalnego certyfikatu na **Developer ID Application: Krzysztof Radzimski (UGL4ZTH3C6)**. Zastosowano wzorzec aktualnego podpisu projektu code-architect, wskazany przez kartę wiedzy 16 i zweryfikowany w aktualnym kodzie. Kontrola obejmuje integralność obu podpisów, wspólny publiczny certyfikat leaf, wąski identyfikator klienta XPC, łańcuch Apple i Team ID, hardened runtime, timestamp oraz brak `get-task-allow` w Release. Nie wykonano notaryzacji ani publikacji.

Pierwsza rejestracja po zmianie podpisu była oznaczona przez macOS jako aktywna, lecz próba uruchomienia kończyła się `Launch Constraint Violation`, a żądanie naprawy poprawnie przekroczyło limit czasu. Wąskie wyrejestrowanie i ponowna rejestracja samego helpera NetUnstick przywróciły odpowiedź „Helper odpowiada (protokół w wersji 2)”. Nie resetowano globalnego stanu elementów tła, nie zmieniano ograniczeń uruchamiania ani zabezpieczeń. Problemy migracji wymagań podpisu w SMAppService opisuje również [Apple DTS](https://developer.apple.com/forums/thread/795022); lokalny SDK rozróżnia synchroniczny status wyrejestrowania od callbacku potwierdzającego zakończenie procesu.

Po odzyskaniu odpowiedzi helpera ponowiono rzeczywistą diagnostykę, zatwierdzono dokładnie osiem tras i obserwowano automatyczną diagnozę po naprawie. W natywnym obrazie i drzewie dostępności pojawiły się „Naprawiono — ponowny check potwierdził poprawę” i „Sieć lokalna i internet działają”; kontrola `local_subnet_route` zmieniła się na sukces, podobnie jak pozostałe podstawowe kontrole. Kandydat zniknął. Pozostałe ślady VPN nadal blokują zwykłe zmiany; nie poszerzano zakresu usuwania tras. Sam ten wynik nie dowodzi połączenia z każdym urządzeniem LAN.

Poprawiony panel potwierdzenia pokazuje rejestrację i zgodę macOS oraz blokuje wykonanie przed przygotowaniem helpera. Po rejestracji weryfikuje odpowiedź XPC, pokazuje postęp i nie odblokowuje naprawy po błędzie handshake. Odświeżanie starej rejestracji czeka na callback `unregister(completionHandler:)` z limitem 5 sekund, zanim zarejestruje zastępstwo; błąd, timeout i anulowanie kończą ten krok bez rejestracji.

| Weryfikacja | Wynik |
| --- | --- |
| `xcodebuild … -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | 35 testów, 0 błędów; preflight helpera, handshake, zachowanie kandydata, kolejność wyrejestrowania, timeout i anulowanie. |
| `swift test --filter 'NetUnstickCoreTests\|NetUnstickRepairTests'` | Core: 13 testów; Repair: 32 testy, jeden test live pominięty; 0 błędów. Instrukcje helpera przetrwały JSON, nieznane teksty z tokenem i prywatną domeną nadal redagowane. |
| Podpisany Release i `check-helper-bundle.sh --require-developer-id` | `BUILD SUCCEEDED`, kontrola podpisu i wymagania klienta XPC zakończona kodem 0. |

Końcowy build z poprawionym oczekiwaniem na wyrejestrowanie zainstalowano w `/Applications/NetUnstick.app` i ponownie uruchomiono przez `abc-desktop`. Ustawienia potwierdziły odpowiedź helpera w protokole 2. Nowa pełna diagnostyka po uruchomieniu znów pokazała „Sieć lokalna i internet działają”, osiem podstawowych kontroli „Bez problemu” oraz brak kandydata do naprawy. Odkrywanie multicast i ustalenie uprawnienia Bonjour pozostały nierozstrzygające; zachowano osobną informację o pozostałych trasach VPN. Okno pozostawiono otwarte z wynikiem i zwolniono pulpit.

Zapis zawiera wyłącznie zredagowane kody i liczniki. Nie utrwalono nazw urządzeń, adresów sieciowych, domen, kont, sekretów ani prywatnych zrzutów ekranu.

## Lokalizacja i pełne wydanie — 21 października 2026

Historyczna weryfikacja pełnego wydania Developer ID **0.3.0 (13)** na hoście macOS arm64:

| Weryfikacja | Wynik |
| --- | --- |
| `swift test` w `Packages/NetUnstickKit` | 128 testów, 7 środowiskowych pominiętych, 0 błędów. Obejmuje lokalizację 24 języków, redakcję raportów, usuwanie historii, decyzje diagnozy i granice napraw. |
| `xcodebuild … -scheme NetUnstick -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | 37 testów, 0 błędów. Obejmuje serializację usuwania historii z aktywnymi operacjami, błędy zapisu i wskazówki przy nieudanej sesji SMB. |
| Release `NetUnstick`, `platform=macOS,arch=arm64` | `BUILD SUCCEEDED`; aplikacja i helper przeszły `check-helper-bundle.sh --require-developer-id`. |
| `python3 Tools/Localization.py` | Kompletność zasobów 24 języków i zgodność placeholderów potwierdzone; nie zastępuje redakcji przez rodzimych użytkowników języka. |

Obejrzano pełną diagnozę Developer ID: 13 kontroli, nagłówek „Sieć lokalna i internet działają”, osiem podstawowych kontroli bez problemu i odrębną blokadę zmian ze względu na pozostałe ślady VPN. Nie wykonywano napraw ani zmian konfiguracji sieci. Nie powtarzano historycznych prób napraw na rzeczywistej awarii ani pełnej macierzy XCUITest z września.

## Jedno wydanie Developer ID — 23 października 2026

Na polecenie właściciela wycofano kanał sklepowy. Usunięto niewysłany szkic recenzji i zapisano brak dostępności na wszystkich rynkach. Ponowne otwarcie panelu recenzji pokazało pustą listę, a panel dostępności potwierdził **0 krajów lub regionów dostępnych oraz 175 niedostępnych**. Samo wyłączenie dostępności pozostawiło rekord na głównej liście aplikacji. Następnie w informacjach NetUnstick wykonano **Remove App** i potwierdzono usunięcie: panel pokazał **Restore App**, a po ponownym otwarciu głównej listy NetUnstick już na niej nie było. Zgodnie z komunikatem Apple rekord trafia do **Removed Apps**, a nazwa sklepowa zostaje zwolniona. Operacje wykonano w Podglądzie, bez sterowania pulpitem.

Z projektu usunięto oddzielny target, testy i flagi wydania sklepowego, metadane publikacji, zrzuty, skrypty archiwizacji i walidacji oraz lokalne eksporty i katalogi budowy tej odmiany. Modele sieciowe i implementację Bonjour przeniesiono do `NetUnstickNetwork`; zachowano pełny mechanizm napraw, helper i lokalizacje. Pomoc, ustawienia, dokumentacja oraz źródła stron w `Distribution/Website` opisują wyłącznie Developer ID. Wygenerowanie lokalnych stron nie publikuje zmian na hostingu ITORG.

| Weryfikacja na macOS arm64 | Wynik |
| --- | --- |
| Release schematu `NetUnstick` z podpisem Developer ID | Kod 0, `BUILD SUCCEEDED`. |
| `check-helper-bundle.sh … --require-developer-id` | Poprawny pakiet aplikacji i helpera, podpisy, Team ID, hardened runtime i wymaganie klienta XPC. |
| `swift test --package-path Packages/NetUnstickKit --jobs 4` | Core 23, Network 73, Repair 32: 128 testów, 7 środowiskowych pominiętych, 0 błędów. |
| `xcodebuild … -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test` | Raport Xcode: 37 testów zaliczonych, 0 pominiętych i 0 błędów. |
| `python3 Tools/Localization.py` | 369 kluczy × 24 języki, kompletność i placeholdery poprawne. |
| Konfiguracja projektu, generatory i czystość zmian | Poprawny plist projektu, minimum macOS 14.0, wyłącznie targety pełnej aplikacji, helpera i jej testów; składnia generatorów oraz `git diff --check` poprawne. |

Łącznie: **165 testów, 7 pominiętych, 0 błędów**. Zbudowanie i testy nie stanowią nowej próby naprawy rzeczywistej awarii. Nie uruchamiano napraw ani nie zmieniano konfiguracji sieci hosta; nie wykonywano nowej notaryzacji ani dystrybucji DMG.

## Instalator PKG Developer ID — 23 października 2026

Przygotowano standardowy instalator Apple dla wydania **0.3.0 (13), arm64, macOS 14+**. Aplikacja i osadzony helper pozostają podpisane certyfikatem Developer ID Application `D6CDD9E6748C6D2AE7D9FAF9D48D5CCAC992630E`. W portalu Apple wystawiono dodatkowy certyfikat **Developer ID Installer** zespołu `UGL4ZTH3C6`, o SHA-1 `93A07778E813EF6D7DB3A33CC934999F0B822467`, i dołączono jego publiczną część do istniejącego klucza wygenerowanego bezpośrednio w lokalnym pęku przez `certtool`. Klucza podpisu nie eksportowano.

Po jawnym wyborze użytkownika włączono dostęp do App Store Connect API i utworzono klucz zespołu „NetUnstick Notary Developer” z rolą **Developer**. `notarytool store-credentials NetUnstick` potwierdził poprawne uwierzytelnienie i zapis profilu w pęku kluczy. Kopia klucza API jest przechowywana poza repozytorium w katalogu o uprawnieniach `0700`, w pliku `0600`; sekretów nie zapisano w kodzie ani logach. Operacje konta wykonano w Podglądzie, bez sterowania pulpitem.

| Weryfikacja | Wynik |
| --- | --- |
| `Tools/BuildPKG.sh --notary-profile NetUnstick`, etap kompilacji Release | `BUILD SUCCEEDED`. Jawne `CODE_SIGN_STYLE=Manual` zapobiega konfliktowi automatycznego podpisu produktów Swift Package z podaną tożsamością Developer ID w Xcode 27.1. |
| `check-helper-bundle.sh --require-developer-id` na aplikacji źródłowej i wyciągniętej z PKG | Kod 0; integralność podpisów, wspólny leaf, ograniczony klient XPC, Team ID, hardened runtime, timestamp i brak uprawnienia debuggera. |
| `pkgutil --check-signature` | Certyfikat Developer ID Installer z poprawnym łańcuchem Apple i zaufanym znacznikiem czasu. |
| `pkgutil --expand-full`, metadane i porównanie SHA-256 plików | Jedyną zawartością payloadu jest `NetUnstick.app`, z lokalizacją instalacji `/Applications`; **66 plików identycznych bajtowo** ze źródłowym Release, pliki aplikacji i helpera wykonywalne. PKG nie zawiera osobnego katalogu `/Applications`, skryptów instalacyjnych ani danych sesji. Wyłączona relokacja, kontrola wersji, zastąpienie całego bundla. |
| Dystrybucja Instalatora | `hostArchitectures=arm64`, minimum `14.0`, wyłącznie domena systemowa; wymaganie zamknięcia `org.netunstick.NetUnstick`. Zasoby w `en.lproj` i `pl.lproj`. |
| `installer -pkg … -target / -showChoicesXML` | Kod 0, aplikacja wybrana i dostępna do instalacji. To odczyt metadanych, bez instalowania. |
| Błędne argumenty i typy certyfikatów | Brak wartości opcji i ID zgłoszenia bez `--resume` zatrzymują proces przed budowaniem i wysyłką. Apple Development jako certyfikat aplikacji oraz Developer ID Application jako certyfikat instalatora są odrzucane przed pakowaniem. |
| `zsh -n`, `git diff --check`, walidacja XML i `Tools/Localization.py` | Poprawna składnia i XML; 369 kluczy × 24 języki aplikacji, bez rozbieżności placeholderów. |

`pkgbuild` na tym hoście wypisuje cztery komunikaty `write: Permission denied` również przy osobnym pakowaniu kopii w katalogu tymczasowym; kończy się kodem 0. Powyższe porównanie wszystkich plików, kontrola wykonywalności, podpisów i odczyt przez systemowy Instalator przeszły. Nie traktowano samego kodu zakończenia narzędzia jako dowodu kompletności pakietu.

Notaryzacja końcowego PKG: zgłoszenie **`34dfdfb4-653e-469d-8eb1-3a4313ee9025`**, wysłane 23 października 2026 o 09:53 UTC. O 10:13 UTC Apple nadal zwracało **`In Progress`**. Pierwsze `notarytool wait --timeout 20m` zakończyło się kodem **124** po 1200 sekundach, a skrypt zakończył się kodem 1 i zachował podpisany pakiet roboczy oraz metadane zgłoszenia. Na tym etapie skrypt poprawnie nie utworzył pliku o końcowej nazwie.

Następnie Apple zakończyło przetwarzanie statusem **`Accepted`**. O 10:38 UTC potwierdzono pełne dokończenie tego samego zgłoszenia, z profilem już zapisanym w lokalnym pęku kluczy:

```sh
Tools/BuildPKG.sh --resume Artifacts/Distribution/NetUnstick-0.3.0-13-arm64-UNNOTARIZED.pkg --submission-id 34dfdfb4-653e-469d-8eb1-3a4313ee9025 --notary-profile NetUnstick
```

Komenda zakończyła się **kodem 0**, bez przebudowy i ponownego wysyłania aplikacji. Pobrano log Apple: `Accepted`, kod `0`, brak uwag. `stapler staple` i `stapler validate` przeszły; `pkgutil --check-signature` potwierdził podpis Developer ID Installer, zaufany timestamp i `Notarization: trusted by the Apple notary service`. Gatekeeper zaakceptował PKG (`--type install`) oraz wyodrębnioną aplikację (`--type execute`), w obu przypadkach ze źródłem **`Notarized Developer ID`**. Odczytowe `installer -query RestartAction` zwróciło `None` (brak wymogu restartu).

Gotowy artefakt: **`Artifacts/Distribution/NetUnstick-0.3.0-13-arm64.pkg`**, wraz z plikiem `.pkg.sha256`. SHA-256 końcowego, notaryzowanego PKG z biletem:

```text
1697f6e2273e20e67d344a9cbb8d9fd3436b94b1a28f0d954419e225715bb2b3
```

Pełny log wznowienia pozostaje w ignorowanym `Artifacts/tmp/pkg-notarization-finish.log`; wynik i log Apple w `Artifacts/Distribution/NetUnstick-0.3.0-13-arm64-notary*.json`. Potwierdzono wymagania podpisu i notaryzacji dla dystrybucji; instalacja na drugim Macu pozostaje poza wykonaną próbą.

Próba oględzin kreatora przez `abc-desktop`: `computer_status` potwierdził gotowy sterownik, zgody Dostępność/Nagrywanie ekranu i aktywną zgodę projektu. Odczytano rzeczywisty obraz i drzewo Findera, otwarto własne okno oraz pole „Idź do” i zweryfikowano ustawioną ścieżkę PKG. Sterownik odmówił kolejnego klawisza z komunikatem „Fokus przeszedł do innego okna lub dialogu”; okna dialogowego nie udało się jednoznacznie przypisać do AXWindows. Nie otwarto kreatora Instalatora i nie deklaruje się wizualnej weryfikacji jego stron. Zwolniono pulpit przez `computer_end_turn`. Nie zmieniano zgód, zabezpieczeń ani nie obchodzono ograniczenia innym sterownikiem. Instalacji na drugim Macu ani naprawy rzeczywistej awarii nie wykonano.

## Wersja aplikacji w Ustawieniach — 23 października 2026

W Ustawieniach zastąpiono informację o wydaniu Developer ID wierszem „Wersja”. Numer wersji i buildu pochodzi z `CFBundleShortVersionString` i `CFBundleVersion` uruchomionej aplikacji. Etykieta ma tłumaczenia we wszystkich 24 obsługiwanych językach.

| Weryfikacja na macOS arm64 | Wynik |
| --- | --- |
| Podpisany Release schematu `NetUnstick` | Kod 0, `BUILD SUCCEEDED`. Metadane zbudowanej aplikacji: `0.3.0 (13)`, minimum macOS `14.0`. |
| `check-helper-bundle.sh … --require-developer-id` | Kod 0; poprawny pakiet helpera, podpisy i wymaganie klienta XPC. |
| `python3 Tools/Localization.py` | 370 kluczy × 24 języki; zasoby i placeholdery zgodne ze źródłem. |
| `git diff --check` | Kod 0. |

Zakres tej weryfikacji obejmuje kompilację, zasoby i podpisy; nie wykonano nowej próby wizualnej Ustawień. Wcześniejszy notaryzowany PKG pozostaje artefaktem sprzed tej zmiany interfejsu.

## Kolory i animacje interfejsu — 23 października 2026

Dodano wspólny styl nieprzezroczystych kart i ikon w ekranie Stan, historii, Ustawieniach i potwierdzeniu naprawy. Kolory wynikają z typowanych stanów i `OperationOutcome`, a nie z tłumaczeń tekstów. Pominięcie i anulowanie pozostają neutralne; pozostałości VPN, niepewność, odmowa uprawnienia i timeout zachowują ostrzegawczy akcent. Pulsowanie symbolu jest związane wyłącznie z aktywną operacją. Krótkie przejścia oraz jednorazowe potwierdzenie zdrowego wyniku diagnostyki respektują systemowe „Ogranicz ruch” i flagę Debug. Nieudana naprawa zachowująca poprzedni stan sieci nie uruchamia potwierdzenia sukcesu. Zwiększony kontrast wzmacnia obrysy i stosuje systemowy kolor pierwszoplanowy do ikon; tekst i symbol pozostają niezależnymi od koloru nośnikami informacji.

| Weryfikacja na macOS arm64 | Wynik |
| --- | --- |
| Podpisane buildy Release i Debug schematu `NetUnstick` | Kod 0, `BUILD SUCCEEDED`; cel pozostaje macOS 14.0. |
| `check-helper-bundle.sh … --require-developer-id` na końcowym Release | Kod 0; poprawne podpisy aplikacji i helpera, wymaganie klienta XPC i ustawienia wydania. |
| `xcodebuild … -only-testing:NetUnstickPresentationTests test` z podpisem Developer ID | **37 testów, 0 błędów**, 15,1 s. Wynik w ignorowanym `Artifacts/AppearanceUnitValidation.xcresult`. Obejmuje m.in. recheck naprawy, anulowanie, blokady VPN, historię i redakcję prezentowanych danych. |
| `python3 Tools/Localization.py` | 370 kluczy × 24 języki, zgodne placeholdery; styl korzysta z istniejących tekstów. |
| Natywne oględziny przez `abc-desktop` | Rzeczywisty obraz i drzewo dostępności nowego Release uruchomionego z `Artifacts/ReleaseDerivedData/Build/Products/Release/NetUnstick.app`. Potwierdzono ekran stanu, postęp odczytowej diagnostyki, jej zakończenie, rozwijanie kontroli, kolory sukcesu/pominięcia i historycznej awarii, Aktywność oraz Ustawienia z `0.3.0 (13)` bez etykiety Developer ID. |

Most pulpitu potwierdził backend `abc-desktop`, gotowość, zgody Dostępność/Nagrywanie ekranu i zgodę projektu. Oględziny wykonano w bieżącym ciemnym motywie hosta. Diagnoza zwróciła 13 kontroli i stan „Sieć lokalna i internet działają”; pozostałe trasy VPN nadal miały bursztynowe ostrzeżenie i blokadę zmian, a udane kontrole zielone ikony. Nie wykonywano napraw ani zmian konfiguracji sieci. Zbudowany Release pozostawiono otwarty na ekranie Stan, a pulpit zwolniono przez `computer_end_turn`.

Pełna automatyczna macierz XCUITest (jasny/ciemny motyw, duży tekst, kontrast i ograniczony ruch) **nie została wykonana**: runner UI nie rozpoczynał testów, również po podpisanej kompilacji w czystym katalogu. Przerwano własne komendy `xcodebuild`; osobna próba bez podpisu także nie rozpoczęła testów, a ponowne użycie jej katalogu zgłosiło `lipo: Operation not permitted`. Odczytowe `DevToolsSecurity -status` wskazało wyłączony tryb Developer; nie ustalono, czy to przyczyna zawieszenia, i nie zmieniano zabezpieczeń systemu. Oględziny natywne zastąpiły próbę w ciemnym motywie, nie potwierdzają całej macierzy ani pełnego przebiegu animacji sukcesu. Systemowy dialog „Idź do” Findera nie dawał się powiązać z AXWindows; aplikację otwarto zwykłą nawigacją folderów, po czym przywrócono pierwotny katalog istniejącego okna Findera. Zamknięcie dodatkowego okna z tym dialogiem zostało odrzucone przez kontrolę fokusu mostu.

Poprzedni notaryzowany PKG pozostaje niezmieniony; ta weryfikacja dotyczy nowych buildów aplikacji. Nie wykonano nowej notaryzacji ani instalacji na drugim Macu.

## Klikanie całego nagłówka panelu — 23 października 2026

Wspólny `FullWidthDisclosureStyle` zastępuje ograniczony obszar strzałki przyciskiem obejmującym cały nagłówek. W kartach „Szczegóły sieci” i „Test połączenia z urządzeniem” również odstępy przy brzegach należą do przycisku. Rozwinięta zawartość jest osobnym obszarem, dzięki czemu pola tekstowe, selektor portu, przyciski i zaznaczanie tekstu zachowują własne działanie. Styl obowiązuje również w kontrolach diagnozy, Aktywności i Ustawieniach. Reprezentacja dostępności wykorzystuje systemowy `DisclosureGroup` w stylu automatycznym, zachowując jego rolę, stan rozwinięcia i lokalizację; przejścia respektują „Ogranicz ruch”.

| Weryfikacja | Wynik |
| --- | --- |
| Podpisany Release `NetUnstick`, `platform=macOS,arch=arm64` | Kod 0, `BUILD SUCCEEDED`; minimum macOS 14.0. |
| `check-helper-bundle.sh … --require-developer-id` | Kod 0, poprawny pakiet aplikacji i helpera oraz wymaganie klienta XPC. |
| `python3 Tools/Localization.py` i `git diff --check` | Kod 0; 370 kluczy × 24 języki, poprawne placeholdery. |
| Natywny klik w puste miejsce po prawej stronie „Szczegółów sieci” | Panel otwarty; rzeczywiste drzewo dostępności pokazało `AXDisclosureTriangle … = 1` i widoczną treść. Klik przy prawej krawędzi nagłówka zwinął go (`= 0`). |
| Natywny klik w dolny i prawy odstęp zwiniętej karty testu urządzenia | Formularz otwarty (`= 1`); klik w tekst nagłówka zwinął go (`= 0`). |
| Pole nazwy urządzenia w otwartym formularzu | Klik i wpisanie testowej nazwy zakończone `verified: true`; panel pozostał rozwinięty. Pole następnie wyczyszczono. Nie uruchamiano połączenia. |
| Nagłówek „Szczegóły i uprawnienia” w Ustawieniach | Klik w pustym obszarze po prawej rozwinął wskazówkę helpera i zachował stan dostępności `= 1`. |
| Wiersz kontroli w Aktywności | Klik w pustym środku wiersza otworzył szczegóły, a ponowny klik je zamknął. |

Próby wykonano na nowym Release z `Artifacts/ReleaseDerivedData/Build/Products/Release/NetUnstick.app` przez rzeczywiste wejścia `abc-desktop`, z obrazem okna i odczytem dostępności, w ciemnym motywie hosta. Most potwierdził gotowość, zgody Dostępność/Nagrywanie ekranu i zgodę projektu. Nie uruchamiano diagnostyki, napraw ani eksportu raportu. Nie powtarzano pełnej macierzy XCUITest z opisanym wyżej ograniczeniem runnera; powyższe wyniki są osobnym, wykonanym testem interakcji natywnej. Przywrócono pierwotny katalog istniejącego okna Findera, pozostawiono nowy build na ekranie Stan ze zwiniętymi kartami i zwolniono pulpit przez `computer_end_turn`.

## Notaryzowane wydanie 0.3.1 (14) — 23 października 2026

Po akceptacji działania interfejsu przez użytkownika przygotowano nowy instalator zawierający numer wersji w Ustawieniach, kolory i animacje oraz rozwijanie paneli całym nagłówkiem. Wersję aplikacji i helpera ustawiono na **0.3.1 (14)** we wszystkich konfiguracjach projektu. Wydanie zbudowano na macOS arm64, Xcode 27.1 (`27A9275`), poleceniem:

```sh
Tools/BuildPKG.sh --notary-profile NetUnstick
```

| Weryfikacja | Wynik |
| --- | --- |
| Kompilacja Release i kontrola aplikacji oraz helpera przed i po spakowaniu | `BUILD SUCCEEDED`; `check-helper-bundle.sh --require-developer-id` zakończony kodem 0. Zachowano Developer ID Application zespołu `UGL4ZTH3C6`, hardened runtime, timestamp i brak `get-task-allow`. |
| Podpis PKG | Developer ID Installer tego samego zespołu, prawidłowy łańcuch Apple i zaufany znacznik czasu. |
| Rozpakowanie payloadu i porównanie z Release | **66 plików/linków**, zgodne SHA-256 i uprawnienia; aplikacja oraz helper wykonywalne, oba `arm64`. Metadane aplikacji `0.3.1 (14)`, pakietu `0.3.1.14`, minimum macOS `14.0`, lokalizacja `/Applications`. |
| Konfiguracja instalacji | Jedynym payloadem jest `NetUnstick.app` z helperem, bez skryptów instalacyjnych; stała lokalizacja i kontrola wersji. Odczytowe `installer -showChoicesXML` zakończone kodem 0, `RestartAction`: `None`. |
| Notaryzacja Apple | Zgłoszenie `16b42e7e-8873-4a6b-aa3b-f2038f016aaf`, wysłane o 12:10 UTC: **`Accepted`**, `statusCode: 0`, `issues: null`. |
| Bilet i Gatekeeper | `stapler staple` i `stapler validate` poprawne; PKG i wyodrębniona aplikacja zaakceptowane jako **`Notarized Developer ID`**. Ponowna walidacja biletu, ocena instalatora i sprawdzenie SHA-256 końcowego pliku zakończone kodem 0. |
| Lokalizacje i konfiguracja projektu | 370 kluczy × 24 języki, zgodne placeholdery; poprawny plist projektu. |

Skrypt zakończył się **kodem 0**. Gotowy instalator: **`Artifacts/Distribution/NetUnstick-0.3.1-14-arm64.pkg`**, rozmiar **1 924 299 bajtów**, wraz z plikiem `.pkg.sha256`. SHA-256 pakietu z dołączonym biletem:

```text
93ce15cdebaef9b03733fd60a0290757160e1be5da4c0e27350665d3074dedb8
```

Log procesu pozostaje w ignorowanym `Artifacts/tmp/pkg-0.3.1-14.log`, a wyniki i log Apple w `Artifacts/Distribution/NetUnstick-0.3.1-14-arm64-notary*.json`. Wcześniejszy instalator `0.3.0 (13)` zachowano. Zakres tej próby obejmuje przygotowanie i weryfikację nowego wydania; nie instalowano go na drugim Macu ani nie powtarzano opisanych wyżej testów UI i napraw rzeczywistej sieci.
