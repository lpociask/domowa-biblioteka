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

test("buduje hierarchiczną ścieżkę lokalizacji i chroni się przed cyklem", () => {
  assert.equal(locationPath("shelf", canonical.locations), "Gabinet / Regał / Półka 2");
  const cyclic = [
    { id: "a", name: "A", type: "room", parentId: "b" },
    { id: "b", name: "B", type: "shelf", parentId: "a" },
  ];
  assert.match(locationPath("a", cyclic), /A/);
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
  assert.equal(merged.publications.length, 1);
  assert.equal(merged.ownedItems.length, 3);
  assert.equal(merged.ownedItems.find((item) => item.id === "copy-3").publicationId, "pub-1");
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
