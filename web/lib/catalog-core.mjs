export const SCHEMA_VERSION = 1;

export const ITEM_TYPES = Object.freeze({
  book: "Książka",
  periodical: "Prasa",
});

const ALLOWED_TYPES = new Set(Object.keys(ITEM_TYPES));
const ALLOWED_STATUSES = new Set(["owned", "loaned", "missing", "archived"]);
const ALLOWED_LOCATION_TYPES = new Set(["home", "room", "bookcase", "shelf", "box", "other"]);

function asString(value, fallback = "") {
  if (value === null || value === undefined) return fallback;
  return String(value).trim();
}

function asOptionalNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function asStringArray(value) {
  if (Array.isArray(value)) return value.map((entry) => asString(entry)).filter(Boolean);
  const single = asString(value);
  return single ? [single] : [];
}

function stableId(prefix, seed) {
  const input = asString(seed, `${prefix}-${Date.now()}`);
  let hash = 2166136261;
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `${prefix}-${(hash >>> 0).toString(36)}`;
}

function normalizedType(value) {
  const type = asString(value, "book").toLowerCase();
  if (ALLOWED_TYPES.has(type)) return type;
  if (["press", "magazine", "newspaper", "journal"].includes(type)) return "periodical";
  return "book";
}

function normalizeIdentifiers(raw, legacyEdition = {}) {
  const identifiers = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const fromArray = Array.isArray(raw)
    ? Object.fromEntries(
        raw
          .map((entry) => [asString(entry?.scheme || entry?.type).toLowerCase(), entry?.value])
          .filter(([scheme, value]) => scheme && value),
      )
    : {};

  const clean = (value) => asString(value).replace(/[\s-]/g, "") || null;
  return {
    ...(identifiers || {}),
    isbn13: clean(identifiers.isbn13 || fromArray.isbn13 || legacyEdition.isbn13),
    isbn10: clean(identifiers.isbn10 || fromArray.isbn10 || legacyEdition.isbn10),
    issn: clean(identifiers.issn || fromArray.issn || legacyEdition.issn),
    ean: clean(identifiers.ean || fromArray.ean || legacyEdition.ean),
    barcode: clean(identifiers.barcode || fromArray.barcode || legacyEdition.barcode),
  };
}

function normalizeMetadata(raw = {}) {
  return {
    ...raw,
    description: asString(raw.description) || null,
    subjects: asStringArray(raw.subjects),
    pageCount: asOptionalNumber(raw.pageCount),
    source: asString(raw.source) || null,
    sourceUrl: asString(raw.sourceUrl) || null,
    coverUrl: asString(raw.coverUrl || raw.cover?.url) || null,
    coverColor: asString(raw.coverColor || raw.cover?.color, "#355f55"),
  };
}

function normalizePublication(raw, index) {
  const normalizedAt = new Date().toISOString();
  const work = raw?.work && typeof raw.work === "object" ? raw.work : {};
  const edition = raw?.edition && typeof raw.edition === "object" ? raw.edition : {};
  const metadata = normalizeMetadata({
    ...(raw || {}),
    ...(raw?.metadata || {}),
    cover: raw?.cover || raw?.metadata?.cover,
  });
  const title = asString(raw?.title || work.title, "Bez tytułu");
  const identifiers = normalizeIdentifiers(raw?.identifiers, {
    isbn13: raw?.isbn13 || raw?.isbn || edition.isbn13,
    isbn10: raw?.isbn10 || edition.isbn10,
    issn: raw?.issn || edition.issn,
    ean: raw?.ean || edition.ean,
    barcode: raw?.barcode || edition.barcode,
  });
  const identifierSeed = Object.entries(identifiers)
    .filter(([, value]) => value)
    .map(([scheme, value]) => `${scheme}:${value}`)
    .join("|");

  return {
    id: asString(raw?.publicationId || raw?.id, stableId("pub", identifierSeed || `${title}-${index}`)),
    type: normalizedType(raw?.type || raw?.kind),
    title,
    subtitle: asString(raw?.subtitle || work.subtitle) || null,
    authors: asStringArray(raw?.authors?.length ? raw.authors : work.authors || raw?.author),
    language: asString(raw?.language || work.language) || null,
    publisher: asString(raw?.publisher || edition.publisher) || null,
    publicationYear: asOptionalNumber(raw?.publicationYear ?? raw?.year ?? edition.publicationYear),
    identifiers,
    issue:
      raw?.issue && typeof raw.issue === "object"
        ? {
            volume: asString(raw.issue.volume) || null,
            number: asString(raw.issue.number) || null,
            date: asString(raw.issue.date) || null,
          }
        : null,
    metadata,
    createdAt: asString(raw?.createdAt) || normalizedAt,
    updatedAt: asString(raw?.updatedAt || raw?.createdAt) || normalizedAt,
  };
}

