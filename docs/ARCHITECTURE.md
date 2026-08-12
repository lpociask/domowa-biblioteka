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
               │ ręczny import / eksport
               │ collection.json
               ▼ ▲
┌─────────────────────────────┐
│ Web na GitHub Pages         │
│ statyczne HTML/CSS/JS       │
│ pamięć lokalna przeglądarki │
└─────────────────────────────┘
```

GitHub Pages publikuje interfejs, lecz nie przyjmuje zapisów z aplikacji. W tej fazie nie ma kont, współdzielenia, chmurowej bazy ani automatycznej synchronizacji pomiędzy urządzeniami. iOS i web wymieniają dane w obie strony wyłącznie przez plik JSON, który użytkownik sam eksportuje, przenosi i importuje.

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
- Import i eksport JSON: jedyna granica wymiany danych w MVP.
- Import jest addytywny i idempotentny względem stabilnych identyfikatorów: pomija istniejące publikacje i egzemplarze, nie nadpisuje lokalnych zmian i nie wykonuje usunięć.
- Zewnętrzne ID są zachowywane przez round-trip, nawet gdy iOS potrzebuje wewnętrznego UUID. Dekodowanie i walidacja importu odbywają się poza głównym wątkiem, przed atomowym zapisem do SwiftData.

Poprawny ISBN 978/979 albo kod prasy 977 przechodzi do edytowalnego formularza. Inny EAN, błędna suma kontrolna lub niepublikacyjny QR pozostają w skanerze z wyjaśnieniem. Lookup działa asynchronicznie i nie blokuje ręcznego uzupełnienia ani zapisu publikacji.

## Wzbogacanie metadanych książek

```text
skan lub ręcznie zatwierdzony kod ISBN
    │ walidacja i normalizacja do ISBN-13
    ▼
Biblioteka Narodowa
    │ brak użytecznego rekordu albo błąd źródła
    ▼
Open Library
    │
    ▼
formularz, który użytkownik może poprawić przed zapisem
```

- Lookup jest uruchamiany przez użytkownika dla pojedynczego ISBN; nie ma działania wsadowego ani wzbogacania w tle.
- Pierwszy użyteczny wynik kończy kaskadę. Awaria BN nie blokuje próby w Open Library, a formularz zawsze pozwala kontynuować ręcznie.
- Zmiany wprowadzone w formularzu podczas trwania zapytania nie są nadpisywane odpowiedzią katalogu.
- Open Library jest eksperymentalnym fallbackiem low-volume. Żądanie używa identyfikującego `User-Agent`, a znormalizowana odpowiedź trafia do jawnego cache aplikacyjnego: trafienia na 30 dni, brak rekordu na 24 godziny, z możliwością użycia starego pozytywnego wpisu podczas awarii do roku.
- Do zewnętrznych katalogów trafia znormalizowany ISBN w adresie zapytania. Kolekcja, lokalizacja egzemplarza i notatki pozostają lokalne.
- `metadata.source` zapisuje źródło zaakceptowanego wyniku jako `bn` lub `openlibrary`.

## Okładki i cache offline

- `Publication` przechowuje wyłącznie zaakceptowany zdalny URL okładki i jej źródło. Lokalny plik obrazu nie jest częścią modelu kolekcji, eksportu ani przyszłej synchronizacji.
- Brakujący URL książki z poprawnym ISBN może zostać wyprowadzony z oficjalnego [Open Library Covers API](https://openlibrary.org/dev/docs/api/covers). Okładka ma osobne provenance, dlatego opis z BN może używać obrazu z Open Library.
- Plikowy cache okładek znajduje się w Application Support, jest wyłączony z backupu, waliduje HTTPS, host, MIME, rozmiar i wymiary, skaluje obraz oraz ogranicza całość polityką LRU.
- Lista biblioteki czyta wyłącznie cache dyskowy. Pobranie sieciowe jest dozwolone po skanie/lookupie albo otwarciu szczegółów, nie podczas zwykłego przewijania całej kolekcji.
- Importowany URL z nieznanego hosta może zostać zachowany dla round-trip, lecz klient nie pobiera go automatycznie.

## Web

- Brak frameworka i bundlera: mniejszy koszt utrzymania GitHub Pages.
- Import pliku zgodnego z `schemaVersion: 1`.
- Eksport tego samego formatu, który może zostać ponownie zaimportowany przez iOS.
- Lokalne przechowywanie danych w przeglądarce.
- Wyszukiwanie oraz filtry bez wysyłania prywatnej kolekcji na serwer.

## Przyszła synchronizacja

Poniższy backend nie jest częścią bieżącego MVP. Do czasu osobnej decyzji po pilocie obowiązuje ręczny transfer pliku JSON, bez własnej chmury.

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
- Aplikacja nie wysyła eksportu automatycznie. Użytkownik wybiera docelowe miejsce pliku i odpowiada za zabezpieczenie ewentualnej kopii chmurowej.
- Import ma limit 25 MB i sprawdza pełny kontrakt, identyfikatory, daty, referencje oraz graf lokalizacji przed zapisem; ponowny import tego samego pliku nie nadpisuje rekordów o tych samych identyfikatorach.
- QR lokalizacji w przyszłości zawiera niejawny UUID, nie nazwę pokoju lub adres.
- Publikacja przechowuje źródło zaakceptowanych metadanych. Czas pobrania i pochodzenie na poziomie pojedynczego pola wymagają przyszłego rozszerzenia modelu.
- Ręczne poprawki użytkownika nie są nadpisywane automatycznie.
