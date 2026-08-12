# Design QA — widok dużych okładek WWW

- Source visual truth: `/private/tmp/HomeLibraryWeb-before-desktop.png`
- Implementation screenshots: `/private/tmp/HomeLibraryWeb-covers-desktop-top.png`, `/private/tmp/HomeLibraryWeb-covers-mobile-press-final-3.png`, `/private/tmp/HomeLibraryWeb-list-mobile-catalog.png`, `/private/tmp/HomeLibraryWeb-real-cover-mobile.png`, `/private/tmp/HomeLibraryWeb-status-loaned-mobile.png`
- Combined comparison evidence: `/private/tmp/polka-design-qa/comparison-final.png`
- Viewports: desktop 1440 × 1000 CSS px; mobile 390 × 844 requested (browser content 375 × 812 CSS px)
- Pixels/density: source 1425 × 2699 px; desktop implementation 1440 × 1000 px; mobile implementation 375 × 812 px; device scale factor 1. Full-view comparison used equal-width side-by-side canvases and a focused catalog crop.
- State: demonstration collection, catalog tab, no filters; both `Okładki` and `Lista` checked. A real Open Library cover was also checked with the `Left Hand` filter.

## Full-view comparison evidence

The implementation preserves the source hierarchy and the selected large-cover catalog: four desktop cards, two mobile cards, cover-first proportions, title/author/location below, and an explicit view control. The broader page intentionally keeps the current 5×12 paper language instead of reverting the rest of the site to the old green design.

## Focused region comparison evidence

The catalog/control strip and first four covers were compared in the lower half of the combined comparison. Cover proportion remains approximately 0.74, the desktop grid is 4 columns, and the `Okładki`/`Lista` control is visible and usable. Mobile evidence confirms 2 columns at 375 CSS px without horizontal overflow and a flat, cover-free list after switching.

## Required fidelity surfaces

- Fonts and typography: current serif display and uppercase micro-label hierarchy are consistent with the iOS/5×12 language; cover typography and the title/author rhythm remain legible at desktop and mobile sizes.
- Spacing and layout rhythm: 4/3/2/1 responsive grid; 44 px controls; stable card padding; no horizontal overflow in the tested mobile viewport.
- Colors and visual tokens: paper, ink, muted ink, orange accent, thin rules, and restrained 8 px radii remain aligned with the current product system.
- Image quality and asset fidelity: the large catalog-cover treatment from the existing first-version component is reused; safe Open Library images take over only after loading and use lazy loading. The catalog treatment remains visible while a remote image is pending or fails.
- Copy/content: visible Polish labels `Okładki` and `Lista`, `aria-pressed`, `aria-controls`, publication status and location are preserved.

## Comparison history

1. Initial implementation restored large cards but also put catalog covers into the compact list and reused the old view preference. Fix: card covers are rendered only in `Okładki`; default and initial markup use `Lista`; the preference key was versioned.
2. Review found eager-request risk because `src` preceded `loading="lazy"`, and an empty paper cover while a lazy image waited. Fix: image behavior attributes are set before `src`; catalog cover content stays visible until `has-cover-image`.
3. Post-fix browser checks: 43/43 data tests pass, JS syntax passes, console has no errors, filters/detail opening work, grid/list persists, real cover loading is restricted to `covers.openlibrary.org`, and list rendering creates no cover image requests.
4. Final mobile review found overlong press metadata in the two-column grid. Fix: the mobile cover view now uses the issue number (or year fallback) rather than duplicating the full issue date; `Wydanie 01` is compacted to `01`. Post-fix evidence is `/private/tmp/HomeLibraryWeb-covers-mobile-press-final-3.png`.

## Findings

No actionable P0, P1, or P2 findings remain. The compact list intentionally remains text-only, including for publications with a remote cover: this preserves the current 5×12 rhythm and ensures ordinary browsing sends no image requests. Residual P3: manual VoiceOver interaction was not run; accessible names and pressed states were inspected through the rendered DOM.

## Primary interactions tested

- switch `Lista` → `Okładki` → `Lista`;
- persistence after reload;
- search filter and opening publication detail;
- real Open Library cover loading with `loading="lazy"`;
- mobile 2-column grid and cover-free list;
- absence of console errors.

final result: passed
