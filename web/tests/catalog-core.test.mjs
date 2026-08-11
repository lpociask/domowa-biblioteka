import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  catalogEntries,
  collectionStats,
  exportPayload,
  filterEntries,
  locationPath,
  mergeCollections,
  normalizeCollection,
  normalizeForSearch,
  sortEntries,
} from "../lib/catalog-core.mjs";

const canonical = {
  schemaVersion: 1,
  exportedAt: "2026-08-11T12:00:00.000Z",
  collection: { id: "collection-1", name: "Testowa" },
  locations: [
    { id: "room", name: "Gabinet", type: "room", parentId: null },
    { id: "case", name: "Regał", type: "bookcase", parentId: "room" },
    { id: "shelf", name: "Półka 2", type: "shelf", parentId: "case" },
  ],
  publications: [
    {
      id: "pub-1",
      type: "book",
      title: "Żółty świat",
      subtitle: null,
      authors: ["Łukasz Żak"],
      language: "pl",
      publisher: "Próba",
      publicationYear: 2024,
      identifiers: { isbn13: "9780306406157", issn: null, ean: null, barcode: null },
      issue: null,
      metadata: { subjects: ["Esej"] },
      createdAt: "2026-08-10T10:00:00Z",
      updatedAt: "2026-08-10T10:00:00Z",
    },
  ],
  ownedItems: [
    {
      id: "copy-1",
      publicationId: "pub-1",
      locationId: "shelf",
      locationPath: ["Gabinet", "Regał", "Półka 2"],
      status: "owned",
      notes: "Pierwszy egzemplarz",
      addedAt: "2026-08-10T11:00:00Z",
      updatedAt: "2026-08-10T11:00:00Z",
    },
    {
      id: "copy-2",
      publicationId: "pub-1",
      locationId: "case",
      locationPath: ["Gabinet", "Regał"],
      status: "loaned",
      notes: null,
      addedAt: "2026-08-11T11:00:00Z",
      updatedAt: "2026-08-11T11:00:00Z",
    },
  ],
};

test("normalizacja zachowuje rozdział publikacji i wielu egzemplarzy", () => {
  const collection = normalizeCollection(canonical);
  assert.equal(collection.publications.length, 1);
  assert.equal(collection.ownedItems.length, 2);
  assert.equal(collection.ownedItems[1].publicationId, "pub-1");
  assert.equal(collection.ownedItems[1].status, "loaned");
});

