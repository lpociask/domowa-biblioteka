# Roadmapa

## Etap 0 — pierwszy vertical slice

- [x] wspólny format kolekcji JSON v1;
- [x] repozytorium oraz pipeline GitHub Pages;
- [x] iOS: lokalna baza, lista, wyszukiwanie, dodawanie i skaner;
- [x] iOS: import i eksport JSON v1, addytywny i idempotentny względem identyfikatorów;
- [x] web: import, wyszukiwanie, filtry i lokalne przechowywanie;
- [x] ręczny transfer kolekcji iOS ↔ web bez backendu i automatycznej synchronizacji;
- [x] testy automatyczne;
- [x] publikacja wersji demonstracyjnej na GitHub Pages.

## Etap 1 — metadane książek

- [x] adapter Biblioteki Narodowej po ISBN;
- [x] kaskadowy fallback Open Library, gdy BN nie zwróci dopasowania albo jest chwilowo niedostępna;
- [x] lookup pojedynczego ISBN uruchamiany przez użytkownika, bez zadań wsadowych;
- [x] cache HTTP dla Open Library i zapis pochodzenia zaakceptowanych metadanych;
- [x] zachowanie ręcznych zmian wykonanych podczas trwania lookupu;
- [x] jawny, trwały cache metadanych: 30 dni dla wyników, 24 godziny dla braku rekordu i awaryjny odczyt stale do roku;
- [x] okładki Open Library z bezpiecznym cache obrazów, limitami, usuwaniem metadanych zdjęcia i pracą offline;
- [ ] adapter e‑ISBN jako uzupełnienie nowych polskich wydań;
- [ ] pochodzenie na poziomie pojedynczych pól i ekran porównania rozbieżnych źródeł;
- [ ] ekran wyboru wyniku, gdy źródła zwracają różne wydania;
- [ ] zdjęcie strony tytułowej i ręczny fallback dla książek bez kodu.

Open Library pozostaje eksperymentalnym źródłem low-volume. Odpowiedzi katalogowe i przetworzone okładki są przechowywane w osobnych, odbudowywalnych cache'ach poza bazą kolekcji i poza kopią zapasową.

## Etap 1.5 — wygodne katalogowanie półki

- [x] wybór i normalizacja bieżącej lokalizacji, np. „Gabinet / Regał 2 / Półka 3”;
- [x] tryb seryjnego skanowania z zachowaniem lokalizacji;
- [x] wykrywanie kolejnej kopii i możliwego ponownego skanu na tej samej półce;
- [x] edycja opisu, przenoszenie egzemplarza i bezpieczne usuwanie;
- [x] szybkie cofnięcie zapisu, edycji, przeniesienia i usunięcia;
- [ ] pomiar ergonomii na pilocie 100–200 realnych obiektów.

## Etap 2 — prasa

- rozdzielenie `Serial → SerialManifestation → Issue → OwnedItem`;
- [x] parser kodu 977: walidacja EAN‑13, automatyczny typ prasa i wyprowadzenie bazowego ISSN;
- test odczytu dodatków EAN‑2/EAN‑5 na fizycznej próbce;
- OCR daty, numeru i tomu z okładki;
- szybki tryb dodawania kolejnych numerów jednego tytułu;
- widok brakujących i zdublowanych numerów.

Kod 977 identyfikuje tytuł/manifestację seryjną, nie konkretny numer. Dwie cyfry wariantu w głównym EAN‑13 nie są numerem wydania; dopóki skaner nie obsługuje osobnego dodatku EAN‑2/EAN‑5 lub OCR okładki, numer i data pozostają polami ręcznymi.

## Etap 3 — prywatna synchronizacja

- konto i uwierzytelnione API;
- Postgres oraz magazyn prywatnych zdjęć;
- kolejka zmian local-first i idempotentna synchronizacja;
- web jako pełnoprawny klient tej samej kolekcji;
- backup, eksport oraz usunięcie konta;
- izolacja danych per kolekcja i historia przenosin egzemplarza.

Etap 3 nie jest rozpoczęty. Ręczny plik JSON pozostaje świadomym mechanizmem transferu i kopii zapasowej do czasu wyników pilota oraz osobnej decyzji o chmurze.

## Etap 4 — funkcje kolekcjonerskie

- domownicy i wypożyczenia;
- własne etykiety QR dla miejsc i egzemplarzy;
- importy z innych aplikacji;
- powiązania z POLONĄ/FBC;
- oferty sklepów wyłącznie przez dozwolone integracje partnerskie.

## Bramka przed backendem

Pilot powinien objąć 100–200 realnych obiektów. Orientacyjne cele:

- co najmniej 90% poprawnych dopasowań współczesnych książek z ISBN;
- mediana poniżej 8 sekund od skanu do zapisu książki;
- mediana poniżej 20 sekund dla numeru prasy wymagającego potwierdzenia;
- mniej niż 15% ręcznych korekt dla książek z ISBN;
- pełne odtworzenie kolekcji z eksportu, zweryfikowane na realnych danych i w obu klientach.

To są progi decyzyjne, nie wyniki osiągnięte przez obecną wersję.
