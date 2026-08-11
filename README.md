# Domowa Biblioteka

Pierwszy vertical slice prywatnego katalogu książek i prasy:

- natywna aplikacja iOS do skanowania, ręcznego dodawania i przechowywania kolekcji lokalnie;
- statyczny katalog WWW działający na GitHub Pages;
- wspólny, wersjonowany format eksportu JSON;
- świadome rozdzielenie publikacji od posiadanego egzemplarza.

> GitHub Pages hostuje wyłącznie statyczne HTML, CSS i JavaScript. Nie jest bazą danych ani bezpiecznym backendem synchronizacji. Bieżący MVP przenosi kolekcję z iOS do webu przez eksport/import JSON, a web przechowuje ją lokalnie w przeglądarce. Eksport webowy służy jako kopia zapasowa lub do przenosin między przeglądarkami; aplikacja iOS nie importuje go jeszcze. Do repozytorium trafiają tylko dane demonstracyjne.

## Struktura

```text
ios/                         aplikacja SwiftUI + SwiftData + VisionKit
web/                         statyczny katalog na GitHub Pages
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

## Prywatność

- Nie commituj prawdziwego eksportu kolekcji.
- Lokalizacje domu są prywatne domyślnie.
- GitHub Pages może być publicznie dostępny nawet wtedy, gdy kod znajduje się w prywatnym repozytorium — zależy to od planu i ustawień GitHub.
- Przyszła synchronizacja będzie wymagała uwierzytelnionego API i bazy danych z izolacją kolekcji użytkowników.

## Następne etapy

1. Pilot na 100–200 realnych książkach i numerach prasy.
2. Integracja Biblioteki Narodowej oraz e‑ISBN za warstwą adapterów.
3. OCR okładki i półautomatyczne rozpoznawanie numerów prasy.
4. Prywatny backend synchronizacji i konto użytkownika.

Szczegółowa kolejność znajduje się w [`docs/ROADMAP.md`](docs/ROADMAP.md).

Analiza źródeł i ograniczeń API znajduje się w [`analiza-produktowa-zrodla.md`](analiza-produktowa-zrodla.md).
