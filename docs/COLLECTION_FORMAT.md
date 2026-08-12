# Format kolekcji JSON v1

Format jest wspólną granicą importu i eksportu między aplikacją iOS a statycznym webem. Transfer jest ręczny: użytkownik zapisuje plik w wybranym miejscu i sam importuje go w drugim kliencie. Model rozdziela publikację od fizycznego egzemplarza, aby obsłużyć wiele kopii tego samego wydania.

Maszynowy kontrakt znajduje się w [`collection.schema.json`](collection.schema.json).

## Przykład

```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-08-11T12:00:00Z",
  "collection": {
    "id": "73D9AC63-E635-457A-A669-096E401DFA12",
    "name": "Moja biblioteka"
  },
  "locations": [
    {
      "id": "DDA262C0-E801-4D0B-A47F-A439B5AC3CE7",
      "name": "Półka 2",
      "type": "shelf",
      "parentId": null
    }
  ],
  "publications": [
    {
      "id": "05B33F9E-7D0F-43A8-A135-4D826AFC9F9E",
      "type": "book",
      "title": "Przykładowa książka",
      "subtitle": null,
      "authors": ["Jan Kowalski"],
      "language": "pl",
      "publisher": "Przykładowe wydawnictwo",
      "publicationYear": 2026,
      "identifiers": {
        "isbn13": "9780306406157",
        "issn": null,
        "ean": "9780306406157",
        "barcode": "9780306406157"
      },
      "issue": null,
      "metadata": {
        "source": "manual",
        "coverUrl": "https://covers.openlibrary.org/b/isbn/9780306406157-M.jpg?default=false",
        "coverSource": "openlibrary"
      },
      "createdAt": "2026-08-11T12:00:00Z",
      "updatedAt": "2026-08-11T12:00:00Z"
    }
  ],
  "ownedItems": [
    {
      "id": "FDCB78F6-8438-4EA8-9B77-5C390FDC50A1",
      "publicationId": "05B33F9E-7D0F-43A8-A135-4D826AFC9F9E",
      "locationId": "DDA262C0-E801-4D0B-A47F-A439B5AC3CE7",
      "locationPath": ["Dom", "Gabinet", "Regał 1", "Półka 2"],
      "status": "owned",
      "notes": null,
      "addedAt": "2026-08-11T12:00:00Z",
      "updatedAt": "2026-08-11T12:00:00Z"
    }
  ]
}
```

## Reguły

- `schemaVersion` jest wymagane i obecnie wynosi `1`.
- Identyfikatory rekordów są stabilnymi, niepustymi stringami i nie muszą być UUID. iOS zachowuje zewnętrzną wartość do ponownego eksportu; wewnętrznie zachowuje poprawny UUID albo deterministycznie mapuje tekst na namespaced UUID.
- Daty używają ISO 8601.
- `type` publikacji w v1 ma wartość `book` albo `periodical`.
- `identifiers` może zawierać ISBN‑13, ISSN, EAN i surowy `barcode`; żaden z nich nie jest kluczem głównym egzemplarza. `barcode` zachowuje oryginalną treść (np. także myślniki lub URL z QR), podczas gdy identyfikatory bibliograficzne mogą być normalizowane do zwartej postaci.
- `issue` jest opcjonalne i może zawierać `number`, `volume` oraz `date` dla konkretnego numeru prasy.
- `locationPath` pozwala wyświetlić lokalizację bez dodatkowych zapytań. `locationId` może być pominięte w najwcześniejszych eksportach.
- `metadata.source` opisuje pochodzenie danych. Aplikacja iOS zapisuje obecnie `manual`, `scan`, `bn` albo `openlibrary`; import zachowuje również inne niepuste wartości źródłowe.
- `metadata.coverUrl` jest opcjonalną, przenośną referencją do okładki, a `metadata.coverSource` zapisuje jej pochodzenie niezależnie od źródła opisu bibliograficznego. Writer v1 zapisuje wyłącznie bezpieczny adres HTTPS bez danych logowania, po normalizacji mieszczący się w 2048 bajtach. Reader zachowuje zgodność ze starszymi plikami: nieważną lub niebezpieczną referencję oraz powiązane `coverSource` pomija, ale nie odrzuca całej publikacji ani kolekcji. Eksport nie zawiera lokalnej ścieżki ani bajtów obrazu.
- Nieznane opcjonalne pola powinny być ignorowane, nie powodować odrzucenia całego importu.

