export const SCHEMA_VERSION = 1;

export const ITEM_TYPES = Object.freeze({
  book: "Książka",
  periodical: "Prasa",
});

const ALLOWED_TYPES = new Set(Object.keys(ITEM_TYPES));
const ALLOWED_STATUSES = new Set(["owned", "loaned", "missing", "archived"]);
const ALLOWED_LOCATION_TYPES = new Set(["home", "room", "bookcase", "shelf", "box", "other"]);
const ISO_8601_DATE_TIME =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$/;

function asString(value, fallback = "") {
  if (value === null || value === undefined) return fallback;
  return String(value).trim();
}

function asOptionalNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizedPublicationYear(value, field, strict) {
  if (value === null || value === undefined || value === "") return null;
  const candidate =
    typeof value === "number"
      ? value
      : typeof value === "string" && /^\d{1,4}$/.test(value.trim())
        ? Number(value.trim())
        : Number.NaN;
  if (Number.isInteger(candidate) && candidate >= 1 && candidate <= 9999) return candidate;
  if (!strict) return null;
  throw new TypeError(`Pole „${field}” musi być liczbą całkowitą od 1 do 9999.`);
}

function isLeapYear(year) {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function canonicalISODate(value) {
  const text = asString(value);
  const match = ISO_8601_DATE_TIME.exec(text);
  if (!match) return null;

  const [, rawYear, rawMonth, rawDay, rawHour, rawMinute, rawSecond, , zone, , rawZoneHour, rawZoneMinute] =
    match;
  const year = Number(rawYear);
  const month = Number(rawMonth);
  const day = Number(rawDay);
  const hour = Number(rawHour);
  const minute = Number(rawMinute);
  const second = Number(rawSecond);
  const zoneHour = zone === "Z" ? 0 : Number(rawZoneHour);
  const zoneMinute = zone === "Z" ? 0 : Number(rawZoneMinute);
  const daysInMonth = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

  if (
    year < 1 ||
    year > 9999 ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInMonth[month - 1] ||
    hour > 23 ||
    minute > 59 ||
    second > 59 ||
    zoneHour > 23 ||
    zoneMinute > 59
  ) {
    return null;
  }

  const timestamp = Date.parse(text);
  if (!Number.isFinite(timestamp)) return null;
  const canonical = new Date(timestamp).toISOString();
  return ISO_8601_DATE_TIME.test(canonical) ? canonical : null;
}

function normalizedISODate(value, field, strict, fallback) {
  const normalized = canonicalISODate(value);
  if (normalized) return normalized;
  if (!strict) return fallback;
  throw new TypeError(`Pole „${field}” musi zawierać prawidłową datę ISO 8601.`);
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
  const rawBarcode = asString(
    identifiers.barcode || fromArray.barcode || legacyEdition.barcode,
  );
  return {
    ...(identifiers || {}),
    isbn13: clean(identifiers.isbn13 || fromArray.isbn13 || legacyEdition.isbn13),
    isbn10: clean(identifiers.isbn10 || fromArray.isbn10 || legacyEdition.isbn10),
    issn: clean(identifiers.issn || fromArray.issn || legacyEdition.issn),
    ean: clean(identifiers.ean || fromArray.ean || legacyEdition.ean),
    barcode: rawBarcode || null,
  };
}

function normalizedCoverUrl(value) {
  const raw = asString(value);
  if (!raw) return null;
  try {
    if (new TextEncoder().encode(raw).length > 2048) throw new TypeError("too long");
    if (!/^[!-~]+$/.test(raw)) throw new TypeError("non-ASCII URL");
    const url = new URL(raw);
    if (url.protocol !== "https:" || !url.hostname || url.username || url.password) {
      throw new TypeError("unsafe URL");
    }
    const normalized = url.href;
    if (new TextEncoder().encode(normalized).length > 2048) throw new TypeError("too long");
    if (!/^[!-~]+$/.test(normalized)) throw new TypeError("non-ASCII URL");
    return normalized;
  } catch {
    return null;
  }
}

export function automaticCoverUrl(value) {
  const normalized = normalizedCoverUrl(value);
  if (!normalized) return null;
  const url = new URL(normalized);
  return url.hostname === "covers.openlibrary.org" &&
    (url.port === "" || url.port === "443")
    ? url.href
    : null;
}

function normalizeMetadata(raw = {}, { strict = true, field = "metadata" } = {}) {
  const coverUrl = normalizedCoverUrl(raw.coverUrl || raw.cover?.url);
  return {
    ...raw,
    description: asString(raw.description) || null,
    subjects: asStringArray(raw.subjects),
    pageCount: asOptionalNumber(raw.pageCount),
    source: asString(raw.source) || null,
    sourceUrl: asString(raw.sourceUrl) || null,
    coverUrl,
    coverSource: coverUrl ? asString(raw.coverSource || raw.cover?.source) || null : null,
    coverColor: asString(raw.coverColor || raw.cover?.color, "#355f55"),
  };
}

function normalizePublication(raw, index, { strict = true, fallbackAt = new Date().toISOString() } = {}) {
  const work = raw?.work && typeof raw.work === "object" ? raw.work : {};
  const edition = raw?.edition && typeof raw.edition === "object" ? raw.edition : {};
  const metadata = normalizeMetadata(
    {
      ...(raw || {}),
      ...(raw?.metadata || {}),
      cover: raw?.cover || raw?.metadata?.cover,
    },
    { strict, field: `publications[${index}].metadata` },
  );
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

  const createdAt = normalizedISODate(
    raw?.createdAt,
    `publications[${index}].createdAt`,
    strict,
    fallbackAt,
  );
  const updatedAt = normalizedISODate(
    strict ? raw?.updatedAt : raw?.updatedAt ?? raw?.createdAt,
    `publications[${index}].updatedAt`,
    strict,
    createdAt,
  );

  return {
    id: asString(raw?.publicationId || raw?.id, stableId("pub", identifierSeed || `${title}-${index}`)),
    type: normalizedType(raw?.type || raw?.kind),
    title,
    subtitle: asString(raw?.subtitle || work.subtitle) || null,
    authors: asStringArray(raw?.authors?.length ? raw.authors : work.authors || raw?.author),
    language: asString(raw?.language || work.language) || null,
    publisher: asString(raw?.publisher || edition.publisher) || null,
    publicationYear: normalizedPublicationYear(
      raw?.publicationYear ?? raw?.year ?? edition.publicationYear,
      `publications[${index}].publicationYear`,
      strict,
    ),
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
    createdAt,
    updatedAt,
  };
}

function normalizeOwnedItem(
  raw,
  index,
  fallbackPublicationId = null,
  { strict = true, fallbackAt = new Date().toISOString() } = {},
) {
  const copy = raw?.copy && typeof raw.copy === "object" ? raw.copy : {};
  const publicationId = asString(raw?.publicationId || fallbackPublicationId);
  const addedAt = normalizedISODate(
    raw?.addedAt ?? copy.addedAt,
    `ownedItems[${index}].addedAt`,
    strict,
    fallbackAt,
  );
  const updatedAt = normalizedISODate(
    strict ? raw?.updatedAt ?? copy.updatedAt : raw?.updatedAt ?? copy.updatedAt ?? raw?.addedAt ?? copy.addedAt,
    `ownedItems[${index}].updatedAt`,
    strict,
    addedAt,
  );
  return {
    id: asString(raw?.ownedItemId || raw?.copyId || raw?.id, stableId("copy", `${publicationId}-${index}`)),
    publicationId,
    locationId: asString(raw?.locationId || raw?.location_id || copy.locationId) || null,
    locationPath: asStringArray(raw?.locationPath || copy.locationPath),
    status: ALLOWED_STATUSES.has(asString(raw?.status || copy.status))
      ? asString(raw?.status || copy.status)
      : "owned",
    notes: asString(raw?.notes || copy.notes) || null,
    addedAt,
    updatedAt,
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

function normalizeLegacyItems(rawItems, fallbackAt) {
  const publicationsByKey = new Map();
  const ownedItems = [];

  rawItems.forEach((raw, index) => {
    const publication = normalizePublication(raw, index, { strict: false, fallbackAt });
    const key = publicationIdentity(publication);
    const existing = publicationsByKey.get(key);
    const publicationId = existing?.id || publication.id;
    if (!existing) publicationsByKey.set(key, publication);
    ownedItems.push(
      normalizeOwnedItem(raw, index, publicationId, { strict: false, fallbackAt }),
    );
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
  const fallbackAt = new Date().toISOString();
  let publications;
  let ownedItems;
  let strictCanonical = false;

  if (Array.isArray(input.publications) && Array.isArray(input.ownedItems)) {
    strictCanonical = true;
    publications = input.publications.map((publication, index) =>
      normalizePublication(publication, index, { strict: true, fallbackAt }),
    );
    ownedItems = input.ownedItems.map((item, index) =>
      normalizeOwnedItem(item, index, null, { strict: true, fallbackAt }),
    );
  } else if (Array.isArray(input.items) || Array.isArray(input)) {
    ({ publications, ownedItems } = normalizeLegacyItems(
      Array.isArray(input) ? input : input.items,
      fallbackAt,
    ));
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
    if (item.locationId && !validLocationIds.has(item.locationId)) {
      item.locationId = null;
    }
  }

  const collection = input.collection && typeof input.collection === "object" ? input.collection : {};
  const name = asString(collection.name || input.name, "Moja kolekcja");
  return {
    schemaVersion: SCHEMA_VERSION,
    exportedAt: normalizedISODate(input.exportedAt, "exportedAt", strictCanonical, fallbackAt),
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

function locationIdentity(parentId, name) {
  return JSON.stringify([parentId || null, asString(name).toLocaleLowerCase("pl-PL")]);
}

function mergeLocations(currentLocations, incomingLocations) {
  const locations = [];
  const locationById = new Map();
  const locationIdByIdentity = new Map();
  const currentIdMap = new Map();
  const incomingIdMap = new Map();

  function availableId(preferredId, identity) {
    const preferred = asString(preferredId);
    if (preferred && !locationById.has(preferred)) return preferred;
    const base = stableId("loc", identity);
    if (!locationById.has(base)) return base;
    let suffix = 2;
    while (locationById.has(`${base}-${suffix}`)) suffix += 1;
    return `${base}-${suffix}`;
  }

  function integrate(sourceLocations, idMap, fallbackMaps = []) {
    const sourceById = new Map(sourceLocations.map((location) => [location.id, location]));
    const resolving = new Set();

    function canonicalIdFor(location) {
      if (idMap.has(location.id)) return idMap.get(location.id);
      if (resolving.has(location.id)) return null;
      resolving.add(location.id);

      let parentId = null;
      if (location.parentId) {
        const sourceParent = sourceById.get(location.parentId);
        if (sourceParent) {
          parentId = canonicalIdFor(sourceParent);
        } else {
          for (const fallbackMap of fallbackMaps) {
            if (fallbackMap.has(location.parentId)) {
              parentId = fallbackMap.get(location.parentId);
              break;
            }
          }
          if (!parentId && locationById.has(location.parentId)) parentId = location.parentId;
        }
      }

      const identity = locationIdentity(parentId, location.name);
      let canonicalId = locationIdByIdentity.get(identity);
      if (!canonicalId) {
        canonicalId = availableId(location.id, identity);
        const mergedLocation = { ...location, id: canonicalId, parentId };
        locations.push(mergedLocation);
        locationById.set(canonicalId, mergedLocation);
        locationIdByIdentity.set(identity, canonicalId);
      }

      idMap.set(location.id, canonicalId);
      resolving.delete(location.id);
      return canonicalId;
    }

    sourceLocations.forEach(canonicalIdFor);
  }

  integrate(currentLocations, currentIdMap);
  integrate(incomingLocations, incomingIdMap, [currentIdMap]);
  return {
    locations,
    currentLocationIdMap: currentIdMap,
    incomingLocationIdMap: incomingIdMap,
  };
}

export function mergeCollections(currentInput, incomingInput) {
  const current = normalizeCollection(currentInput);
  const incoming = normalizeCollection(incomingInput);
  const { locations, currentLocationIdMap, incomingLocationIdMap } = mergeLocations(
    current.locations,
    incoming.locations,
  );

  const publicationsByIdentity = new Map();
  const incomingPublicationIdMap = new Map();
  current.publications.forEach((publication) =>
    publicationsByIdentity.set(publicationIdentity(publication), publication),
  );
  incoming.publications.forEach((publication) => {
    const key = publicationIdentity(publication);
    const existing = publicationsByIdentity.get(key);
    const canonicalId = existing?.id || publication.id;
    incomingPublicationIdMap.set(publication.id, canonicalId);
    publicationsByIdentity.set(key, { ...publication, id: canonicalId });
  });

  const ownedItemMap = new Map(
    current.ownedItems.map((item) => [
      item.id,
      {
        ...item,
        locationId: currentLocationIdMap.get(item.locationId) || item.locationId,
      },
    ]),
  );
  incoming.ownedItems.forEach((item) =>
    ownedItemMap.set(item.id, {
      ...item,
      publicationId: incomingPublicationIdMap.get(item.publicationId) || item.publicationId,
      locationId:
        incomingLocationIdMap.get(item.locationId) ||
        currentLocationIdMap.get(item.locationId) ||
        item.locationId,
    }),
  );

  return {
    schemaVersion: SCHEMA_VERSION,
    exportedAt: new Date().toISOString(),
    collection: current.collection,
    locations,
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
  return {
    ...collection,
    schemaVersion: SCHEMA_VERSION,
    exportedAt: normalizedISODate(exportedAt, "exportedAt", true),
  };
}
