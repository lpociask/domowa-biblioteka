# Design QA — WWW zgodne z aplikacją iOS

## Materiał źródłowy

- Główna prawda wizualna: `/private/tmp/HomeLibrary-iOS-library-reference.png`
- Dodatkowy wzorzec języka 5×12: `/Users/lpociask/Documents/magazyny/5x12/docs/screenshots/library-iphone.jpg`
- Implementacja mobilna: `/private/tmp/HomeLibraryWeb-final-mobile-top-normalized-375x815.png`
- Implementacja desktopowa: `/private/tmp/HomeLibraryWeb-final-desktop-top-1440x1000.png`
- Szczegóły publikacji: `/private/tmp/HomeLibraryWeb-final-detail-mobile-390x844.png`
- Widok serii prasy: `/private/tmp/HomeLibraryWeb-final-periodicals-mobile.png`
- Porównanie pełnego widoku: `/private/tmp/HomeLibrary-Web-iOS-final-comparison.png`
- Porównanie skupione na mastheadzie i metrykach: `/private/tmp/HomeLibrary-Web-iOS-focused-comparison.png`

## Normalizacja i stan

- Źródło iOS: 1206 × 2622 px; proporcjonalnie znormalizowane do 375 × 815 px.
- Implementacja: przeglądarka ustawiona na 390 × 844 CSS px, efektywny obszar treści 375 × 844 CSS px ze względu na pionowy pasek przewijania; kadr porównawczy 375 × 815 px, density factor 1.
- Dodatkowe viewporty: 320 × 568, 820 × 1180 i 1440 × 1000 CSS px.
- Stan: jasny motyw, zapełniona kolekcja. Źródło ma 6 egzemplarzy, fixture WWW ma 9; różnica danych nie jest różnicą wizualną.
- Kadr WWW nie zawiera chromu przeglądarki, a źródło iOS zawiera systemowy pasek statusu. Porównanie ocenia właściwy interfejs aplikacji od mastheadu w dół.

## Ocena powierzchni wierności

- Typografia: redakcyjny krój serif dla mastheadów i tytułów oraz systemowy sans dla sterowania odpowiadają podziałowi iOS. Skala, waga, tracking mikrotekstu i zawijanie działają na 320–1440 px.
- Rytm i układ: papierowa strona, cienkie reguły, płaski pasek czterech metryk, pomarańczowe CTA oraz wiersze publikacji z indeksami odwzorowują hierarchię iOS. Mobile nie ma poziomego overflow.
- Kolory i tokeny: `#F4EDDF`, `#F0E6D2`, `#171713`, `#6D685E`, `#DD6B24`, `#A9470D` i `#B14E11` są zgodne z `LibraryTheme`.
- Obrazy: użyto rzeczywistej tekstury papieru z aplikacji iOS. Okładka pojawia się wyłącznie wtedy, gdy istnieje prawdziwy bezpieczny URL; usunięto sztuczną okładkę z monogramem ze szczegółów.
- Treść: WWW zachowuje komunikat o lokalnym zapisie GitHub Pages. Główne CTA to „Importuj kolekcję”, czyli webowy odpowiednik głównej akcji „Skanuj publikację” z iOS.
- Ikony: istniejący zestaw liniowych ikon WWW zachowuje wspólną wagę i rozmiar. Dokładna zgodność glifów SF Symbols pozostaje opcjonalnym P3.

## Historia porównań i poprawek

### Iteracja 1 — zablokowana

- [P0] Mobilny masthead miał 382 px szerokości przy 375 px obszaru treści; tytuł 50,7 px wypychał pomarańczową kropkę do osobnego wiersza i tworzył poziomy scroll.
- [P1] Przyciski nagłówka miały 42 × 40 px.
- [P1] Szczegóły bez prawdziwej okładki pokazywały sztuczną, kodową okładkę z monogramem.
- [P2] Metryki mobilne były układem 2 × 2 zamiast płaskiego paska czterech wartości.
- [P2] Mobilny toolbar filtrów był zbyt wysoki, a nad katalogiem brakowało równoważnego głównego CTA.

### Wprowadzone poprawki

- Masthead dostał osobny flexowy punkt akcentowy i kompaktową skalę 31 px; końcowy `scrollWidth == clientWidth` na 320 i 390 px.
- Oba przyciski nagłówka i przycisk zamknięcia szczegółów mają minimum 44 × 44 px.
- Szczegóły są pełnoekranowe na telefonie; bez realnej okładki blok obrazu nie jest renderowany.
- Metryki układają się w jeden czterokolumnowy pasek na telefonie.
- Filtry mają dwa pola w pierwszym rzędzie i pełną szerokość sortowania w drugim.
- Dodano pełnoszerokie pomarańczowe CTA „Importuj kolekcję”.

### Iteracja 2 — zaliczona

- Dowód po poprawkach: `/private/tmp/HomeLibrary-Web-iOS-final-comparison.png`.
- Skupiony dowód mastheadu i metryk: `/private/tmp/HomeLibrary-Web-iOS-focused-comparison.png`.
- Brak pozostałych P0/P1/P2. Różnice funkcjonalne — import zamiast skanowania oraz informacja o braku synchronizacji — są celowe dla statycznej strony GitHub Pages.

## Sprawdzone interakcje

- wyszukiwanie i stan braku wyników;
- filtry typu i lokalizacji oraz sortowanie;
- przełącznik siatka/lista;
- zakładki Katalog/Serie prasy, w tym strzałka klawiatury;
- szczegóły publikacji i zamknięcie dialogu;
- import poprawnego `collection.json`, wybór scalania i zachowanie 9 egzemplarzy;
- eksport uruchamia funkcję i pokazuje potwierdzenie;
- skrót `⌘K` ustawia fokus w wyszukiwarce;
- 44-punktowe cele dotykowe, 320 px compact, 390 px mobile, 820 px tablet, 1440 px desktop;
- konsola przeglądarki: 0 błędów i 0 ostrzeżeń.

## Pozostały P3

- W przyszłości można zastąpić istniejące liniowe SVG ikonami z jednej biblioteki o metrykach jeszcze bliższych SF Symbols. Nie zmienia to hierarchii, obsługi ani spójności obecnego widoku.

final result: passed
