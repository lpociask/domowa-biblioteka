# Domowa Biblioteka

Pierwszy vertical slice prywatnego katalogu książek i prasy:

- natywna aplikacja iOS do skanowania, ręcznego dodawania oraz lokalnego przechowywania kolekcji;
- automatyczne uzupełnianie książek po ISBN: najpierw z Biblioteki Narodowej, a w razie braku wyniku z Open Library;
- trwały cache metadanych i bezpieczne okładki Open Library działające także po utracie połączenia;
- rozpoznawanie prasowego EAN‑13 z prefiksem `977`, automatyczne ustawienie typu prasa, wyprowadzenie bazowego ISSN oraz zachowanie dodatków EAN‑2/EAN‑5;
- lokalny OCR okładki prasy z jawnym potwierdzeniem numeru, tomu i daty oraz analiza serii, luk i duplikatów;
- statyczny katalog WWW działający na GitHub Pages i przechowujący dane lokalnie w przeglądarce;
- wspólny, wersjonowany format importu i eksportu JSON;
- świadome rozdzielenie publikacji od posiadanego egzemplarza.

**Działające demo:** [lpociask.github.io/domowa-biblioteka](https://lpociask.github.io/domowa-biblioteka/)

> GitHub Pages hostuje wyłącznie statyczne HTML, CSS i JavaScript. Nie jest bazą danych ani backendem synchronizacji. Bieżący MVP przenosi kolekcję pomiędzy iOS i webem ręcznie, za pomocą pliku JSON; oba klienty obsługują import i eksport. Nie ma konta, automatycznej synchronizacji ani wysyłania kolekcji do chmury przez aplikację. Import iOS dodaje brakujące rekordy, ale nie nadpisuje już istniejących lokalnych danych. Do repozytorium trafiają tylko dane demonstracyjne.

## Struktura

```text
ios/                         aplikacja SwiftUI + SwiftData + VisionKit
web/                         statyczny katalog na GitHub Pages
fixtures/                    wspólne przypadki testowe round-trip
docs/ARCHITECTURE.md         decyzje techniczne i granice MVP
docs/COLLECTION_FORMAT.md    kontrakt wymiany danych v1
.github/workflows/           testy i publikacja Pages
```

## Uruchomienie iOS

Wymagania: Xcode 26 lub nowszy, iOS 17+.

1. Otwórz `ios/HomeLibrary.xcodeproj`.
2. Wybierz schemat `HomeLibrary` i symulator iPhone'a.
3. Uruchom aplikację. Skaner kamery wymaga fizycznego, wspieranego urządzenia; na symulatorze dostępne jest ręczne wpisanie kodu.

Walidacja z terminala:

```bash
xcodebuild -project ios/HomeLibrary.xcodeproj \
  -scheme HomeLibrary \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

## Uruchomienie WWW

Strona nie wymaga instalowania zależności ani budowania bundla.

```bash
python3 -m http.server 8080 --directory web
```

Następnie otwórz `http://localhost:8080`.

Testy web:

```bash
node --test web/tests/*.test.mjs
```

Publiczny kontrakt maszynowy: [collection.schema.json](https://lpociask.github.io/domowa-biblioteka/collection.schema.json).

## Prywatność

- Nie commituj prawdziwego eksportu kolekcji.
- Lokalizacje domu są prywatne domyślnie.
- Plik JSON może zawierać lokalizacje i notatki. Przenoś go świadomie, np. przez aplikację Pliki lub AirDrop, i samodzielnie wybierz miejsce przechowywania kopii.
- Lookup metadanych wysyła do Biblioteki Narodowej, a w razie potrzeby do Open Library, wyłącznie znormalizowany ISBN. Nie wysyła lokalizacji, notatek ani całej kolekcji.
- Open Library jest używane wyłącznie jako wywoływany przez użytkownika fallback o małym wolumenie; jawny cache metadanych i okładek ogranicza ponowne zapytania, ale nie służy do masowego wzbogacania kolekcji.
- GitHub Pages może być publicznie dostępny nawet wtedy, gdy kod znajduje się w prywatnym repozytorium — zależy to od planu i ustawień GitHub.
- Przyszła synchronizacja będzie wymagała uwierzytelnionego API i bazy danych z izolacją kolekcji użytkowników.

## Następne etapy

1. Pilot na 100–200 realnych książkach i numerach prasy wraz z lokalnym raportem czasu, skuteczności źródeł i ręcznych korekt.
2. Dalsze utwardzenie metadanych: e‑ISBN, pochodzenie pojedynczych pól i obsługa niejednoznacznych wyników.
3. Walidacja na fizycznych próbkach dodatków EAN‑2/EAN‑5, OCR oraz analizy brakujących i zdublowanych numerów.
4. Dopiero po pilocie: decyzja o prywatnym backendzie synchronizacji i koncie użytkownika.

Szczegółowa kolejność znajduje się w [`docs/ROADMAP.md`](docs/ROADMAP.md).

Analiza źródeł i ograniczeń API znajduje się w [`analiza-produktowa-zrodla.md`](analiza-produktowa-zrodla.md).
