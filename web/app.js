import {
  ITEM_TYPES,
  catalogEntries,
  collectionStats,
  exportPayload,
  filterEntries,
  locationPath,
  mergeCollections,
  normalizeCollection,
  sortEntries,
} from "./lib/catalog-core.mjs";

const STORAGE_KEY = "polka.collection.v1";
const VIEW_KEY = "polka.catalog.view";
const MAX_IMPORT_BYTES = 25 * 1024 * 1024;

const elements = {
  collectionTitle: document.querySelector("#collection-title"),
  statTotal: document.querySelector("#stat-total"),
  statBooks: document.querySelector("#stat-books"),
  statPress: document.querySelector("#stat-press"),
  statUnlocated: document.querySelector("#stat-unlocated"),
  search: document.querySelector("#search-input"),
  type: document.querySelector("#type-filter"),
  location: document.querySelector("#location-filter"),
  sort: document.querySelector("#sort-select"),
  grid: document.querySelector("#publication-grid"),
  resultsCount: document.querySelector("#results-count"),
  emptyState: document.querySelector("#empty-state"),
  clearFilters: document.querySelector("#clear-filters-button"),
  emptyClear: document.querySelector("#empty-clear-button"),
  gridView: document.querySelector("#grid-view-button"),
  listView: document.querySelector("#list-view-button"),
  importButton: document.querySelector("#import-button"),
  exportButton: document.querySelector("#export-button"),
  resetButton: document.querySelector("#reset-button"),
  fileInput: document.querySelector("#file-input"),
  detailDialog: document.querySelector("#detail-dialog"),
  detailContent: document.querySelector("#detail-content"),
  detailClose: document.querySelector("#detail-close-button"),
  importDialog: document.querySelector("#import-dialog"),
  importSummary: document.querySelector("#import-summary"),
  importClose: document.querySelector("#import-close-button"),
  importCancel: document.querySelector("#import-cancel-button"),
  replaceImport: document.querySelector("#replace-import-button"),
  mergeImport: document.querySelector("#merge-import-button"),
  toast: document.querySelector("#toast"),
  storageSummary: document.querySelector("#storage-summary"),
};

const state = {
  collection: null,
  pendingImport: null,
  pendingFilename: "",
  view: readLocalValue(VIEW_KEY) === "list" ? "list" : "grid",
  toastTimer: null,
};

function readLocalValue(key) {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writeLocalValue(key, value) {
  try {
    window.localStorage.setItem(key, value);
    return true;
  } catch {
    return false;
  }
}

function removeLocalValue(key) {
  try {
    window.localStorage.removeItem(key);
  } catch {
    // Brak dostępu do localStorage nie blokuje bieżącej sesji.
  }
}

function makeElement(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined && text !== null) element.textContent = text;
  return element;
}

function icon(name) {
  const paths = {
    location:
      '<path d="M12 21s6-5.4 6-11a6 6 0 1 0-12 0c0 5.6 6 11 6 11Z"/><circle cx="12" cy="10" r="2"/>',
    source:
      '<path d="M10 13a5 5 0 0 0 7.5.5l2-2a5 5 0 0 0-7-7l-1.1 1.1M14 11a5 5 0 0 0-7.5-.5l-2 2a5 5 0 0 0 7 7l1.1-1.1"/>',
  };
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  svg.innerHTML = paths[name] || "";
  return svg;
}

function safeColor(value) {
  const color = String(value || "");
  return /^#[0-9a-f]{6}$/i.test(color) ? color : "#355f55";
}

function titleMonogram(title) {
  const words = String(title)
    .split(/\s+/)
    .map((word) => word.replace(/[^\p{L}\p{N}]/gu, ""))
    .filter(Boolean);
  if (!words.length) return "?";
  if (words.length === 1) return words[0].slice(0, 2).toLocaleUpperCase("pl-PL");
  return `${words[0][0]}${words[1][0]}`.toLocaleUpperCase("pl-PL");
}

function statusLabel(status) {
  return {
    owned: "W kolekcji",
    loaned: "Wypożyczona",
    missing: "Brak na miejscu",
    archived: "Archiwalna",
  }[status] || "W kolekcji";
}

function typeLabel(publication) {
  return publication.type === "periodical" ? "Prasa" : ITEM_TYPES[publication.type] || "Publikacja";
}

function issueLabel(publication) {
  if (!publication.issue) return "";
  return [publication.issue.number, publication.issue.date].filter(Boolean).join(" · ");
}

function authorLabel(publication) {
  if (publication.authors.length) return publication.authors.join(", ");
  if (publication.publisher) return publication.publisher;
  return publication.type === "periodical" ? "Numer czasopisma" : "Autor nieznany";
}

