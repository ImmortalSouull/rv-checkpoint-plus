# RV Checkpoint+ (RV There Yet?)

[English](README.md) | [Русский](README.ru.md) | **Polski**

![RV Checkpoint+](showcase/nexus/final/01_cover.jpg)

Najczęstsza skarga w świeżych negatywnych recenzjach na Steam: zapisywać można tylko na stałych punktach kontrolnych.
Jeden zły skok, jeden błąd albo jeden niedźwiedź cofa całą grupę, a wczytanie wyrzuca naprawy zrobione od tamtej
pory.

RV Checkpoint+ dodaje:

| Klawisz | Co robi |
|---|---|
| **F5** | **Szybki zapis.** Zapisuje kampera teraz: uszkodzenia, naprawy, przedmioty na nim, ekwipunek i to, gdzie stoi. |
| **F9** | **Szybkie wczytanie.** Wraca do ostatniego szybkiego zapisu. Nie cofa do punktu kontrolnego. |
| **F8** | **Menu punktów kontrolnych.** Wróć do dowolnego wcześniejszego punktu, np. po pominięty przedmiot. Naciśnij F8 ponownie, by cofnąć się dalej, F9, by jechać, albo poczekaj, by anulować. Kamper zachowuje obecne naprawy. |
| **F7** | **Ratuj kampera.** Przewrócony, zakleszczony albo wpadł pod świat? Pierwsze naciśnięcie go uwalnia. Drugie w ciągu kilku sekund stawia go z powrotem na koła w ostatnim bezpiecznym miejscu. |
| **F6** | **Odblokuj.** Stawia Cię przy drzwiach kampera. **Shift+F6** sprowadza do kampera wszystkich graczy. |
| (auto) | **Naprawy są zapisywane** kilka sekund po naprawie kampera, więc wczytanie już ich nie cofa. |

Więcej szczegółów:
- **Koniec gry zachowuje szybki zapis.** Gdy kamper zostanie zniszczony, gra startuje od nowa, a mod ustawia kampera
  i graczy w miejscu szybkiego zapisu, nie na punkcie kontrolnym.
- **Wyjście w połowie trasy.** Naciśnij F5, wyjdź, a później użyj *Wczytaj grę* i kontynuujesz od szybkiego zapisu.
- **Stare szybkie zapisy wygasają.** Dotarcie do nowego punktu kontrolnego zastępuje stary szybki zapis. Nowa gra
  o starej nazwie ignoruje stary plik.
- **Żadnych złych zapisów.** Mod nie zapisze, gdy kamper jest w powietrzu albo na boku.

## Instalacja
1. Zainstaluj **UE4SS** (wersja eksperymentalna, obsługuje UE 5.6): skopiuj `dwmapi.dll` i folder `ue4ss` z
   [RE-UE4SS experimental-latest](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest) obok
   `RV There Yet?\Ride\Binaries\Win64\Ride-Win64-Shipping.exe`.
2. Skopiuj folder `RVCheckpointPlus` do `...\Win64\ue4ss\Mods\`. Zawiera już `enabled.txt`.
3. Uruchom grę.

Ustawienia są w `RVCheckpointPlus\Scripts\config.lua`: klawisze, automatyczny zapis po naprawie, zapis co określony
czas i długość komunikatów na ekranie.

## Gra wieloosobowa
- Mod potrzebny jest tylko **hostowi**. W tej grze zapisy i punkty kontrolne należą do hosta. Gracze bez moda mogą
  dołączyć.
- Gracze są przenoszeni własną funkcją gry `TeleportPlayerTo`.
- Sprawdzałem to tylko jako host sam (jeden komputer). Kooperacja z prawdziwymi znajomymi nie była sprawdzana,
  więc daj znać, co się dzieje.

## Odinstalowanie
Usuń `ue4ss\Mods\RVCheckpointPlus`. Szybkie zapisy są w jego folderze `saves`. Twoje zwykłe zapisy gry nigdy nie są
zmieniane, poza własną funkcją zapisu gry.

## Zgodność
- Sprawdzone na wersji gry **v1.3.20702** (UE 5.6) na Mabutts Valley i Mt. Yurbuttsk.
- Nie podmienia żadnych plików gry i nie używa modów pak, więc aktualizacje gry raczej go nie zepsują.

## Podziękowania
- Mod stworzony przez Claude (AI od Anthropic) dla [immortalsouul](https://www.nexusmods.com/profile/immortalsouul),
  który testował go w grze i go publikuje.
- UE4SS — zespół UE4SS-RE.
- RV There Yet? — Nuggets Entertainment.

Tłumaczenie przygotowane przy pomocy AI.

## Licencja
MIT (zob. `LICENSE`). To repozytorium nie zawiera plików gry.
