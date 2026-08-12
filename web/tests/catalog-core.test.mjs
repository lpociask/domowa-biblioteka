import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  PILOT_REPORT_IMPORT_MESSAGE,
  PilotReportImportError,
  analyzePeriodicals,
  automaticCoverUrl,
  catalogEntries,
  collectionStats,
  exportPayload,
  filterEntries,
  isPilotMetricsReport,
  locationPath,
  mergeCollections,
  normalizeCollection,
  normalizeForSearch,
  parseEANSupplementBarcode,
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

const pilotMetricsReport = {
  schemaVersion: 1,
  catalog: [
    {
      publicationKind: "book",
      attempts: 25,
      completed: 22,
      cancelled: 3,
    },
  ],
  corrections: {
    completedItems: 22,
    correctedItems: 4,
    manualCorrections: 12,
  },
  lookups: [
    {
      source: "nationalLibrary",
      attempts: 29,
      found: 16,
    },
  ],
  location: { measurements: 22, reusedPrevious: 2 },
  mutations: [],
  ocr: { attempts: 0 },
  search: { sessions: 0 },
  transfers: [],
};

function makePeriodicalCollection(publications, copies = null) {
  const normalizedPublications = publications.map((publication, index) => ({
    ...canonical.publications[0],
    id: publication.id || `press-${index + 1}`,
    type: "periodical",
    title: publication.title ?? "Magazyn Testowy",
    publisher: publication.publisher ?? "Wydawnictwo",
    language: publication.language ?? "pl",
    publicationYear: publication.publicationYear ?? null,
    identifiers: {
      isbn13: null,
      isbn10: null,
      issn: publication.issn ?? null,
      ean: publication.ean ?? null,
      barcode: publication.barcode ?? null,
    },
    issue: {
      number: publication.issueNumber ?? null,
      volume: publication.issueVolume ?? null,
      date: publication.issueDate ?? null,
    },
  }));
  const normalizedCopies = copies || normalizedPublications.map((publication, index) => ({
    ...canonical.ownedItems[0],
    id: `press-copy-${index + 1}`,
    publicationId: publication.id,
  }));
  return {
    ...structuredClone(canonical),
    publications: normalizedPublications,
    ownedItems: normalizedCopies,
  };
}

test("normalizacja zachowuje rozdział publikacji i wielu egzemplarzy", () => {
  const collection = normalizeCollection(canonical);
  assert.equal(collection.publications.length, 1);
  assert.equal(collection.ownedItems.length, 2);
  assert.equal(collection.ownedItems[1].publicationId, "pub-1");
  assert.equal(collection.ownedItems[1].status, "loaned");
});

test("raport pomiarowy pilota jest rozpoznawany i odrzucany z instrukcją importu kolekcji", () => {
  const input = structuredClone(pilotMetricsReport);
  const unchanged = structuredClone(input);

  assert.equal(isPilotMetricsReport(input), true);
  assert.throws(
    () => normalizeCollection(input),
    (error) =>
      error instanceof PilotReportImportError &&
      error.message === PILOT_REPORT_IMPORT_MESSAGE,
  );
  assert.deepEqual(input, unchanged);
});

test("dodatkowe pola raportowe nie blokują prawidłowego pliku kolekcji", () => {
  const input = {
    ...structuredClone(canonical),
    catalog: pilotMetricsReport.catalog,
    corrections: pilotMetricsReport.corrections,
    lookups: pilotMetricsReport.lookups,
  };

  assert.equal(isPilotMetricsReport(input), false);
  assert.equal(normalizeCollection(input).ownedItems.length, 2);
});

