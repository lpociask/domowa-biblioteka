# Architektura pierwszego MVP

## Cel vertical slice

Pierwsza wersja ma potwierdzić trzy rzeczy:

1. Czy dużą kolekcję da się katalogować wystarczająco szybko?
2. Czy zapis `publikacja → egzemplarz → lokalizacja` rozwiązuje pytanie „czy to mam i gdzie to leży?”
3. Czy ten sam eksport można wygodnie przeglądać na telefonie i w przeglądarce?

## Granice systemu

```text
┌─────────────────────────────┐
│ iOS                         │
│ SwiftUI + VisionKit         │
│ SwiftData (lokalna baza)    │
└──────────────┬──────────────┘
               │ eksport iOS → import web
               │ collection.json
               ▼
┌─────────────────────────────┐
│ Web na GitHub Pages         │
│ statyczne HTML/CSS/JS       │
│ pamięć lokalna przeglądarki │
└─────────────────────────────┘
```

GitHub Pages publikuje interfejs, lecz nie przyjmuje bezpiecznie zapisów z aplikacji. W tej fazie nie ma kont, współdzielenia ani automatycznej synchronizacji pomiędzy urządzeniami. Przepływ iOS → web działa przez plik JSON; import tego pliku z powrotem do aplikacji iOS nie należy jeszcze do MVP.

## Model domeny

```text
Publication 1 ── N OwnedItem N ── 1 Location
```

`Publication` opisuje wydanie książki albo konkretny numer prasy. `OwnedItem` opisuje fizyczny egzemplarz należący do kolekcji. To rozdzielenie pozwala mieć dwie kopie tego samego ISBN w różnych miejscach i stanie.

W kolejnej wersji model prasy zostanie rozszerzony do:

```text
Serial → SerialManifestation → Issue → OwnedItem
```

## iOS

- SwiftUI: interfejs.
- SwiftData: lokalne, trwałe przechowywanie.
- VisionKit `DataScannerViewController`: skan kodów na wspieranym urządzeniu.
- Ręczny fallback: wymagany na symulatorze, starym urządzeniu i dla publikacji bez czytelnego kodu.
- Eksport JSON: jedyna granica wymiany danych w MVP.

Skan powinien zostać zapisany lokalnie natychmiast. Późniejsze wzbogacenie metadanych nie może blokować katalogowania półki.

## Web

- Brak frameworka i bundlera: mniejszy koszt utrzymania GitHub Pages.
- Import pliku zgodnego z `schemaVersion: 1`.
- Lokalne przechowywanie danych w przeglądarce.
- Wyszukiwanie oraz filtry bez wysyłania prywatnej kolekcji na serwer.

## Przyszła synchronizacja

Docelowy przepływ:

```text
iOS / Web
    │ uwierzytelnione, idempotentne API
    ▼
Postgres + object storage
    │
    ├── adapter Biblioteki Narodowej
    ├── adapter e‑ISBN
    ├── adaptery katalogów zagranicznych
    └── kolejka OCR / wzbogacania danych
```

Backend nie może być GitHub Pages. Powinien zapewnić uwierzytelnienie, izolację danych per kolekcja, historię zmian, backup i kontrolę licencji metadanych.

## Zasady bezpieczeństwa

- Prawdziwy eksport kolekcji jest ignorowany przez Git.
- Dane demonstracyjne nie zawierają adresów ani rzeczywistych lokalizacji użytkownika.
- QR lokalizacji w przyszłości zawiera niejawny UUID, nie nazwę pokoju lub adres.
- Pola pobrane z zewnętrznych źródeł przechowują pochodzenie i czas pobrania.
- Ręczne poprawki użytkownika nie są nadpisywane automatycznie.
