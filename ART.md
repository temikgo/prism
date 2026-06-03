# Prisma — арт-пайплайн

> **Душа арта — живой свет.** Мир Призмы целиком сделан из света и являет себя светом.
> Наш визуальный язык **выводится из физики света** (свечение, силуэт, преломление, луч,
> каустика), а НЕ заимствуется у других игр. Урок (дорого осознанный): обобщённые
> «HS / Clash / Valorant»-стили поверх обычных фэнтези-субъектов выходят **бездушными** —
> свет в них становится косметикой, а должен быть **сутью**. Так же чужероден миру субъект-машина
> (был «железный бур») — субъекты должны быть существами/явлениями света.

## Система: что зафиксировано, что варьируется

Промпт собирается из **фиксированных** компонентов (это и есть единый дом-стиль, его не крутим)
плюс единственной **переменной** — субъекта:

- **STYLE / DETAIL / LIGHT / FORMAT / PALETTE — заперты** в BASE ниже.
- **SUBJECT (поле `art` карты) — варьируется.** Здесь живёт всё разнообразие: разные силуэты,
  позы, существа и явления — чтобы карты не были похожи друг на друга.

Сборка: `{BASE с подставленными {COLOR} и {ACCENT}} Subject: {поле art карты}.`

## Стиль «существа из живого света» — BASE (фиксированный)

> Stylized art for Prisma, a world where everything is made of and revealed by living light. A
> single being or phenomenon shaped from **{COLOR}** ray-light: a bold, clean, readable silhouette
> glowing from within — a translucent luminous body, a few bright internal light-lines and a
> glowing core or eyes, soft volumetric glow with a crisp rim, set against deep darkness so the
> light reads. Simplified, few large shapes, no busy detail, no realistic flesh, metal or texture
> — it is light given form. {COLOR} dominant with **{ACCENT}** complementary glints, strong
> contrast of glow against dark. A distinct silhouette and pose for each card so cards never look
> alike. Vertical 2:3 portrait, single subject filling the frame, simple dark atmospheric
> background. No text, no card frame, no border, no UI.

## Цвет → комплементарный акцент

| Цвет | {COLOR} | {ACCENT} |
|---|---|---|
| 🔴 | red | cool teal |
| 🟡 | yellow | cool blue and violet |
| 🟢 | green | warm magenta and amber |
| 🔵 | blue | warm orange and amber |
| 🟣 | violet | gold and lime-green |
| ⚪ | (rainbow/full-spectrum) | balanced palette, no single accent |

⚪ нейтральный — особый: вместо «{COLOR} ray-light» → `unsplit white / full-spectrum light, a soft
prismatic rainbow glow; balanced, no single ray`.

## Субъекты — только из мира света (правило)

Субъект карты — **существо или явление света**, а не фэнтези-машина или обычное животное.
Механику переводим в **световую метафору** по лучу (идентичности — из `EFFECTS.md`):

- 🔴 **Красный (Алый луч)** — проникающий, неотвратимый, самозалечивающийся: копья/кометы/лучи, что буравят насквозь и не гаснут.
- 🟡 **Жёлтый (Сияние)** — слепит и являет: маяки, вспышки, прожекторы, щиты и нимбы света.
- 🟢 **Зелёный (Рост)** — свет в жизнь: ростки, кроны, споры и лозы из света, живые лучи.
- 🔵 **Синий (Линза)** — разум, время, холод: линзы, часы, иней-свет, отложенные лучи.
- 🟣 **Фиолетовый (Преломление)** — незримый, преломлённый: тени-света, иллюзии, отражения, скрытые лучи.
- ⚪ **Нейтральный** — нерасщеплённый белый/полный спектр: радужное мерцание.

Это связывает **арт и концепт карты**: новые карты придумываем как существа/явления света, а не
«дракон с дрелью».

## Родственный вариант — витраж/преломление

«Витражный» стиль: субъект собран из плоских цветных сегментов с тёмными швами (преломлённый
свет, калейдоскоп). Тоже световой и очень тематичный, и при этом проще. Держим как **акцентный
вариант** — кандидат для заклинаний/аур/особых карт (отдельный мини-BASE добавим, когда решим,
где именно применять).

## Формат и сохранение

- **Карты — вертикальный портрет 2:3** (в ChatGPT/gpt-image размер `1024×1536`).
- **Герои — квадрат 1:1** (`1024×1024`), см. `ART_HEROES.md`.
- Файл: `client-godot/art/<id>.png` (имя = `id` карты). После добавления PNG один раз импортнуть:
  `Godot --headless --path client-godot --import`.

## Пример (🔴 «Неугасимый бур» → переосмыслен как свет)

Старый субъект (железный бур) — чужероден миру. Новый, световой:
> {BASE: COLOR=red, ACCENT=cool teal} Subject: a relentless lance-comet of red light boring
> forward — a sleek elongated being of red ray-light with a spiralling luminous tip, trailing
> embers that never fade, a sharp glowing point, fierce forward motion.

Под каждую карту меняется только `Subject:` (= поле `art`); BASE/таблица — неизменны.

## Отложено на потом (не сейчас)

Чистый **постер-силуэт** (плоский чёрный силуэт + свечение, минимал) — стиль очень нравится, но
для основного карт-арта слишком скуп (не читается «кто это»). **Откладываем** как кандидат под
особое применение (сплэш-экраны, промо, заставки).
