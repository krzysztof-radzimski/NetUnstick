# NetUnstick

NetUnstick jest natywną aplikacją macOS w Swift i SwiftUI. Jej planowany cel to diagnozowanie problemów z dostępem do urządzeń lokalnych po rozłączeniu VPN, w pierwszej kolejności FortiClient/FortiGate. Obecna wersja otwiera standardowe okno z demonstracyjnym interfejsem Stan, Aktywność i Ustawienia. Interfejs używa deterministycznych mocków i nie uruchamia jeszcze rzeczywistych kontroli ani napraw. Biblioteka `NetUnstickNetwork` udostępnia odczyt stanu sieci, ostrożną ocenę VPN oraz osiem diagnostyk DNS, tras, interfejsów, proxy i łączności oraz trzy operacje lokalnego odkrywania. `DiagnosisEngine` zwraca kandydackie przyczyny i hipotezy scenariuszy Fortinet. Diagnostyka nie jest jeszcze podłączona do interfejsu; przycisk w oknie uruchamia wyłącznie symulację. Nie zmienia ustawień i nie wymaga podwyższonych uprawnień.

Minimalna wersja systemu to **macOS 14.0** (`MACOSX_DEPLOYMENT_TARGET = 14.0`). Projekt używa lokalnego pakietu `Packages/NetUnstickKit` z modułami `NetUnstickCore`, `NetUnstickNetwork` i `NetUnstickRepair`. `NetUnstickCore` zawiera kontrakty wyników i operacji, typowaną redakcję evidence, rejestr sesji oraz renderer raportu. Moduł napraw pozostaje pustym punktem rozszerzenia. Nie ma zależności zewnętrznych.

Ikona Dock to własny znak trzech węzłów i przywróconej ścieżki. Projekt używa kompletnego `AppIcon.appiconset` zgodnego z macOS 14.0; warianty źródłowe Default, Dark, Mono/Tinted i Clear oraz instrukcja odtwarzania są w [Design/AppIcon/README.md](Design/AppIcon/README.md). Automatyczne przełączanie tych wariantów przez system wymaga zweryfikowanego zasobu `.icon` i obecnie nie jest deklarowane.

## Budowanie i testowanie

Wymagane są Xcode i narzędzia wiersza poleceń Apple. Z katalogu repozytorium:

```sh
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -showBuildSettings | rg MACOSX_DEPLOYMENT_TARGET
cd Packages/NetUnstickKit && swift test
NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter ReadOnlySmokeTests
NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter HostDiagnosisSmokeTests
NETUNSTICK_BONJOUR_LIVE=1 swift test --filter BonjourDiscoveryTests/testLocalAdvertiserHarness
```

Schemat `NetUnstick` jest współdzielony. Smoke test uruchamia się osobno na macOS; obserwuje host bez zmian i zapisuje wyłącznie zredagowany JSON do `.build/netunstick-smoke-redacted.json` w katalogu pakietu. Brak VPN jest prawidłowym wynikiem. Testy `NetUnstickCore` sprawdzają kontrakty, redakcję, limity i błędy magazynu. Testy `NetUnstickNetwork` obejmują parsery, decyzję VPN, procesy, prywatność oraz tablice decyzji diagnostycznych. Smoke test diagnozy uruchamia aktualny kolektor i checki na hoście; aktywny VPN lub brak internetu dają wynik inconclusive/skipped. `NetUnstickRepair` potwierdza obecnie tylko dostępność modułu.

## Odczyt sieci i ograniczenia

`SystemNetworkStateCollector` odczytuje `NWPath`, aktywne interfejsy, trasy, DNS, proxy i wybrane klucze dynamic store. Dla tras używa wyłącznie stałych poleceń odczytowych `/usr/sbin/netstat`; wykonawca ma limit czasu i wyjścia, sprawdza exit status i obsługuje anulowanie. Nie uruchamia powłoki. Żadna z tych operacji nie wymaga uprawnień administratora. Snapshot surowy jest krótkotrwały i nie jest kodowany ani logowany. `SanitizedNetworkSnapshot` zawiera tylko typy, liczby, obecność i losowo zasolone identyfikatory korelacyjne; do `OperationResult` trafia jeszcze węższy zestaw typowanych evidence.

`VPNStateDetector` zwraca `active`, `inactive` albo `unknown` ze stabilnym kodem przyczyny. Błąd częściowy, sprzeczne sygnały i ślad tunelu po rozłączeniu dają `unknown`, który blokuje przyszłe akcje zmieniające sieć tak samo jak `active`. Wynik obcego klienta VPN może pozostać nieustalony; sam proces FortiClient ani pojedyncze API nie dowodzi rozłączenia. Po rozłączeniu można pobrać kilka próbek w ograniczonym oknie. Kolektor nie steruje FortiClient ani nie odczytuje jego konfiguracji zarządzanej.

## Diagnostyka DNS, tras i ścieżki

