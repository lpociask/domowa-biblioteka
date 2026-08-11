# Katalog domowej biblioteki i prasy — notatka badawcza

Data analizy: 11 sierpnia 2026 r.

## Teza produktowa

Największą wartością nie jest kolejna lista przeczytanych książek, lecz prywatny inwentarz odpowiadający w kilka sekund na dwa pytania: „czy to mam?” i „gdzie dokładnie to leży?”. Potencjalną przewagą względem typowych katalogów książkowych jest obsługa konkretnych numerów prasy, hierarchicznych lokalizacji i szybkiego katalogowania całej półki lub pudła.

Rekomendowany kierunek: aplikacja iOS jako główne narzędzie skanowania i pracy offline, uzupełniona prostym webem do wyszukiwania, edycji i eksportu. Dane powinny być przechowywane local-first i synchronizowane przez neutralny backend.

## Zakres i metoda

Przegląd objął oficjalne materiały produktów konkurencyjnych, dokumentację bibliotek narodowych i międzynarodowych baz bibliograficznych, dokumentację API oraz standardy ISBN, ISSN i GS1. Analiza dotyczy publikacji polskich i zagranicznych, książek nowych i starszych oraz prasy z kodami 977, zwykłymi GTIN/UPC i bez kodu.

Oceny priorytetów w raporcie są ocenami eksperckimi w skali 1–5, a nie pomiarem zachowania użytkowników:

- 5 — konieczne, aby produkt spełnił główną obietnicę;
- 4 — ważne w pierwszej użytecznej wersji;
- 3 — przydatne, ale może poczekać na potwierdzenie popytu;
- 2 — rozszerzenie po MVP;
- 1 — świadomie poza początkowym zakresem.

## Konkurenci — oficjalne materiały

