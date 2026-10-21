# Przygotowanie NetUnstick do Mac App Store

Stan wymagań sprawdzono 21 października 2026. Przygotowanie lokalnego projektu nie oznacza zatwierdzenia przez Apple ani publikacji.

## Dwa osobne wydania

Użytkownik wybrał utrzymanie dwóch wydań. `NetUnstick` zachowuje podpis Developer ID, diagnostykę systemową i jawnie potwierdzane naprawy. `NetUnstickAppStore` jest oddzielnym targetem i schematem z flagą `APP_STORE`, sandboxem i identyfikatorem `org.netunstick.NetUnstick.AppStore`. Nie zawiera helpera, LaunchDaemona ani wykonawcy napraw. Ma własną historię w kontenerze aplikacji; instalacja wydania sklepowego nie migruje ani nie kasuje historii pełnego wydania.

Powodem jest [reguła 2.4.5 Apple](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility): Mac App Store wymaga sandboxa i nie dopuszcza eskalacji do root. Ukrycie przycisku naprawy nie wystarcza — ograniczenie jest realizowane także przez skład kompilowanego pakietu i kontrolę gotowej binarki.

| Funkcja | App Store | Developer ID |
| --- | --- | --- |
| Ścieżka sieci, DNS, próbne połączenie internetowe | Odczyt przez publiczne API | Odczyt |
| Bonjour i test wskazanego urządzenia TCP | Tak, z limitem czasu i zgodą Sieć lokalna | Tak |
| Globalne trasy, konfiguracja DNS/proxy, ustalanie stanu VPN | Poza zakresem | Tak, z ograniczeniami opisanymi w README |
| Negocjacja SMB i gotowość udostępniania plików | Poza zakresem | Tak |
| Helper, odnowienie DHCP, usuwanie zweryfikowanych tras | Brak | Osobne potwierdzenie i ponowna kontrola |
| Lokalna historia, podgląd/eksport, usuwanie historii, pomoc | Tak | Tak |

Nie należy opisywać sklepowej wersji jako narzędzia naprawiającego FortiClient, VPN lub systemowy routing. Nie ustala ona globalnego stanu VPN. Niepowodzenie jednego celu TCP nie jest dowodem awarii całego internetu.

## Interfejs, języki i pomoc

Ekran główny pokazuje status i główną akcję. Szczegóły sieci, techniczne powody kontroli oraz formularz urządzenia są rozwijane; wynik błędu i aktywna operacja pozostają widoczne. Pomoc działa lokalnie z menu Pomoc i Ustawień. Zawiera instrukcję, zakresy obu wydań, interpretację wyników, uprawnienia, bezpieczeństwo i politykę prywatności.

Warstwa `L10n` w NetUnstickCore jest wspólna dla aplikacji i modułów SwiftPM. Kody wyników, identyfikatory i zamknięta lista danych zapisywanych w historii pozostają niezależne od języka. Nazwy operacji i następne kroki są tłumaczone podczas prezentacji. Źródło to `Tools/LocalizationSource.json`, tłumaczenia są w `Tools/Translations`, a generator sprawdza kompletność i zgodność placeholderów. Obsługiwany zestaw obejmuje 24 języki urzędowe UE, w tym irlandzki i maltański. Liczba języków aplikacji nie jest liczbą lokalizacji metadanych obsługiwanych przez App Store Connect. Przed publicznym wydaniem potrzebna jest redakcja językowa, szczególnie instrukcji technicznych i polityki.

## Prywatność i bezpieczeństwo

`PrivacyInfo.xcprivacy` deklaruje brak śledzenia i danych zbieranych przez twórcę. Bieżący kod nie ma kont, reklam, analityki ani automatycznego wysyłania raportów i nie używa bezpośrednio kategorii required-reason API. Apple wymaga informacji o zbieranych danych na wszystkich platformach; wymóg deklarowania required-reason API w dokumentacji dotyczy wskazanych platform mobilnych, nie należy automatycznie przenosić wszystkich reguł iOS na macOS. Przy dodaniu API lub SDK należy powtórzyć audyt i wygenerować raport prywatności w Organizerze. Źródło: [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files).

Diagnostyka wysyła zapytanie o `example.com`, łączy się TCP z `1.1.1.1:443`, przegląda lokalne usługi Bonjour i na polecenie użytkownika kontaktuje się z podanym urządzeniem. Operator resolvera i celu widzi zwykłe metadane sieciowe, w tym adres źródłowy. Nie jest to telemetryczne przesłanie raportu do twórcy. Opis tej aktywności jest dostępny w pomocy i polityce.

