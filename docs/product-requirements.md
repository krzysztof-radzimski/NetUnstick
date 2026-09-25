# NetUnstick — wymagania produktu

## Cel i stan

NetUnstick to natywne narzędzie macOS pomagające zdiagnozować brak dostępu do urządzeń w sieci lokalnej po rozłączeniu VPN i zmianie Wi-Fi, bez restartowania komputera. Pierwszy przypadek dotyczy FortiClient łączącego się z FortiGate. Sama obserwacja użytkownika nie wskazuje jednej przyczyny ani skutecznej naprawy. Obecny projekt zawiera tylko uruchamialny fundament; poniższe funkcje są wymaganiami przyszłego MVP, nie opisem działania obecnej aplikacji.

Nazwa produktu: **NetUnstick**, krótka nazwa angielska. W rozmowie przeprowadzono jedynie wstępne wyszukanie nazwy; nie stanowi to weryfikacji znaków towarowych. Krótki opis projektu: „A native macOS utility for diagnosing and fixing local network issues after disconnecting from a VPN.”

Proponowane tematy repozytorium z rozmowy: `macos`, `swift`, `swiftui`, `vpn`, `forticlient`, `network-diagnostics`, `network-troubleshooting`, `bonjour`. Nie używać `vpn-client`, ponieważ produkt nie jest klientem VPN.

## Zakres MVP

1. Standardowe okno macOS i widoczna ikona Dock. Stan Wi-Fi i VPN, bieżąca czynność, jej wynik oraz następny krok są czytelne w głównym widoku. Skrót w pasku menu może być dodatkiem.
2. Jawny przycisk **Sprawdź sieć** uruchamia tylko odczyt. Sprawdzenie rozdziela wykrywanie urządzenia, rozwiązywanie nazw i bezpośrednie połączenie/trasy. Użytkownik może podać znany adres urządzenia do testu bezpośredniego połączenia; adres nie trafia domyślnie do logów ani eksportu.
3. Aplikacja rekomenduje wyłącznie pojedynczą naprawę popartą wynikiem sprawdzenia i przed uruchomieniem pokazuje jej przewidywany wpływ. Użytkownik uruchamia ją jawnie. Każda naprawa ma limit czasu, daje się anulować, gdy to możliwe, i nie jest powtarzana bez końca.
4. Przed naprawą zapisuje się istotny stan i wynik właściwego sprawdzenia; potem ponawia odczyt stanu i to samo sprawdzenie. Sukces oznacza usunięcie zaobserwowanej usterki, a nie sam poprawny kod wyjścia polecenia. Bez realnie odtworzonego przypadku naprawa pozostaje **kandydatem, niezweryfikowanym w praktyce**.
5. Widok aktywności pokazuje postęp, czasy, nazwy operacji, wynik i błędy. Szczegóły techniczne można rozwinąć. Po żądaniu użytkownika aplikacja pokazuje podgląd redagowanego raportu UTF-8 i standardowy dialog zapisu.

## Scenariusze awarii do rozróżnienia

| Scenariusz po rozłączeniu VPN i przejściu do innego Wi-Fi | Sygnał diagnostyczny | Wniosek / dalszy krok |
| --- | --- | --- |
| Telewizor, Mac lub inne urządzenie nie pojawia się na liście, ale znany adres działa | Test bezpośredniego połączenia działa, odkrywanie Bonjour/mDNS nie | Podejrzenie lokalnego odkrywania; nie utożsamiać AirPlay z samym dostępem IP. |
| Urządzenie jest widoczne, lecz połączenie nie dochodzi | Odkrywanie działa, połączenie lub trasa do lokalnego adresu zawodzi | Sprawdzić, czy ruch do sieci lokalnej biegnie przez właściwy interfejs Wi-Fi. |
| Nazwa urządzenia nie działa, a adres działa | Rozwiązanie nazwy zawodzi, bezpośrednie połączenie działa | Oddzielić DNS od lokalnego Bonjour/mDNS. |
| Po zmianie Wi-Fi pozostał nieaktualny adres, dzierżawa lub ustawienie | Odczyt konfiguracji i porównanie stanu wskazują konkretną niespójność | Rozważyć odnowienie DHCP lub odświeżenie właściwego elementu dopiero po potwierdzeniu. |
| Bezpośredni adres i odkrywanie zawodzą | Brak jednoznacznej przyczyny | Pokazać ograniczenie diagnozy; nie uruchamiać sekwencji ogólnego resetu. |

