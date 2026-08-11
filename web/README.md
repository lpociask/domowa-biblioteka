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
- Bieżąca kolekcja jest przechowywana w `localStorage` pod kluczem `polka.collection.v1`.
- GitHub Pages serwuje wyłącznie pliki statyczne. Nie wysyła kolekcji do repozytorium i nie synchronizuje jej z iPhone’em. W MVP aplikacja iOS eksportuje JSON do webu, a eksport webowy służy jako kopia lub do przenosin między przeglądarkami. Import do iOS nie jest jeszcze dostępny.
- Interfejs nie pobiera zewnętrznych okładek, więc samo przeglądanie katalogu nie ujawnia listy publikacji zewnętrznym serwerom obrazów.

## Publikacja na GitHub Pages

Folder `web/` jest kompletnym katalogiem publikacyjnym. Workflow wdrożeniowy powinien przekazać jego zawartość jako artefakt Pages. Plik `.nojekyll` wyłącza przetwarzanie przez Jekyll.
