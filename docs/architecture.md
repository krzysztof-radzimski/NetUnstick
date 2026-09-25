# Architektura NetUnstick

## Stan i kierunek

Obecny kod jest tylko fundamentem: okno SwiftUI i trzy rozdzielone moduły bez kolektorów, diagnoz ani napraw. Poniższe kontrakty wyznaczają granice dla kolejnych prac.

| Odpowiedzialność | Miejsce | Kontrakt |
| --- | --- | --- |
| Zbieranie stanu | `NetUnstickNetwork` | Tylko odczyt przez wspierane API macOS; obserwacje Wi-Fi, VPN, interfejsów, tras, DNS oraz testy połączenia/Bonjour jako oddzielne operacje. Bez zmian konfiguracji. |
| Diagnoza | `NetUnstickCore` | Czyste decyzje na oczyszczonych obserwacjach; wynik „nieustalone”, gdy danych brakuje. Stabilne kody i strukturalne wyniki. |
| Pojedyncze naprawy | `NetUnstickRepair` | Oddzielna jawna akcja, ograniczony zakres i czas, kontrola stanu VPN, ponowny test. Kandydat pozostaje niezweryfikowany do realnego incydentu. |
| Rejestr sesji i eksport | Docelowo `NetUnstickCore` lub osobny moduł | `Logger` do diagnostyki; ograniczona historia aplikacji i oczyszczony raport UTF-8 dopiero na żądanie, z podglądem i dialogiem zapisu. |
| Prezentacja | `App`, `Features`, `Resources` | Stan, postęp, wynik, następny krok i rozwijane szczegóły; widoczne zwykłe okno i Dock. `TestSupport` dla testowych danych i atrap. |

## Sekwencja sprawdzenia i naprawy

Diagnoza: obserwacja → niezależne kontrole read-only → strukturalne wyniki i ostrożna decyzja. Naprawa: **before → check → action → after → recheck**. Zapisuje się przed/po istotny stan i wynik *tego samego* sprawdzenia. Poprawny exit code akcji potwierdza tylko wykonanie polecenia, nie naprawę. Timeout, anulowanie, brak uprawnień, pominięcie i błąd mają odrębne wyniki. Każdy wynik ma początek/koniec, outcome, oczyszczone dowody i stabilny kod błędu w przypadku niepowodzenia. Bez nieskończonych ponowień.

Warunek bezpieczeństwa jest sprawdzany tuż przed każdą akcją zmieniającą sieć: **VPN active lub VPN unknown = żadnych zmian sieci** i komunikat z przyczyną. Zmiana stanu VPN pomiędzy diagnozą a akcją wymaga ponownej oceny. Nie wolno zbiorczo usuwać tras, DNS, zapory czy usług, zmieniać FortiClient/FortiGate ani wyłączać ochrony lub restartować systemu.

## Granica zaufania i uprawnienia

Proces aplikacji jest nieuprzywilejowany. Planowany helper, tylko jeżeli konkretna akcja wymaga podniesienia uprawnień, jest osobną granicą zaufania: wąskie API o zamkniętej liście operacji, walidacja argumentów i uprawnionego klienta, ponowny odczyt stanu VPN przed zmianą oraz strukturalna odpowiedź. Aplikacja nie przekazuje helperowi arbitralnych poleceń ani tekstu shell. Stała ścieżka programu i tablica argumentów, limit czasu, kod wyjścia oraz sanitacja wyniku są obowiązkowe. Żaden helper ani polecenie uprzywilejowane nie istnieją obecnie; przed dodaniem należy opisać żądane uprawnienie i zakres operacji.

## Dane i testy

Granica prywatności przebiega przed Logger, historią i eksportem. Domyślnie usuwać lub redagować nazwy urządzeń, SSID, publiczne IP, domeny wewnętrzne, sekrety i zawartość pakietów. Wyjście polecenia jest poufne do czasu sanitacji. Historia ma limit; eksport korzysta wyłącznie z niej, nie z globalnych logów. Testy przyszłych modułów mają obejmować decyzje przy brakujących obserwacjach, VPN active/unknown, sukces/porażkę ponownego sprawdzenia oraz redakcję i błędy eksportu. Testy nie mogą tylko powtarzać implementacji.
