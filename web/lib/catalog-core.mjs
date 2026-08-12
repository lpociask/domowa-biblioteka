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

function hasValidEAN13Checksum(value) {
  if (!/^\d{13}$/.test(value)) return false;
  const sum = [...value.slice(0, 12)].reduce(
    (total, digit, index) => total + Number(digit) * (index % 2 === 0 ? 1 : 3),
    0,
  );
  return (10 - (sum % 10)) % 10 === Number(value[12]);
}

export function parseEANSupplementBarcode(value) {
  const normalized = asString(value).replace(/\s/g, "");
  const match = /^(\d{13})\+(\d{2}|\d{5})$/.exec(normalized);
  if (!match || !match[1].startsWith("977") || !hasValidEAN13Checksum(match[1])) {
    return null;
  }
  return {
    ean: match[1],
    supplement: match[2],
    canonical: `${match[1]}+${match[2]}`,
  };
}

function normalizeIdentifiers(raw, legacyEdition = {}, { strict = false, field = "identifiers" } = {}) {
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
  const supplementalBarcode = parseEANSupplementBarcode(rawBarcode);
  const explicitEAN = clean(identifiers.ean || fromArray.ean || legacyEdition.ean);
  if (strict && explicitEAN && !/^\d{13}$/.test(explicitEAN)) {
    throw new TypeError(`Pole „${field}.ean” musi zawierać dokładnie 13 cyfr.`);
  }
  if (strict && explicitEAN && supplementalBarcode && explicitEAN !== supplementalBarcode.ean) {
    throw new TypeError(
      `Pola „${field}.ean” i „${field}.barcode” wskazują różne główne kody EAN-977.`,
    );
  }
  return {
    ...(identifiers || {}),
    isbn13: clean(identifiers.isbn13 || fromArray.isbn13 || legacyEdition.isbn13),
    isbn10: clean(identifiers.isbn10 || fromArray.isbn10 || legacyEdition.isbn10),
    issn: clean(identifiers.issn || fromArray.issn || legacyEdition.issn),
    ean:
      explicitEAN ||
      supplementalBarcode?.ean ||
      null,
    barcode: supplementalBarcode?.canonical || rawBarcode || null,
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
  const identifiers = normalizeIdentifiers(
    raw?.identifiers,
    {
      isbn13: raw?.isbn13 || raw?.isbn || edition.isbn13,
      isbn10: raw?.isbn10 || edition.isbn10,
      issn: raw?.issn || edition.issn,
      ean: raw?.ean || edition.ean,
      barcode: raw?.barcode || edition.barcode,
    },
    { strict, field: `publications[${index}].identifiers` },
  );
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

const PERIODICAL_MAXIMUM_MISSING_RANGE = 200;
const PERIODICAL_MAXIMUM_MISSING_ISSUES = 50;

function canonicalISSN(value) {
  const compact = asString(value).toUpperCase().replace(/[\s-]/g, "");
  if (!/^\d{7}[\dX]$/.test(compact)) return null;
  const sum = [...compact.slice(0, 7)].reduce(
    (total, digit, index) => total + Number(digit) * (8 - index),
    0,
  );
  const checkValue = (11 - (sum % 11)) % 11;
  const expected = compact[7] === "X" ? 10 : Number(compact[7]);
  if (checkValue !== expected) return null;
  return `${compact.slice(0, 4)}-${compact.slice(4)}`;
}

function issnFromEAN977(value) {
  const composite = parseEANSupplementBarcode(value);
  const ean = composite?.ean || asString(value).replace(/[\s-]/g, "");
  if (!/^977\d{10}$/.test(ean) || !hasValidEAN13Checksum(ean)) return null;
  const stem = ean.slice(3, 10);
  const sum = [...stem].reduce(
    (total, digit, index) => total + Number(digit) * (8 - index),
    0,
  );
  const checkValue = (11 - (sum % 11)) % 11;
  const check = checkValue === 10 ? "X" : String(checkValue);
  return canonicalISSN(`${stem}${check}`);
}

function normalizedPeriodicalMetadata(value) {
  return normalizeForSearch(value)
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function parsedPeriodicalIssueNumber(value) {
  const compact = asString(value)
    .replace(/[–—−]/g, "-")
    .replace(/\s/g, "");
  let match = /^(\d{1,4})-(\d{1,4})\/(\d{4})$/.exec(compact);
  if (match) {
    const first = Number(match[1]);
    const last = Number(match[2]);
    const year = Number(match[3]);
    if (first > 0 && last >= first && year >= 1800 && year <= 2199) {
      return { canonical: `${first}-${last}/${year}`, range: { first, last }, encodedYear: year };
    }
    return null;
  }

  match = /^(\d{1,4})\/(\d{4})$/.exec(compact);
  if (match) {
    const number = Number(match[1]);
    const year = Number(match[2]);
    if (number > 0 && year >= 1800 && year <= 2199) {
      return { canonical: `${number}/${year}`, range: { first: number, last: number }, encodedYear: year };
    }
    return null;
  }

  match = /^(\d{4})\/(\d{1,4})$/.exec(compact);
  if (match) {
    const year = Number(match[1]);
    const number = Number(match[2]);
    if (number > 0 && year >= 1800 && year <= 2199) {
      return { canonical: `${number}/${year}`, range: { first: number, last: number }, encodedYear: year };
    }
    return null;
  }

  if (/^\d{1,4}$/.test(compact) && Number(compact) > 0) {
    const number = Number(compact);
    return { canonical: String(number), range: { first: number, last: number }, encodedYear: null };
  }
  return null;
}

function periodicalCycle(publication, parsedIssue) {
  if (parsedIssue?.encodedYear) {
    return { kind: "year", value: parsedIssue.encodedYear, label: String(parsedIssue.encodedYear) };
  }
  const dateYear = /(?:^|\D)((?:18|19|20|21)\d{2})(?:\D|$)/.exec(
    asString(publication.issue?.date),
  );
  if (dateYear) {
    return { kind: "year", value: Number(dateYear[1]), label: dateYear[1] };
  }
  if (
    Number.isInteger(publication.publicationYear) &&
    publication.publicationYear >= 1800 &&
    publication.publicationYear <= 2199
  ) {
    return {
      kind: "year",
      value: publication.publicationYear,
      label: String(publication.publicationYear),
    };
  }
  const volume = normalizedPeriodicalMetadata(publication.issue?.volume);
  if (volume) {
    const numericVolume = /^\d+$/.test(volume) ? String(Number(volume)) : volume;
    return { kind: "volume", value: numericVolume, label: `Tom ${numericVolume}` };
  }
  return { kind: "continuous", value: "continuous", label: "Numeracja ciągła" };
}

function periodicalCycleId(cycle) {
  return `${cycle.kind}:${cycle.value}`;
}

function comparePeriodicalCycles(left, right) {
  const rank = { year: 0, volume: 1, continuous: 2 };
  if (rank[left.kind] !== rank[right.kind]) return rank[left.kind] - rank[right.kind];
  if (left.kind === "year") return Number(left.value) - Number(right.value);
  return String(left.value).localeCompare(String(right.value), "pl", {
    sensitivity: "base",
    numeric: true,
  });
}

function preferredPeriodicalValue(values) {
  const candidates = values.map(asString).filter(Boolean);
  if (!candidates.length) return "";
  const counts = new Map();
  for (const candidate of candidates) {
    const key = normalizedPeriodicalMetadata(candidate);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return [...candidates].sort((left, right) => {
    const leftKey = normalizedPeriodicalMetadata(left);
    const rightKey = normalizedPeriodicalMetadata(right);
    const countDifference = (counts.get(rightKey) || 0) - (counts.get(leftKey) || 0);
    if (countDifference) return countDifference;
    return left.localeCompare(right, "pl", { sensitivity: "base", numeric: true });
  })[0];
}

function parsedLooseDate(value) {
  const text = asString(value);
  let match = /((?:18|19|20|21)\d{2})[-./](0?[1-9]|1[0-2])[-./](0?[1-9]|[12]\d|3[01])/.exec(text);
  if (match) return { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) };
  match = /((?:18|19|20|21)\d{2})[-./](0?[1-9]|1[0-2])/.exec(text);
  if (match) return { year: Number(match[1]), month: Number(match[2]), day: null };
  match = /(?:^|\D)((?:18|19|20|21)\d{2})(?:\D|$)/.exec(text);
  return match ? { year: Number(match[1]), month: null, day: null } : null;
}

function periodicalDatesConflict(leftValue, rightValue) {
  const left = parsedLooseDate(leftValue);
  const right = parsedLooseDate(rightValue);
  if (left && right) {
    if (left.year !== right.year) return true;
    if (left.month && right.month && left.month !== right.month) return true;
    return Boolean(left.day && right.day && left.day !== right.day);
  }
  return normalizedPeriodicalMetadata(leftValue) !== normalizedPeriodicalMetadata(rightValue);
}

function partitionCompatiblePeriodicalIssues(issues, publicationForIssue) {
  const groups = [];
  const sortedIssues = [...issues].sort((left, right) =>
    left.publicationId.localeCompare(right.publicationId, "pl", { numeric: true }),
  );

  for (const issue of sortedIssues) {
    const publication = publicationForIssue.get(issue);
    const compatibleGroup = groups.find((group) =>
      group.every((candidate) =>
        periodicalSupplementsAreCompatible(
          publicationForIssue.get(candidate),
          publication,
        ),
      ),
    );
    if (compatibleGroup) compatibleGroup.push(issue);
    else groups.push([issue]);
  }

  return groups;
}

function periodicalIdentification(publication) {
  const explicitRaw = asString(publication.identifiers.issn);
  const explicit = canonicalISSN(explicitRaw);
  const derived = [
    issnFromEAN977(publication.identifiers.ean),
    issnFromEAN977(publication.identifiers.barcode),
  ]
    .filter(Boolean)
    .filter((value, index, values) => values.indexOf(value) === index)
    .sort();
  const warnings = [];

  if (explicitRaw && !explicit) {
    warnings.push({
      kind: "invalidExplicitISSN",
      message: `Jawny ISSN „${explicitRaw}” ma niepoprawny format lub cyfrę kontrolną.`,
      publicationIds: [publication.id],
    });
  }
  const conflict = explicit && derived.find((value) => value !== explicit);
  if (conflict || derived.length > 1) {
    warnings.push({
      kind: "identifierConflict",
      message: "Jawny ISSN i EAN-977 wskazują różne serie; rekord został odizolowany.",
      publicationIds: [publication.id],
    });
    return {
      id: `conflict:${publication.id}`,
      kind: "conflict",
      issn: explicit,
      warnings,
    };
  }
  if (explicit || derived[0]) {
    const issn = explicit || derived[0];
    return { id: `issn:${issn.replace("-", "")}`, kind: "issn", issn, warnings };
  }

  const title = normalizedPeriodicalMetadata(publication.title);
  const publisher = normalizedPeriodicalMetadata(publication.publisher);
  const language = normalizedPeriodicalMetadata(publication.language);
  if (title && publisher && language) {
    return {
      id: `metadata:${JSON.stringify([title, publisher, language])}`,
      kind: "metadata",
      issn: null,
      warnings,
    };
  }
  return {
    id: `publication:${publication.id}`,
    kind: "isolated",
    issn: null,
    warnings,
  };
}

/**
 * Builds a deterministic, read-only projection of periodical series. The
 * projection is never persisted and does not change the collection format.
 */
export function analyzePeriodicals(collectionInput) {
  const collection = normalizeCollection(collectionInput);
  const publicationsById = new Map(
    collection.publications.map((publication) => [publication.id, publication]),
  );
  const copiesByPublication = new Map();
  let excludedArchivedCopyCount = 0;
  let excludedNonPeriodicalItemCount = 0;

  for (const ownedItem of collection.ownedItems) {
    const publication = publicationsById.get(ownedItem.publicationId);
    if (publication?.type !== "periodical") {
      excludedNonPeriodicalItemCount += 1;
      continue;
    }
    if (ownedItem.status === "archived") {
      excludedArchivedCopyCount += 1;
      continue;
    }
    const copy = {
      id: ownedItem.id,
      status: ownedItem.status,
      location: locationPath(ownedItem.locationId, collection.locations, ownedItem.locationPath),
    };
    if (!copiesByPublication.has(publication.id)) copiesByPublication.set(publication.id, []);
    copiesByPublication.get(publication.id).push(copy);
  }

  const grouped = new Map();
  for (const publication of [...collection.publications].sort((left, right) =>
    left.id.localeCompare(right.id, "pl", { numeric: true }),
  )) {
    const copies = copiesByPublication.get(publication.id);
    if (!copies?.length || publication.type !== "periodical") continue;
    copies.sort((left, right) => left.id.localeCompare(right.id, "pl", { numeric: true }));
    const identification = periodicalIdentification(publication);
    if (!grouped.has(identification.id)) {
      grouped.set(identification.id, { identification, publications: [] });
    }
    grouped.get(identification.id).publications.push({ publication, copies, identification });
  }

  const series = [...grouped.entries()].map(([seriesId, group]) => {
    const publicationForIssue = new Map();
    const issues = group.publications.map(({ publication, copies }) => {
      const parsed = parsedPeriodicalIssueNumber(publication.issue?.number);
      const cycle = parsed ? periodicalCycle(publication, parsed) : null;
      const issue = {
        id: `${seriesId}|issue:${publication.id}`,
        publicationId: publication.id,
        issueNumber: asString(publication.issue?.number),
        canonicalIssueNumber: parsed?.canonical || null,
        range: parsed?.range || null,
        cycle,
        issueDate: asString(publication.issue?.date),
        issueVolume: asString(publication.issue?.volume),
        publicationYear: publication.publicationYear,
        copies,
      };
      publicationForIssue.set(issue, publication);
      return issue;
    });
    issues.sort((left, right) => {
      if (left.cycle && right.cycle) {
        const cycleDifference = comparePeriodicalCycles(left.cycle, right.cycle);
        if (cycleDifference) return cycleDifference;
      } else if (left.cycle) return -1;
      else if (right.cycle) return 1;
      const firstDifference = (left.range?.first ?? Infinity) - (right.range?.first ?? Infinity);
      if (firstDifference) return firstDifference;
      const lastDifference = (left.range?.last ?? Infinity) - (right.range?.last ?? Infinity);
      if (lastDifference) return lastDifference;
      return left.publicationId.localeCompare(right.publicationId, "pl", { numeric: true });
    });

    const multipleCopyGroups = issues
      .filter((issue) => issue.copies.length > 1)
      .map((issue) => ({
        id: `${seriesId}|copies:${issue.publicationId}`,
        publicationId: issue.publicationId,
        itemIds: issue.copies.map((copy) => copy.id),
      }));

    const duplicateCandidates = new Map();
    for (const issue of issues) {
      if (!issue.cycle || !issue.range) continue;
      const key = `${periodicalCycleId(issue.cycle)}|${issue.range.first}-${issue.range.last}`;
      if (!duplicateCandidates.has(key)) duplicateCandidates.set(key, []);
      duplicateCandidates.get(key).push(issue);
    }
    const duplicatePublicationGroups = [];
    const warnings = group.publications.flatMap(({ identification }) => identification.warnings);
    for (const [key, matchingIssues] of [...duplicateCandidates.entries()].sort()) {
      const compatibleGroups = partitionCompatiblePeriodicalIssues(
        matchingIssues,
        publicationForIssue,
      );
      for (const compatibleIssues of compatibleGroups) {
        if (compatibleIssues.length < 2) continue;
        const nonemptyDates = compatibleIssues.map((issue) => issue.issueDate).filter(Boolean);
        const dateConflict = nonemptyDates.some((value, index) =>
          nonemptyDates.slice(index + 1).some((other) => periodicalDatesConflict(value, other)),
        );
        const volumes = compatibleIssues
          .map((issue) => normalizedPeriodicalMetadata(issue.issueVolume))
          .filter(Boolean);
        const volumeConflict = new Set(volumes).size > 1;
        const publicationIds = compatibleIssues.map((issue) => issue.publicationId).sort();
        if (dateConflict || volumeConflict) {
          warnings.push({
            kind: "conflictingIssueMetadata",
            message: "Rekordy tego numeru mają sprzeczną datę lub tom i nie zostały oznaczone jako pewny duplikat.",
            publicationIds,
          });
          continue;
        }
        duplicatePublicationGroups.push({
          id: `${seriesId}|duplicate:${key}:${publicationIds.join(",")}`,
          cycle: compatibleIssues[0].cycle,
          range: compatibleIssues[0].range,
          publicationIds,
          itemIds: compatibleIssues
            .flatMap((issue) => issue.copies.map((copy) => copy.id))
            .sort(),
        });
      }
    }

    const rangesByCycle = new Map();
    for (const issue of issues) {
      if (!issue.cycle || !issue.range) continue;
      const key = periodicalCycleId(issue.cycle);
      if (!rangesByCycle.has(key)) rangesByCycle.set(key, { cycle: issue.cycle, ranges: [] });
      rangesByCycle.get(key).ranges.push(issue.range);
    }
    const missingIssues = [];
    for (const [cycleId, { cycle, ranges }] of [...rangesByCycle.entries()].sort((left, right) =>
      comparePeriodicalCycles(left[1].cycle, right[1].cycle),
    )) {
      const minimum = Math.min(...ranges.map((range) => range.first));
      const maximum = Math.max(...ranges.map((range) => range.last));
      const span = maximum - minimum + 1;
      if (span > PERIODICAL_MAXIMUM_MISSING_RANGE) {
        warnings.push({
          kind: "missingRangeLimitExceeded",
          message: `Zakres ${minimum}–${maximum} dla ${cycle.label} przekracza limit ${PERIODICAL_MAXIMUM_MISSING_RANGE}.`,
          publicationIds: [],
        });
        continue;
      }
      const present = new Set();
      for (const range of ranges) {
        for (let number = range.first; number <= range.last; number += 1) present.add(number);
      }
      const missing = [];
      for (let number = minimum; number <= maximum; number += 1) {
        if (!present.has(number)) missing.push(number);
      }
      missingIssues.push(
        ...missing.slice(0, PERIODICAL_MAXIMUM_MISSING_ISSUES).map((number) => ({
          id: `${seriesId}|missing:${cycleId}:${number}`,
          cycle,
          number,
        })),
      );
      if (missing.length > PERIODICAL_MAXIMUM_MISSING_ISSUES) {
        warnings.push({
          kind: "missingListTruncated",
          message: `Lista braków dla ${cycle.label} została ograniczona do ${PERIODICAL_MAXIMUM_MISSING_ISSUES} pozycji.`,
          publicationIds: [],
        });
      }
    }

    const publications = group.publications.map(({ publication }) => publication);
    return {
      id: seriesId,
      identification: group.identification.kind,
      title: preferredPeriodicalValue(publications.map((publication) => publication.title)) || "Prasa bez tytułu",
      publisher: preferredPeriodicalValue(publications.map((publication) => publication.publisher)),
      language: preferredPeriodicalValue(publications.map((publication) => publication.language)),
      issn: group.identification.issn,
      issues,
      missingIssues,
      multipleCopyGroups,
      duplicatePublicationGroups,
      warnings: warnings.map((warning, index) => ({
        id: `${seriesId}|warning:${warning.kind}:${index}`,
        ...warning,
      })),
    };
  });

  series.sort((left, right) => {
    const titleDifference = left.title.localeCompare(right.title, "pl", {
      sensitivity: "base",
      numeric: true,
    });
    return titleDifference || left.id.localeCompare(right.id, "pl", { numeric: true });
  });
  return { series, excludedArchivedCopyCount, excludedNonPeriodicalItemCount };
}

function publicationIdentity(publication) {
  if (publication.type === "periodical") {
    const supplementalBarcode = parseEANSupplementBarcode(publication.identifiers.barcode);
    const issue = publication.issue;
    const hasIssueIdentity = Boolean(issue?.volume || issue?.number || issue?.date);

    if (hasIssueIdentity) {
      const seriesIdentifier = publication.identifiers.issn
        ? `issn:${publication.identifiers.issn}`
        : publication.identifiers.ean
          ? `ean:${publication.identifiers.ean}`
          : supplementalBarcode
            ? `ean:${supplementalBarcode.ean}`
            : null;
      if (!seriesIdentifier) return `id:${publication.id}`;
      const supplement = supplementalBarcode?.supplement || "";
      return `periodical:${seriesIdentifier}:${issue.volume || ""}:${issue.number || ""}:${issue.date || ""}:supplement:${supplement}`;
    }

    if (supplementalBarcode) {
      return `periodical:barcode:${supplementalBarcode.canonical}`;
    }
    return `id:${publication.id}`;
  }

  const preferred = ["isbn13", "isbn10", "issn", "ean", "barcode"].find(
    (key) => publication.identifiers[key],
  );
  if (preferred) return `${preferred}:${publication.identifiers[preferred]}`;
  return `id:${publication.id}`;
}

function hasPeriodicalIssueIdentity(publication) {
  const issue = publication.type === "periodical" ? publication.issue : null;
  return Boolean(issue?.volume || issue?.number || issue?.date);
}

function periodicalCompositeIdentity(publication) {
  if (publication.type !== "periodical") return null;
  return parseEANSupplementBarcode(publication.identifiers.barcode)?.canonical || null;
}

function mergedPeriodicalIssue(existingIssue, incomingIssue) {
  const value = (key) => asString(incomingIssue?.[key]) || asString(existingIssue?.[key]) || null;
  const issue = {
    volume: value("volume"),
    number: value("number"),
    date: value("date"),
  };
  return issue.volume || issue.number || issue.date ? issue : null;
}

function periodicalIssueFallbackIdentity(publication) {
  if (publication.type !== "periodical") return null;
  const issue = publication.issue;
  if (!issue?.volume && !issue?.number && !issue?.date) return null;
  const supplementalBarcode = parseEANSupplementBarcode(publication.identifiers.barcode);
  const seriesIdentifier = publication.identifiers.issn
    ? `issn:${publication.identifiers.issn}`
    : publication.identifiers.ean
      ? `ean:${publication.identifiers.ean}`
      : supplementalBarcode
        ? `ean:${supplementalBarcode.ean}`
        : null;
  if (!seriesIdentifier) return null;
  return `periodical:${seriesIdentifier}:${issue.volume || ""}:${issue.number || ""}:${issue.date || ""}`;
}

function periodicalSupplementsAreCompatible(left, right) {
  const leftComposite = parseEANSupplementBarcode(left.identifiers.barcode);
  const rightComposite = parseEANSupplementBarcode(right.identifiers.barcode);
  const leftEAN = asString(left.identifiers.ean || leftComposite?.ean);
  const rightEAN = asString(right.identifiers.ean || rightComposite?.ean);
  if (leftEAN && rightEAN && leftEAN !== rightEAN) return false;
  const leftSupplement = leftComposite?.supplement;
  const rightSupplement = rightComposite?.supplement;
  return !leftSupplement || !rightSupplement || leftSupplement === rightSupplement;
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

  const publicationsById = new Map();
  const publicationsByIdentity = new Map();
  const identityByPublicationId = new Map();
  const periodicalsByIssue = new Map();
  const issueKeyByPublicationId = new Map();
  const periodicalsByComposite = new Map();
  const compositeKeyByPublicationId = new Map();
  const incomingPublicationIdMap = new Map();

  function removePublicationFromIndexes(publicationId) {
    const previousIdentity = identityByPublicationId.get(publicationId);
    if (previousIdentity) {
      const bucket = publicationsByIdentity.get(previousIdentity);
      bucket?.delete(publicationId);
      if (bucket?.size === 0) publicationsByIdentity.delete(previousIdentity);
    }
    identityByPublicationId.delete(publicationId);

    const previousIssueKey = issueKeyByPublicationId.get(publicationId);
    if (previousIssueKey) {
      const bucket = periodicalsByIssue.get(previousIssueKey);
      bucket?.delete(publicationId);
      if (bucket?.size === 0) periodicalsByIssue.delete(previousIssueKey);
    }
    issueKeyByPublicationId.delete(publicationId);

    const previousCompositeKey = compositeKeyByPublicationId.get(publicationId);
    if (previousCompositeKey) {
      const bucket = periodicalsByComposite.get(previousCompositeKey);
      bucket?.delete(publicationId);
      if (bucket?.size === 0) periodicalsByComposite.delete(previousCompositeKey);
    }
    compositeKeyByPublicationId.delete(publicationId);
  }

  function indexPublication(publication) {
    const identity = publicationIdentity(publication);
    publicationsById.set(publication.id, publication);
    if (!publicationsByIdentity.has(identity)) publicationsByIdentity.set(identity, new Map());
    publicationsByIdentity.get(identity).set(publication.id, publication);
    identityByPublicationId.set(publication.id, identity);

    const issueKey = periodicalIssueFallbackIdentity(publication);
    if (issueKey) {
      if (!periodicalsByIssue.has(issueKey)) periodicalsByIssue.set(issueKey, new Map());
      periodicalsByIssue.get(issueKey).set(publication.id, publication);
      issueKeyByPublicationId.set(publication.id, issueKey);
    }

    const compositeKey = periodicalCompositeIdentity(publication);
    if (compositeKey) {
      if (!periodicalsByComposite.has(compositeKey)) {
        periodicalsByComposite.set(compositeKey, new Map());
      }
      periodicalsByComposite.get(compositeKey).set(publication.id, publication);
      compositeKeyByPublicationId.set(publication.id, compositeKey);
    }
  }

  current.publications.forEach(indexPublication);
  incoming.publications.forEach((publication) => {
    const key = publicationIdentity(publication);
    let existing = publicationsById.get(publication.id);
    if (!existing) {
      const exactCandidates = [...(publicationsByIdentity.get(key)?.values() || [])]
        .filter(
          (candidate) =>
            publication.type !== "periodical" ||
            periodicalSupplementsAreCompatible(candidate, publication),
        )
        .sort((left, right) => left.id.localeCompare(right.id));
      [existing] = exactCandidates;
    }
    if (!existing) {
      const issueKey = periodicalIssueFallbackIdentity(publication);
      const candidates = issueKey
        ? [...(periodicalsByIssue.get(issueKey)?.values() || [])].filter((candidate) =>
            periodicalSupplementsAreCompatible(candidate, publication),
          )
        : [];
      if (candidates.length === 1) [existing] = candidates;
    }
    if (!existing) {
      const compositeKey = periodicalCompositeIdentity(publication);
      const candidates = compositeKey
        ? [...(periodicalsByComposite.get(compositeKey)?.values() || [])]
            .filter((candidate) =>
              !hasPeriodicalIssueIdentity(candidate) ||
              !hasPeriodicalIssueIdentity(publication),
            )
            .sort((left, right) => left.id.localeCompare(right.id))
        : [];
      // Existing duplicate records make this match ambiguous. Keep every
      // current record and the incoming one instead of choosing arbitrarily.
      if (candidates.length === 1) [existing] = candidates;
    }

    const canonicalId = existing?.id || publication.id;
    incomingPublicationIdMap.set(publication.id, canonicalId);
    if (existing) {
      removePublicationFromIndexes(existing.id);
      publicationsById.delete(existing.id);
    }
    const existingSupplement = existing
      ? parseEANSupplementBarcode(existing.identifiers.barcode)
      : null;
    const incomingSupplement = parseEANSupplementBarcode(publication.identifiers.barcode);
    let mergedIdentifiers = publication.identifiers;
    if (incomingSupplement) {
      mergedIdentifiers = {
        ...publication.identifiers,
        ean: incomingSupplement.ean,
        barcode: incomingSupplement.canonical,
      };
    } else if (existingSupplement) {
      mergedIdentifiers = {
        ...publication.identifiers,
        // A composite is one atomic observation: never pair its add-on
        // with a different incoming main EAN.
        ean: existingSupplement.ean,
        barcode: existingSupplement.canonical,
      };
    }
    const mergedPublication = {
      ...publication,
      id: canonicalId,
      identifiers: mergedIdentifiers,
      issue:
        existing && publication.type === "periodical"
          ? mergedPeriodicalIssue(existing.issue, publication.issue)
          : publication.issue,
    };
    indexPublication(mergedPublication);
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
    publications: [...publicationsById.values()],
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
