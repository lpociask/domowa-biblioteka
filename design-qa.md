# Design QA — iOS editorial redesign

## Comparison target

- Source visual truth: `/Users/lpociask/Documents/magazyny/5x12/docs/screenshots/library-iphone.jpg`
- Primary implementation capture: `/Users/lpociask/Documents/ChatGPT/katalogowanie ksiazej i prasy/docs/screenshots/ios-redesign-reference-viewport.png`
- Additional implementation captures:
  - `/Users/lpociask/Documents/ChatGPT/katalogowanie ksiazej i prasy/docs/screenshots/ios-redesign-compact-empty.png`
  - `/Users/lpociask/Documents/ChatGPT/katalogowanie ksiazej i prasy/docs/screenshots/ios-redesign-compact-populated.png`
  - `/Users/lpociask/Documents/ChatGPT/katalogowanie ksiazej i prasy/docs/screenshots/ios-redesign-ipad-populated.png`
  - `/Users/lpociask/Documents/ChatGPT/katalogowanie ksiazej i prasy/docs/screenshots/ios-redesign-compact-ax5.png`
- State: light appearance; source library/home and implementation populated library/home. The product content differs intentionally, while the visual grammar is the fidelity target.

## Viewports and normalization

| Artifact | Pixel dimensions | Logical viewport | Density |
|---|---:|---:|---:|
| 5×12 source | 1206 × 2622 | 402 × 874 pt | 3× |
| iPhone reference implementation | 1206 × 2622 | 402 × 874 pt | 3× |
| Compact iPhone implementation | 750 × 1334 | 375 × 667 pt | 2× |
| iPad mini implementation | 1488 × 2266 | 744 × 1133 pt | 2× |
| Compact iPhone AX5 | 750 × 1334 | 375 × 667 pt | 2× |

The primary source and implementation were captured at identical pixel dimensions, logical viewport, density, light appearance, and home/library state. They were opened in the same comparison input at original resolution. Compact, tablet, empty, populated, and largest accessibility text states were checked separately.

## Full-view comparison evidence

- Typography: both use a dominant black serif display, serif explanatory copy, compact uppercase sans-serif labels with tracking, and monospaced metrics. The implementation preserves the source hierarchy without copying the 5×12 wordmark or editorial copy.
- Spacing and layout: 24 pt page gutters, large editorial section intervals, thin horizontal rules, and a flat paper canvas match the source rhythm. Native iOS toolbar safe areas are an intentional platform adaptation.
- Colors and tokens: the implementation uses the source paper `#F4EDDF`, warm paper `#F0E6D2`, ink `#171713`, muted ink `#6D685E`, and orange `#DD6B24` for decorative marks. Small semantic text/icons use accessible `#A9470D`, while white-on-orange actions use `#B14E11` so contrast remains above 4.5:1.
- Image quality: the original 5×12 paper texture is reused as a real raster asset at its native treatment. SF Symbols are used for platform actions; there are no emoji, handcrafted SVGs, CSS/code art, fake illustrations, or placeholder imagery.
- Copy and content: all visible text belongs to the catalog product and explains scanning, metadata, location, search, and collection state. No design prompt or internal QA copy leaks into the app.
- Shape and surfaces: content is structured with rules and flat paper surfaces. Rounded treatment is limited to controls; generic pastel cards, glass surfaces, gradients, and decorative shadows were removed.

## Focused comparison evidence

No separate crop was required because the primary 1206 × 2622 captures make the masthead, metric strip, CTA, search field, and first list row readable at original resolution. The iPad capture additionally verifies row typography, thin rules, metadata hierarchy, and the two-column adaptive layout. The compact and AX5 captures verify wrapping and vertical rhythm at the smallest supported phone height and largest Dynamic Type category.

## States and interactions checked

- Empty library and populated library.
- Compact iPhone, 402 × 874 iPhone reference viewport, and iPad mini.
- Largest accessibility Dynamic Type category; collection title no longer splits inside a word and the page remains scrollable.
- Scanner unavailable/manual fallback, lookup loading/failure, and add form were inspected during implementation.
- Scan, manual add, import, export, search, detail navigation, serial-add continuation, duplicate warning, and save routes remain connected.
- Full iOS automated suite: 77 passed, 0 failed, 0 skipped.
- Web regression suite: 18 passed, 0 failed.

## Findings

No actionable P0, P1, or P2 visual differences remain. The native toolbar and product-specific content differ from the reference by design; palette, typography, rhythm, rules, surfaces, icon treatment, and responsive behavior preserve the target language.

### Follow-up polish (P3)

- Add real publication covers once the cover/cache roadmap increment lands; until then the intentionally typographic list is coherent and does not use fake cover placeholders.
- Recheck long user-defined collection names in Polish and non-Latin scripts during the pilot.

## Comparison history

1. Initial simulator pass found legacy letterboxing with large black bands (P1). Added generated launch-screen metadata to both app configurations. Post-fix compact captures fill the complete display.
2. Scanner pass found the compact/manual fallback collapsing to roughly one row (P1). Added a scrollable fallback with a 240 pt minimum and 340 pt maximum. Post-fix scanner content and CTA remain reachable.
3. Add-form pass found lookup actions consuming the compact viewport and obscuring the first data fields (P1). Replaced them with a compact status/action strip and compact form masthead. Post-fix title and location fields remain reachable above the sticky save action.
4. Compact populated pass found a four-item vertical metric stack and a floating system search control hiding collection content (P1/P2). Replaced the fallback with a 2 × 2 metric grid and added an inline editorial search field. Post-fix evidence: `ios-redesign-compact-populated.png`.
5. Exact 402 × 874 comparison found long metric labels hyphenating inside words (P2). Added a minimum cell width, single-line tightening, and a 2 × 2 fallback. Post-fix evidence: `ios-redesign-reference-viewport.png`.
6. Largest Dynamic Type pass found the collection name splitting inside “biblioteka” (P2). Added a bounded three-line display treatment with controlled minimum scaling. Post-fix evidence: `ios-redesign-compact-ax5.png`.
7. Accessibility review found the source orange below the contrast requirement for small labels and white button text (P2). Kept the exact source orange for decorative rules, then added darker semantic and action variants with measured contrast above 4.5:1. All final captures were regenerated after the fix.

## Final result

passed