Bonjour/mDNS służy do odnajdywania usług lokalnych; AirPlay może od niego zależeć, lecz samo wykrycie urządzenia nie dowodzi działania przesyłania, połączenia ani uprawnień sieciowych. Testy powinny wskazywać, który poziom działa. FortiClient/FortiGate to kontekst pierwszych incydentów, nie część implementacji VPN. W dokumentacji Fortinet odnotowano problemy dostępu do lokalnej sieci przy split tunneling oraz DNS w niektórych wersjach macOS/FortiClient; nie dowodzi to przyczyny konkretnego incydentu. Wersje macOS i FortiClient oraz typ SSL VPN/IPsec należy odczytać, gdy możliwe, albo uzyskać od użytkownika. Brak możliwości odtworzenia awarii dziś nie blokuje fundamentu, lecz blokuje twierdzenie o skuteczności napraw.

## Bezpieczeństwo, uprawnienia i prywatność

- Diagnostyka jest tylko odczytem. Przy VPN aktywnym lub o nieznanym stanie żadna czynność zmieniająca sieć nie jest dozwolona; aplikacja wyjaśnia pominięcie.
- Nie implementować VPN i nie zmieniać ustawień zarządzanych przez FortiClient/FortiGate ani polityk firmowych. Nie usuwać zbiorczo tras, DNS, reguł zapory czy usług; nie wyłączać zabezpieczeń ani automatycznie restartować macOS.
- Kandydaci do osobnej oceny: odnowienie stanu Wi-Fi/DHCP, odświeżenie rozwiązywania nazw lub odkrywania lokalnego, przywrócenie jednoznacznie wskazanego nieaktualnego ustawienia. Żaden kandydat nie jest dziś potwierdzoną naprawą.
- Preferować wspierane API Apple (`Network`, `SystemConfiguration`). Ewentualne polecenie systemowe: stała ścieżka programu, tablica argumentów, kod wyjścia, limit czasu i redakcja wyniku; bez budowania ciągu shell z danych użytkownika. Każde wymagane uprawnienie opisać przed dodaniem. Helper uprzywilejowany może oferować tylko wąskie, jawnie zdefiniowane operacje.
- Każde sprawdzenie i naprawa zwraca strukturalny wynik: początek/koniec, rezultat, oczyszczone dowody, stabilny kod błędu. Rozróżnić pominięcie, anulowanie, odmowę uprawnień, timeout i błąd.
- Używać `Logger` do diagnostyki deweloperskiej i ograniczonej rozmiarem historii sesji należącej do aplikacji. Zapis obejmuje ID sesji, wersje aplikacji/macOS, nazwę czynności, czas, wynik, domenę/kod błędu, oczyszczony stan przed/po i ponowny test. Nie czytać globalnego logu jako źródła raportu.
- Nie zapisywać sekretów, danych uwierzytelniających VPN, tokenów, kluczy ani zawartości pakietów. Nazwy urządzeń, SSID, publiczne IP i domeny wewnętrzne domyślnie pomijać lub redagować. Dowolne wyjście polecenia traktować jako poufne do chwili oczyszczenia. Bez telemetrii i wysyłki w tle.

## Doświadczenie macOS

Swift i SwiftUI, bez zależności runtime spoza systemu. Interfejs ma reagować na tryb jasny/ciemny, kolor akcentu, zwiększony kontrast, skalowanie tekstu i ograniczony ruch. Natywne kontrolki, semantyczne kolory, nawigacja klawiaturą i etykiety VoiceOver. Ikona aplikacji powinna być charakterystyczna, czytelna w małym Docku i mieć warianty wyglądu wspierane przez wybrany target. Surowe logi pozostają w rozwijanych szczegółach.

## Mierzalne kryteria odbioru przyszłego MVP

