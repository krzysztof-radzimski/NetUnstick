# Architektura NetUnstick

## Stan i kierunek

Obecny kod ma okno SwiftUI i trzy rozdzielone moduły. `NetUnstickCore` implementuje wspólne kontrakty wyników, redakcję, historię i renderer raportu. `NetUnstickNetwork` dostarcza podłączone do UI odczyt stanu, konserwatywną ocenę VPN i kontrole sieci. `NetUnstickRepair` zawiera planowanie, wykonanie jawnych napraw oraz opcjonalny helper. Zwykłe uruchomienie korzysta z rzeczywistych usług; atrapy są dostępne wyłącznie w trybach testowych Debug. Żadnej naprawy nie potwierdzono jeszcze na odtworzonej usterce.

| Odpowiedzialność | Miejsce | Kontrakt |
| --- | --- | --- |
| Zbieranie stanu | `NetUnstickNetwork` | Odczyt `NWPath`, `getifaddrs`, SystemConfiguration i tras z ograniczonego procesu. Testy Bonjour są oddzielnymi operacjami NWBrowser; testy połączenia z urządzeniem pozostają przyszłym zakresem. Bez zmian konfiguracji. |
| Diagnoza | `NetUnstickCore` | Czyste decyzje na oczyszczonych obserwacjach; wynik „nieustalone”, gdy danych brakuje. Stabilne kody i strukturalne wyniki. |
| Pojedyncze naprawy | `NetUnstickRepair` | Oddzielna jawna akcja, ograniczony zakres i czas, kontrola stanu VPN, ponowny test. Kandydat pozostaje niezweryfikowany do realnego incydentu. |
| Rejestr sesji i eksport | `NetUnstickCore` | `Logger` do diagnostyki; ograniczona historia aplikacji i oczyszczony raport UTF-8. UI udostępnia podgląd i jawnie otwierany dialog zapisu. |
| Prezentacja | `App`, `Features`, `Resources` | Stan, postęp, wynik, następny krok i rozwijane szczegóły; widoczne zwykłe okno i Dock. `TestSupport` dla testowych danych i atrap. |

## Sekwencja sprawdzenia i naprawy

Diagnoza: obserwacja → niezależne kontrole read-only → strukturalne wyniki i ostrożna decyzja. Naprawa: **before → check → action → after → recheck**. Zapisuje się przed/po istotny stan i wynik *tego samego* sprawdzenia. Poprawny exit code akcji potwierdza tylko wykonanie polecenia, nie naprawę. Timeout, anulowanie, brak uprawnień, pominięcie i błąd mają odrębne wyniki. Każdy wynik ma początek/koniec, outcome, oczyszczone dowody i stabilny kod błędu w przypadku niepowodzenia. Bez nieskończonych ponowień.

Warunek bezpieczeństwa jest sprawdzany tuż przed każdą akcją zmieniającą sieć: **VPN active lub VPN unknown = żadnych zmian sieci** i komunikat z przyczyną. Zmiana stanu VPN pomiędzy diagnozą a akcją wymaga ponownej oceny. Nie wolno zbiorczo usuwać tras, DNS, zapory czy usług, zmieniać FortiClient/FortiGate ani wyłączać ochrony lub restartować systemu.

## Granica zaufania i uprawnienia

Proces aplikacji jest nieuprzywilejowany. Opcjonalny helper jest osobną granicą zaufania: wąskie API o zamkniętej liście operacji, walidacja argumentów i uprawnionego klienta, ponowny odczyt stanu VPN przed zmianą oraz strukturalna odpowiedź. Aplikacja nie przekazuje helperowi arbitralnych poleceń ani tekstu shell. Szczegółowy zakres i wymagania podpisu opisano poniżej.

## Dane i testy

Granica prywatności przebiega przed Logger, historią i eksportem. Domyślnie usuwane lub redagowane są nazwy urządzeń, SSID, publiczne IP, domeny wewnętrzne, sekrety i zawartość pakietów. Wyjście polecenia jest poufne do czasu sanitacji. Historia ma limit; eksport korzysta wyłącznie z niej, nie z globalnych logów. Testy obejmują decyzje przy brakujących obserwacjach, VPN active/unknown, sukces/porażkę ponownego sprawdzenia oraz redakcję i błędy eksportu.

## Uprzywilejowany helper (macOS 14+)

`NetUnstickHelper` jest osobnym LaunchDaemon uruchamianym jako root dopiero po jawnej rejestracji przez `SMAppService.daemon(...).register()` i zatwierdzeniu przez administratora w Elementach logowania. Plist jest osadzony w `Contents/Library/LaunchDaemons`, a wykonywalny helper w `Contents/MacOS`. Diagnozy są od niego niezależne. UI udostępnia jawną rejestrację w Ustawieniach i korzysta z helpera wyłącznie dla potwierdzonej naprawy, która go wymaga. Rejestracji na rzeczywistym hoście jeszcze nie zweryfikowano.

XPC przyjmuje tylko wersję 1 oraz zamknięty enum. Przypadek odświeżenia cache resolvera i mDNS pozostaje w formacie protokołu, ale jest odrzucany. Dozwolone są żądanie ponownej konfiguracji DHCP fizycznego interfejsu `enN`, usunięcie jednej osieroconej trasy IPv4 do prywatnego lub link-local prefiksu przez brakujący interfejs `enN`. Żądanie nie ma ścieżki programu, shell stringu ani listy argumentów. Helper ponownie czyta stan i odmawia przy VPN active/unknown, częściowym odczycie, wielu pasujących trasach, trasie domyślnej, publicznej sieci, tunelu lub braku potwierdzenia DHCP. Usunięcie trasy wykorzystuje dokładny prefiks, bramę i zakres interfejsu. Dwa odczyty przed usunięciem ograniczają wyścig, ale nie gwarantują atomowości. Po każdej akcji wymagany jest ponowny check w warstwie napraw; wynik helpera potwierdza wykonanie akcji, nie rozwiązanie problemu.

DHCP korzysta z `SCNetworkInterfaceForceConfigurationRefresh`; wymaga root. Globalne czyszczenie cache i sygnał do mDNSResponder nie są wykonywane. Trasa używa `/sbin/route` ze stałą składnią. Proces nie używa powłoki, ma ograniczone środowisko, limit pięciu sekund na polecenie i 4 KiB łącznego wyjścia; klient XPC czeka najwyżej 30 sekund na odpowiedź. Surowe bajty nie trafiają do odpowiedzi ani logu. Nie ma ingerencji w FortiClient/FortiGate.

Listener wymaga klienta o identyfikatorze `org.netunstick.NetUnstick` i dokładnie tym samym certyfikacie podpisu co helper. Helper odczytuje odcisk SHA-1 certyfikatu z własnego, poprawnego podpisu i tworzy wymaganie `certificate leaf = H"…"`; bez certyfikatu lub przy błędnym podpisie nie uruchamia usługi. SHA-1 jest tutaj identyfikatorem certyfikatu używanym przez składnię wymagań macOS, nie skrótem danych diagnostycznych. Lokalny certyfikat self-signed `NetUnstick Local Code Signing` jest przechowywany w pęku kluczy użytkownika i ponownie używany przy każdej przebudowie. Build bez podpisu służy tylko testom kompilacji i pakowania. Rzeczywista rejestracja przez `SMAppService` pozostaje niezweryfikowana dla lokalnego certyfikatu i nadal wymaga zgody systemowej administratora; podpis self-signed nie daje notaryzacji ani nie zastępuje tej zgody.
