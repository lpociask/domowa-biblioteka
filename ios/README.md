# HomeLibrary iOS

Natywny vertical slice dla iOS 17+, bez zewnętrznych zależności. Dane są przechowywane lokalnie w SwiftData.

## Zakres MVP

- ręczne dodawanie książek i konkretnych numerów prasy,
- skanowanie publikacyjnych EAN-13: ISBN 978/979 i kodów prasy 977 przez VisionKit, z best-effort odczytem dodatków EAN‑2/EAN‑5,
- QR jest akceptowany tylko wtedy, gdy cała jego treść jest poprawnym ISBN; pozostałe kody nie zamykają skanera i dostają czytelny komunikat,
- ręczny fallback skanera (działa również na symulatorze),
- lista, wyszukiwanie, szczegóły i usuwanie egzemplarzy,
- lokalizacja jako ścieżka, np. `Dom / Gabinet / Regał A / Półka 2`,
- osobne modele `Publication` i `OwnedItem`,
- import i eksport wspólnego formatu JSON v1 używanego przez stronę WWW,
- uzupełnianie książki po ISBN w kaskadzie Biblioteka Narodowa → Open Library,
- okładki Open Library oraz trwałe, odbudowywalne cache metadanych i obrazów.
- lokalny OCR okładki prasy oraz read-only analiza serii, luk, wielu kopii i powtórzonych rekordów.

## Kody prasy 977

Po zeskanowaniu prawidłowego EAN‑13 z prefiksem `977` formularz automatycznie wybiera typ `Prasa`, zapisuje EAN i wyprowadza bazowy ISSN wraz z jego cyfrą kontrolną. Taki kod nie uruchamia katalogów książkowych BN/Open Library.

Główny kod 977 nie wystarcza do pewnego rozpoznania konkretnego numeru czasopisma. Dwie cyfry po bazie ISSN są wariantem wydawcy, a właściwy numer bywa zapisany w osobnym dodatku EAN‑2/EAN‑5 albo tylko na okładce.

Skaner czeka krótko na dodatek zgłoszony przez VisionKit i zachowuje pełny kod jako `EAN13+EAN2` lub `EAN13+EAN5`. Ponieważ systemowy odczyt zależy od urządzenia, druku i kadru, formularz ma także jawne pole ręczne. Aplikacja nie zakłada, że wartość dodatku zawsze jest numerem wydania: pokazuje ją osobno i pozwala skopiować do pola numeru dopiero po świadomym potwierdzeniu z okładką. Dwa różne niepuste dodatki nie są traktowane jako ten sam numer, a przy tym samym dodatku użytkownik może wymusić osobny numer, gdy okładka wskazuje inne wydanie lub datę.

Formularz prasy pozwala też zrobić lub wybrać zdjęcie przedniej okładki. Vision rozpoznaje tekst lokalnie po polsku, angielsku i niemiecku, a parser proponuje numer, tom i datę. Użytkownik wybiera, które wartości zastosować; już wypełnione pola nie są nadpisywane. Zdjęcie nie trafia do bazy, cache ani sieci i znika po zakończeniu zadania OCR.

## Lookup metadanych

Po zeskanowaniu lub zatwierdzeniu prawidłowego ISBN-13 w ręcznym fallbacku skanera aplikacja wykonuje pojedynczy lookup. ISBN-10 wpisany w rozszerzonych danych formularza jest normalizowany do ISBN-13. Najpierw aplikacja pyta API Biblioteki Narodowej. Open Library jest sprawdzane dopiero wtedy, gdy BN nie zwróci użytecznego rekordu albo odpowie błędem.

- Pierwszy użyteczny wynik uzupełnia tytuł, podtytuł, autorów, wydawcę, rok i język.
- Formularz pozostaje edytowalny podczas zapytania; wpisane w tym czasie wartości nie są nadpisywane.
- Brak wyniku lub awaria obu katalogów nie blokuje ręcznego zapisu.
- Open Library jest przeznaczone wyłącznie do wywołań low-volume inicjowanych przez użytkownika. Jawny cache metadanych przechowuje trafienia 30 dni, brak rekordu 24 godziny i może awaryjnie użyć starego trafienia do roku. Nie ma pobierania wsadowego.
- W rekordzie zostaje zapisane źródło zaakceptowanych danych: `bn` albo `openlibrary`.
- Adres okładki i jej źródło są przenośne w eksporcie, natomiast przetworzony obraz pozostaje w osobnym lokalnym cache, wyłączonym z kopii zapasowej. Lista nie rozpoczyna pobierania okładek podczas przewijania.

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