function makeCover(publication) {
  const cover = makeElement("div", "publication-cover");
  cover.style.setProperty("--cover-color", safeColor(publication.metadata.coverColor));
  cover.append(
    makeElement("span", "cover-type", typeLabel(publication)),
    makeElement("strong", "cover-monogram", titleMonogram(publication.title)),
    makeElement("span", "cover-year", publication.publicationYear || "bez daty"),
  );
  return cover;
}

function makeCard(entry) {
  const { publication, ownedItem, locationLabel } = entry;
  const card = makeElement("button", "publication-card");
  card.type = "button";
  card.dataset.entryId = entry.id;
  card.setAttribute("aria-label", `Pokaż szczegóły: ${publication.title}, ${locationLabel}`);

  const coverWrap = makeElement("div", "publication-cover-wrap");
  coverWrap.append(makeCover(publication));
  if (ownedItem.status !== "owned") {
    coverWrap.append(makeElement("span", "status-chip", statusLabel(ownedItem.status)));
  }

  const info = makeElement("div", "publication-info");
  const context = issueLabel(publication) || (publication.publicationYear ? String(publication.publicationYear) : "Bez daty");
  info.append(
    makeElement("p", "publication-kicker", `${typeLabel(publication)} · ${context}`),
    makeElement("h3", "publication-title", publication.title),
    makeElement("p", "publication-author", authorLabel(publication)),
  );

  const location = makeElement(
    "p",
    `publication-location${locationLabel === "Bez lokalizacji" ? " is-unlocated" : ""}`,
  );
  location.append(icon("location"), makeElement("span", "", locationLabel));
  info.append(location);
  card.append(coverWrap, info);
  return card;
}

function pluralize(number, forms) {
  const mod100 = number % 100;
  const mod10 = number % 10;
  if (number === 1) return forms[0];
  if (mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14)) return forms[1];
  return forms[2];
}

function hasActiveFilters() {
  return Boolean(elements.search.value.trim()) || elements.type.value !== "all" || elements.location.value !== "all";
}

function updateLocationOptions() {
  const selected = elements.location.value;
  const locations = [...state.collection.locations].sort((left, right) =>
    locationPath(left.id, state.collection.locations).localeCompare(
      locationPath(right.id, state.collection.locations),
      "pl",
      { sensitivity: "base", numeric: true },
    ),
  );
  elements.location.replaceChildren();
  const allOption = makeElement("option", "", "Wszędzie");
  allOption.value = "all";
  elements.location.append(allOption);
  for (const location of locations) {
    const path = locationPath(location.id, state.collection.locations).split(" / ");
    const option = makeElement("option", "", `${"— ".repeat(Math.max(0, path.length - 1))}${location.name}`);
    option.value = location.id;
    elements.location.append(option);
  }
  elements.location.value = [...elements.location.options].some((option) => option.value === selected)
    ? selected
    : "all";
}

function render() {
  if (!state.collection) return;
  const stats = collectionStats(state.collection);
  elements.collectionTitle.textContent = state.collection.collection.name;
  document.title = `${state.collection.collection.name} — Półka`;
  elements.statTotal.textContent = stats.total.toLocaleString("pl-PL");
  elements.statBooks.textContent = stats.books.toLocaleString("pl-PL");
  elements.statPress.textContent = stats.press.toLocaleString("pl-PL");
  elements.statUnlocated.textContent = stats.unlocated.toLocaleString("pl-PL");

  const entries = catalogEntries(state.collection);
  const visible = sortEntries(
    filterEntries(
      entries,
      {
        query: elements.search.value,
        type: elements.type.value,
        locationId: elements.location.value,
      },
      state.collection.locations,
    ),
    elements.sort.value,
  );

  elements.grid.replaceChildren(...visible.map(makeCard));
  elements.grid.classList.toggle("is-list", state.view === "list");
  elements.grid.setAttribute("aria-busy", "false");
  elements.resultsCount.textContent = `${visible.length.toLocaleString("pl-PL")} ${pluralize(visible.length, ["egzemplarz", "egzemplarze", "egzemplarzy"])} z ${stats.total.toLocaleString("pl-PL")}`;
  elements.emptyState.hidden = visible.length !== 0;
  elements.grid.hidden = visible.length === 0;
  elements.clearFilters.hidden = !hasActiveFilters();
  elements.gridView.classList.toggle("is-active", state.view === "grid");
  elements.listView.classList.toggle("is-active", state.view === "list");
  elements.gridView.setAttribute("aria-pressed", String(state.view === "grid"));
  elements.listView.setAttribute("aria-pressed", String(state.view === "list"));
  elements.storageSummary.textContent = `${stats.total.toLocaleString("pl-PL")} ${pluralize(stats.total, ["egzemplarz", "egzemplarze", "egzemplarzy"])} · zapis lokalny`;
}

