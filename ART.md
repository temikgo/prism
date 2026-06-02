# Prisma — арт-пайплайн

Единство держит фиксированный **BASE**-промпт; уникальность — поле `art` карты (сцена) +
цвет и его комплементарный акцент. Сборка:

```
{BASE с подставленными {COLOR} и {ACCENT}} Scene: {art карты}.
```

## Решено

- Стиль — **полированный card-art уровня Hearthstone** (умеренная деталь, чисто, читаемо),
  форма из **нескольких крупных граней на гладких светящихся поверхностях** —
  **без мелких кристаллов-«чешуи»**, без «дешёвого шума».
- **НЕ монохром.** Существо светится своим цветом (идентичность карты), но палитра богатая:
  **комплементарные акценты**, нейтральные тёмные/светлые тона, чистый контраст. Фон —
  **простой, атмосферный, размытый**, с лёгкой глубиной.
- Язык промпта — **English**; формат — **портрет**; поле `art` — English.
- Без текста и рамки — рамку/числа рисует клиент (DESIGN §9).
- **Куда сохранять:** `art/<id>.png` (имя файла = `id` карты).

## BASE (фиксированный)

> Card game art for Prisma. Polished stylized fantasy card-art like a Hearthstone
> illustration, clean and readable, intentional shapes and lighting, not noisy. A subject
> of glowing crystal light, a few bold large facets and smooth luminous surfaces, no tiny
> crystal scales. The subject glows **{COLOR}** so the card reads {COLOR}, but the overall
> palette is rich and cinematic, NOT monochrome: complementary **{ACCENT}** accents,
> neutral dark and light tones, strong clean contrast. Simple atmospheric blurred
> background with soft depth. Vertical portrait, single subject filling most of the frame.
> No text, no card frame, no border.

## Цвет → комплементарный акцент

| Цвет | {COLOR} | {ACCENT} |
|---|---|---|
| 🔴 | red | cool teal |
| 🟡 | yellow | cool blue and violet |
| 🟢 | green | warm magenta and amber |
| 🔵 | blue | warm orange and amber |
| 🟣 | violet | gold and lime-green |
| ⚪ | (rainbow/full-spectrum) | balanced palette, no single accent |

⚪ нейтральный — особый: вместо «glows {COLOR}» → `shimmers with a soft prismatic rainbow
so the card reads as neutral full-spectrum; balanced rich palette, not monochrome`.

## Пример (🔴 «Неугасимый бур»)

> {BASE: COLOR=red, ACCENT=cool teal} Scene: dynamic close-up of a crimson crystal-light
> drill-creature's head and shoulders, fierce expression, strong silhouette.

Под каждую карту меняются `{COLOR}`, `{ACCENT}` (из таблицы) и `Scene:` (= поле `art`).