test("kanoniczna normalizacja emituje całkowity rok i daty ISO 8601", () => {
  const input = structuredClone(canonical);
  input.exportedAt = "2026-08-11T14:00:00+02:00";
  input.publications[0].publicationYear = "2024";
  input.publications[0].createdAt = "2026-08-10T12:00:00+02:00";
  const collection = normalizeCollection(input);

  assert.equal(collection.publications[0].publicationYear, 2024);
  assert.equal(Number.isInteger(collection.publications[0].publicationYear), true);
  assert.equal(collection.exportedAt, "2026-08-11T12:00:00.000Z");
  assert.equal(collection.publications[0].createdAt, "2026-08-10T10:00:00.000Z");

  const payload = exportPayload(collection, "2026-08-11T17:00:00+02:00");
  assert.equal(payload.exportedAt, "2026-08-11T15:00:00.000Z");
  for (const value of [
    payload.publications[0].createdAt,
    payload.publications[0].updatedAt,
    payload.ownedItems[0].addedAt,
    payload.ownedItems[0].updatedAt,
  ]) {
    assert.match(value, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  }
});

test("kanoniczna normalizacja odrzuca nieprawidłowe lata i daty", () => {
  for (const invalidYear of [0, 2024.5, 10000, "rok 2024"]) {
    const input = structuredClone(canonical);
    input.publications[0].publicationYear = invalidYear;
    assert.throws(() => normalizeCollection(input), /publicationYear/);
  }

  const invalidPublicationDate = structuredClone(canonical);
  invalidPublicationDate.publications[0].createdAt = "2026-02-29T10:00:00Z";
  assert.throws(() => normalizeCollection(invalidPublicationDate), /createdAt/);

  const invalidItemDate = structuredClone(canonical);
  invalidItemDate.ownedItems[0].addedAt = "11.08.2026";
  assert.throws(() => normalizeCollection(invalidItemDate), /addedAt/);
  assert.throws(() => exportPayload(canonical, "jutro"), /exportedAt/);
});

test("buduje hierarchiczną ścieżkę lokalizacji i chroni się przed cyklem", () => {
  assert.equal(locationPath("shelf", canonical.locations), "Gabinet / Regał / Półka 2");
  const cyclic = [
    { id: "a", name: "A", type: "room", parentId: "b" },
    { id: "b", name: "B", type: "shelf", parentId: "a" },
  ];
  assert.match(locationPath("a", cyclic), /A/);
});

test("normalizacja usuwa nieistniejące locationId i zachowuje ścieżkę zapasową", () => {
  const input = structuredClone(canonical);
  input.ownedItems[0].locationId = "missing-location";
  input.ownedItems[0].locationPath = ["Dom", "Gabinet", "Półka awaryjna"];

  const normalized = normalizeCollection(input);
  assert.equal(normalized.ownedItems[0].locationId, null);
  assert.deepEqual(normalized.ownedItems[0].locationPath, [
    "Dom",
    "Gabinet",
    "Półka awaryjna",
  ]);

  const exported = exportPayload(normalized, "2026-08-11T14:00:00.000Z");
  assert.equal(exported.ownedItems[0].locationId, null);
  assert.deepEqual(exported.ownedItems[0].locationPath, normalized.ownedItems[0].locationPath);
});

test("wyszukiwanie jest niewrażliwe na polskie znaki i obejmuje identyfikator", () => {
  const collection = normalizeCollection(canonical);
  const entries = catalogEntries(collection);
  assert.equal(normalizeForSearch("ŁÓDŹ"), "lodz");
  assert.equal(filterEntries(entries, { query: "zolty lukasz" }, collection.locations).length, 2);
  assert.equal(filterEntries(entries, { query: "9780306406157" }, collection.locations).length, 2);
  assert.equal(filterEntries(entries, { query: "nie istnieje" }, collection.locations).length, 0);
});

test("filtr lokalizacji obejmuje elementy w lokalizacjach potomnych", () => {
  const collection = normalizeCollection(canonical);
  const entries = catalogEntries(collection);
  assert.equal(filterEntries(entries, { locationId: "room" }, collection.locations).length, 2);
  assert.equal(filterEntries(entries, { locationId: "shelf" }, collection.locations).length, 1);
});

test("sortowanie po dodaniu ustawia najnowszy egzemplarz jako pierwszy", () => {
  const entries = catalogEntries(canonical);
  assert.equal(sortEntries(entries, "addedDesc")[0].id, "copy-2");
});

test("import legacy items[] jest tolerowany i mapuje prasę na periodical", () => {
  const legacy = normalizeCollection({
    name: "Stary eksport",
    locations: [],
    items: [
      {
        id: "old-copy",
        kind: "magazine",
        title: "Kwartalnik",
        issn: "1234-5678",
        issue: { number: "2/2025" },
        copy: { status: "owned" },
      },
    ],
  });
  assert.equal(legacy.publications[0].type, "periodical");
  assert.equal(legacy.publications[0].identifiers.issn, "12345678");
  assert.equal(legacy.ownedItems[0].publicationId, legacy.publications[0].id);
});

test("legacy normalizuje błędny rok i daty do bezpiecznych fallbacków", () => {
  const legacy = normalizeCollection({
    name: "Stary eksport",
    exportedAt: "nie-data",
    items: [
      {
        id: "legacy-copy",
        title: "Książka bez poprawnych dat",
        year: "2024.5",
        createdAt: "wczoraj",
        updatedAt: "jutro",
        copy: { addedAt: "brak", updatedAt: "nadal brak" },
      },
    ],
  });

  assert.equal(legacy.publications[0].publicationYear, null);
  for (const value of [
    legacy.exportedAt,
    legacy.publications[0].createdAt,
    legacy.publications[0].updatedAt,
    legacy.ownedItems[0].addedAt,
    legacy.ownedItems[0].updatedAt,
  ]) {
    assert.match(value, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  }
});

test("łączenie deduplikuje wydanie, lecz zachowuje różne fizyczne kopie", () => {
  const incoming = structuredClone(canonical);
  incoming.collection = { id: "collection-2", name: "Importowana" };
  incoming.publications[0].id = "foreign-pub-id";
  incoming.publications[0].title = "Żółty świat — opis z importu";
  incoming.ownedItems = [
    {
      ...incoming.ownedItems[0],
      id: "copy-3",
      publicationId: "foreign-pub-id",
    },
  ];
  const merged = mergeCollections(canonical, incoming);
  assert.deepEqual(merged.collection, canonical.collection);
  assert.equal(merged.publications.length, 1);
  assert.equal(merged.ownedItems.length, 3);
  assert.equal(merged.ownedItems.find((item) => item.id === "copy-3").publicationId, "pub-1");
});

test("łączenie zachowuje lokalizacje o tej samej nazwie pod różnymi rodzicami", () => {
  const incoming = structuredClone(canonical);
  incoming.collection = { id: "collection-salon", name: "Salon" };
  incoming.locations = [
    { id: "salon", name: "Salon", type: "room", parentId: null },
    { id: "salon-shelf", name: "Półka 2", type: "shelf", parentId: "salon" },
  ];
  incoming.publications[0].id = "foreign-pub-id";
  incoming.ownedItems = [
    {
      ...incoming.ownedItems[0],
      id: "copy-salon",
      publicationId: "foreign-pub-id",
      locationId: "salon-shelf",
      locationPath: ["Salon", "Półka 2"],
    },
  ];

  const merged = mergeCollections(canonical, incoming);
  const shelves = merged.locations.filter((location) => location.name === "Półka 2");
  const salonCopy = merged.ownedItems.find((item) => item.id === "copy-salon");

  assert.equal(shelves.length, 2);
  assert.notEqual(shelves[0].parentId, shelves[1].parentId);
  assert.equal(locationPath(salonCopy.locationId, merged.locations), "Salon / Półka 2");
  assert.equal(locationPath("shelf", merged.locations), "Gabinet / Regał / Półka 2");
});

test("wspólny fixture przechodzi normalize, export i merge bez utraty semantyki", async () => {
  const url = new URL("../../fixtures/roundtrip-v1.json", import.meta.url);
  const fixture = JSON.parse(await readFile(url, "utf8"));
  const exported = exportPayload(normalizeCollection(fixture), fixture.exportedAt);
  const incoming = structuredClone(exported);
  incoming.locations[0].id = "incoming-room";
  incoming.locations[1].id = "incoming-shelf";
  incoming.locations[1].parentId = "incoming-room";
  incoming.ownedItems[0].locationId = "incoming-shelf";

  const merged = mergeCollections(exported, incoming);
  const roundTripped = normalizeCollection(
    JSON.parse(JSON.stringify(exportPayload(merged, "2026-08-11T14:00:00.000Z"))),
  );

  assert.equal(roundTripped.publications.length, 1);
  assert.equal(roundTripped.ownedItems.length, 1);
  assert.equal(roundTripped.locations.length, 2);
  assert.equal(roundTripped.publications[0].id, "publication-with-text-id");
  assert.equal(roundTripped.ownedItems[0].id, "owned-item-with-text-id");
  assert.equal(roundTripped.ownedItems[0].publicationId, "publication-with-text-id");
  assert.equal(roundTripped.publications[0].identifiers.barcode, "FIXTURE-001");
  assert.deepEqual(roundTripped.publications[0].authors, [
    "Sacher-Masoch, Leopold von",
    "Nowak, Anna",
  ]);
  assert.equal(roundTripped.ownedItems[0].locationId, "location-shelf");
  assert.equal(
    locationPath(roundTripped.ownedItems[0].locationId, roundTripped.locations),
    "Gabinet / Półka bez ISBN",
  );
});

test("dwa numery tego samego ISSN pozostają osobnymi publikacjami", () => {
  const base = {
    ...canonical,
    publications: [
      {
        ...canonical.publications[0],
        id: "periodical-1",
        type: "periodical",
        identifiers: { isbn13: null, issn: "12345678", ean: null, barcode: null },
        issue: { number: "1/2026", volume: null, date: "2026-01" },
      },
    ],
    ownedItems: [
      { ...canonical.ownedItems[0], id: "press-copy-1", publicationId: "periodical-1" },
    ],
  };
  const incoming = structuredClone(base);
  incoming.publications[0].id = "periodical-2";
  incoming.publications[0].issue = { number: "2/2026", volume: null, date: "2026-04" };
  incoming.ownedItems[0].id = "press-copy-2";
  incoming.ownedItems[0].publicationId = "periodical-2";
  const merged = mergeCollections(base, incoming);
  assert.equal(merged.publications.length, 2);
  assert.equal(merged.ownedItems.length, 2);
});

test("statystyki liczą egzemplarze, a nie tylko rekordy publikacji", () => {
  assert.deepEqual(collectionStats(canonical), {
    total: 2,
    publications: 1,
    books: 2,
    press: 0,
    located: 2,
    unlocated: 0,
  });
});

test("eksport ma kanoniczną wersję 1 i zadany czas eksportu", () => {
  const payload = exportPayload(canonical, "2026-08-11T15:00:00.000Z");
  assert.equal(payload.schemaVersion, 1);
  assert.equal(payload.exportedAt, "2026-08-11T15:00:00.000Z");
  assert.ok(Array.isArray(payload.publications));
  assert.ok(Array.isArray(payload.ownedItems));
  assert.equal("items" in payload, false);
});

test("odrzuca eksport z nieobsługiwaną wersją i osierocony egzemplarz", () => {
  assert.throws(() => normalizeCollection({ ...canonical, schemaVersion: 2 }), /Nieobsługiwana wersja/);
  assert.throws(
    () =>
      normalizeCollection({
        ...canonical,
        ownedItems: [{ ...canonical.ownedItems[0], publicationId: "missing" }],
      }),
    /nieistniejącą publikację/,
  );
});

test("dołączony collection.json jest poprawnym eksportem v1", async () => {
  const url = new URL("../collection.json", import.meta.url);
  const sample = JSON.parse(await readFile(url, "utf8"));
  const normalized = normalizeCollection(sample);
  assert.equal(normalized.schemaVersion, 1);
  assert.ok(normalized.publications.length >= 6);
  assert.ok(normalized.ownedItems.length > normalized.publications.length);
  assert.ok(normalized.publications.some((publication) => publication.type === "periodical"));
});