| ID | Kryterium |
| --- | --- |
| PR-01 | Ręczne „Sprawdź sieć” tworzy sesję i wyłącznie odczytane wyniki dla Wi-Fi, VPN, odkrywania, nazw oraz bezpośredniego połączenia; wynik wskazuje, które kroki się udały. |
| PR-02 | Dla trzech pierwszych scenariuszy powyżej testy diagnozy zwracają odrębne decyzje, a brak danych daje „nieustalone”, bez zgadywania naprawy. |
| PR-03 | VPN active/unknown powoduje pominięcie każdej naprawy zmieniającej sieć; testy potwierdzają brak wywołania wykonawcy. |
| PR-04 | Każda naprawa wymaga jawnego uruchomienia i sekwencji before/check/action/after/recheck. Raport „sukces” pojawia się tylko po poprawie tego samego sprawdzenia. |
| PR-05 | Timeout, anulowanie, brak uprawnień i błąd mają odrębne wyniki i komunikat z następnym krokiem; testy obejmują ścieżki błędów. |
| PR-06 | Eksport następuje tylko na żądanie, po podglądzie i wyborze miejsca; testy potwierdzają redakcję przykładowych SSID, nazw, IP, domen i sekretów. |
| PR-07 | Główne okno i Dock umożliwiają wejście do aplikacji; kontrola ręczna obejmuje jasny/ciemny motyw, kontrast, powiększony tekst, klawiaturę, VoiceOver i czytelność ikony w Docku/Finderze. |
| PR-08 | Skuteczność konkretnej naprawy jest opisana jako potwierdzona dopiero po realnej awarii i pozytywnym porównaniu przed/po. |

## Macierz pokrycia źródłowej rozmowy

Wiersze obejmują wszystkie decyzje i potrzeby produktowe z `konwersacja.md`; historia obsługi interfejsu Codex, zapisy narzędzi i wcześniejsze robocze propozycje nazw nie są wymaganiami aplikacji.

| Wymaganie / informacja z rozmowy | Sekcja dokumentu | Planowany komponent |
| --- | --- | --- |
| Brak dostępu do TV/Maca po VPN i zmianie Wi-Fi, restart jako obejście | Cel i stan; Scenariusze | NetUnstickNetwork / NetUnstickCore |
| FortiClient łączony z FortiGate; SSL VPN/IPsec i wersje do ustalenia | Scenariusze | NetUnstickNetwork / rejestr sesji |
| Znane hipotezy: split tunneling, DNS, trasy lokalne | Scenariusze | NetUnstickCore / NetUnstickNetwork |
| Rozróżnienie odkrywania Bonjour, połączenia IP, nazw i tras | Zakres MVP; Scenariusze | NetUnstickNetwork / NetUnstickCore |
| AirPlay/TV i Mac jako urządzenia docelowe | Scenariusze | NetUnstickNetwork / prezentacja |
| Znany adres do testu połączenia | Zakres MVP | NetUnstickNetwork / prezentacja |
| Nie trzeba czekać na awarię, ale nie obiecywać skuteczności | Cel i stan; Kryteria PR-08 | NetUnstickRepair / dokumentacja |
| Odnowienie DHCP i inne ostrożne kandydaty, bez resetu zbiorczego | Bezpieczeństwo | NetUnstickRepair |
| Mała natywna aplikacja macOS, Swift/SwiftUI, Network/SystemConfiguration, bez własnego VPN | Doświadczenie; Bezpieczeństwo | App / pakiet Swift |
| Przycisk „Sprawdź sieć”, czytelny wynik i jawna naprawa | Zakres MVP | Features / NetUnstickCore |
| Widoczny postęp, logi i błędy do zapisu oraz rozwoju produktu | Zakres MVP; Prywatność | rejestr sesji/eksport / Features |
| Nowoczesny wygląd, motywy macOS, własna ikona Dock | Doświadczenie; PR-07 | App / Resources |
| Nazwa angielska NetUnstick | Cel i stan | App / README |
| Opis About i tematy repozytorium: macOS, Swift, SwiftUI, VPN, FortiClient, diagnostyka, Bonjour | Cel i stan; Scenariusze; Doświadczenie | metadane repozytorium |

Źródła kontekstu: [Apple Bonjour](https://developer.apple.com/bonjour/), [Apple Network](https://developer.apple.com/documentation/network), [Apple SystemConfiguration](https://developer.apple.com/documentation/systemconfiguration), [Apple DHCP](https://support.apple.com/en-sa/guide/mac-help/mchlp1545/mac), [Fortinet 7.2.4 known issues](https://docs.fortinet.com/document/forticlient/7.2.4/macos-release-notes/124818/known-issues), [Fortinet 7.2.11 known issues](https://docs.fortinet.com/document/forticlient/7.2.11/macos-release-notes/068193/existing-known-issues).