Osiem checków implementuje `DiagnosticCheck` i zwraca `OperationResult` z kodem przyczyny w typowanym evidence. Teksty dla UI są przypisane do stabilnych kodów `NetworkCheckReason`. Każdy check ma własny limit czasu; próby DNS (`example.com`) i TCP (`1.1.1.1:443`) są wyłącznie odczytowe i nie przechowują odpowiedzi ani publicznego IP. Brak internetu sam w sobie daje ograniczenie środowiska i nie jest dowodem awarii Bonjour. Trasa do lokalnej podsieci jest oceniana z obserwowanej tablicy tras IPv4/IPv6; brak maski adresu interfejsu może dać wynik niejednoznaczny. Porządek resolverów jest oceną kolejności zaobserwowanych wpisów, nie gwarancją kolejności wszystkich zapytań macOS. Proxy/PAC jest sygnałem kandydackim, a nie dowodem pochodzenia z FortiClient. Żaden check nie zmienia konfiguracji ani nie wymaga uprawnień administratora.

## Sesje i raport

`BoundedSessionStore` zapisuje format JSON w `Application Support/NetUnstick/sessions.json` metodą atomową. Format ma wersję 1; maksymalnie przechowuje 20 sesji, 100 wpisów na sesję i plik 4 MB. Uszkodzony plik daje pustą historię z ostrzeżeniem; nieznana wersja formatu zatrzymuje zapis bez nadpisania pliku. Błąd uprawnień i anulowanie są zgłaszane wywołującemu. Raport UTF-8 zawiera nagłówek sesji, czasy, wyniki i wyłącznie typowane, oczyszczone evidence. `ReportRenderer` zwraca treść i model podglądu; interfejs demonstracyjny otwiera dialog zapisu dopiero po podglądzie na żądanie użytkownika. `Logger` zapisuje prywatny rekord bez evidence i nie czyta logów globalnych.

## Dalsze wymagania

Samowystarczalna specyfikacja, scenariusze, kryteria odbioru i macierz pochodzenia wymagań są w [docs/product-requirements.md](docs/product-requirements.md). Granice modułów, prywatności, uprawnień i zasada weryfikacji naprawy są w [docs/architecture.md](docs/architecture.md). Żadna naprawa nie jest uznana za skuteczną bez odtworzonej awarii i poprawy sprawdzenia przed/po.

## Bonjour i scenariusze Fortinet

`BonjourDiscoveryChecking` przegląda wyłącznie `_airplay._tcp` i `_raop._tcp` przez `NWBrowser`, z limitem czasu i anulowaniem. Nie łączy się z odbiornikami. Wynik podaje osobno liczbę usług obu typów, typ interfejsu i stabilny kod przyczyny. Nie utrwala nazwy urządzenia, endpointu, rekordu TXT, adresu ani portu. Brak usług jest wynikiem niejednoznacznym, nie usterką; sama obecność usługi nie dowodzi działania przesyłania. `LocalMulticastPathCheck` sprawdza obecność fizycznego interfejsu i lokalnej trasy; nawet poprawna trasa nie dowodzi transportu mDNS. `BonjourPermissionCheck` odróżnia systemową odmowę dostępu od błędu browsera; macOS może nie ujawnić zgody osobnym API. Aplikacja deklaruje tylko używane typy Bonjour i lokalizowany cel dostępu do sieci lokalnej. Test live reklamuje fikcyjną usługę; bez zgody lub widoczności mDNS kończy się jako skipped.

`FortinetScenarioClassifier` używa wyłącznie publicznego snapshotu i wyników checków. Rozpoznaje kandydackie: trasę podsieci przez tunel, pozostały resolver/search domain lub proxy, osierocony tunel, blokadę lokalnej sieci przy aktywnym VPN oraz możliwy problem klienta albo infrastruktury wielosegmentowej. Każdy wynik jest hipotezą z listą dowodów potrzebnych do potwierdzenia i bezpiecznym krokiem kontaktu z administratorem. Metadane wersji FortiClient są opcjonalne i ograniczone do numeru wersji z publicznego bundla aplikacji. Brak wersji nie jest błędem; nie odczytujemy ustawień zarządzanych, poświadczeń ani plików prywatnych. Wskazówka nie stwierdza przyczyny konkretnej awarii, a naprawa polityki FortiGate/EMS nie jest dostępna w aplikacji.

## Interfejs demonstracyjny

Argument `--scenario=<nazwa>` wybiera deterministyczny scenariusz: `healthy`, `dns-residue`, `route-blocked`, `bonjour-denied`, `no-receiver`, `vpn-active`, `vpn-unknown`, `operation-progress`, `permission-denied`, `timeout`, `repair-success` lub `repair-failure`. Bez argumentu aplikacja pokazuje stan nieznany i pustą historię. Przycisk diagnostyki wykonuje wyłącznie operację mocka. Kandydat naprawy oraz potwierdzenie też są symulacją; nie zmieniają sieci. Pomocnik nie jest instalowany. Eksport wymaga otwarcia podglądu i jawnego zapisu przez systemowy dialog; plik UTF-8 używa formatu raportu `ReportRenderer` 1. Skróty: ⌘D diagnostyka, Esc anulowanie, ⇧⌘E podgląd raportu. Testy UI są w `NetUnstickUITests`; samokończący się skrypt `Tools/CaptureMatrix.sh` zapisuje 12 zrzutów do `Artifacts/ScreenshotMatrix`. Flagi `--ui-light`, `--ui-dark` i `--ui-contrast` służą tylko do testów wyglądu. Zwykłe uruchomienie używa preferencji systemowych.