test("przypadkowy niepełny JSON zachowuje ogólny błąd formatu kolekcji", () => {
  const input = {
    schemaVersion: 1,
    catalog: [],
    corrections: {},
  };

  assert.equal(isPilotMetricsReport(input), false);
  assert.throws(
    () => normalizeCollection(input),
    /Plik nie zawiera tablic „publications” i „ownedItems”/,
  );
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

test("okładka HTTPS przechodzi round-trip, a niebezpieczna referencja jest pomijana bez utraty kolekcji", () => {
  const input = structuredClone(canonical);
  input.publications[0].metadata.coverUrl =
    "https://covers.openlibrary.org/b/isbn/9780306406157-M.jpg?default=false";
  input.publications[0].metadata.coverSource = "openlibrary";

  const normalized = normalizeCollection(input);
  const exported = exportPayload(normalized, "2026-08-11T14:00:00Z");
  assert.equal(exported.publications[0].metadata.coverUrl, input.publications[0].metadata.coverUrl);
  assert.equal(exported.publications[0].metadata.coverSource, "openlibrary");

  for (const invalidUrl of [
    "http://covers.openlibrary.org/b/id/123-M.jpg",
    "file:///tmp/cover.jpg",
    "https://user:secret@covers.openlibrary.org/b/id/123-M.jpg",
    "https://covers.openlibrary.org/okładka.jpg",
    "https://covers.openlibrary.org/cover name.jpg",
    "legacy-local-cache-key",
    `https://example.com/${"<".repeat(700)}`,
    { legacy: "local-cache-key" },
    12345,
  ]) {
    const invalid = structuredClone(canonical);
    invalid.publications[0].metadata.coverUrl = invalidUrl;
    invalid.publications[0].metadata.coverSource = ["legacy"];
    const withoutUnsafeCover = normalizeCollection(invalid);
    assert.equal(withoutUnsafeCover.publications.length, 1);
    assert.equal(withoutUnsafeCover.publications[0].title, canonical.publications[0].title);
    assert.equal(withoutUnsafeCover.publications[0].metadata.coverUrl, null);
    assert.equal(withoutUnsafeCover.publications[0].metadata.coverSource, null);
    assert.equal(withoutUnsafeCover.ownedItems.length, canonical.ownedItems.length);
  }

  assert.equal(
    automaticCoverUrl("HTTPS://covers.openlibrary.org/b/id/123-M.jpg"),
    "https://covers.openlibrary.org/b/id/123-M.jpg",
  );
  assert.equal(
    automaticCoverUrl("https://covers.openlibrary.org:443/b/id/123-M.jpg"),
    "https://covers.openlibrary.org/b/id/123-M.jpg",
  );
  assert.equal(automaticCoverUrl("https://covers.openlibrary.org:444/b/id/123-M.jpg"), null);
  assert.equal(automaticCoverUrl("https://example.com/cover.jpg"), null);
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

test("dodatek EAN-2/EAN-5 jest walidowany, kanonizowany i wyszukiwalny", () => {
  assert.deepEqual(parseEANSupplementBarcode("9771234567003 + 05"), {
    ean: "9771234567003",
    supplement: "05",
    canonical: "9771234567003+05",
  });
  assert.equal(parseEANSupplementBarcode("9771234567003+12345")?.supplement, "12345");
  assert.equal(parseEANSupplementBarcode("9771234567004+05"), null);
  assert.equal(parseEANSupplementBarcode("9780306406157+05"), null);
  assert.equal(parseEANSupplementBarcode("9771234567003+5"), null);

  const input = structuredClone(canonical);
  input.publications[0] = {
    ...input.publications[0],
    type: "periodical",
    identifiers: {
      isbn13: null,
      issn: "12345679",
      ean: null,
      barcode: "9771234567003 + 05",
    },
  };
  const collection = normalizeCollection(input);
  assert.equal(collection.publications[0].identifiers.ean, "9771234567003");
  assert.equal(collection.publications[0].identifiers.barcode, "9771234567003+05");
  assert.equal(filterEntries(catalogEntries(collection), { query: "05" }, []).length, 2);
});

test("analiza prasy grupuje poprawny ISSN i ISSN wyprowadzony z EAN-977", () => {
  const collection = makePeriodicalCollection([
    { id: "explicit", title: "Pierwszy tytuł", issn: "0033-2488", issueNumber: "1/2026" },
    { id: "derived", title: "Drugi tytuł", ean: "9770033248007", issueNumber: "2/2026" },
    { id: "composite", barcode: "9770033248007+03", issueNumber: "3/2026" },
  ]);

  const analysis = analyzePeriodicals(collection);
  assert.equal(analysis.series.length, 1);
  assert.equal(analysis.series[0].issn, "0033-2488");
  assert.equal(analysis.series[0].issues.length, 3);
});

test("analiza prasy izoluje rekord ze sprzecznym jawnym ISSN i EAN", () => {
  const collection = makePeriodicalCollection([
    { id: "ordinary", issn: "1050-124X", issueNumber: "1" },
    {
      id: "conflict",
      issn: "1050-124X",
      ean: "9770033248007",
      issueNumber: "2",
    },
  ]);

  const analysis = analyzePeriodicals(collection);
  assert.equal(analysis.series.length, 2);
  const isolated = analysis.series.find((series) => series.identification === "conflict");
  assert.deepEqual(isolated.issues.map((issue) => issue.publicationId), ["conflict"]);
  assert.deepEqual(isolated.warnings.map((warning) => warning.kind), ["identifierConflict"]);
});

test("fallback metadanych wymaga zgodnego tytułu, wydawcy i języka", () => {
  const collection = makePeriodicalCollection([
    {
      id: "metadata-a",
      title: " Życie   Nauki! ",
      publisher: "Prószyński & S-ka",
      language: "PL",
      issueNumber: "1",
    },
    {
      id: "metadata-b",
      title: "zycie nauki",
      publisher: "proszynski s ka",
      language: "pl",
      issueNumber: "2",
    },
    {
      id: "without-publisher",
      title: "Życie Nauki",
      publisher: "",
      language: "pl",
      issueNumber: "3",
    },
  ]);

  const analysis = analyzePeriodicals(collection);
  assert.equal(analysis.series.length, 2);
  assert.equal(analysis.series.find((series) => series.identification === "metadata").issues.length, 2);
  assert.equal(analysis.series.find((series) => series.identification === "isolated").issues.length, 1);
});

test("analiza prasy parsuje cztery obsługiwane zapisy numeru", () => {
  const collection = makePeriodicalCollection([
    { id: "plain", issueNumber: "8", publicationYear: 2025 },
    { id: "number-year", issueNumber: "8/2026" },
    { id: "year-number", issueNumber: "2027/8" },
    { id: "combined", issueNumber: "1–2/2028" },
  ]);
  const issues = new Map(
    analyzePeriodicals(collection).series.flatMap((series) => series.issues)
      .map((issue) => [issue.publicationId, issue]),
  );

  assert.equal(issues.get("plain").canonicalIssueNumber, "8");
  assert.deepEqual(issues.get("plain").cycle, { kind: "year", value: 2025, label: "2025" });
  assert.equal(issues.get("number-year").canonicalIssueNumber, "8/2026");
  assert.equal(issues.get("year-number").canonicalIssueNumber, "8/2027");
  assert.deepEqual(issues.get("combined").range, { first: 1, last: 2 });
});

test("braki obejmują wyłącznie wewnętrzną lukę i uwzględniają numer łączony", () => {
  const collection = makePeriodicalCollection([
    { id: "one-two", issueNumber: "1-2/2026" },
    { id: "four", issueNumber: "4/2026" },
  ]);
  const series = analyzePeriodicals(collection).series[0];

  assert.deepEqual(series.missingIssues.map((missing) => missing.number), [3]);
  assert.equal(series.missingIssues[0].cycle.label, "2026");
});

test("analiza nie wylicza luk dla zakresu ponad 200 i ogranicza listę do 50", () => {
  const excessive = analyzePeriodicals(makePeriodicalCollection([
    { id: "first", issueNumber: "1" },
    { id: "far", issueNumber: "201" },
  ])).series[0];
  assert.equal(excessive.missingIssues.length, 0);
  assert.deepEqual(excessive.warnings.map((warning) => warning.kind), ["missingRangeLimitExceeded"]);

  const capped = analyzePeriodicals(makePeriodicalCollection([
    { id: "first", issueNumber: "1" },
    { id: "last", issueNumber: "60" },
  ])).series[0];
  assert.equal(capped.missingIssues.length, 50);
  assert.equal(capped.missingIssues.at(-1).number, 51);
  assert.deepEqual(capped.warnings.map((warning) => warning.kind), ["missingListTruncated"]);
});

test("wiele kopii i powtórzone rekordy publikacji są raportowane osobno", () => {
  const publications = [
    { id: "record-a", issueNumber: "8/2026", issueDate: "2026-08" },
    { id: "record-b", issueNumber: "2026/8", issueDate: "2026-08-15" },
  ];
  const copies = [
    { ...canonical.ownedItems[0], id: "copy-a-1", publicationId: "record-a" },
    { ...canonical.ownedItems[1], id: "copy-a-2", publicationId: "record-a" },
    { ...canonical.ownedItems[0], id: "copy-b", publicationId: "record-b", status: "missing" },
  ];
  const series = analyzePeriodicals(makePeriodicalCollection(publications, copies)).series[0];

  assert.equal(series.multipleCopyGroups.length, 1);
  assert.deepEqual(series.multipleCopyGroups[0].itemIds, ["copy-a-1", "copy-a-2"]);
  assert.equal(series.duplicatePublicationGroups.length, 1);
  assert.deepEqual(series.duplicatePublicationGroups[0].publicationIds, ["record-a", "record-b"]);
});

test("analiza duplikatów respektuje różne jawne EAN i dodatki, ale pozwala na brak dodatku", () => {
  const common = {
    title: "Miesięcznik testowy",
    issn: "0033-2488",
    issueNumber: "8/2026",
    issueDate: "2026-08",
  };
  const differentSupplements = makePeriodicalCollection([
    {
      ...common,
      id: "supplement-05",
      ean: "9770033248007",
      barcode: "9770033248007+05",
    },
    {
      ...common,
      id: "supplement-06",
      ean: "9770033248007",
      barcode: "9770033248007+06",
    },
  ]);
  assert.equal(
    analyzePeriodicals(differentSupplements).series[0].duplicatePublicationGroups.length,
    0,
  );

  const differentMainEANs = makePeriodicalCollection([
    {
      ...common,
      id: "main-00",
      ean: "9770033248007",
      barcode: "9770033248007+05",
    },
    {
      ...common,
      id: "main-01",
      ean: "9770033248014",
      barcode: "9770033248014+05",
    },
  ]);
  assert.equal(
    analyzePeriodicals(differentMainEANs).series[0].duplicatePublicationGroups.length,
    0,
  );

  const missingSupplement = makePeriodicalCollection([
    {
      ...common,
      id: "without-supplement",
      ean: "9770033248007",
      barcode: "9770033248007",
    },
    {
      ...common,
      id: "with-supplement",
      ean: "9770033248007",
      barcode: "9770033248007+05",
    },
  ]);
  const duplicateGroups = analyzePeriodicals(missingSupplement).series[0]
    .duplicatePublicationGroups;
  assert.equal(duplicateGroups.length, 1);
  assert.deepEqual(
    duplicateGroups[0].publicationIds,
    ["with-supplement", "without-supplement"],
  );

  const reversed = structuredClone(missingSupplement);
  reversed.publications.reverse();
  reversed.ownedItems.reverse();
  assert.deepEqual(analyzePeriodicals(missingSupplement), analyzePeriodicals(reversed));
});

test("analiza prasy wyklucza archiwalne kopie, ale zachowuje wypożyczone i brakujące", () => {
  const publications = [
    { id: "archived", issueNumber: "1/2026" },
    { id: "loaned", issueNumber: "2/2026" },
    { id: "missing", issueNumber: "4/2026" },
  ];
  const copies = [
    { ...canonical.ownedItems[0], id: "copy-archived", publicationId: "archived", status: "archived" },
    { ...canonical.ownedItems[0], id: "copy-loaned", publicationId: "loaned", status: "loaned" },
    { ...canonical.ownedItems[0], id: "copy-missing", publicationId: "missing", status: "missing" },
  ];
  const analysis = analyzePeriodicals(makePeriodicalCollection(publications, copies));

  assert.equal(analysis.excludedArchivedCopyCount, 1);
  assert.deepEqual(analysis.series[0].issues.flatMap((issue) => issue.copies.map((copy) => copy.status)), [
    "loaned",
    "missing",
  ]);
  assert.deepEqual(analysis.series[0].missingIssues.map((missingIssue) => missingIssue.number), [3]);
});

test("wynik analizy prasy jest deterministyczny dla odwróconej kolejności", () => {
  const input = makePeriodicalCollection([
    { id: "b", title: "B", issueNumber: "3/2026" },
    { id: "a", title: "A", issueNumber: "1/2026" },
    { id: "c", title: "B", issueNumber: "1/2026" },
  ]);
  const reversed = structuredClone(input);
  reversed.publications.reverse();
  reversed.ownedItems.reverse();

  assert.deepEqual(analyzePeriodicals(input), analyzePeriodicals(reversed));
});

test("analiza prasy nie modyfikuje kolekcji ani formatu eksportu", () => {
  const input = makePeriodicalCollection([
    { id: "press-read-only", issn: "0033-2488", issueNumber: "8/2026" },
  ]);
  const before = structuredClone(input);

  analyzePeriodicals(input);

  assert.deepEqual(input, before);
  const payload = exportPayload(input, input.exportedAt);
  assert.equal("periodicalSeries" in payload, false);
  assert.equal("analysis" in payload, false);
});

test("kanoniczny import odrzuca sprzeczne główne EAN i barcode prasy", () => {
  const input = structuredClone(canonical);
  input.publications[0] = {
    ...input.publications[0],
    type: "periodical",
    identifiers: {
      isbn13: null,
      issn: "0033248X",
      ean: "9771234567003",
      barcode: "9770033248007+05",
    },
  };

  assert.throws(
    () => normalizeCollection(input),
    /wskazują różne główne kody EAN-977/,
  );
});

test("kanoniczny import wymaga dokładnie 13 cyfr w polu EAN", () => {
  for (const ean of ["9770033248007+05", "977003324800705", "9770033248007+abc"]) {
    const input = structuredClone(canonical);
    input.publications[0] = {
      ...input.publications[0],
      type: "periodical",
      identifiers: { isbn13: null, issn: null, ean, barcode: null },
    };
    assert.throws(() => normalizeCollection(input), /musi zawierać dokładnie 13 cyfr/);
  }
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
  assert.equal(
    roundTripped.publications[0].metadata.coverUrl,
    "https://cdn.example.org/covers/fixture-001.jpg",
  );
  assert.equal(roundTripped.publications[0].metadata.coverSource, "fixture");
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

test("łączenie prasy rozpoznaje wyłącznie ten sam pełny EAN z dodatkiem", () => {
  function collectionWithSupplement({ publicationId, copyId, supplement, barcode = true }) {
    return {
      ...structuredClone(canonical),
      publications: [
        {
          ...canonical.publications[0],
          id: publicationId,
          type: "periodical",
          title: "Magazyn testowy",
          identifiers: {
            isbn13: null,
            issn: "12345679",
            ean: "9771234567003",
            barcode: barcode ? `9771234567003+${supplement}` : "9771234567003",
          },
          issue: null,
        },
      ],
      ownedItems: [
        {
          ...canonical.ownedItems[0],
          id: copyId,
          publicationId,
        },
      ],
    };
  }

  const first = collectionWithSupplement({
    publicationId: "press-a",
    copyId: "press-copy-a",
    supplement: "05",
  });
  const sameIssue = collectionWithSupplement({
    publicationId: "press-b",
    copyId: "press-copy-b",
    supplement: "05",
  });
  const sameMerged = mergeCollections(first, sameIssue);
  assert.equal(sameMerged.publications.length, 1);
  assert.equal(sameMerged.ownedItems.length, 2);

  const otherIssue = collectionWithSupplement({
    publicationId: "press-c",
    copyId: "press-copy-c",
    supplement: "06",
  });
  assert.equal(mergeCollections(first, otherIssue).publications.length, 2);

  const withoutSupplementA = collectionWithSupplement({
    publicationId: "press-d",
    copyId: "press-copy-d",
    supplement: "",
    barcode: false,
  });
  const withoutSupplementB = collectionWithSupplement({
    publicationId: "press-e",
    copyId: "press-copy-e",
    supplement: "",
    barcode: false,
  });
  assert.equal(mergeCollections(withoutSupplementA, withoutSupplementB).publications.length, 2);
});

test("prasa zachowuje fallback numeru przy brakującym dodatku, ale nie scala dwóch różnych dodatków", () => {
  function issueCollection(publicationId, copyId, barcode) {
    return {
      ...structuredClone(canonical),
      publications: [
        {
          ...canonical.publications[0],
          id: publicationId,
          type: "periodical",
          title: "Miesięcznik testowy",
          identifiers: {
            isbn13: null,
            issn: "00332488",
            ean: "9770033248007",
            barcode,
          },
          issue: { number: "8/2026", volume: null, date: "2026-08" },
        },
      ],
      ownedItems: [
        {
          ...canonical.ownedItems[0],
          id: copyId,
          publicationId,
        },
      ],
    };
  }

  const withoutAddon = issueCollection("press-no-addon", "copy-no-addon", "9770033248007");
  const addon05 = issueCollection("press-addon-05", "copy-addon-05", "9770033248007+05");
  const addon06 = issueCollection("press-addon-06", "copy-addon-06", "9770033248007+06");

  const fallbackMerged = mergeCollections(withoutAddon, addon05);
  assert.equal(fallbackMerged.publications.length, 1);
  assert.equal(fallbackMerged.ownedItems.length, 2);
  assert.equal(fallbackMerged.publications[0].identifiers.barcode, "9770033248007+05");

  const reverseFallbackMerged = mergeCollections(addon05, withoutAddon);
  assert.equal(reverseFallbackMerged.publications.length, 1);
  assert.equal(
    reverseFallbackMerged.publications[0].identifiers.barcode,
    "9770033248007+05",
  );

  const conflicting = mergeCollections(addon05, addon06);
  assert.equal(conflicting.publications.length, 2);
  assert.equal(conflicting.ownedItems.length, 2);
});

test("fallback prasy nie scala sprzecznych głównych EAN i nie tworzy niespójnego composite", () => {
  function issueCollection(publicationId, copyId, ean, barcode) {
    const result = structuredClone(canonical);
    result.publications = [
      {
        ...canonical.publications[0],
        id: publicationId,
        type: "periodical",
        title: "Miesięcznik testowy",
        identifiers: { isbn13: null, issn: "00332488", ean, barcode },
        issue: { number: "8/2026", volume: null, date: "2026-08" },
      },
    ];
    result.ownedItems = [
      { ...canonical.ownedItems[0], id: copyId, publicationId },
    ];
    return result;
  }

  const withComposite = issueCollection(
    "press-main-a",
    "copy-main-a",
    "9770033248007",
    "9770033248007+05",
  );
  const conflictingMain = issueCollection(
    "press-main-b",
    "copy-main-b",
    "9771234567003",
    "9771234567003",
  );

  const merged = mergeCollections(withComposite, conflictingMain);
  assert.equal(merged.publications.length, 2);
  assert.equal(merged.ownedItems.length, 2);
  for (const publication of merged.publications) {
    const composite = parseEANSupplementBarcode(publication.identifiers.barcode);
    if (composite) assert.equal(publication.identifiers.ean, composite.ean);
  }
});

test("exact match prasy nie scala różnych głównych EAN przy tym samym ISSN numerze i dodatku", () => {
  function issueCollection(publicationId, copyId, ean) {
    const result = structuredClone(canonical);
    result.publications = [
      {
        ...canonical.publications[0],
        id: publicationId,
        type: "periodical",
        title: "Miesięcznik testowy",
        identifiers: {
          isbn13: null,
          issn: "00332488",
          ean,
          barcode: `${ean}+05`,
        },
        issue: { number: "8/2026", volume: null, date: "2026-08" },
      },
    ];
    result.ownedItems = [
      { ...canonical.ownedItems[0], id: copyId, publicationId },
    ];
    return result;
  }

  const first = issueCollection("press-main-a", "copy-main-a", "9770033248007");
  const second = issueCollection("press-main-b", "copy-main-b", "9770033248014");
  const merged = mergeCollections(first, second);

  assert.equal(merged.publications.length, 2);
  assert.equal(merged.ownedItems.length, 2);
  assert.deepEqual(
    new Set(merged.publications.map((publication) => publication.identifiers.ean)),
    new Set(["9770033248007", "9770033248014"]),
  );
  assert.deepEqual(
    new Set(merged.ownedItems.map((item) => item.publicationId)),
    new Set(["press-main-a", "press-main-b"]),
  );
  for (const publication of merged.publications) {
    const composite = parseEANSupplementBarcode(publication.identifiers.barcode);
    assert.equal(composite?.ean, publication.identifiers.ean);
    assert.equal(composite?.supplement, "05");
  }
});

test("merge pełnego composite zachowuje bogatszy opis numeru w obu kierunkach", () => {
  function compositeCollection(publicationId, copyId, issue) {
    const result = structuredClone(canonical);
    result.publications = [
      {
        ...canonical.publications[0],
        id: publicationId,
        type: "periodical",
        title: "Miesięcznik testowy",
        identifiers: {
          isbn13: null,
          issn: "00332488",
          ean: "9770033248007",
          barcode: "9770033248007+05",
        },
        issue,
      },
    ];
    result.ownedItems = [
      { ...canonical.ownedItems[0], id: copyId, publicationId },
    ];
    return result;
  }

  const issue = { number: "8/2026", volume: "XLII", date: "2026-08" };
  const withoutIssue = compositeCollection("press-empty", "copy-empty", null);
  const withIssue = compositeCollection("press-rich", "copy-rich", issue);

  for (const [current, incoming, expectedPublicationId] of [
    [withoutIssue, withIssue, "press-empty"],
    [withIssue, withoutIssue, "press-rich"],
  ]) {
    const merged = mergeCollections(current, incoming);
    assert.equal(merged.publications.length, 1);
    assert.equal(merged.ownedItems.length, 2);
    assert.equal(merged.publications[0].id, expectedPublicationId);
    assert.deepEqual(merged.publications[0].issue, issue);
    assert.equal(merged.publications[0].identifiers.ean, "9770033248007");
    assert.equal(merged.publications[0].identifiers.barcode, "9770033248007+05");
    assert.deepEqual(
      new Set(merged.ownedItems.map((item) => item.publicationId)),
      new Set([expectedPublicationId]),
    );
    assert.doesNotThrow(() =>
      normalizeCollection(exportPayload(merged, "2026-08-12T01:00:00Z")),
    );
  }
});

test("merge composite nie wybiera arbitralnie spośród istniejących duplikatów", () => {
  const current = structuredClone(canonical);
  current.publications = ["current-a", "current-b"].map((id) => ({
    ...canonical.publications[0],
    id,
    type: "periodical",
    title: "Miesięcznik testowy",
    identifiers: {
      isbn13: null,
      issn: "00332488",
      ean: "9770033248007",
      barcode: "9770033248007+05",
    },
    issue: null,
  }));
  current.ownedItems = current.publications.map((publication, index) => ({
    ...canonical.ownedItems[0],
    id: `current-copy-${index + 1}`,
    publicationId: publication.id,
  }));

  const incoming = structuredClone(canonical);
  incoming.publications = [
    {
      ...canonical.publications[0],
      id: "incoming-rich",
      type: "periodical",
      title: "Miesięcznik testowy",
      identifiers: {
        isbn13: null,
        issn: "00332488",
        ean: "9770033248007",
        barcode: "9770033248007+05",
      },
      issue: { number: "8/2026", volume: null, date: "2026-08" },
    },
  ];
  incoming.ownedItems = [
    { ...canonical.ownedItems[0], id: "incoming-copy", publicationId: "incoming-rich" },
  ];

  const merged = mergeCollections(current, incoming);
  const publicationIds = new Set(merged.publications.map((publication) => publication.id));
  assert.equal(merged.publications.length, 3);
  assert.equal(merged.ownedItems.length, 3);
  assert.equal(
    merged.ownedItems.every((item) => publicationIds.has(item.publicationId)),
    true,
  );
});

test("merge zachowuje istniejące zdublowane rekordy prasy i wszystkie referencje egzemplarzy", () => {
  const current = structuredClone(canonical);
  current.publications = ["press-duplicate-a", "press-duplicate-b"].map((id) => ({
    ...canonical.publications[0],
    id,
    type: "periodical",
    title: "Duplikat historyczny",
    identifiers: {
      isbn13: null,
      issn: "00332488",
      ean: "9770033248007",
      barcode: "9770033248007+05",
    },
    issue: null,
  }));
  current.ownedItems = current.publications.map((publication, index) => ({
    ...canonical.ownedItems[0],
    id: `press-duplicate-copy-${index + 1}`,
    publicationId: publication.id,
  }));

  const incoming = structuredClone(canonical);
  incoming.publications[0].id = "incoming-book";
  incoming.ownedItems = [
    {
      ...incoming.ownedItems[0],
      id: "incoming-book-copy",
      publicationId: "incoming-book",
    },
  ];

  const merged = mergeCollections(current, incoming);
  const publicationIds = new Set(merged.publications.map((publication) => publication.id));
  assert.equal(merged.publications.length, 3);
  assert.equal(merged.ownedItems.length, 3);
  assert.equal(publicationIds.has("press-duplicate-a"), true);
  assert.equal(publicationIds.has("press-duplicate-b"), true);
  assert.equal(
    merged.ownedItems.every((item) => publicationIds.has(item.publicationId)),
    true,
  );
  assert.doesNotThrow(() => normalizeCollection(exportPayload(merged, "2026-08-12T01:00:00Z")));
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
