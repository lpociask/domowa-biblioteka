# Roadmapa

## Etap 0 — pierwszy vertical slice

- [x] wspólny format kolekcji JSON v1;
- [x] repozytorium oraz pipeline GitHub Pages;
- [x] iOS: lokalna baza, lista, wyszukiwanie, dodawanie i skaner;
- [x] iOS: eksport JSON;
- [x] web: import, wyszukiwanie, filtry i lokalne przechowywanie;
- [x] testy automatyczne;
- [ ] publikacja wersji demonstracyjnej na GitHub Pages.

## Etap 1 — metadane książek

- adapter Biblioteki Narodowej po ISBN/ISSN;
- adapter e‑ISBN jako uzupełnienie nowych polskich wydań;
- cache odpowiedzi z pochodzeniem na poziomie rekordu;
- ekran wyboru wyniku, gdy źródła zwracają różne wydania;
- zdjęcie strony tytułowej i ręczny fallback dla książek bez kodu.

## Etap 2 — prasa

- rozdzielenie `Serial → SerialManifestation → Issue → OwnedItem`;
- parser kodu 977;
- test odczytu dodatków EAN‑2/EAN‑5 na fizycznej próbce;
- OCR daty, numeru i tomu z okładki;
- szybki tryb dodawania kolejnych numerów jednego tytułu;
- widok brakujących i zdublowanych numerów.

## Etap 3 — prywatna synchronizacja

- konto i uwierzytelnione API;
- Postgres oraz magazyn prywatnych zdjęć;
- kolejka zmian local-first i idempotentna synchronizacja;
- web jako pełnoprawny klient tej samej kolekcji;
- backup, eksport oraz usunięcie konta;
- izolacja danych per kolekcja i historia przenosin egzemplarza.

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
- pełne odtworzenie kolekcji z eksportu.

To są progi decyzyjne, nie wyniki osiągnięte przez obecną wersję.
