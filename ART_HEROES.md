# Prisma — арт героев (художники Призма-Арены)

Дополняет `ART.md`. Герои — **художники-дуэлянты**, что сражаются светом на Призма-Арене
(Испытание Мастерства). Каждый герой = **портрет** + **пассивная сила** (`DESIGN.md §6`) + **иконка
абилки**. Стиль — тот же, что у карт: **существо из живого света** (см. `ART.md`), но герой —
**человекоподобная фигура**, и формат **квадрат 1:1**.

Отличия от карт:
- это **персонаж** (фигура художника), а не существо/явление; поза и силуэт — узнаваемые.
- герой **не привязан к лучу** (отдельная ось от цветов колоды) → у каждого своя сигнатурная
  палитра и мотив, а не цвет карты.
- **формат квадрат 1:1** (`1024×1024`); клиент кадрирует портрет квадратом, лицо/торс по центру.
- пока **1 статичный арт** на героя.

## HERO-BASE (фиксированный)

> Stylized hero portrait for Prisma, a world made of and revealed by living light. A humanoid
> duelist-artist of the Prisma Arena, shaped from light: a bold, clean, readable figure glowing
> from within — a translucent luminous body and a few bright internal light-lines, a glowing core
> and eyes, soft volumetric glow with a crisp rim, set against deep darkness so the light reads.
> Their signature is **{MOTIF}**, lit in **{PALETTE}**. Simplified, few large shapes, no busy
> detail, no realistic flesh, metal or texture — light given form. A distinct recognizable
> silhouette and a confident pose. Square 1:1 composition, a single centered figure filling most
> of the frame, simple dark atmospheric background. No text, no card frame, no border, no UI.

Отображаемое имя героя — **одно слово** (личное имя художника); мантия («Призма» и т.п.) — лор.

| id | Имя | Мантия | Сила (пассив) | Иконка |
|---|---|---|---|---|
| `hero_prism` | **Ирида** | Призма | Спектральный сдвиг — раз в ход 1 кристалл тратится как соседний по спектру цвет | `prism.svg` |
| `hero_eclipse` | **Эреб** | Затмение | Пожиратель света — существо, ударившее твоего героя, навсегда теряет 1 атаки | `eclipse.svg` |
| `hero_palette` | **Тициана** | Палитра | Смешение красок — первый за ход розыгрыш мультиколор-карты даёт добор | `palette.svg` |
| `hero_facet` | **Гемма** | Огранка | Огранка — будишь любую банкованную карту; разбуженные существа +1/+1 | `facet.svg` |

> **Отложено в бэклог:** Кьяра «Линза» / Прозрение (`clairvoyance`) — готовый кандидат, арт `hero_lens.png` сохранён, но из боевого пула и кода (движок/глоссарий/тесты) убран. Возрождение — заново подключить `clairvoyance` (топ-карта во view) + иконку.

## Промпты

Актуальные промпты всех 4 героев (BASE + сцена, MJ v7) — в `ART_PROMPTS.md` (раздел ГЕРОИ),
единый источник. Сохранять в `client-godot/art/<id>.png`, размер `1024×1024`.

Особое: **Эреб «Затмение»** переведён в **чёрно-белый монохром-затмение** (молодой дерзкий
силуэт, дымка), а не цветной. **Кьяра «Линза»** (`hero_lens.png`, `clairvoyance`) — отложенный
кандидат, арт сохранён.

## Иконки абилок

Одноцветные белые SVG 24×24, тонируются клиентом (как ключевик-иконки). Уже созданы:
- `prism.svg` — треугольная призма с входящим лучом и веером преломлённых лучей.
- `eclipse.svg` — корона-кольцо вокруг затемнённого диска.
- `lens.svg` — выпуклая линза, фокусирующая луч в точку.
