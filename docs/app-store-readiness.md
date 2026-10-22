# Przygotowanie NetUnstick do Mac App Store

Stan przygotowania zaktualizowano 22 października 2026. Upload buildu do App Store Connect nie oznacza zatwierdzenia przez Apple ani publikacji.

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

[Reguła 5.1.1 Apple](https://developer.apple.com/app-store/review/guidelines/#privacy) wymaga dostępnej polityki prywatności w aplikacji i metadanych. Strony produktu są opublikowane w serwisie ITORG: [polska](https://itorg.pl/NetUnstick/), [angielska](https://itorg.pl/en/NetUnstick/) i [hiszpańska](https://itorg.pl/es/NetUnstick/). Publiczne strony wsparcia i prywatności pod poniższymi adresami przeszły 22 października kontrolę HTTP 200 i treści; wcześniejsza blokada HTTP 404 została usunięta. Polityka oraz pomoc offline podają potwierdzonego wydawcę ITORG Krzysztof Radzimski i kontakt kr@itorg.pl. Strony opisują także dobrowolną korespondencję wsparcia i zwykłe logi hostingu.

| Język | Wsparcie | Polityka prywatności |
| --- | --- | --- |
| Polski | [Wsparcie](https://itorg.pl/NetUnstick/pl/support) | [Prywatność](https://itorg.pl/NetUnstick/pl/privacy) |
| Angielski | [Support](https://itorg.pl/NetUnstick/en/support) | [Privacy](https://itorg.pl/NetUnstick/en/privacy) |
| Hiszpański | [Soporte](https://itorg.pl/NetUnstick/es/support) | [Privacidad](https://itorg.pl/NetUnstick/es/privacy) |

Źródła lokalnych materiałów są w `Distribution/Website`, a paczka do hostingu w `Artifacts/Distribution/NetUnstick-Website.zip`. Kanoniczne publiczne adresy wsparcia i prywatności nie mają rozszerzenia `.html`. `Tools/CheckStoreMetadata.py --submission` przeszedł po opublikowaniu stron; ten wynik potwierdza lokalne materiały i adresy HTTPS, a warunki konta, zrzuty oraz recenzja Apple pozostają osobnymi etapami.

## Materiały i dane publikacji

`Distribution/AppStore/metadata.{en,pl,es-ES,es-MX}.json` zawierają opisy zgodne z wersją sklepową, słowa kluczowe, instrukcje recenzenta i odpowiedzi prywatności. Zapisano je w czterech lokalizacjach rekordu App Store Connect: en-US, pl, es-ES i es-MX. We wszystkich czterech lokalizacjach zapisano i ponownie odczytano `supportURL`, `marketingURL` i `privacyPolicyURL`, wskazujące sprawdzony publiczny hosting ITORG i kanoniczne adresy bez rozszerzenia `.html`. Obie hiszpańskie lokalizacje korzystają z tej samej hiszpańskiej strony produktu, wsparcia i polityki. W aplikacji pozostaje kompletna kopia polityki offline.

## Zapisane ustawienia pierwszego wydania

- Rekord **6825738008**, bundle ID `org.netunstick.NetUnstick.AppStore`, wersja **1.0 (14)**. Finalny build przeszedł upload i jest przypięty do wersji. Stan aplikacji: Prepare for Submission.
- Cena bazowa USA **0,99 USD**, automatyczne lokalne odpowiedniki (podczas kontroli: Polska 4,99 PLN, kraje EUR 0,99 EUR). To jednorazowy zakup bez subskrypcji i IAP; przyszłe aktualizacje tej aplikacji są bez dopłat. Brak dodatkowego limitu aktywacji po stronie NetUnstick nie znosi warunków konta i pobierania Apple.
- **45 rynków**: wszystkie 27 państw UE, USA oraz Argentyna, Boliwia, Chile, Kolumbia, Kostaryka, Dominikana, Ekwador, Salwador, Gwatemala, Honduras, Meksyk, Nikaragua, Panama, Paragwaj, Peru, Urugwaj i Wenezuela. Pozostałe rynki, w tym Chiny i Azja, są wyłączone; automatyczne dodawanie przyszłych storefrontów jest wyłączone.
- Kategoria Utilities, obliczona klasyfikacja 4+, standardowa EULA Apple, brak treści zewnętrznych, brak logowania, kontakt recenzenta ITORG, angielskie instrukcje sond i uzasadnienia trzech uprawnień sandboxa.
- Deklaracja **Data Not Collected** została opublikowana w App Privacy. Wydanie pozostaje ustawione na **ręczne udostępnienie** po ewentualnym zatwierdzeniu. Nie wysłano aplikacji do App Review.
- Aplikacja jest oznaczona jako aplikacja przedsiębiorcy; weryfikacja DSA konta nadal ma stan **In Review**. Paid Apps Agreement ma stan **New** i nie został podpisany. Zgłoszenie zmiany samego adresu zostało wysłane do Apple za wyraźną zgodą właściciela i czeka na weryfikację. Nie potwierdzono końcowego zapisu adresu; Business nadal pokazywał poprzednie dane. Danych podatkowych ani bankowych nie zmieniano. Tych danych i umów nie należy kopiować z obcego projektu ani ustalać na podstawie samej nazwy handlowej.

Konto Apple jest typu Individual. Dla osoby prowadzącej jednoosobową działalność Apple pokazuje osobiste imię i nazwisko jako sprzedawcę; branding ITORG w aplikacji i copyright nie zmienia automatycznie nazwy sprzedawcy konta. Źródła: [rejestracja Apple](https://developer.apple.com/help/account/membership/program-enrollment/), [nazwa dewelopera](https://developer.apple.com/help/app-store-connect/create-an-app-record/set-your-developer-name). Zapis cen, terytoriów i stanu jest w `Distribution/AppStore/publication.json`.

Po niepotwierdzonej próbie edycji danych w Business wysłano oficjalny formularz [Membership Information Update](https://developer.apple.com/contact/request/update-individual-information/), wyłącznie w sprawie adresu. Właściciel jawnie zatwierdził wysłanie zgłoszenia. Apple wyświetlił podziękowanie i zapowiedź weryfikacji oraz odpowiedzi; numeru sprawy na stronie nie pokazano. Konto pozostało Individual, a zmiany nazwy prawnej nie wnioskowano. Nie zapisano w repozytorium prywatnego adresu ani adresu kontaktowego konta Apple. Potwierdzenie otrzymania zgłoszenia nie oznacza zatwierdzenia zmiany; [Apple wymaga weryfikacji i akceptacji takich aktualizacji](https://developer.apple.com/help/account/membership/updating-your-account-information).

Z projektu **Kościół** wykorzystano doświadczenie z lokalnych plików `ChurchApp.iOS/AppStore/1.0/pl-PL`: błędne przypisywanie funkcji konkretnemu buildowi i wybór terytoriów mogą opóźnić review. Nie skopiowano jego kont, danych recenzenta, zgód, klasyfikacji treści ani polityki prywatności. Problemy licencji publikacji treści religijnych w Chinach nie są automatycznie wymaganiem NetUnstick. Materiały tego projektu były wyłącznie odczytywane.

Przed wysłaniem należy:

- Poczekać na weryfikację zgłoszenia zmiany adresu przez Apple i potwierdzić jej odzwierciedlenie w danych członkostwa oraz Business.
- Następnie dokończyć Paid Apps Agreement oraz zweryfikować i uzupełnić wymagane dane bankowe i podatkowe na koncie właściciela. Profil jest potrzebny dla TestFlight oraz restricted entitlements; zwykły sandbox macOS sam w sobie nie wymaga profilu.
- Potwierdzić [status przedsiębiorcy DSA](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements) oraz kontakt wydawcy. Decyzja o tym statusie należy do właściciela, nie wynika z samego certyfikatu.
- Potwierdzić końcowe odpowiedzi dotyczące eksportu kryptografii. Brak własnego szyfrowania lub korzystanie wyłącznie z szyfrowania systemowego wymaga odpowiedniej deklaracji w formularzu, nie stanowi ogólnego oświadczenia o zwolnieniu prawnym. Opublikowane strony HTTPS przeszły kontrolę.
- Wykonać aktualne zrzuty wydania sklepowego w obsługiwanych rozmiarach Mac App Store, sprawdzić ikony, oba motywy, klawiaturę i długie tłumaczenia. Nowych zrzutów sklepowych nie wykonano: sterowanie pulpitem było zajęte, a następnie przerwane. Istniejący obraz strony produktu 1800 × 1208 nie ma obsługiwanego rozmiaru zrzutu Mac App Store.
- Sprawdzić gotowy build w Xcode Organizer, raport prywatności i wymagania aktualnego SDK; podpis Developer ID nie jest podpisem dystrybucji sklepowej.

Nie dodano kont użytkowników aplikacji, telemetrii ani zdalnego przesyłania raportów. Upload buildu wykonano z istniejącym kontem Xcode, a build został przetworzony i przypięty do wersji. Strony produktu, wsparcia i prywatności są publicznie dostępne. Wysłanie aplikacji do App Review i późniejsze ręczne udostępnienie pozostają kolejnymi etapami po spełnieniu opisanych warunków.

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

`CheckStoreMetadata.py` bez opcji sprawdza format i limity lokalnych materiałów, bez dowodzenia dostępności stron. `--check-urls` i `--submission` wykonują ograniczone czasowo odczyty publicznego HTTPS, sprawdzając HTTP 200, HTML, nazwę aplikacji i kontakt. `--submission` odrzuca niedostępne lub niewłaściwe strony. `CheckAppStoreBundle.py --distribution` wymaga podpisu dystrybucyjnego App Store; lokalny podpis ad hoc lub Apple Development nie wystarcza. Obecny profil jest sprawdzany pod kątem platformy, App ID, zespołu, ważności i zgodności certyfikatu. Profil jest wymagany przy restricted entitlements; tryb `--testflight` zawsze go wymaga. Aplikacja macOS z samymi unrestricted entitlements (w tym obecny sandbox i dostęp sieciowy) może trafić do App Store bez profilu — zgodnie z [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

Archiwum Xcode jest podpisywane Apple Development przy automatycznym podpisywaniu. Podpis dystrybucyjny powstaje przy eksporcie w Xcode Organizer, również z użyciem [certyfikatów zarządzanych w chmurze](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/). Dopiero gotowy eksport należy sprawdzić trybem `--distribution`. `ArchiveAppStore.sh` nie eksportuje ani nie wysyła aplikacji; opcjonalny `--allow-provisioning-updates` pozwala Xcode zaktualizować potrzebne materiały podpisu za pomocą skonfigurowanego konta. Nie należy wymuszać Apple Distribution w automatycznie podpisywanym targetcie archiwum.
