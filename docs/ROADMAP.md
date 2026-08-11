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
- [ ] adapter e‑ISBN jako uzupełnienie nowych polskich wydań;
- [ ] jawny, trwały cache metadanych z TTL, pochodzeniem pól i polityką odświeżania;
- [ ] ekran wyboru wyniku, gdy źródła zwracają różne wydania;
- [ ] zdjęcie strony tytułowej i ręczny fallback dla książek bez kodu.

Open Library pozostaje eksperymentalnym źródłem low-volume. Bieżący cache jest cache'em HTTP `URLSession`, a nie trwałą lokalną bazą odpowiedzi.

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