function normalizeOwnedItem(raw, index, fallbackPublicationId = null) {
  const normalizedAt = new Date().toISOString();
  const copy = raw?.copy && typeof raw.copy === "object" ? raw.copy : {};
  const publicationId = asString(raw?.publicationId || fallbackPublicationId);
  return {
    id: asString(raw?.ownedItemId || raw?.copyId || raw?.id, stableId("copy", `${publicationId}-${index}`)),
    publicationId,
    locationId: asString(raw?.locationId || raw?.location_id || copy.locationId) || null,
    locationPath: asStringArray(raw?.locationPath || copy.locationPath),
    status: ALLOWED_STATUSES.has(asString(raw?.status || copy.status))
      ? asString(raw?.status || copy.status)
      : "owned",
    notes: asString(raw?.notes || copy.notes) || null,
    addedAt: asString(raw?.addedAt || copy.addedAt) || normalizedAt,
    updatedAt:
      asString(raw?.updatedAt || copy.updatedAt || raw?.addedAt || copy.addedAt) || normalizedAt,
  };
}

function normalizeLocation(raw, index) {
  const name = asString(raw?.name || raw?.label, `Lokalizacja ${index + 1}`);
  const rawType = asString(raw?.type, "other");
  const type = rawType === "furniture" ? "bookcase" : rawType;
  return {
    id: asString(raw?.id, stableId("loc", `${name}-${index}`)),
    name,
    type: ALLOWED_LOCATION_TYPES.has(type) ? type : "other",
    parentId: asString(raw?.parentId || raw?.parent_id) || null,
  };
}

function normalizeLegacyItems(rawItems) {
  const publicationsByKey = new Map();
  const ownedItems = [];

  rawItems.forEach((raw, index) => {
    const publication = normalizePublication(raw, index);
    const key = publicationIdentity(publication);
    const existing = publicationsByKey.get(key);
    const publicationId = existing?.id || publication.id;
    if (!existing) publicationsByKey.set(key, publication);
    ownedItems.push(normalizeOwnedItem(raw, index, publicationId));
  });

  return { publications: [...publicationsByKey.values()], ownedItems };
}

