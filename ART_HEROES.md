# Prisma — арт героев (художники Призма-Арены)

Дополняет `ART.md` (арт карт). Герои — это **художники-дуэлянты**, что сражаются светом
на Призма-Арене (Испытание Мастерства). Каждый герой = **портрет** + **пассивная сила**
(подробности в `DESIGN.md §6`) + **иконка абилки**.

Чем отличается от арта карт:
- **Это персонаж** (человек/сущность — сам художник), а не существо-кристалл.
  Поэтому базовый промпт другой: портрет дуэлянта, а не «subject of crystal light».
- **Герой не привязан к лучу** (отдельная ось от цветов колоды). Поэтому у каждого —
  своя **сигнатурная палитра и мотив**, а не цвет карты. Это «внецветные» образы:
  спектр целиком, тень, ясность.
- **Пока 1 статичный арт** на героя (без вариаций/анимаций — это пост-MVP).

## Куда сохранять

- **Портрет:** `client-godot/art/<heroId>.png`, где `heroId` = `id` дефа героя
  (`hero_prism`, `hero_eclipse`, `hero_lens`). Клиент читает как `res://art/<heroId>.png`.
- **Иконка абилки:** `client-godot/icons/<name>.svg` — одноцветный белый SVG 24×24
  (как `leaf.svg`/`halo.svg`); клиент тонирует его под нужный цвет через `Ui.icon`.
- После добавления PNG один раз заимпортить:
  `Godot --headless --path client-godot --import` (SVG-иконки — так же).

## HERO-BASE (фиксированный)

> Character art for Prisma, a hero portrait of a duelist of the Prisma Arena. Polished
> stylized fantasy hero portrait like a Hearthstone hero, clean and readable, intentional
> shapes and lighting, not noisy. A humanoid artist-duelist who paints and fights with
> living light — a striking face and a confident pose, head-and-shoulders to waist. Their
> signature is **{MOTIF}**, and they are lit in **{PALETTE}**. Rich cinematic palette,
> neutral dark and light tones, strong clean contrast, NOT monochrome. Simple atmospheric
> blurred arena background with soft depth and a faint hint of a great prism. Vertical
> portrait, single figure filling most of the frame. No text, no card frame, no border,
> no UI.

Сборка под героя: подставить `{MOTIF}` и `{PALETTE}` из таблицы и добавить `Scene:`.

## Герои

Отображаемое имя героя — **одно слово** (личное имя художника); мантия («Призма» и т.п.) —
лор, не часть имени.

| id | Имя | Мантия | Сила (пассив) | Иконка |
|---|---|---|---|---|
| `hero_prism` | **Ирида** | Призма | Спектральный сдвиг — раз в ход 1 кристалл тратится как соседний по спектру цвет | `prism.svg` |
| `hero_eclipse` | **Эреб** | Затмение | Полумрак — существа, бьющие твоего героя, наносят на 1 меньше | `eclipse.svg` |
| `hero_lens` | **Кьяра** | Линза | Прозрение — ты всегда видишь верхнюю карту своей колоды | `lens.svg` |

### 🔱 Ирида «Призма» — `hero_prism`
- **{MOTIF}:** a triangular glass prism splitting a single beam into a full rainbow fan.
- **{PALETTE}:** balanced full-spectrum prismatic rainbow light, neutral (no single ray).
- **Scene:** Iris, a poised duelist-painter, raises a faceted glass prism; a beam of white
  light enters and arcs out of it as a rainbow fan sweeping across her, her brush trailing
  refracted color.

### 🌑 Эреб «Затмение» — `hero_eclipse`
- **{MOTIF}:** a dark eclipse disc ringed by a thin bright corona, shadow pooling.
- **{PALETTE}:** deep shadow blacks and cold blue-violet, with a thin gold corona rim-light.
- **Scene:** Erebus, half-swallowed in shadow, haloed by the bright corona of a total
  eclipse; darkness drips from his brush as he paints with absence of light.