function clearFilters() {
  elements.search.value = "";
  elements.type.value = "all";
  elements.location.value = "all";
  render();
  elements.search.focus();
}

function detailPair(term, description) {
  if (description === null || description === undefined || description === "") return null;
  const wrapper = document.createElement("div");
  wrapper.append(makeElement("dt", "", term), makeElement("dd", "", String(description)));
  return wrapper;
}

function bestIdentifier(publication) {
  const labels = [
    ["ISBN", publication.identifiers.isbn13 || publication.identifiers.isbn10],
    ["ISSN", publication.identifiers.issn],
    ["EAN", publication.identifiers.ean],
    ["Kod", publication.identifiers.barcode],
  ];
  return labels.find(([, value]) => value) || ["Identyfikator", null];
}

function safeHttpUrl(value) {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

function openDetail(entryId) {
  const entry = catalogEntries(state.collection).find((candidate) => candidate.id === entryId);
  if (!entry) return;
  const { publication, ownedItem, locationLabel } = entry;
  elements.detailContent.replaceChildren();

  const layout = makeElement("div", "detail-layout");
  const coverPanel = makeElement("div", "detail-cover-panel");
  coverPanel.append(makeCover(publication), makeElement("span", "detail-status", statusLabel(ownedItem.status)));

  const body = makeElement("div", "detail-body");
  body.append(makeElement("p", "detail-type", [typeLabel(publication), issueLabel(publication)].filter(Boolean).join(" · ")));
  const title = makeElement("h2", "", publication.title);
  title.id = "detail-title";
  body.append(title);
  if (publication.subtitle) body.append(makeElement("p", "detail-subtitle", publication.subtitle));
  body.append(makeElement("p", "detail-authors", authorLabel(publication)));

  const locationCard = makeElement(
    "div",
    `detail-location-card${locationLabel === "Bez lokalizacji" ? " is-unlocated" : ""}`,
  );
  const locationText = document.createElement("div");
  locationText.append(
    makeElement("span", "", "Lokalizacja egzemplarza"),
    makeElement("strong", "", locationLabel),
  );
  locationCard.append(icon("location"), locationText);
  body.append(locationCard);

  if (publication.metadata.description) {
    body.append(makeElement("p", "detail-description", publication.metadata.description));
  }

  const [identifierName, identifierValue] = bestIdentifier(publication);
  const details = makeElement("dl", "detail-data");
  const data = [
    detailPair("Wydawca", publication.publisher),
    detailPair("Rok wydania", publication.publicationYear),
    detailPair(identifierName, identifierValue),
    detailPair("Język", publication.language?.toLocaleUpperCase("pl-PL")),
    detailPair("Liczba stron", publication.metadata.pageCount),
    detailPair("Dodano", formatDate(ownedItem.addedAt)),
  ].filter(Boolean);
  details.append(...data);
  if (data.length) body.append(details);

  if (ownedItem.notes) body.append(makeElement("p", "detail-note", `Notatka: ${ownedItem.notes}`));
  const sourceUrl = safeHttpUrl(publication.metadata.sourceUrl);
  if (sourceUrl) {
    const source = makeElement("a", "detail-source", `Źródło: ${publication.metadata.source || "zobacz rekord"}`);
    source.href = sourceUrl;
    source.target = "_blank";
    source.rel = "noopener noreferrer";
    body.append(source);
  } else if (publication.metadata.source) {
    body.append(makeElement("p", "detail-source", `Źródło: ${publication.metadata.source}`));
  }

  layout.append(coverPanel, body);
  elements.detailContent.append(layout);
  elements.detailDialog.showModal();
}

function formatDate(value) {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return value;
  return new Intl.DateTimeFormat("pl-PL", { dateStyle: "medium" }).format(date);
}

function showToast(message, error = false) {
  window.clearTimeout(state.toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.toggle("is-error", error);
  elements.toast.hidden = false;
  state.toastTimer = window.setTimeout(() => {
    elements.toast.hidden = true;
  }, 4200);
}

function persistCollection(collection = state.collection) {
  if (!collection) return false;
  const ok = writeLocalValue(STORAGE_KEY, JSON.stringify(exportPayload(collection)));
  if (!ok) showToast("Nie udało się zapisać kolekcji w tej przeglądarce.", true);
  return ok;
}

async function loadExample({ persist = true } = {}) {
  const response = await fetch("./collection.json", { cache: "no-store" });
  if (!response.ok) throw new Error(`Nie udało się wczytać danych przykładowych (${response.status}).`);
  state.collection = normalizeCollection(await response.json());
  if (persist) persistCollection();
  updateLocationOptions();
  render();
}

async function initialize() {
  const saved = readLocalValue(STORAGE_KEY);
  if (saved) {
    try {
      state.collection = normalizeCollection(JSON.parse(saved));
    } catch (error) {
      removeLocalValue(STORAGE_KEY);
      showToast(`Lokalny zapis był uszkodzony. Przywracamy przykład. ${error.message}`, true);
    }
  }

  if (!state.collection) await loadExample();
  updateLocationOptions();
  render();
}

function exportCollection() {
  if (!state.collection) return;
  const payload = exportPayload(state.collection);
  const blob = new Blob([`${JSON.stringify(payload, null, 2)}\n`], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  const date = new Date().toISOString().slice(0, 10);
  link.href = url;
  link.download = `collection-${date}.json`;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
  showToast("Kolekcja została wyeksportowana do pliku JSON.");
}

async function prepareImport(file) {
  try {
    if (file.size > MAX_IMPORT_BYTES) {
      throw new TypeError("Plik jest za duży. Maksymalny rozmiar importu to 25 MB.");
    }
    const parsed = JSON.parse(await file.text());
    const collection = normalizeCollection(parsed);
    const stats = collectionStats(collection);
    state.pendingImport = collection;
    state.pendingFilename = file.name;
    elements.importSummary.textContent = `${file.name}: ${stats.total} ${pluralize(stats.total, ["egzemplarz", "egzemplarze", "egzemplarzy"])}, ${stats.publications} ${pluralize(stats.publications, ["publikacja", "publikacje", "publikacji"])} i ${collection.locations.length} ${pluralize(collection.locations.length, ["lokalizacja", "lokalizacje", "lokalizacji"])}.`;
    elements.importDialog.showModal();
  } catch (error) {
    showToast(`Nie udało się zaimportować pliku: ${error.message}`, true);
  } finally {
    elements.fileInput.value = "";
  }
}

function completeImport(mode) {
  if (!state.pendingImport) return;
  const importedCollection =
    mode === "merge" ? mergeCollections(state.collection, state.pendingImport) : state.pendingImport;
  if (!persistCollection(importedCollection)) return;

  state.collection = importedCollection;
  state.pendingImport = null;
  clearFilters();
  updateLocationOptions();
  render();
  elements.importDialog.close();
  showToast(mode === "merge" ? "Kolekcje zostały połączone." : "Kolekcja została zastąpiona.");
}

async function resetExample() {
  const accepted = window.confirm(
    "Przywrócić dane przykładowe? Obecna kolekcja zapisana w tej przeglądarce zostanie zastąpiona.",
  );
  if (!accepted) return;
  try {
    await loadExample();
    clearFilters();
    showToast("Przywrócono kolekcję demonstracyjną.");
  } catch (error) {
    showToast(error.message, true);
  }
}

function closeDialogOnBackdrop(event) {
  if (event.target === event.currentTarget) event.currentTarget.close();
}

elements.search.addEventListener("input", render);
elements.type.addEventListener("change", render);
elements.location.addEventListener("change", render);
elements.sort.addEventListener("change", render);
elements.clearFilters.addEventListener("click", clearFilters);
elements.emptyClear.addEventListener("click", clearFilters);
elements.grid.addEventListener("click", (event) => {
  const card = event.target.closest("[data-entry-id]");
  if (card) openDetail(card.dataset.entryId);
});
elements.gridView.addEventListener("click", () => {
  state.view = "grid";
  writeLocalValue(VIEW_KEY, state.view);
  render();
});
elements.listView.addEventListener("click", () => {
  state.view = "list";
  writeLocalValue(VIEW_KEY, state.view);
  render();
});
elements.importButton.addEventListener("click", () => elements.fileInput.click());
elements.fileInput.addEventListener("change", () => {
  const [file] = elements.fileInput.files;
  if (file) prepareImport(file);
});
elements.exportButton.addEventListener("click", exportCollection);
elements.resetButton.addEventListener("click", resetExample);
elements.detailClose.addEventListener("click", () => elements.detailDialog.close());
elements.detailDialog.addEventListener("click", closeDialogOnBackdrop);
elements.importClose.addEventListener("click", () => elements.importDialog.close());
elements.importCancel.addEventListener("click", () => elements.importDialog.close());
elements.importDialog.addEventListener("click", closeDialogOnBackdrop);
elements.replaceImport.addEventListener("click", () => completeImport("replace"));
elements.mergeImport.addEventListener("click", () => completeImport("merge"));
document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLocaleLowerCase() === "k") {
    event.preventDefault();
    elements.search.focus();
  }
});

initialize().catch((error) => {
  elements.grid.setAttribute("aria-busy", "false");
  elements.resultsCount.textContent = "Nie udało się uruchomić katalogu.";
  showToast(error.message, true);
});
