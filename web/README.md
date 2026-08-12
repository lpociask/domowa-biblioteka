# Półka — katalog webowy

Statyczny, responsywny podgląd kolekcji przeznaczony do publikacji na GitHub Pages. Nie wymaga bundlera, npm ani zewnętrznych bibliotek.

## Uruchomienie lokalne

Z katalogu głównego repozytorium:

```bash
python3 -m http.server 8000 --directory web
```

Następnie otwórz `http://localhost:8000`. Pliku `index.html` nie należy uruchamiać bezpośrednio przez `file://`, ponieważ przeglądarka może zablokować pobranie przykładowego JSON-u.

## Testy

```bash
node --test web/tests/*.test.mjs
```

Testy korzystają wyłącznie z modułów wbudowanych w Node.js.

## Dane i synchronizacja

- Format wejścia i wyjścia to kanoniczny `collection.json` v1: osobne `publications[]` i `ownedItems[]` pozwalają opisać wiele fizycznych kopii jednego wydania.
- Importer toleruje starszy format `items[]` i normalizuje go do v1.
- Raport pomiarowy pilota z iOS jest rozpoznawany przed importem i nie zmienia kolekcji ani `localStorage`. Do WWW należy wybrać eksport JSON kolekcji z głównego menu aplikacji iOS.
- Kanoniczny v1 wymaga poprawnych dat ISO 8601 i całkowitego roku 1–9999. Podczas scalania te same hierarchiczne lokalizacje są deduplikowane także wtedy, gdy pochodzą z różnych klientów i mają inne ID.
- Import pliku jest ograniczony do 25 MB, tak samo jak w aplikacji iOS.
- Bieżąca kolekcja jest przechowywana w `localStorage` pod kluczem `polka.collection.v1`.
- Zakładka „Serie prasy” jest projekcją tylko do odczytu: grupuje numery, pokazuje wewnętrzne luki oraz rozdziela wiele fizycznych kopii od powtórzonych rekordów publikacji. Wynik nie trafia do JSON-u ani `localStorage`.
- GitHub Pages serwuje wyłącznie pliki statyczne. Nie wysyła kolekcji do repozytorium i nie synchronizuje jej automatycznie z iPhone’em. W MVP wspólny plik JSON można eksportować i importować w obie strony między aplikacją iOS a WWW oraz przenosić między przeglądarkami.
- Otwarcie katalogu i przewijanie listy nie pobiera zewnętrznych okładek. Po świadomym otwarciu szczegółów aplikacja może pobrać wyłącznie obraz HTTPS z `covers.openlibrary.org`; nieznane hosty zachowuje w JSON-ie, ale ich automatycznie nie wywołuje.

## Publikacja na GitHub Pages

Folder `web/` jest kompletnym katalogiem publikacyjnym. Workflow wdrożeniowy powinien przekazać jego zawartość jako artefakt Pages. Plik `.nojekyll` wyłącza przetwarzanie przez Jekyll.