## Import w iOS

Importer iOS przyjmuje wyłącznie pełny, kanoniczny dokument `schemaVersion: 1`. Wymagane są `exportedAt`, `collection`, `locations`, `publications`, `ownedItems` i wszystkie pola oznaczone jako wymagane w schemacie. Tolerancyjny import starszego `items[]` istnieje tylko po stronie webu, który przed dalszym eksportem normalizuje dane do v1.

Przed zapisem importer sprawdza między innymi:

- obsługiwaną wersję schematu;
- niepuste i unikalne identyfikatory publikacji oraz egzemplarzy;
- typ publikacji, wymagany tytuł, zakres roku oraz status egzemplarza;
- kompletność referencji `ownedItem.publicationId` w importowanym pliku;
- poprawność dat ISO 8601, z opcjonalnymi sekundami ułamkowymi;
- unikalność lokalizacji, istnienie rodziców i brak cykli w hierarchii;
- limit 25 MB oraz limity 50 000 publikacji, 100 000 egzemplarzy i 50 000 lokalizacji.

Semantyka importu jest celowo bezpieczna i addytywna:

- prawidłowe UUID są zachowywane, a identyfikatory tekstowe z webu są wewnętrznie mapowane na UUID w osobnych przestrzeniach; oryginalna wartość pozostaje identyfikatorem kolejnego eksportu;
- ponowny import tego samego pliku pomija rekordy o istniejących identyfikatorach;
- istniejące lokalne rekordy nie są nadpisywane, scalane ani usuwane;
- wiele egzemplarzy jednej publikacji pozostaje osobnymi `ownedItems`;
- niepusty `locationPath` ma pierwszeństwo; w przeciwnym razie ścieżka jest odtwarzana z `locationId` oraz `parentId`;
- import do pustej bazy przyjmuje `collection.id` i `collection.name`; przy scalaniu z istniejącą kolekcją oba klienty zachowują jej lokalną tożsamość;
- publikacja bez żadnego fizycznego egzemplarza jest odrzucana, ponieważ bieżący model i eksport iOS są inwentarzem posiadanych obiektów;
- brak `metadata.source` otrzymuje wartość `import`;
- prawidłowy `metadata.coverUrl` jest normalizowany do adresu HTTPS bez danych logowania i po normalizacji może mieć najwyżej 2048 bajtów; nieznany host może zostać zachowany w eksporcie, ale nie jest automatycznie pobierany; nieważna referencja ze starszego pliku oraz jej `coverSource` są pomijane bez odrzucania publikacji lub całego importu;
- nieznane pola są ignorowane, dzięki czemu opcjonalne rozszerzenia webu nie blokują importu.

Odczyt, dekodowanie i walidacja pliku przebiegają poza głównym wątkiem. Dopiero sprawdzony plan importu jest atomowo stosowany do SwiftData na `MainActor`.

Import JSON nie jest synchronizacją ani mechanizmem rozwiązywania konfliktów. Aby świadomie zastąpić dane, trzeba przygotować osobny przepływ migracji; obecny importer chroni lokalne poprawki przez pomijanie istniejących identyfikatorów.

## Prywatność pliku

Eksport może zawierać nazwy pomieszczeń, dokładne ścieżki półek i prywatne notatki. Aplikacja nie wysyła go automatycznie do chmury. Użytkownik wybiera sposób transferu i miejsce kopii, a prawdziwe eksporty nie powinny trafiać do repozytorium ani publicznego hostingu.

Okładki Open Library są pobierane tylko w przepływie świadomie uruchomionego lookupu albo po otwarciu szczegółów. Lista korzysta z lokalnego cache i nie odpytuje serwera obrazów podczas przewijania. WWW nie pobiera całej listy okładek podczas otwierania kolekcji; znany obraz Open Library jest ładowany dopiero w szczegółach publikacji.

## Migracje

Importer sprawdza `schemaVersion`. Zmiana łamiąca kompatybilność wymaga nowego numeru wersji i migratora. Dodanie pola opcjonalnego nie wymaga zmiany wersji. Obsługa importu v1 nie oznacza automatycznej migracji przyszłych wersji.