### 🔍 Кьяра «Линза» — `hero_lens`
- **{MOTIF}:** a great convex glass lens focusing light to one bright point.
- **{PALETTE}:** clear cool glassy whites and pale blue, a sharp gold focal glint (clarity).
- **Scene:** Chiara gazes through a great convex lens; a beam focuses to a single brilliant
  point, faint shimmering after-images of what is to come hovering at the edges.

## Готовые промпты (BASE + Scene собраны)

Скопировать целиком в генератор; результат сохранить в `client-godot/art/<id>.png`.

**Пропорция:** **квадрат 1:1** — в ChatGPT/gpt-image выбрать размер **`1024×1024`** (дефолт).
Клиент показывает героя квадратом, так что квадратный исходник кадрируется минимально; лицо/торс
держать по центру кадра.

**`hero_prism.png` — Ирида «Призма»:**

> Character art for Prisma, a hero portrait of a duelist of the Prisma Arena. Polished
> stylized fantasy hero portrait like a Hearthstone hero, clean and readable, intentional
> shapes and lighting, not noisy. A humanoid artist-duelist who paints and fights with
> living light — a striking face and a confident pose, head-and-shoulders to waist. Their
> signature is a triangular glass prism splitting a single beam into a full rainbow fan, and
> they are lit in balanced full-spectrum prismatic rainbow light, neutral with no single ray.
> Rich cinematic palette, neutral dark and light tones, strong clean contrast, NOT
> monochrome. Simple atmospheric blurred arena background with soft depth and a faint hint of
> a great prism. Square 1:1 composition, a single centered figure filling most of the frame. No text, no card
> frame, no border, no UI. Scene: Iris, a poised duelist-painter, raises a faceted glass
> prism; a beam of white light enters and arcs out of it as a rainbow fan sweeping across
> her, her brush trailing refracted color.

**`hero_eclipse.png` — Эреб «Затмение»:**

> Character art for Prisma, a hero portrait of a duelist of the Prisma Arena. Polished
> stylized fantasy hero portrait like a Hearthstone hero, clean and readable, intentional
> shapes and lighting, not noisy. A humanoid artist-duelist who paints and fights with
> living light — a striking face and a confident pose, head-and-shoulders to waist. Their
> signature is a dark eclipse disc ringed by a thin bright corona with shadow pooling, and
> they are lit in deep shadow blacks and cold blue-violet with a thin gold corona rim-light.
> Rich cinematic palette, neutral dark and light tones, strong clean contrast, NOT
> monochrome. Simple atmospheric blurred arena background with soft depth and a faint hint of
> a great prism. Square 1:1 composition, a single centered figure filling most of the frame. No text, no card
> frame, no border, no UI. Scene: Erebus, half-swallowed in shadow, haloed by the bright
> corona of a total eclipse; darkness drips from his brush as he paints with the absence of
> light.

**`hero_lens.png` — Кьяра «Линза»:**

> Character art for Prisma, a hero portrait of a duelist of the Prisma Arena. Polished
> stylized fantasy hero portrait like a Hearthstone hero, clean and readable, intentional
> shapes and lighting, not noisy. A humanoid artist-duelist who paints and fights with
> living light — a striking face and a confident pose, head-and-shoulders to waist. Their
> signature is a great convex glass lens focusing light to one bright point, and they are lit
> in clear cool glassy whites and pale blue with a sharp gold focal glint of clarity. Rich
> cinematic palette, neutral dark and light tones, strong clean contrast, NOT monochrome.
> Simple atmospheric blurred arena background with soft depth and a faint hint of a great
> prism. Square 1:1 composition, a single centered figure filling most of the frame. No text, no card frame,
> no border, no UI. Scene: Chiara gazes through a great convex lens; a beam focuses to a
> single brilliant point, faint shimmering after-images of what is to come hovering at the
> edges.

## Иконки абилок

Одноцветные белые SVG 24×24, тонируются клиентом (как ключевик-иконки). Уже созданы:
- `prism.svg` — треугольная призма с входящим лучом и веером преломлённых лучей.
- `eclipse.svg` — корона-кольцо вокруг затемнённого диска.
- `lens.svg` — выпуклая линза, фокусирующая луч в точку.