Historia jest ograniczona do 20 sesji, 100 wpisów na sesję i 4 MB. Usuwanie historii wymaga osobnego potwierdzenia; usuwa wyłącznie plik historii tego wydania, także przy nieobsługiwanej wersji formatu. Nie usuwa wyeksportowanych raportów i nie zmienia sieci. Obsłużone są błąd uprawnień oraz anulowanie. Logi systemowe podlegają retencji macOS. Zapis raportu wymaga podglądu i standardowego dialogu wyboru pliku.

[Reguła 5.1.1 Apple](https://developer.apple.com/app-store/review/guidelines/#privacy) wymaga dostępnej polityki prywatności w aplikacji i metadanych. Pliki `Distribution/Website/{en,pl}/{privacy,support}.html` są gotowe do umieszczenia na publicznym HTTPS. Nie zostały opublikowane. Nie należy podawać jako URL nieistniejącej strony, prywatnego repozytorium ani lokalnego pliku.

## Materiały i dane publikacji

`Distribution/AppStore/metadata.{en,pl}.json` zawierają opisy zgodne z wersją sklepową, słowa kluczowe, instrukcje recenzenta i proponowane odpowiedzi prywatności. Celowo nie uzupełniają fikcyjnymi wartościami pól `supportURL` i `privacyPolicyURL`. Wydawca musi opublikować strony, potwierdzić dane kontaktowe i uzupełnić te pola. W aplikacji pozostaje kompletna kopia polityki offline.

Z projektu **Kościół** wykorzystano doświadczenie z lokalnych plików `ChurchApp.iOS/AppStore/1.0/pl-PL`: błędne przypisywanie funkcji konkretnemu buildowi i wybór terytoriów mogą opóźnić review. Nie skopiowano jego kont, danych recenzenta, zgód, klasyfikacji treści ani polityki prywatności. Problemy licencji publikacji treści religijnych w Chinach nie są automatycznie wymaganiem NetUnstick. Materiały tego projektu były wyłącznie odczytywane.

Przed wysłaniem należy:

- Utworzyć rekord macOS z dokładnym bundle ID, potwierdzić aktualne umowy i profil dystrybucji.
- Potwierdzić [status przedsiębiorcy DSA](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements) oraz kontakt wydawcy. Decyzja o tym statusie należy do właściciela, nie wynika z samego certyfikatu.
- Wybrać kraje dystrybucji świadomie. Języki UE nie ustawiają automatycznie terytoriów ani przyszłych rynków.
- Uzupełnić publiczne URL, kontakt App Review, ceny, klasyfikację wiekową, prawa do treści i odpowiedzi dotyczące eksportu kryptografii zgodnie z tym buildem. Brak własnego szyfrowania lub korzystanie wyłącznie z szyfrowania systemowego wymaga odpowiedniej deklaracji w formularzu, nie stanowi ogólnego oświadczenia o zwolnieniu prawnym.
- Wykonać aktualne zrzuty wydania sklepowego w obsługiwanych rozmiarach Mac App Store, sprawdzić ikony, oba motywy, klawiaturę i długie tłumaczenia.
- Sprawdzić gotowy build w Xcode Organizer, raport prywatności i wymagania aktualnego SDK; podpis Developer ID nie jest podpisem dystrybucji sklepowej.

Żadne konto, telemetria, serwer wsparcia, wysyłka do App Store Connect ani publikacja nie są częścią tych lokalnych zmian.

## Polecenia odbioru

```sh
python3 Tools/Localization.py
python3 Tools/BuildPrivacyPages.py
python3 Tools/CheckStoreMetadata.py
python3 Tools/CheckStoreMetadata.py --submission
xcodebuild -project NetUnstick.xcodeproj -scheme NetUnstickAppStore -configuration Release -destination 'platform=macOS,arch=arm64' build
python3 Tools/CheckAppStoreBundle.py '<gotowy-pakiet.app>'
Tools/ArchiveAppStore.sh
```

`CheckStoreMetadata.py` dopuszcza przygotowane materiały i jawnie raportuje braki. Tryb `--submission` musi je odrzucić do czasu uzupełnienia wymaganych URL. `CheckAppStoreBundle.py --distribution` dodatkowo wymaga certyfikatu dystrybucji App Store i profilu; lokalny podpis do testów sandboxa nie wystarcza. Skrypt archiwizacji nie wysyła niczego do Apple.