export function normalizeCollection(input) {
  if (!input || typeof input !== "object") {
    throw new TypeError("Plik kolekcji musi zawierać obiekt JSON.");
  }

  if (!Array.isArray(input) && input.schemaVersion !== undefined && input.schemaVersion !== SCHEMA_VERSION) {
    throw new TypeError(`Nieobsługiwana wersja formatu: ${input.schemaVersion}. Oczekiwana: 1.`);
  }

  const rawLocations = Array.isArray(input.locations) ? input.locations : [];
  const locations = rawLocations.map(normalizeLocation);
  let publications;
  let ownedItems;

  if (Array.isArray(input.publications) && Array.isArray(input.ownedItems)) {
    publications = input.publications.map(normalizePublication);
    ownedItems = input.ownedItems.map((item, index) => normalizeOwnedItem(item, index));
  } else if (Array.isArray(input.items) || Array.isArray(input)) {
    ({ publications, ownedItems } = normalizeLegacyItems(Array.isArray(input) ? input : input.items));
  } else {
    throw new TypeError("Plik nie zawiera tablic „publications” i „ownedItems”.");
  }

  const publicationIds = new Set(publications.map((publication) => publication.id));
  const orphan = ownedItems.find((item) => !publicationIds.has(item.publicationId));
  if (orphan) {
    throw new TypeError(`Egzemplarz „${orphan.id}” wskazuje nieistniejącą publikację.`);
  }

  const validLocationIds = new Set(locations.map((location) => location.id));
  for (const item of ownedItems) {
    if (item.locationId && !validLocationIds.has(item.locationId) && !item.locationPath.length) {
      item.locationId = null;
    }
  }

  const collection = input.collection && typeof input.collection === "object" ? input.collection : {};
  const name = asString(collection.name || input.name, "Moja kolekcja");
  return {
    schemaVersion: SCHEMA_VERSION,
    exportedAt: asString(input.exportedAt) || new Date().toISOString(),
    collection: {
      id: asString(collection.id || input.collectionId, stableId("collection", name)),
      name,
    },
    locations,
    publications,
    ownedItems,
  };
}

export function normalizeForSearch(value) {
  return asString(value)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLocaleLowerCase("pl-PL")
    .replace(/ł/g, "l")
    .replace(/ß/g, "ss")
    .replace(/æ/g, "ae")
    .replace(/œ/g, "oe")
    .replace(/[đð]/g, "d")
    .replace(/þ/g, "th");
}

export function locationPath(locationId, locations, fallbackPath = []) {
  if (!locationId) return fallbackPath.length ? fallbackPath.join(" / ") : "Bez lokalizacji";
  const byId = new Map(locations.map((location) => [location.id, location]));
  const parts = [];
  const visited = new Set();
  let current = byId.get(locationId);
  while (current && !visited.has(current.id)) {
    visited.add(current.id);
    parts.unshift(current.name);
    current = current.parentId ? byId.get(current.parentId) : null;
  }
  return parts.length ? parts.join(" / ") : fallbackPath.join(" / ") || "Bez lokalizacji";
}

export function catalogEntries(collectionInput) {
  const collection = normalizeCollection(collectionInput);
  const publicationsById = new Map(
    collection.publications.map((publication) => [publication.id, publication]),
  );
  return collection.ownedItems.map((ownedItem) => ({
    id: ownedItem.id,
    publication: publicationsById.get(ownedItem.publicationId),
    ownedItem,
    locationLabel: locationPath(ownedItem.locationId, collection.locations, ownedItem.locationPath),
  }));
}

function descendantLocationIds(locationId, locations) {
  if (!locationId) return new Set();
  const result = new Set([locationId]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const location of locations) {
      if (location.parentId && result.has(location.parentId) && !result.has(location.id)) {
        result.add(location.id);
        changed = true;
      }
    }
  }
  return result;
}

function entrySearchText(entry) {
  const { publication, ownedItem, locationLabel } = entry;
  const issue = publication.issue
    ? [publication.issue.volume, publication.issue.number, publication.issue.date].filter(Boolean)
    : [];
  return normalizeForSearch(
    [
      publication.title,
      publication.subtitle,
      ...publication.authors,
      publication.publisher,
      publication.publicationYear,
      ...Object.entries(publication.identifiers).flatMap(([scheme, value]) =>
        value ? [scheme, value] : [],
      ),
      ...issue,
      ...publication.metadata.subjects,
      ownedItem.notes,
      locationLabel,
    ]
      .filter(Boolean)
      .join(" "),
  );
}