- [Libib](https://www.libib.com/) i [cennik Libib](https://www.libib.com/pricing): web, iOS i Android; skan ISBN/UPC, kolekcje, synchronizacja i eksport. Bezpłatny plan ma ograniczenie liczby pozycji, a funkcje organizacyjne i API są rozwijane w płatnym planie.
- [CLZ Books na urządzenia mobilne](https://clz.com/books/mobile) oraz [wersja web](https://clz.com/books/web): silny produkt książkowy ze skanowaniem ISBN, lokalizacją, stanem i synchronizacją. Oficjalne materiały koncentrują się na książkach, nie na katalogowaniu pojedynczych numerów prasy.
- [LibraryThing](https://www.librarything.com/about), [funkcje](https://www.librarything.com/more) i [oficjalna aplikacja](https://www.librarything.com/official-app): duży katalog społecznościowy korzystający z bibliotek i serwisów książkowych, z aplikacją mobilną i importem/eksportem.
- [BookBuddy](https://www.kimicoapps.com/bookbuddy): aplikacja iOS do prywatnego katalogu książek ze skanowaniem, wypożyczeniami, synchronizacją i eksportem.
- [Book Tracker](https://booktrack.app/faq/what-is-book-tracker-and-how-does-it-work/): mocny wzorzec fizycznej hierarchii `biblioteka → regał → półka → pozycja`, ale bez pełnoprawnego klienta WWW i bez wyeksponowanego modelu pojedynczych numerów prasy.

Wniosek konkurencyjny jest ograniczony do przejrzanych oficjalnych materiałów: rynek ma dojrzałe katalogi książek, natomiast obsługa numeru czasopisma jako osobnego obiektu oraz domowej topografii kolekcji nie jest w nich eksponowana jako główny przepływ.

## Źródła metadanych — Polska

- [Biblioteka Narodowa — REST API](https://data.bn.org.pl/docs/bibs): rekordy bibliograficzne w JSON, XML, MARCXML i MARC; wyszukiwanie m.in. po ISBN/ISSN, tytule, autorze, wydawcy, języku i roku.
- [Biblioteka Narodowa — OAI-PMH](https://data.bn.org.pl/docs/oai): przyrostowa synchronizacja rekordów i możliwość budowy własnego indeksu.
- [Biblioteka Narodowa — informacja o otwartych danych](https://www.bn.org.pl/aktualnosci/3345-biblioteka-narodowa-otwiera-najwieksza-polska-baze-danych-bibliograficznych.html): oficjalna deklaracja bezpłatnego udostępnienia danych bibliograficznych przez API, OAI i pliki.
- [e-ISBN — dokumentacja API](https://www.e-isbn.pl/IsbnWeb/start/Dokumentacja_API.pdf): dane wydawnicze w ONIX/XML i wyszukiwanie po ISBN.
- [Biblioteka Narodowa — ISSN](https://www.bn.org.pl/dla-wydawcow/issn/): polskie centrum informacji o identyfikacji wydawnictw ciągłych.
- [NUKAT — komunikaty](https://centrum.nukat.edu.pl/pl/komunikaty): katalog polskich bibliotek naukowych, ale oficjalny komunikat z 15 lipca 2026 r. zapowiada zakończenie działalności 31 grudnia 2026 r. Nie należy budować nowej zależności od NUKAT.
- [POLONA OpenAPI](https://polona.pl/api/search-service/api-docs): wyszukiwanie polskich obiektów cyfrowych, szczególnie starszych książek i prasy. Powinna służyć do linkowania do kopii cyfrowej, z respektowaniem praw zapisanych przy konkretnym obiekcie.
- [Federacja Bibliotek Cyfrowych — otwarte dane](https://fbc.pionier.net.pl/text?id=about-fbc#open-data): agregator polskich bibliotek i repozytoriów cyfrowych. Przydatny do odkrywania i linkowania; trwały import wymaga stabilnego interfejsu i zachowania licencji instytucji źródłowej.

Rekomendowana kolejność dla polskiej książki w MVP: BN REST → e-ISBN → źródła globalne → ręczne potwierdzenie. Dane sklepów nie powinny zastępować bibliografii.

## Źródła metadanych — świat

- [Open Library APIs](https://openlibrary.org/developers/api) i [licencjonowanie](https://openlibrary.org/developers/licensing): otwarte API do lekkiego użycia oraz zrzuty danych do zastosowań masowych; wymagane są cache i respektowanie limitów.
- [Google Books Volumes API](https://developers.google.com/books/docs/v1/reference/volumes/list), [opis API](https://developers.google.com/books/docs/overview), [warunki Books API](https://developers.google.com/books/terms) i [zasady oznaczeń](https://developers.google.com/books/branding): szerokie pokrycie książek i części magazynów, ale z obowiązkiem atrybucji i linkowania oraz istotnymi ograniczeniami komercjalizacji i trwałego przechowywania. W płatnym produkcie wymaga osobnej oceny prawnej lub zgody Google.
- [Crossref REST API](https://www.crossref.org/documentation/retrieve-metadata/rest-api/): dobre źródło dla prac naukowych, czasopism i DOI; nie jest ogólnym katalogiem prasy konsumenckiej.
- [Library of Congress APIs](https://www.loc.gov/apis/) i [SRU/Z39.50](https://www.loc.gov/apis/additional-apis/search-retrieval-via-url/): źródła biblioteczne dla publikacji amerykańskich i międzynarodowych.
- [Deutsche Nationalbibliothek — SRU](https://www.dnb.de/DE/Professionell/Metadatendienste/Datenbezug/SRU/sru.html): bezpłatne wyszukiwanie w DNB, GND i katalogu czasopism ZDB.
- [VIAF API](https://www.oclc.org/developer/api/oclc-apis/viaf.en.html): normalizacja autorów i wariantów nazw z wielu bibliotek narodowych.
- [ISSN Portal](https://portal.issn.org/) i [usługi ISSN](https://www.issn.org/services/): autorytatywne źródło dla wydawnictw ciągłych; pełne dane i automatyczny dostęp są usługą komercyjną, więc w MVP potrzebny jest krajowy lub ręczny fallback.
- [ISBNdb](https://isbndb.com/isbn-database): płatna baza książek oferująca użycie komercyjne w ramach subskrypcji; kandydat do wersji produkcyjnej po sprawdzeniu jakości na polskiej i międzynarodowej próbce oraz warunków cache i usuwania danych po zakończeniu subskrypcji.
- [WorldCat Search API](https://www.oclc.org/developer/api/oclc-apis/worldcat-search-api.en.html): wartościowe dane biblioteczne, ale dostęp nie jest dobrym publicznym fundamentem niezależnego MVP; wymaga sprawdzenia bieżącej oferty i uprawnień OCLC.

Goodreads nie powinien być zależnością nowego produktu: oficjalny wątek deweloperski opisuje zakończenie wydawania nowych kluczy API i wygaszanie narzędzi ([Goodreads API deprecation](https://www.goodreads.com/topic/show/21788520-api-deprecation)).

## Księgarnie i ceny

- [Allegro API — FAQ](https://developer.allegro.pl/faq) oraz [zasady API](https://developer.allegro.pl/rules): dostęp jest autoryzowany, a oficjalne materiały ograniczają wykorzystanie danych katalogu poza Allegro. Bez osobnej zgody/licencji nie należy kopiować opisów ani zdjęć do własnej bazy; można rozważyć jedynie link lub formalną integrację partnerską.
- [EmpikPlace — Developer Portal](https://www.pomoc.empikplace.com/portal/pl/kb/articles/developer-portal-18-9-2025): API marketplace służy sprzedawcom do obsługi ofert i zamówień, nie jest publicznym API czytelniczego katalogu Empiku. Import danych wymagałby umowy partnerskiej.
- [eBay Browse API](https://developer.ebay.com/api-docs/buy/browse/overview.html): wyszukiwanie ofert i produktów po GTIN w obsługiwanych rynkach.

Ceny i dostępność powinny być osobnym, nietrwałym rekordem z walutą, krajem, sprzedawcą i czasem obserwacji. Nie należy budować produktu na scrapingu księgarń ani traktować oferty handlowej jako kanonicznego rekordu publikacji. W pierwszej wersji bezpieczniejsze są zwykłe linki do wyszukania publikacji; automatyczne ceny dopiero po uzyskaniu właściwych praw.

## Standardy i model danych

- [BIBFRAME 2.0](https://www.loc.gov/bibframe/docs/bibframe2-model.html): rozdzielenie utworu, konkretnej publikacji/instancji i fizycznego egzemplarza. W uproszczonym modelu produktu: `Work → Edition → Item`.
- [International ISBN Agency — czym jest ISBN](https://www.isbn-international.org/content/what-isbn): ISBN identyfikuje określone wydanie i format, nie egzemplarz należący do użytkownika.
- [ISSN — główne zasady przypisywania](https://www.issn.org/understanding-the-issn/assignment-rules/issn-the-major-principles/): osobne manifestacje i istotne zmiany tytułu mogą otrzymywać odrębne ISSN. ISSN identyfikuje wydawnictwo ciągłe, nie pojedynczy numer.
- [GS1 — użycie ISSN w kodzie kreskowym](https://support.gs1.org/support/solutions/articles/43000734320-how-is-an-issn-used-in-a-gs1-barcode-) i [GS1 General Specifications](https://www.gs1.org/standards/barcodes-epcrfid-id-keys/gs1-general-specifications): prefiks 977, wariant wydania i opcjonalny add-on EAN-2/EAN-5.

Minimalny model:

```text
Work 1 ── N Edition 1 ── N Item
Serial 1 ── N SerialManifestation 1 ── N Issue 1 ── N Item
Location 1 ── N Item
```

Każde pole pobrane z zewnątrz powinno zachowywać źródło, datę i poziom pewności. Ręczna poprawka użytkownika ma wyższy priorytet niż późniejszy import.

## Skanowanie i technologia

- [Apple DataScannerViewController](https://developer.apple.com/documentation/visionkit/datascannerviewcontroller) i [skanowanie danych kamerą](https://developer.apple.com/documentation/visionkit/scanning-data-with-the-camera): natywne skanowanie tekstu i kodów na wspieranych urządzeniach.
- [MDN BarcodeDetector](https://developer.mozilla.org/en-US/docs/Web/API/BarcodeDetector): webowy interfejs pozostaje eksperymentalny i nie ma jednolitej dostępności, co zwiększa ryzyko web-only dla masowego skanowania.

Obsługę dodatków EAN-2/EAN-5 trzeba zweryfikować na realnym korpusie prasy. Dla kodu 977 aplikacja powinna ustalić tytuł po ISSN, a konkretny numer rozpoznać z add-onu, OCR okładki i krótkiego potwierdzenia użytkownika.

## Założenia do pilotażu

Przed pełną budową należy przetestować 100–200 reprezentatywnych obiektów: nowe polskie książki, książki zagraniczne, stare pozycje bez ISBN, popularne czasopisma, prasę specjalistyczną, numery łączone i wydania specjalne.

Proponowane cele pilotażu — są to progi decyzyjne, nie wyniki badania:

- co najmniej 90% poprawnych automatycznych dopasowań dla współczesnych książek z ISBN;
- mediana poniżej 8 sekund od skanu do zapisu nowej książki;
- mediana poniżej 20 sekund dla numeru prasy wymagającego potwierdzenia;
- mniej niż 15% ręcznych korekt dla książek z ISBN;
- 100% odtwarzalności danych z eksportu i kopii zapasowej.

## Ograniczenia i ryzyka

- Pokrycie metadanych zależy od kraju, wieku i rodzaju publikacji; nie istnieje jedno kompletne źródło światowe.
- Konkretne numery prasy są znacznie słabiej opisane niż tytuły wydawnictw ciągłych.
- Okładki, opisy i streszczenia mogą podlegać prawu autorskiemu lub ograniczeniom licencyjnym, nawet gdy identyfikatory i podstawowe fakty bibliograficzne są swobodniej używane.
- Limity, ceny i zasady API mogą się zmieniać; przed implementacją komercyjną potrzebny jest audyt regulaminów i licencji.
- Dane o dokładnej lokalizacji kolekcji powinny być prywatne domyślnie. Kody QR miejsc powinny zawierać niejawne identyfikatory, nie nazwy pomieszczeń ani adres.
- Przegląd nie obejmuje testu rozpoznawania na fizycznej kolekcji użytkownika; jakość skanera, OCR i źródeł trzeba potwierdzić w pilotażu.
