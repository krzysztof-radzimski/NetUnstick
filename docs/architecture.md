# Architektura NetUnstick

## Stan i kierunek

Obecny kod ma okno SwiftUI i trzy rozdzielone moduły. `NetUnstickCore` implementuje wspólne kontrakty wyników, redakcję, historię i renderer raportu. `NetUnstickNetwork` implementuje odczyt stanu, konserwatywną ocenę VPN i kontrole sieci; nie są jeszcze podłączone do UI. `NetUnstickRepair` zawiera opcjonalny helper dla przyszłych jawnych napraw. Interfejs jest demonstracyjny i oparty na mockach. Poniższe kontrakty wyznaczają granice dla kolejnych prac.

| Odpowiedzialność | Miejsce | Kontrakt |
| --- | --- | --- |
| Zbieranie stanu | `NetUnstickNetwork` | Odczyt `NWPath`, `getifaddrs`, SystemConfiguration i tras z ograniczonego procesu. Testy Bonjour są oddzielnymi operacjami NWBrowser; testy połączenia z urządzeniem pozostają przyszłym zakresem. Bez zmian konfiguracji. |
| Diagnoza | `NetUnstickCore` | Czyste decyzje na oczyszczonych obserwacjach; wynik „nieustalone”, gdy danych brakuje. Stabilne kody i strukturalne wyniki. |
| Pojedyncze naprawy | `NetUnstickRepair` | Oddzielna jawna akcja, ograniczony zakres i czas, kontrola stanu VPN, ponowny test. Kandydat pozostaje niezweryfikowany do realnego incydentu. |
| Rejestr sesji i eksport | `NetUnstickCore` | `Logger` do diagnostyki; ograniczona historia aplikacji i oczyszczony raport UTF-8. Podłączenie podglądu i dialogu zapisu do UI jest kolejnym krokiem. |
| Prezentacja | `App`, `Features`, `Resources` | Stan, postęp, wynik, następny krok i rozwijane szczegóły; widoczne zwykłe okno i Dock. `TestSupport` dla testowych danych i atrap. |

## Sekwencja sprawdzenia i naprawy

Diagnoza: obserwacja → niezależne kontrole read-only → strukturalne wyniki i ostrożna decyzja. Naprawa: **before → check → action → after → recheck**. Zapisuje się przed/po istotny stan i wynik *tego samego* sprawdzenia. Poprawny exit code akcji potwierdza tylko wykonanie polecenia, nie naprawę. Timeout, anulowanie, brak uprawnień, pominięcie i błąd mają odrębne wyniki. Każdy wynik ma początek/koniec, outcome, oczyszczone dowody i stabilny kod błędu w przypadku niepowodzenia. Bez nieskończonych ponowień.

Warunek bezpieczeństwa jest sprawdzany tuż przed każdą akcją zmieniającą sieć: **VPN active lub VPN unknown = żadnych zmian sieci** i komunikat z przyczyną. Zmiana stanu VPN pomiędzy diagnozą a akcją wymaga ponownej oceny. Nie wolno zbiorczo usuwać tras, DNS, zapory czy usług, zmieniać FortiClient/FortiGate ani wyłączać ochrony lub restartować systemu.

## Granica zaufania i uprawnienia

Proces aplikacji jest nieuprzywilejowany. Opcjonalny helper jest osobną granicą zaufania: wąskie API o zamkniętej liście operacji, walidacja argumentów i uprawnionego klienta, ponowny odczyt stanu VPN przed zmianą oraz strukturalna odpowiedź. Aplikacja nie przekazuje helperowi arbitralnych poleceń ani tekstu shell. Szczegółowy zakres i wymagania podpisu opisano poniżej.

## Dane i testy

Granica prywatności przebiega przed Logger, historią i eksportem. Domyślnie usuwać lub redagować nazwy urządzeń, SSID, publiczne IP, domeny wewnętrzne, sekrety i zawartość pakietów. Wyjście polecenia jest poufne do czasu sanitacji. Historia ma limit; eksport korzysta wyłącznie z niej, nie z globalnych logów. Testy przyszłych modułów mają obejmować decyzje przy brakujących obserwacjach, VPN active/unknown, sukces/porażkę ponownego sprawdzenia oraz redakcję i błędy eksportu. Testy nie mogą tylko powtarzać implementacji.

## Uprzywilejowany helper (macOS 14+)

`NetUnstickHelper` jest osobnym LaunchDaemon uruchamianym jako root dopiero po jawnej rejestracji przez `SMAppService.daemon(...).register()` i zatwierdzeniu przez administratora w Elementach logowania. Plist jest osadzony w `Contents/Library/LaunchDaemons`, a wykonywalny helper w `Contents/MacOS`. Diagnozy są od niego niezależne. Interfejs demonstracyjny nie rejestruje ani nie używa helpera; przyszła integracja musi wywoływać rejestrację tylko po jawnym wyborze naprawy przez użytkownika.

XPC przyjmuje tylko wersję 1 oraz trzy przypadki zamkniętego enumu: odświeżenie cache resolvera i mDNS, żądanie ponownej konfiguracji DHCP fizycznego interfejsu `enN`, usunięcie jednej osieroconej trasy IPv4 do prywatnego lub link-local prefiksu przez brakujący interfejs `enN`. Żądanie nie ma ścieżki programu, shell stringu ani listy argumentów. Helper ponownie czyta stan i odmawia przy VPN active/unknown, częściowym odczycie, wielu pasujących trasach, trasie domyślnej, publicznej sieci, tunelu lub braku potwierdzenia DHCP. Usunięcie trasy wykorzystuje dokładny prefiks, bramę i zakres interfejsu. Dwa odczyty przed usunięciem ograniczają wyścig, ale nie gwarantują atomowości. Po każdej akcji wymagany jest ponowny check w warstwie napraw; wynik helpera potwierdza wykonanie akcji, nie rozwiązanie problemu.

DHCP korzysta z `SCNetworkInterfaceForceConfigurationRefresh`; wymaga root. Cache używa wyłącznie `/usr/bin/dscacheutil -flushcache` i `/usr/bin/killall -HUP mDNSResponder`, z ponowną oceną VPN przed drugą komendą. Trasa używa `/sbin/route` ze stałą składnią. Proces nie używa powłoki, ma ograniczone środowisko, limit pięciu sekund na polecenie i 4 KiB łącznego wyjścia; klient XPC czeka najwyżej 30 sekund na odpowiedź. Surowe bajty nie trafiają do odpowiedzi ani logu. Nie ma ingerencji w FortiClient/FortiGate.

Listener wymaga klienta o identyfikatorze `org.netunstick.NetUnstick` i dokładnie tym samym certyfikacie podpisu co helper. Helper odczytuje odcisk SHA-1 certyfikatu z własnego, poprawnego podpisu i tworzy wymaganie `certificate leaf = H"…"`; bez certyfikatu lub przy błędnym podpisie nie uruchamia usługi. SHA-1 jest tutaj identyfikatorem certyfikatu używanym przez składnię wymagań macOS, nie skrótem danych diagnostycznych. Lokalny certyfikat self-signed `NetUnstick Local Code Signing` jest przechowywany w pęku kluczy użytkownika i ponownie używany przy każdej przebudowie. Build bez podpisu służy tylko testom kompilacji i pakowania. Rzeczywista rejestracja przez `SMAppService` pozostaje niezweryfikowana dla lokalnego certyfikatu i nadal wymaga zgody systemowej administratora; podpis self-signed nie daje notaryzacji ani nie zastępuje tej zgody.
