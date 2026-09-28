# NetUnstick

NetUnstick jest natywną aplikacją macOS w Swift i SwiftUI do diagnozowania problemów z dostępem do urządzeń lokalnych po rozłączeniu VPN, w pierwszej kolejności FortiClient/FortiGate. Ekran Stan obserwuje stan VPN i uruchamia rzeczywisty `DiagnosisEngine` na jawne żądanie. Pokazuje postęp jedenastu checków, ich zredagowane wyniki i kandydatów z `RepairCatalog`. Diagnostyka pozostaje wyłącznie odczytowa i nie wymaga administratora. Żadna naprawa nie uruchamia się automatycznie.

Minimalna wersja systemu to **macOS 14.0** (`MACOSX_DEPLOYMENT_TARGET = 14.0`). Projekt używa lokalnego pakietu `Packages/NetUnstickKit` z modułami `NetUnstickCore`, `NetUnstickNetwork` i `NetUnstickRepair`. `NetUnstickCore` zawiera kontrakty wyników i operacji, typowaną redakcję evidence, rejestr sesji oraz renderer raportu. Opcjonalny helper XPC wykonuje wyłącznie jawnie potwierdzone, wąskie akcje. Tryby `--scenario=` są dostępne tylko w konfiguracji Debug do deterministycznych testów UI; zwykłe uruchomienie używa rzeczywistych usług. Nie ma zależności zewnętrznych.

Ikona Dock to własny znak trzech węzłów i przywróconej ścieżki. Projekt używa kompletnego `AppIcon.appiconset` zgodnego z macOS 14.0; warianty źródłowe Default, Dark, Mono/Tinted i Clear oraz instrukcja odtwarzania są w [Design/AppIcon/README.md](Design/AppIcon/README.md). Automatyczne przełączanie tych wariantów przez system wymaga zweryfikowanego zasobu `.icon` i obecnie nie jest deklarowane.

## Kandydackie naprawy

`RepairPlanBuilder` mapuje wybrane kody diagnostyczne na ponowienie checku i odnowienie DHCP dla jednego potwierdzonego interfejsu. Interfejs pokazuje kandydatów i `ConfirmationSummary`; wybrany plan przechodzi przez `RepairExecutor` dopiero po potwierdzeniu. Plan jest propozycją, nie obietnicą naprawy. Odnowienie DHCP jest oferowane tylko przy potwierdzeniu jednego interfejsu DHCP w odczytowych metadanych `SystemConfiguration` i ponownej walidacji w executorze oraz helperze. Brak takich danych oznacza brak tej propozycji. Usunięcie trasy po nieistniejącym tunelu nie jest oferowane: aktualny detektor ocenia taki stan jako VPN `unknown`, a helper dopuszcza tylko nieobecny interfejs fizyczny `en*`.

`RepairExecutor` wymaga jawnego wywołania po potwierdzeniu przez użytkownika oraz zapisu do `BoundedSessionStore` przed zmianą. Błąd zapisu zatrzymuje akcję. Przed zmianą ponownie sprawdza diagnozę, VPN i zasób; helper powtarza walidację. Po akcji zbiera stan i uruchamia powiązany check. Sukces oznacza dopiero poprawny recheck. Pogorszenie ścieżki, utrata fizycznego interfejsu, resolverów lub trasy domyślnej daje osobny błąd `state_worsened`. Aktywny lub nieznany VPN blokuje zmianę; wyniki `vpn_active` i `vpn_unknown` zawierają odrębne wskazówki. Proxy/PAC i podejrzenia ustawień Fortinet wymagają kontaktu z administratorem. Odnowienie DHCP wymaga zatwierdzenia uprzywilejowanego helpera; brak rejestracji lub odmowa jest raportowana. Globalne czyszczenie cache resolvera i restart mDNSResponder zostały wyłączone; starsze żądanie XPC odświeżenia cache jest odrzucane. Protokół helpera nie oferuje bezpiecznej operacji odwrotnej, więc automatyczny rollback nie jest wykonywany.

## Budowanie i testowanie

Wymagane są Xcode i narzędzia wiersza poleceń Apple. Z katalogu repozytorium:

```sh
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath Artifacts/DerivedData CODE_SIGNING_ALLOWED=NO clean build
NetUnstick/TestSupport/check-helper-bundle.sh Artifacts/DerivedData/Build/Products/Debug/NetUnstick.app
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath Artifacts/SignedDerivedData CODE_SIGNING_ALLOWED=YES build
NetUnstick/TestSupport/check-helper-bundle.sh Artifacts/SignedDerivedData/Build/Products/Debug/NetUnstick.app --require-stable-signing
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath Artifacts/DerivedData -only-testing:NetUnstickPresentationTests CODE_SIGNING_ALLOWED=NO test
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath Artifacts/UITestDerivedData -parallel-testing-enabled NO -only-testing:NetUnstickUITests CODE_SIGNING_ALLOWED=YES test
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -showBuildSettings | rg MACOSX_DEPLOYMENT_TARGET
cd Packages/NetUnstickKit && swift test
NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter ReadOnlySmokeTests
NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter HostDiagnosisSmokeTests
NETUNSTICK_BONJOUR_LIVE=1 swift test --filter BonjourDiscoveryTests/testLocalAdvertiserHarness
```

Schemat `NetUnstick` jest współdzielony. Smoke test uruchamia się osobno na macOS; obserwuje host bez zmian i zapisuje wyłącznie zredagowany JSON do `.build/netunstick-smoke-redacted.json` w katalogu pakietu. Brak VPN jest prawidłowym wynikiem. Testy `NetUnstickCore` sprawdzają kontrakty, redakcję, limity i błędy magazynu. Testy `NetUnstickNetwork` obejmują parsery, decyzję VPN, procesy, prywatność oraz tablice decyzji diagnostycznych. Smoke test diagnozy uruchamia aktualny kolektor i checki na hoście; aktywny VPN lub brak internetu dają wynik inconclusive/skipped. `NetUnstickRepair` testuje odmowy i mapowanie odpowiedzi helpera. Produkty lokalnego pakietu Swift są linkowane statycznie, a skrypt pakowania sprawdza brak zależności od frameworków pakietu poza bundlem. Testy UI wymagają aktywnej sesji graficznej i zgody systemu na automatyzację; runner jest podpisywany lokalnie ad hoc. Build `CODE_SIGNING_ALLOWED=NO` weryfikuje kompilację i pakowanie, ale nie pozwala zarejestrować daemona.

Buildy z `CODE_SIGNING_ALLOWED=YES` podpisują aplikację i helper certyfikatem **NetUnstick Local Code Signing**. Skrypt `Tools/CreateLocalSigningIdentity.sh` tworzy go tylko raz w pęku kluczy `login` i ustawia zaufanie użytkownika wyłącznie dla podpisywania kodu; macOS może poprosić o zgodę. Klucz prywatny nie trafia do repozytorium. Nie uruchamiaj ponownie tworzenia nowego certyfikatu zamiast istniejącego: zmiana certyfikatu zmieni tożsamość aplikacji. Kolejne przebudowy używają tego samego certyfikatu, a kontrola `--require-stable-signing` sprawdza zgodność podpisów i wymaganie klienta XPC. Self-signed służy tylko do lokalnych buildów, nie daje notaryzacji ani automatycznej akceptacji przez Gatekeeper. Rejestracja daemona wymaga jawnej akcji w Ustawieniach aplikacji i zgody administratora w Elementach logowania; działającej rejestracji z tym podpisem nie potwierdzono.

## Uprawnienia

Zwykła diagnostyka nie wymaga administratora. Odkrywanie Bonjour korzysta z uprawnienia macOS „Sieć lokalna”; odmowa daje odrębny wynik i wskazówkę sprawdzenia zgody. Uruchomienie naprawy DHCP wymaga rejestracji helpera XPC i zatwierdzenia przez administratora w Elementach logowania. Aplikacja nie zatwierdza helpera samodzielnie i nie czeka na takie zatwierdzenie podczas diagnostyki.

## Odczyt sieci i ograniczenia