export function filterEntries(entries, options = {}, locations = []) {
  const queryTerms = normalizeForSearch(options.query).split(/\s+/).filter(Boolean);
  const type = asString(options.type, "all");
  const locationId = asString(options.locationId, "all");
  const allowedLocations = locationId === "all" ? null : descendantLocationIds(locationId, locations);

  return entries.filter((entry) => {
    const typeMatch =
      type === "all" ||
      entry.publication.type === type ||
      (type === "press" && entry.publication.type === "periodical");
    const locationMatch =
      !allowedLocations ||
      (entry.ownedItem.locationId && allowedLocations.has(entry.ownedItem.locationId));
    if (!typeMatch || !locationMatch) return false;
    if (!queryTerms.length) return true;
    const haystack = entrySearchText(entry);
    return queryTerms.every((term) => haystack.includes(term));
  });
}

export function sortEntries(entries, sort = "titleAsc") {
  const collator = new Intl.Collator("pl", { sensitivity: "base", numeric: true });
  return [...entries].sort((left, right) => {
    if (sort === "addedDesc") {
      return asString(right.ownedItem.addedAt).localeCompare(asString(left.ownedItem.addedAt));
    }
    if (sort === "yearDesc") {
      return (right.publication.publicationYear || 0) - (left.publication.publicationYear || 0);
    }
    if (sort === "locationAsc") return collator.compare(left.locationLabel, right.locationLabel);
    return collator.compare(left.publication.title, right.publication.title);
  });
}

function publicationIdentity(publication) {
  const preferred = ["isbn13", "isbn10", "issn", "ean", "barcode"].find(
    (key) => publication.identifiers[key],
  );
  const issueKey = publication.issue
    ? `:${publication.issue.volume || ""}:${publication.issue.number || ""}:${publication.issue.date || ""}`
    : "";
  if (preferred) return `${preferred}:${publication.identifiers[preferred]}${issueKey}`;
  return `id:${publication.id}`;
}

export function mergeCollections(currentInput, incomingInput) {
  const current = normalizeCollection(currentInput);
  const incoming = normalizeCollection(incomingInput);
  const locationMap = new Map(current.locations.map((location) => [location.id, location]));
  incoming.locations.forEach((location) => locationMap.set(location.id, location));

  const publicationsByIdentity = new Map();
  const incomingIdMap = new Map();
  current.publications.forEach((publication) =>
    publicationsByIdentity.set(publicationIdentity(publication), publication),
  );
  incoming.publications.forEach((publication) => {
    const key = publicationIdentity(publication);
    const existing = publicationsByIdentity.get(key);
    const canonicalId = existing?.id || publication.id;
    incomingIdMap.set(publication.id, canonicalId);
    publicationsByIdentity.set(key, { ...publication, id: canonicalId });
  });

  const ownedItemMap = new Map(current.ownedItems.map((item) => [item.id, item]));
  incoming.ownedItems.forEach((item) =>
    ownedItemMap.set(item.id, {
      ...item,
      publicationId: incomingIdMap.get(item.publicationId) || item.publicationId,
    }),
  );

  return {
    schemaVersion: SCHEMA_VERSION,
    exportedAt: new Date().toISOString(),
    collection: incoming.collection,
    locations: [...locationMap.values()],
    publications: [...publicationsByIdentity.values()],
    ownedItems: [...ownedItemMap.values()],
  };
}

export function collectionStats(collectionInput) {
  const collection = normalizeCollection(collectionInput);
  const publicationById = new Map(collection.publications.map((item) => [item.id, item]));
  const books = collection.ownedItems.filter(
    (item) => publicationById.get(item.publicationId)?.type === "book",
  ).length;
  const press = collection.ownedItems.filter((item) =>
    publicationById.get(item.publicationId)?.type === "periodical",
  ).length;
  const located = collection.ownedItems.filter(
    (item) => item.locationId || item.locationPath.length,
  ).length;
  return {
    total: collection.ownedItems.length,
    publications: collection.publications.length,
    books,
    press,
    located,
    unlocated: collection.ownedItems.length - located,
  };
}

export function exportPayload(collectionInput, exportedAt = new Date().toISOString()) {
  const collection = normalizeCollection(collectionInput);
  return { ...collection, schemaVersion: SCHEMA_VERSION, exportedAt };
}
