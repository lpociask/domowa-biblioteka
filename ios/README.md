# HomeLibrary iOS

Natywny vertical slice dla iOS 17+, bez zewnętrznych zależności. Dane są przechowywane lokalnie w SwiftData.

## Zakres MVP

- ręczne dodawanie książek i konkretnych numerów prasy,
- skanowanie EAN-13, UPC-E i QR przez VisionKit,
- ręczny fallback skanera (działa również na symulatorze),
- lista, wyszukiwanie, szczegóły i usuwanie egzemplarzy,
- lokalizacja jako ścieżka, np. `Dom / Gabinet / Regał A / Półka 2`,
- osobne modele `Publication` i `OwnedItem`,
- eksport do wspólnego formatu JSON v1 używanego przez stronę WWW.

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