Obecny interfejs nie przyjmuje znanego adresu urządzenia do testu połączenia. Diagnostyka używa stałych celów kontrolnych i obserwacji lokalnej.

`SystemNetworkStateCollector` odczytuje `NWPath`, aktywne interfejsy, trasy, DNS, proxy i wybrane klucze dynamic store. Dla tras używa wyłącznie stałych poleceń odczytowych `/usr/sbin/netstat`; wykonawca ma limit czasu i wyjścia, sprawdza exit status i obsługuje anulowanie. Nie uruchamia powłoki. Żadna z tych operacji nie wymaga uprawnień administratora. Snapshot surowy jest krótkotrwały i nie jest kodowany ani logowany. `SanitizedNetworkSnapshot` zawiera tylko typy, liczby, obecność i losowo zasolone identyfikatory korelacyjne; do `OperationResult` trafia jeszcze węższy zestaw typowanych evidence.

`VPNStateDetector` zwraca `active`, `inactive` albo `unknown` ze stabilnym kodem przyczyny. Błąd częściowy, sprzeczne sygnały i ślad tunelu po rozłączeniu dają `unknown`, który blokuje przyszłe akcje zmieniające sieć tak samo jak `active`. Wynik obcego klienta VPN może pozostać nieustalony; sam proces FortiClient ani pojedyncze API nie dowodzi rozłączenia. Po rozłączeniu można pobrać kilka próbek w ograniczonym oknie. Kolektor nie steruje FortiClient ani nie odczytuje jego konfiguracji zarządzanej.

## Diagnostyka DNS, tras i ścieżki

Osiem checków implementuje `DiagnosticCheck` i zwraca `OperationResult` z kodem przyczyny w typowanym evidence. Teksty dla UI są przypisane do stabilnych kodów `NetworkCheckReason`. Każdy check ma własny limit czasu; próby DNS (`example.com`) i TCP (`1.1.1.1:443`) są wyłącznie odczytowe i nie przechowują odpowiedzi ani publicznego IP. Brak internetu sam w sobie daje ograniczenie środowiska i nie jest dowodem awarii Bonjour. Trasa do lokalnej podsieci jest oceniana z obserwowanej tablicy tras IPv4/IPv6; brak maski adresu interfejsu może dać wynik niejednoznaczny. Porządek resolverów jest oceną kolejności zaobserwowanych wpisów, nie gwarancją kolejności wszystkich zapytań macOS. Proxy/PAC jest sygnałem kandydackim, a nie dowodem pochodzenia z FortiClient. Żaden check nie zmienia konfiguracji ani nie wymaga uprawnień administratora.

## Sesje i raport

`BoundedSessionStore` zapisuje format JSON w `Application Support/NetUnstick/sessions.json` metodą atomową. Format ma wersję 1; maksymalnie przechowuje 20 sesji, 100 wpisów na sesję i plik 4 MB. Uszkodzony plik daje pustą historię z ostrzeżeniem; nieznana wersja formatu zatrzymuje zapis bez nadpisania pliku. Błąd uprawnień i anulowanie są zgłaszane wywołującemu. Raport UTF-8 zawiera nagłówek sesji, czasy, wyniki i wyłącznie typowane, oczyszczone evidence. `ReportRenderer` zasila podgląd wybranej sesji; standardowy dialog zapisu otwiera się dopiero po jawnym kliknięciu „Zapisz raport…”. `Logger` zapisuje prywatny rekord bez evidence i nie czyta logów globalnych. Nie ma telemetrii ani wysyłki raportów w tle.

## Dalsze wymagania

Samowystarczalna specyfikacja, scenariusze, kryteria odbioru i macierz pochodzenia wymagań są w [docs/product-requirements.md](docs/product-requirements.md). Wyniki testów i ograniczenia środowiskowe są w [docs/verification.md](docs/verification.md). Granice modułów, prywatności, uprawnień i zasada weryfikacji naprawy są w [docs/architecture.md](docs/architecture.md). Żadna naprawa nie jest uznana za skuteczną bez odtworzonej awarii i poprawy sprawdzenia przed/po.

## Bonjour i scenariusze Fortinet

