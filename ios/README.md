# HomeLibrary iOS

Natywny vertical slice dla iOS 17+, bez zewnętrznych zależności. Dane są przechowywane lokalnie w SwiftData.

## Zakres MVP

- ręczne dodawanie książek i konkretnych numerów prasy,
- skanowanie EAN-13 (w tym kodów prasy 977), UPC-E i QR przez VisionKit,
- ręczny fallback skanera (działa również na symulatorze),
- lista, wyszukiwanie, szczegóły i usuwanie egzemplarzy,
- lokalizacja jako ścieżka, np. `Dom / Gabinet / Regał A / Półka 2`,
- osobne modele `Publication` i `OwnedItem`,
- import i eksport wspólnego formatu JSON v1 używanego przez stronę WWW,
- uzupełnianie książki po ISBN w kaskadzie Biblioteka Narodowa → Open Library.

## Kody prasy 977

Po zeskanowaniu prawidłowego EAN‑13 z prefiksem `977` formularz automatycznie wybiera typ `Prasa`, zapisuje EAN i wyprowadza bazowy ISSN wraz z jego cyfrą kontrolną. Taki kod nie uruchamia katalogów książkowych BN/Open Library.

Główny kod 977 nie wystarcza do pewnego rozpoznania konkretnego numeru czasopisma. Dwie cyfry po bazie ISSN są wariantem wydawcy, a właściwy numer bywa zapisany w osobnym dodatku EAN‑2/EAN‑5 albo tylko na okładce. Bieżący skaner nie odczytuje dodatku, dlatego numer, tom i data pozostają do potwierdzenia ręcznego.

## Lookup metadanych

Po zeskanowaniu lub zatwierdzeniu prawidłowego ISBN w ręcznym fallbacku skanera aplikacja normalizuje ISBN-10/ISBN-13 i wykonuje pojedynczy lookup. Najpierw pyta API Biblioteki Narodowej. Open Library jest sprawdzane dopiero wtedy, gdy BN nie zwróci użytecznego rekordu albo odpowie błędem.

- Pierwszy użyteczny wynik uzupełnia tytuł, podtytuł, autorów, wydawcę, rok i język.
- Formularz pozostaje edytowalny podczas zapytania; wpisane w tym czasie wartości nie są nadpisywane.
- Brak wyniku lub awaria obu katalogów nie blokuje ręcznego zapisu.
- Open Library jest przeznaczone wyłącznie do wywołań low-volume inicjowanych przez użytkownika. Żądania korzystają z cache HTTP `returnCacheDataElseLoad`; nie ma pobierania wsadowego ani trwałego cache'u metadanych.
- W rekordzie zostaje zapisane źródło zaakceptowanych danych: `bn` albo `openlibrary`.

Do katalogów trafia tylko znormalizowany ISBN. Lokalizacja egzemplarza, notatki i pozostała kolekcja nie są częścią żądania.

## Import i eksport JSON

Opcje `Eksportuj JSON` i `Importuj JSON` znajdują się w menu `Więcej`. Plik należy przenieść ręcznie, np. przez aplikację Pliki lub AirDrop. Aplikacja nie ma konta, własnej chmury ani automatycznej synchronizacji.

Import v1:

- wymaga pełnego kanonicznego dokumentu v1 oraz sprawdza daty, identyfikatory, referencje i graf lokalizacji przed zapisem;
- odrzuca pliki większe niż 25 MB i nadmierną liczbę rekordów;
- odczytuje, dekoduje i waliduje plik poza głównym wątkiem, a dopiero gotowy plan zapisuje w SwiftData;
- zachowuje zewnętrzne ID przez kolejny eksport; wewnętrznie pozostawia UUID albo deterministycznie mapuje tekst w osobnych przestrzeniach publikacji i egzemplarzy;
- dodaje brakujące publikacje i egzemplarze oraz zachowuje wiele kopii;
- przy ponownym imporcie pomija istniejące identyfikatory i nie nadpisuje lokalnych rekordów;
- odtwarza lokalizację z `locationPath` albo z hierarchii `locations`;
- przy imporcie do pustej bazy przyjmuje nazwę i ID kolekcji z pliku.

Plik może zawierać prywatne nazwy pomieszczeń i notatki. Użytkownik wybiera jego miejsce docelowe; prawdziwego eksportu nie należy commitować ani publikować na GitHub Pages.

## Uruchomienie

Otwórz `HomeLibrary.xcodeproj` w Xcode i wybierz schemat `HomeLibrary`.

Kompilacja z terminala:

```sh
xcodebuild \
  -project HomeLibrary.xcodeproj \
  -scheme HomeLibrary \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Testy:

```sh
xcodebuild \
  -project HomeLibrary.xcodeproj \
  -scheme HomeLibrary \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData \
  test
```

Skaner aparatu nie jest dostępny w iOS Simulator, więc ekran automatycznie pokazuje pole do ręcznego wpisania kodu.
