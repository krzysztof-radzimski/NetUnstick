# NetUnstick

NetUnstick jest natywną aplikacją macOS w Swift i SwiftUI. Jej planowany cel to diagnozowanie problemów z dostępem do urządzeń lokalnych po rozłączeniu VPN, w pierwszej kolejności FortiClient/FortiGate. Obecna wersja otwiera standardowe okno. Biblioteka `NetUnstickNetwork` udostępnia odczyt stanu sieci i ostrożną ocenę VPN, lecz sprawdzenie nie jest jeszcze podłączone do interfejsu. Nie zmienia ustawień i nie wymaga podwyższonych uprawnień.

Minimalna wersja systemu to **macOS 14.0** (`MACOSX_DEPLOYMENT_TARGET = 14.0`). Projekt używa lokalnego pakietu `Packages/NetUnstickKit` z modułami `NetUnstickCore`, `NetUnstickNetwork` i `NetUnstickRepair`. `NetUnstickCore` zawiera kontrakty wyników i operacji, typowaną redakcję evidence, rejestr sesji oraz renderer raportu. Moduł napraw pozostaje pustym punktem rozszerzenia. Nie ma zależności zewnętrznych.

## Budowanie i testowanie

Wymagane są Xcode i narzędzia wiersza poleceń Apple. Z katalogu repozytorium:

```sh
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstick -configuration Debug -showBuildSettings | rg MACOSX_DEPLOYMENT_TARGET
cd Packages/NetUnstickKit && swift test
NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter ReadOnlySmokeTests
```

Schemat `NetUnstick` jest współdzielony. Smoke test uruchamia się osobno na macOS; obserwuje host bez zmian i zapisuje wyłącznie zredagowany JSON do `.build/netunstick-smoke-redacted.json` w katalogu pakietu. Brak VPN jest prawidłowym wynikiem. Testy `NetUnstickCore` sprawdzają kontrakty, redakcję, limity i błędy magazynu. Testy `NetUnstickNetwork` obejmują parsery, decyzję VPN, procesy i prywatność. `NetUnstickRepair` potwierdza obecnie tylko dostępność modułu.

## Odczyt sieci i ograniczenia

`SystemNetworkStateCollector` odczytuje `NWPath`, aktywne interfejsy, trasy, DNS, proxy i wybrane klucze dynamic store. Dla tras używa wyłącznie stałych poleceń odczytowych `/usr/sbin/netstat`; wykonawca ma limit czasu i wyjścia, sprawdza exit status i obsługuje anulowanie. Nie uruchamia powłoki. Żadna z tych operacji nie wymaga uprawnień administratora. Snapshot surowy jest krótkotrwały i nie jest kodowany ani logowany. `SanitizedNetworkSnapshot` zawiera tylko typy, liczby, obecność i losowo zasolone identyfikatory korelacyjne; do `OperationResult` trafia jeszcze węższy zestaw typowanych evidence.

`VPNStateDetector` zwraca `active`, `inactive` albo `unknown` ze stabilnym kodem przyczyny. Błąd częściowy, sprzeczne sygnały i ślad tunelu po rozłączeniu dają `unknown`, który blokuje przyszłe akcje zmieniające sieć tak samo jak `active`. Wynik obcego klienta VPN może pozostać nieustalony; sam proces FortiClient ani pojedyncze API nie dowodzi rozłączenia. Po rozłączeniu można pobrać kilka próbek w ograniczonym oknie. Kolektor nie steruje FortiClient ani nie odczytuje jego konfiguracji zarządzanej.

## Sesje i raport

`BoundedSessionStore` zapisuje format JSON w `Application Support/NetUnstick/sessions.json` metodą atomową. Format ma wersję 1; maksymalnie przechowuje 20 sesji, 100 wpisów na sesję i plik 4 MB. Uszkodzony plik daje pustą historię z ostrzeżeniem; nieznana wersja formatu zatrzymuje zapis bez nadpisania pliku. Błąd uprawnień i anulowanie są zgłaszane wywołującemu. Raport UTF-8 zawiera nagłówek sesji, czasy, wyniki i wyłącznie typowane, oczyszczone evidence. `ReportRenderer` zwraca treść i model podglądu; dialog zapisu nie jest jeszcze podłączony. `Logger` zapisuje prywatny rekord bez evidence i nie czyta logów globalnych.

## Dalsze wymagania

Samowystarczalna specyfikacja, scenariusze, kryteria odbioru i macierz pochodzenia wymagań są w [docs/product-requirements.md](docs/product-requirements.md). Granice modułów, prywatności, uprawnień i zasada weryfikacji naprawy są w [docs/architecture.md](docs/architecture.md). Żadna naprawa nie jest uznana za skuteczną bez odtworzonej awarii i poprawy sprawdzenia przed/po.