`BonjourDiscoveryChecking` przegląda wyłącznie `_airplay._tcp` i `_raop._tcp` przez `NWBrowser`, z limitem czasu i anulowaniem. Nie łączy się z odbiornikami. Wynik podaje osobno liczbę usług obu typów, typ interfejsu i stabilny kod przyczyny. Nie utrwala nazwy urządzenia, endpointu, rekordu TXT, adresu ani portu. Brak usług jest wynikiem niejednoznacznym, nie usterką; sama obecność usługi nie dowodzi działania przesyłania. `LocalMulticastPathCheck` sprawdza obecność fizycznego interfejsu i lokalnej trasy; nawet poprawna trasa nie dowodzi transportu mDNS. `BonjourPermissionCheck` odróżnia systemową odmowę dostępu od błędu browsera; macOS może nie ujawnić zgody osobnym API. Aplikacja deklaruje tylko używane typy Bonjour i lokalizowany cel dostępu do sieci lokalnej. Test live wystawia krótkotrwałą fikcyjną usługę i sprawdza jej typ przez systemową przeglądarkę; przeszedł na tym hoście po poprawie testowego listenera. Brak zgody lub widoczności mDNS może nadal spowodować pominięcie testu.

`FortinetScenarioClassifier` używa wyłącznie publicznego snapshotu i wyników checków. Rozpoznaje kandydackie: trasę podsieci przez tunel, pozostały resolver/search domain lub proxy, osierocony tunel, blokadę lokalnej sieci przy aktywnym VPN oraz możliwy problem klienta albo infrastruktury wielosegmentowej. Każdy wynik jest hipotezą z listą dowodów potrzebnych do potwierdzenia i bezpiecznym krokiem kontaktu z administratorem. Metadane wersji FortiClient są opcjonalne i ograniczone do numeru wersji z publicznego bundla aplikacji. Brak wersji nie jest błędem; nie odczytujemy ustawień zarządzanych, poświadczeń ani plików prywatnych. Wskazówka nie stwierdza przyczyny konkretnej awarii, a naprawa polityki FortiGate/EMS nie jest dostępna w aplikacji.

## Interfejs i tryby testowe

Wydanie produkcyjne rozpoczyna od obserwacji VPN i pustej lub zapisanej historii. Po stabilnym rozłączeniu pokazuje banner i proponuje diagnostykę. Aktywny lub niepewny VPN blokuje zmiany również przy ponownej ocenie po kliknięciu potwierdzenia. Status helpera jest w Ustawieniach; rejestracja i otwarcie Elementów logowania są jawnymi akcjami. Diagnostyka nie czeka na zatwierdzenie helpera. Po naprawie UI pokazuje „Naprawiono” tylko dla wyniku `success` z potwierdzającym recheckiem; inne wyniki zachowują odrębne stany.

W konfiguracji Debug argument `--scenario=<nazwa>` wybiera deterministyczny scenariusz prezentacyjny: `healthy`, `dns-residue`, `route-blocked`, `bonjour-denied`, `no-receiver`, `vpn-active`, `vpn-unknown`, `operation-progress`, `permission-denied`, `timeout`, `repair-success` lub `repair-failure`. Argument `--integration-scenario=` uruchamia prawdziwy composition root z fake granicą systemu dla scenariuszy `healthy`, `fault`, `verified`, `unresolved`, `vpn-active` i `vpn-unknown`; zapis testowych sesji pozostaje w `DerivedData/UITestSessions`. Bez argumentu również Debug używa prawdziwych usług. Flagi `--ui-light`, `--ui-dark`, `--ui-contrast`, `--ui-large-text` i `--ui-reduce-motion` służą testom wyglądu; ostatnia wyłącza animacje transakcji SwiftUI tylko w Debug i nie zmienia ustawienia systemowego. Skróty: ⌘D diagnostyka, Esc anulowanie, ⇧⌘E podgląd raportu. Brak FortiClient, odbiornika AirPlay, internetu lub zgody na sieć lokalną jest prawidłowym stanem środowiska; check może wtedy zwrócić `skipped`, `permissionDenied` lub wynik niejednoznaczny.
