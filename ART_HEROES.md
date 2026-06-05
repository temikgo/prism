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

## Готовые промпты (BASE + Scene собраны)

Сохранять в `client-godot/art/<id>.png`, затем импорт Godot. Размер **`1024×1024`** (квадрат).

**`hero_prism.png` — Ирида «Призма»:**
> Stylized hero portrait for Prisma, a world made of and revealed by living light. A humanoid
> duelist-artist of the Prisma Arena, shaped from light: a bold clean readable figure glowing from
> within — a translucent luminous body and a few bright internal light-lines, a glowing core and
> eyes, soft volumetric glow with a crisp rim, set against deep darkness so the light reads. Her
> signature is a faceted glass prism splitting a single beam into a full rainbow fan, lit in
> balanced full-spectrum prismatic rainbow light. Simplified, few large shapes, no busy detail, no
> realistic flesh or metal or texture — light given form. A distinct recognizable silhouette and a
> confident pose. Square 1:1 composition, a single centered figure filling most of the frame,
> simple dark atmospheric background. No text, no card frame, no border, no UI. Scene: Iris raises
> a prism; a beam of white light enters and arcs out of it as a fan of rainbow light sweeping
> across her.

**`hero_eclipse.png` — Эреб «Затмение»:**
> Stylized hero portrait for Prisma, a world made of and revealed by living light. A humanoid
> duelist-artist of the Prisma Arena, shaped from light: a bold clean readable figure glowing from
> within, but mostly drawn in shadow — a dark form rimmed by light, a glowing core and eyes, soft
> volumetric glow against deep darkness. His signature is a dark eclipse disc ringed by a thin
> bright corona, lit in deep shadow with a thin gold corona rim and a cold blue-violet glow.
> Simplified, few large shapes, no busy detail, no realistic flesh or metal or texture — light
> (and its absence) given form. A distinct recognizable silhouette and a confident pose. Square
> 1:1 composition, a single centered figure filling most of the frame, simple dark atmospheric
> background. No text, no card frame, no border, no UI. Scene: Erebus haloed by the bright corona
> of a total eclipse, painting with the absence of light as darkness pools around him.

**`hero_lens.png` — Кьяра «Линза»:**
> Stylized hero portrait for Prisma, a world made of and revealed by living light. A humanoid
> duelist-artist of the Prisma Arena, shaped from light: a bold clean readable figure glowing from
> within — a translucent luminous body and a few bright internal light-lines, a glowing core and
> eyes, soft volumetric glow with a crisp rim, set against deep darkness so the light reads. Her
> signature is a great convex glass lens focusing light to one bright point, lit in clear cool
> glassy whites and pale blue with a sharp gold focal glint. Simplified, few large shapes, no busy
> detail, no realistic flesh or metal or texture — light given form. A distinct recognizable
> silhouette and a calm focused pose. Square 1:1 composition, a single centered figure filling
> most of the frame, simple dark atmospheric background. No text, no card frame, no border, no UI.
> Scene: Chiara gazes through a great lens; a beam focuses to a single brilliant point, faint
> shimmering after-images of what is to come hovering at the edges.

## Иконки абилок

Одноцветные белые SVG 24×24, тонируются клиентом (как ключевик-иконки). Уже созданы:
- `prism.svg` — треугольная призма с входящим лучом и веером преломлённых лучей.
- `eclipse.svg` — корона-кольцо вокруг затемнённого диска.
- `lens.svg` — выпуклая линза, фокусирующая луч в точку.
