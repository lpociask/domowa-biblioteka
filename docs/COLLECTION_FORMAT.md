# Format kolekcji JSON v1

Format jest wspólną granicą między aplikacją iOS i statycznym webem. Model rozdziela publikację od fizycznego egzemplarza, aby obsłużyć wiele kopii tego samego wydania.

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
        "source": "manual"
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
- Wszystkie identyfikatory wewnętrzne są stabilnymi UUID zapisanymi jako tekst.
- Daty używają ISO 8601.
- `type` publikacji w v1 ma wartość `book` albo `periodical`.
- `identifiers` może zawierać ISBN‑13, ISSN, EAN i surowy kod kreskowy; żaden z nich nie jest kluczem głównym egzemplarza.
- `issue` jest opcjonalne i może zawierać `number`, `volume` oraz `date` dla konkretnego numeru prasy.
- `locationPath` pozwala wyświetlić lokalizację bez dodatkowych zapytań. `locationId` może być pominięte w najwcześniejszych eksportach.
- `metadata.source` w MVP może mieć wartość `manual` albo `scan`. W przyszłości będzie zawierać identyfikator adaptera i czas pobrania.
- Nieznane opcjonalne pola powinny być ignorowane, nie powodować odrzucenia całego importu.

## Migracje

Importer sprawdza `schemaVersion`. Zmiana łamiąca kompatybilność wymaga nowego numeru wersji i migratora. Dodanie pola opcjonalnego nie wymaga zmiany wersji.
