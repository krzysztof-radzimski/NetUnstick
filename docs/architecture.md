# Architektura NetUnstick

## Stan i kierunek

Obecny kod ma okno SwiftUI i trzy rozdzielone moduły. `NetUnstickCore` implementuje wspólne kontrakty wyników, redakcję, historię i renderer raportu. `NetUnstickNetwork` implementuje odczyt stanu, konserwatywną ocenę VPN oraz diagnostykę sieci i Bonjour. Helper udostępnia wąskie operacje dla przyszłych napraw; skuteczna naprawa nie została jeszcze potwierdzona na rzeczywistym incydencie. Poniższe kontrakty wyznaczają granice dla kolejnych prac.

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

Proces aplikacji jest nieuprzywilejowany. Opcjonalny helper jest osobną granicą zaufania: wąskie API o zamkniętej liście operacji, walidacja argumentów i uprawnionego klienta, ponowny odczyt stanu VPN przed zmianą oraz strukturalna odpowiedź. Aplikacja nie przekazuje helperowi arbitralnych poleceń ani tekstu shell. Stała ścieżka programu i tablica argumentów, limit czasu, kod wyjścia oraz sanitacja wyniku są obowiązkowe. Dokładny zakres uprawnień opisuje sekcja poniżej.

## Dane i testy

Granica prywatności przebiega przed Logger, historią i eksportem. Domyślnie usuwać lub redagować nazwy urządzeń, SSID, publiczne IP, domeny wewnętrzne, sekrety i zawartość pakietów. Wyjście polecenia jest poufne do czasu sanitacji. Historia ma limit; eksport korzysta wyłącznie z niej, nie z globalnych logów. Testy przyszłych modułów mają obejmować decyzje przy brakujących obserwacjach, VPN active/unknown, sukces/porażkę ponownego sprawdzenia oraz redakcję i błędy eksportu. Testy nie mogą tylko powtarzać implementacji.

## Uprzywilejowany helper (macOS 14+)

`NetUnstickHelper` jest osobnym LaunchDaemon uruchamianym jako root dopiero po jawnym
`SMAppService.daemon(...).register()` i zatwierdzeniu przez administratora w Elementach
logowania. Plist jest osadzony w `Contents/Library/LaunchDaemons`, a wykonywalny
helper w `Contents/MacOS`. Diagnozy są od niego niezależne. Aplikacja nie wywołuje
rejestracji automatycznie; pokazuje status `notRegistered`, `enabled`,
`requiresApproval`, `notFound` i przycisk otwierający właściwy panel systemowy.

XPC przyjmuje tylko wersję 1 oraz trzy przypadki zamkniętego enumu: odświeżenie
cache resolvera i mDNS, żądanie ponownej konfiguracji DHCP fizycznego interfejsu
`enN`, usunięcie jednej osieroconej trasy IPv4 do prywatnego lub link-local
prefiksu przez brakujący interfejs `enN`. Żądanie nie ma ścieżki programu,
shell stringu ani listy argumentów. Helper ponownie czyta stan i odmawia przy
VPN active/unknown, częściowym odczycie, wielu pasujących trasach, trasie
domyślnej, publicznej sieci, tunelu lub braku potwierdzenia DHCP. Usunięcie trasy
wykorzystuje dokładny prefiks, bramę i zakres interfejsu. Dwa odczyty przed
usunięciem ograniczają wyścig, ale nie gwarantują atomowości; nieudane polecenie
jest zgłaszane jako błąd, a sukces polecenia wymaga późniejszego ponownego checku.

DHCP korzysta z `SCNetworkInterfaceForceConfigurationRefresh`; wymaga root.
Cache używa wyłącznie `/usr/bin/dscacheutil -flushcache` i
`/usr/bin/killall -HUP mDNSResponder`, a trasa `/sbin/route` ze stałą składnią.
Proces nie używa powłoki, ma ograniczone środowisko, limit pięciu sekund i 4 KiB
łącznego wyjścia; surowe bajty nie trafiają do odpowiedzi ani logu. Kod 0
potwierdza wykonanie akcji, nie rozwiązanie problemu. Wynik ma kod, czas,
result i zwykły następny krok. Nie ma ingerencji w FortiClient/FortiGate.

Listener wymaga klienta o identyfikatorze `org.netunstick.NetUnstick`, kotwicy
Apple generic i identycznym Team ID jak podpis helpera. Helper bez Team ID nie
uruchamia usługi. Dystrybucja wymaga podpisania aplikacji i osadzonego helpera
tym samym zespołem Developer ID lub Apple Development. Build bez podpisu służy
wyłącznie testom kompilacji i pakowania; nie można nim zarejestrować działającego
daemona. Sama rejestracja wymaga zgody systemowej i nie jest częścią testów CI.
