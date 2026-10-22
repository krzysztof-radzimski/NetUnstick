# Zrzuty sklepowe NetUnstick 1.0 (14)

48 rzeczywistych zrzutów natywnej aplikacji w 24 językach, po dwa ujęcia na język:

- **01-network.jpg** — wynik diagnostyki tylko do odczytu, z czterema poprawnymi kontrolami sieci.
- **02-privacy-help.jpg** — Ustawienia: zakres wydania sklepowego, prywatność oraz dostęp do polityki i pomocy.

Zrzuty wykonano 22 października 2026 r. na macOS 27.0.1, na komputerze arm64, z wydania sklepowego **1.0 (14)**. Okno miało rozmiar 1280 × 800 punktów, a natywny obraz Retina ma **2560 × 1600 pikseli**. Sterowanie odbywało się przez `abc-desktop`, a zapis obrazu przez natywny `screencapture`. Obrazy są w formacie **JPEG RGB, bez kanału alfa**. Nie były skalowane, retuszowane ani edytowane; nie dodawano napisów ani makiet interfejsu. Każdy obraz obejrzano podczas wykonania.

[manifest.json](manifest.json) zawiera mapowanie języków, rozmiary plików, znaczniki czasu i sumy SHA-256. Wszystkie 48 plików sprawdzono za pomocą `sips`, odczytu metadanych pliku i obliczenia sum kontrolnych.

**Stan wysyłki:** zapisano i ponownie zweryfikowano 22 października 2026 r. we wszystkich **19 lokalizacjach App Store Connect** — łącznie **38 przypięć obrazów**, po dwa na lokalizację. Każdą lokalizację ponownie otwarto: pokazywała licznik „2 of 10”, dwie miniatury HTTPS i nie korzystała z „Using Existing Assets”. Potwierdza to zapis zrzutów; nie jest potwierdzeniem wysłania aplikacji do recenzji ani jej publikacji.

Lokalny komplet można sprawdzić skończonym [walidatorem zrzutów](../../../Tools/CheckStoreScreenshots.py), uruchamiając w katalogu głównym repozytorium:

```sh
python3 Tools/CheckStoreScreenshots.py
```

Walidator kontroluje kompletność języków i ujęć, mapowania sklepowe, rzeczywisty format, wymiary, kolory, brak alfa oraz sumy SHA-256. Nie zastępuje oględzin obrazu ani sprawdzenia zapisu na stronie Apple.

## Zestawy językowe

| Język aplikacji | Lokalizacja w App Store Connect | Diagnostyka | Pomoc i prywatność |
| --- | --- | --- | --- |
| Bułgarski (`bg`) | Tylko lokalnie | [Otwórz](bg/01-network.jpg) | [Otwórz](bg/02-privacy-help.jpg) |
| Czeski (`cs`) | `cs` | [Otwórz](cs/01-network.jpg) | [Otwórz](cs/02-privacy-help.jpg) |
| Duński (`da`) | `da` | [Otwórz](da/01-network.jpg) | [Otwórz](da/02-privacy-help.jpg) |
| Niemiecki (`de`) | `de-DE` | [Otwórz](de/01-network.jpg) | [Otwórz](de/02-privacy-help.jpg) |
| Grecki (`el`) | `el` | [Otwórz](el/01-network.jpg) | [Otwórz](el/02-privacy-help.jpg) |
| Angielski (`en`) | `en-US` | [Otwórz](en/01-network.jpg) | [Otwórz](en/02-privacy-help.jpg) |
| Hiszpański (`es`) | `es-ES`, `es-MX` | [Otwórz](es/01-network.jpg) | [Otwórz](es/02-privacy-help.jpg) |
| Estoński (`et`) | Tylko lokalnie | [Otwórz](et/01-network.jpg) | [Otwórz](et/02-privacy-help.jpg) |
| Fiński (`fi`) | `fi` | [Otwórz](fi/01-network.jpg) | [Otwórz](fi/02-privacy-help.jpg) |
| Francuski (`fr`) | `fr-FR` | [Otwórz](fr/01-network.jpg) | [Otwórz](fr/02-privacy-help.jpg) |
| Irlandzki (`ga`) | Tylko lokalnie | [Otwórz](ga/01-network.jpg) | [Otwórz](ga/02-privacy-help.jpg) |
| Chorwacki (`hr`) | `hr` | [Otwórz](hr/01-network.jpg) | [Otwórz](hr/02-privacy-help.jpg) |
| Węgierski (`hu`) | `hu` | [Otwórz](hu/01-network.jpg) | [Otwórz](hu/02-privacy-help.jpg) |
| Włoski (`it`) | `it` | [Otwórz](it/01-network.jpg) | [Otwórz](it/02-privacy-help.jpg) |
| Litewski (`lt`) | Tylko lokalnie | [Otwórz](lt/01-network.jpg) | [Otwórz](lt/02-privacy-help.jpg) |
| Łotewski (`lv`) | Tylko lokalnie | [Otwórz](lv/01-network.jpg) | [Otwórz](lv/02-privacy-help.jpg) |
| Maltański (`mt`) | Tylko lokalnie | [Otwórz](mt/01-network.jpg) | [Otwórz](mt/02-privacy-help.jpg) |
| Niderlandzki (`nl`) | `nl-NL` | [Otwórz](nl/01-network.jpg) | [Otwórz](nl/02-privacy-help.jpg) |
| Polski (`pl`) | `pl-PL` | [Otwórz](pl/01-network.jpg) | [Otwórz](pl/02-privacy-help.jpg) |
| Portugalski (`pt`) | `pt-PT` | [Otwórz](pt/01-network.jpg) | [Otwórz](pt/02-privacy-help.jpg) |
| Rumuński (`ro`) | `ro` | [Otwórz](ro/01-network.jpg) | [Otwórz](ro/02-privacy-help.jpg) |
| Słowacki (`sk`) | `sk` | [Otwórz](sk/01-network.jpg) | [Otwórz](sk/02-privacy-help.jpg) |
| Słoweński (`sl`) | `sl` | [Otwórz](sl/01-network.jpg) | [Otwórz](sl/02-privacy-help.jpg) |
| Szwedzki (`sv`) | `sv` | [Otwórz](sv/01-network.jpg) | [Otwórz](sv/02-privacy-help.jpg) |

18 zestawów odpowiada 19 lokalizacjom obsługiwanym w App Store Connect. Hiszpański dla Hiszpanii i Meksyku używa tych samych dwóch obrazów, ponieważ natywny interfejs aplikacji nie różni się między tymi regionami. App Store Connect nie udostępnia osobnych lokalizacji bułgarskiej, estońskiej, irlandzkiej, litewskiej, łotewskiej i maltańskiej; ich kompletne zestawy zachowano lokalnie.

Po sesji przechwytywania przywrócono wcześniejsze preferencje językowe, rozmiar okna i historię aplikacji. Pliki nie zawierają prywatnych raportów ani historii użytkownika.
