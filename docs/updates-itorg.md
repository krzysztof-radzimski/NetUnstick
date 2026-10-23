# Aktualizacje NetUnstick na stronie ITORG

NetUnstick sprawdza przy uruchomieniu `https://itorg.pl/NetUnstick/updates/latest.json`.
Sprawdzanie można wyłączyć w Ustawieniach; ręczny przycisk działa niezależnie.
Po wykryciu nowszej zgodnej wersji aplikacja pokazuje informację i przycisk pobierania.
Po pobraniu oraz sprawdzeniu podpisów użytkownik otwiera systemowy Instalator.
Instalator wymaga zamknięcia aplikacji i autoryzacji administratora. Po instalacji
użytkownik uruchamia aplikację ponownie. Nie ma cichej instalacji ani zmian uprawnień helpera.

## Przygotowanie każdego wydania

1. Zwiększ `MARKETING_VERSION` i monotoniczny `CURRENT_PROJECT_VERSION` aplikacji oraz helpera.
2. Uruchom z korzenia repozytorium NetUnstick:

   ```sh
   Tools/BuildPKG.sh --notary-profile NetUnstick --update-feed
   ```

3. Skrypt po zaakceptowanej notaryzacji i walidacji tworzy gotowy PKG, a następnie
   `Artifacts/UpdatePublication/`. W środku są `public/NetUnstick/updates/latest.json`,
   wersjonowany PKG, SHA-256, fragment nagłówków, ta instrukcja i materiały prywatności PL/EN/ES.
   Numerów ani hashy
   w pliku JSON nie wpisuje się ręcznie: pochodzą z rzeczywistego pakietu.

Istniejący notaryzowany PKG można przygotować oddzielnie:

```sh
Tools/BuildUpdateFeed.sh --package Artifacts/Distribution/NetUnstick-0.4.0-15-arm64.pkg
```

Narzędzie odrzuca `UNNOTARIZED`, brak biletu Apple, niewłaściwy podpis, inny bundle,
niepoprawną architekturę i pakiety większe niż 25 MiB. Ten limit wynika z
[limitu pliku Cloudflare Pages](https://developers.cloudflare.com/pages/platform/limits/).
Zmiana treści istniejącego wersjonowanego PKG jest odrzucana — wydaj nowy numer buildu.

## Przeniesienie do repozytorium ITORG

Projekt ITORG zbadano jako sąsiednie repozytorium `itorg.pl` tylko do odczytu.
Jest to Next.js z `output: 'export'`, katalogiem `public/` i eksportem `out/`.
Nie wymaga API, bazy danych ani Pages Functions do obsługi aktualizacji.

W osobnej pracy w repozytorium ITORG:

1. Przenieś zawartość przygotowanego `public/NetUnstick/updates/` do katalogu o tej
   samej ścieżce w ITORG. Zachowaj wcześniejsze wersjonowane PKG i pliki SHA-256;
   zastąp tylko `latest.json`. Nie używaj Git LFS dla tych plików: eksport musi
   zawierać rzeczywisty PKG, a nie tekstowy wskaźnik.
2. Dopisz `headers.fragment` do istniejącego `public/_headers`, zachowując jego
   reguły bezpieczeństwa. Cloudflare opisuje ten mechanizm w
   [dokumentacji nagłówków Pages](https://developers.cloudflare.com/pages/configuration/headers/).
3. Obecny `public/_routes.json` wyklucza `/NetUnstick/*` z funkcji doboru języka.
   Zachowaj to wykluczenie. Plik JSON i PKG mają być publicznie dostępne bez
   przekierowania językowego, logowania, wyzwania przeglądarkowego ani ciasteczek.
4. Zmień odnośnik pobierania na stronie produktu na nowy wersjonowany PKG. W badanej
   kopii ITORG pozostają jeszcze wzmianki o planowanej edycji Mac App Store;
   aktualny produkt to pełne wydanie Developer ID. Uzupełnij politykę prywatności
   o sprawdzanie aktualizacji; aktualne treści PL/EN/ES są w `privacy-content/`
   przygotowanej paczki. To materiały treściowe, nie projekt graficzny strony do podmiany.
5. Wykonaj testy i eksport strony, następnie opublikuj komplet zasobów normalnym
   procesem Cloudflare Pages. Publikuj JSON razem z dostępnym już PKG, nie wcześniej.
   Żaden skrypt NetUnstick nie zapisuje do drugiego repozytorium ani nie publikuje strony.

Po publikacji sprawdź odpowiedź HTTP 200 dla JSON i PKG oraz zgodność SHA-256.
Na starszym wydaniu obsługującym aktualizacje sprawdź wykrycie nowej wersji,
pobranie, walidację, anulowanie i instalację za zgodą administratora.
Wydania do `0.3.1 (14)` nie zawierają modułu aktualizacji — pierwsze przejście na
wydanie z tym modułem wymaga zwykłej instalacji PKG.

## Podpis pliku wersji i klucze

`latest.json` zawiera czytelny obiekt `release` i podpis Ed25519 w `signature`.
Podpis obejmuje JSON `release` zakodowany przez `AppUpdateRelease.signingData()`
(posortowane klucze, bez escapowania ukośników). Klient odtwarza ten sam zapis
i weryfikuje go publicznym kluczem wbudowanym w aplikację.
Samodzielna zmiana wersji, URL, rozmiaru lub SHA-256 unieważnia podpis.

Prywatny klucz jest zapisany w pęku kluczy Maca wydawniczego jako generic password:
service `org.netunstick.update-signing`, account `ed25519-release-v1`. Nie trafia do repo,
manifestu, logów ani paczki publikacyjnej. `--initialize-key` tworzy go tylko,
jeśli nie istnieje, i wypisuje wyłącznie część publiczną. Nie uruchamiaj tego
na nowym Macu w celu zastąpienia utraconego klucza: nowy klucz nie będzie pasował
do zainstalowanych aplikacji. Zachowaj możliwość odzyskania pęku Maca wydawniczego.
Planowana rotacja wymaga wydania aplikacji z nowym kluczem; utrata starego może
wymusić ręczną instalację takiego wydania.

Wrapper podpisuje narzędzie wydawnicze stabilnym Developer ID z identyfikatorem
`org.netunstick.UpdateFeedTool`, zanim odczyta ono swój klucz. Przy niedostępnym
pęku kluczy kończy pracę błędem, zamiast czekać bez końca na ukryty dialog.

## Granice i prywatność

Klient akceptuje tylko HTTPS na `itorg.pl/NetUnstick/updates/`, także po przekierowaniu.
Plik wersji ma limit 16 KiB, PKG 25 MiB; pobieranie jest strumieniowe i ograniczone
czasowo. Niepełne pliki są usuwane, a cache pobrań starszych niż siedem dni sprzątany
przy kolejnym pobraniu. Niepoprawny podpis, hash lub ocena Gatekeeper blokuje instalację.
Tuż przed otwarciem Instalatora plik jest weryfikowany ponownie.

Sprawdzanie odbywa się najwyżej raz automatycznie na uruchomienie procesu. Nie ma
periodycznego odpytywania w tle, kont, identyfikatorów urządzenia, cookies ani wysyłki
raportów. Hosting widzi zwykłe metadane HTTP, w tym adres IP. Błąd lub brak pliku
na stronie nie blokuje diagnostyki. Uprzywilejowany helper nie uczestniczy w aktualizacji.
