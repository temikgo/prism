# Prism — карта репозитория (читать ПЕРВЫМ)

Самодостаточный справочник: дерево, поток данных, карты модулей движка и
клиента, контракт протокола, каталог ключевиков/эффектов и кукбук «где менять
X». Цель — найти любой модуль/действие/ключевик и точку правки без grep-разведки.
Сопутствующие доки: `BACKLOG.md` (что делаем/решили), `DESIGN.md` (правила игры),
`EFFECTS.md` (каталог ключевиков), `REFACTOR.md` (целевая архитектура клиента).

---

## A1. Дерево репозитория

```
engine/                 C++-движок правил (детерминированный, без сети/IO)
  include/prism/         публичные заголовки: types / card / game / protocol
  src/                   card.cpp · game.cpp · protocol.cpp
  tests/tests.cpp        doctest, 83 теста
  third_party/json.hpp   nlohmann::json (vendored)
server/                  WebSocket-менеджер комнат (C++), линкует движок
  src/main.cpp           лобби (комнаты по коду) + проброс действий в Game
  src/ws.hpp             минимальный websocket-фрейминг
  test_ws_smoke.py       смоук лобби/матча
client-godot/            Godot-4.3 клиент (GDScript)
  *.gd                   ~35 модулей (см. A4)
  cards.json             синхрон-КОПИЯ cards/sample.json (данные карт)
  App.tscn / Main.tscn   корень-роутер / сцена матча
  icons/ fonts/ art/     SVG-иконки, шрифты, арты карт/героев/UI
cards/sample.json        МАСТЕР-данные карт (69: 52 creature, 11 spell, 4 hero, 2 aura)
tools/                   balance.py (кривая стоимости) · build_prompts.py (арт-промпты)
                         · run_client.sh (импорт+запуск Godot)
*.md                     DESIGN (правила) · EFFECTS (ключевики) · ART/ART_PROMPTS/
                         ART_HEROES (арт) · APP_SHELL (экраны/лобби) · REFACTOR
                         (план клиента) · BACKLOG (задачи) · README (сборка/запуск)
```

`cards/sample.json` и `client-godot/cards.json` обязаны быть **идентичны** (движок
грузит первый, клиент — второй). Менять оба синхронно.

---

## A2. Поток данных (с именами функций)

Действие игрока (клик/дроп) → строится JSON-действие в `Main.gd` →

1. `Main._send(obj)` → `Router._send` → `Net.send(obj)` (WebSocket text-frame).
2. Сервер `handleText` (`server/src/main.cpp`): лобби-команды (`createRoom`/
   `joinRoom`/`leaveRoom`) → `handleLobby`; иначе игровое действие →
   `applyAction(*room.game, seat, payload)`.
3. `applyAction(Game&, actor, json)` (`protocol.cpp`): диспетчер по полю
   `action` → методы `Game` (`game.cpp`): `playCard`/`awaken`/`placeCardToMana`/
   `attackCreature`/`attackHero`/`endTurn`/`mulligan`/`resolveScry`/`activate`.
4. Сервер `broadcastRoom`: `viewJson(game, 0)` и `viewJson(game, 1)` —
   **редактированный под каждого игрока** вид (скрыты рука и не-awaken карты
   в мана-ряду соперника; floodlight/facet открывают часть) → шлёт каждому сокету.
5. Клиент: `Net._process` принимает кадр → `Router._on_message(data)` →
   если есть `type` (лобби) обрабатывает там; иначе (это view) → `Main.feed_view(view)`.
6. `Main.feed_view` → `_ingest_view`: считает `GameState.diff` (что изменилось по
   hp/составу) и `_diff_hero_hp` (урон по героям) → `_rebuild()` (полная пересборка
   борда) → `Fx`-анимации через `_animate_changes(dmg, summoned, hero_dmg)`.

Однонаправленно: клиент только шлёт действия и рисует присланный view; вся
правда — в движке. Локального предсказания нет.

---

## A3. Движок — карта модулей

### `types.hpp` — примитивы
`Color` (Red/Yellow/Green/Blue/Violet/Colorless), `ColorCount`, `colorName`/
`colorFromString`/`idx`. `Cost{pips[ColorCount], generic}`. `Stats{atk,hp}`.
`ManaPool{crystals[], available[]}` с методами:
- `addCrystal(color)`, `canPay(cost)`, `pay(cost)` — жадная оплата generic;
- `pay(cost, genericPay)` — оплата с **явной раскладкой** generic по цветам
  (игрок выбрал, какие кристаллы тратить; проверяет точную сумму).
**Расширять:** новый цвет → enum + `colorName`/`colorFromString` + `ColorCount`.

### `card.hpp` / `card.cpp` — статические данные карт
`KeywordRef{id, optional<int> n}`, `EffectDef{trigger, selector, action, value,
required}`, `CardDef{id, nameRu, textRu, art, type, colors, cost, stats,
keywords[], effects[]}` + хелперы `keyword/hasKeyword/keywordN`. `CardLibrary`
грузит JSON (`loadFile`/`loadJsonString`), отдаёт стабильные `const CardDef*`.
`EffectDef.required`: целевой эффект по умолчанию **необязателен** (нет цели →
пропуск, карта играется); `required:true` — цель обязательна (эффект-цена, напр.
«пожертвуй своё существо»). **Расширять:** новое поле карты → структура + парс в
`card.cpp`.

### `game.hpp` / `game.cpp` — состояние и легальные действия
Рантайм-состояние: `Player{hero, heroHp, heroArmor, mana, manaRow, hand, deck,
board, graveyard, auras, pending, ...}`, `Creature` (рантайм-инстанс с
atk/hp/maxHp/sick/frozenTurns/blindTurns/shield/warded/stealthed/token...),
`Game` владеет двумя `Player` + библиотекой.

Ключевые методы (по группам):
- **Жизненный цикл хода:** `start`/`startTurn` (рефилл маны, снятие усталости,
  старт-триггеры, добор) / `endTurn` / `applyTurnStartTriggers` (regen, growth,
  photosynthesis) / `processDelayed` (синие delay-эффекты) / `tickStatuses`
  (декремент freeze/blind) / `checkDeaths` (трупы в кладбище).
- **Розыгрыш:** `playCard(handIndex, target, pos, genericPay?)` →
  `playTargetLegal` (валидна ли цель: 0+optional пропускает, 0+required блокирует,
  заданная цель должна быть валидной — защита от стелса) → `playResolved` →
  `resolveOnPlay` → `executeAction`. `awaken(manaRowIndex,...)` — разбудить
  карту из мана-ряда. `placeCardToMana(handIndex, color)` — забанковать карту.
  `activate(id)` — активная способность существа.
- **Бой:** `attackCreature(attacker, target)` / `attackHero(attacker)` (учёт
  provoke через `enemyHasProvoke`, pierce/bypass/self_lifesteal, ward, stealth),
  `dealHeroDamage` (сначала броня, потом hp), `damageCreature`, `absorbWard`.
- **Эффекты/контину:** `executeAction(EffectDef, owner, target, src)` —
  диспетчер инлайн-экшенов (см. A6), `applyLingering`, `recomputeContinuous`
  (ауры/chill пересчитывают статы), `hasAura`, `summonToken`, `makeMirage`
  (иллюзия-копия), `bounceCreature`, `buffStats`, `healCreature`.
- **Скай/мулиган:** `mulligan`, `resolveScry`/`startScry`/`scryPeek`.
- **События:** `emit`/`processEvents`/`reactTo` (Died → spores/haunt-реакции).

**Селекторы цели** (`findSelected`): `chosen_friendly_minion` /
`chosen_any_minion` / `chosen_enemy_minion`(дефолт) / `enemy_hero`.

### `protocol.hpp` / `protocol.cpp` — мост JSON ↔ движок
`applyAction(Game&, actor, actionJson)` — парсит действие, гейтит «только
активный игрок» (кроме мулигана), вызывает метод `Game`. `viewJson(Game&, you)`
— сериализует редактированный вид (см. A5). **Расширять:** новое действие →
ветка в `applyAction`; новое поле view → `creatureJson`/`playerJson`/`viewJson`.

---

## A4. Клиент — карта модулей

Соглашения: «чистый» = не читает глобальное состояние, только аргументы;
«билдер» = статические функции, строят `Control` из данных; «глобал» =
автозагрузка/синглтон-стиль через `class_name`.

### Координатор матча — `Main.gd` (~840 стр., см. под-карту ниже)
Координатор сцены матча: хранит `view`, владеет персистентными слоями
(`BoardLayer`×2, `HandRow`), на каждый view пересобирает борд из модулей-виджетов
и гоняет play-флоу/анимации. Сборку рисуют вынесенные виджеты (`BoardRow`,
`HeroMedallion`, `PilesColumn`, оверлеи); легальность — `Rules`; данные карт —
`CardData`. Виджеты эмитят **намерения** (attack/cast/play/awaken), Main их
маршрутизирует в сеть/Fx. (Разнос — Фаза D плана, выполнена.)

**Под-карта `Main.gd` по секциям:**
- *Каркас/топбар:* `_ready` `_load_cards` `_build_shell` `_build_topbar`
  `_reposition_end_btn` (кнопка хода закреплена у низа вьюпорта) `_on_window_resized`
  `_process` `_update_board_gap`/`_remove_board_gap`.
- *Координатор:* `bind(sender)` `feed_view` `set_status` `_send` `_ingest_view`
  `_diff_hero_hp` `_animate_changes` `_animate_piles` `_attack_creature`/
  `_attack_hero` `_node_center`/`_creature_node`/`_take_creature`.
- *View-запросы (тонкие делегаты в `Rules`/`CardData`):* `_my_turn`
  `_can_place_mana` `_is_playable` `_has_legal_target` `_enemy_has_provoke`
  `_valid_attack_target` `_can_play_here`/`_can_cast_on` `_generic_choices` и т.п.
- *Сборка борда (тонкие врапперы над виджетами):* `_rebuild` (полная пересборка)
  `_player_half` `_hero_medallion`(→`HeroMedallion`) `_piles_column`(→`PilesColumn`)
  `_board_row`(→`BoardRow`) `_ensure_layer` (владеет `BoardLayer`×2)
  `_hand_row`/`_make_hand_card`/`_refresh_hand_card` `_make_card`(→`CardView.widget`)
  `_banner` `_separator` `_controls`.
- *Play-флоу:* `_play_payload` `_spell_cast_fx` `_play_at_drop` `_dispatch_play`
  (→ confirm потери эффекта → мана-пикер → send) `_dispatch_play_mana`
  `_confirm_lost_effect` `_drop_insert_index` `_place_mana` `_show_color_picker`/
  `_close_picker` `_on_hand_double` `_on_awaken_clicked`.
- *Оверлеи (роутинг в `_rebuild`):* монтирует `MulliganPanel`/`ScryPanel`/
  `GameOverPanel`; держит выбор (`_mull_sel`/`_scry_sel`), хендлеры
  `_toggle_mulligan`/`_send_mulligan`/`_toggle_scry`/`_send_scry`.

### Оболочка и сеть
- `Router` (`router.gd`) — корень `App.tscn`: переключает экраны (`_go_*`),
  держит общий `Backdrop`, коннект/реконнект (`_connect`/`_on_message`/`_on_close`),
  настройки (`_load_settings`/`_save_settings`). `_on_message`: `type` → лобби,
  иначе → `feed_view` активного матча.
- `Net` (`net.gd`) — тонкая обёртка `WebSocketPeer`: `connect_to`/`is_open`/
  `send`/`_process` (эмитит `message`/`opened`/`closed`).

### Экраны (каждый — `Control` с `class_name`)
`MainMenu` (меню+лого), `PlayMenu`, `CreateRoom`, `JoinRoom` (`show_error`),
`RoomWait`, `LoadoutSelect` (выбор героя/колоды), `SettingsScreen` (URL сервера).

### Чистые модули данных/логики
- `CardData` (`cards_data.gd`) — статика над `cards.json`: `load_file` `def`
  `name_of`/`text_of` `is_creature`/`is_spell` `heroes`/`deck_cards`
  `target_side`/`needs_target`/`target_required`/`targeted_effect_texts`
  `has_keyword`/`keyword_n` `total_cost`/`can_afford`/`can_afford_with_shift`
  `display_id`.
- `Rules` (`rules.gd`) — **чистая легальность** над `view` (компаньон `CardData`):
  `my_turn`/`can_place_mana`/`is_playable`/`has_legal_target`/`enemy_has_provoke`/
  `valid_attack_target`/`can_play_here`/`can_cast_on`/`can_awaken`/`generic_choices`.
  Зовётся и из `Main`, и из виджетов (без обращения к координатору).
- `GameState` (`game_state.gd`) — `diff(prev_hp, new_view)` (что изменилось),
  `departed(prev, new)` (ушедшие существа).
- `Glossary` (`glossary.gd`) — генерация ТЕКСТА правил из keywords+effects:
  `keyword`/`keyword_name`/`effect_text`/`status_lines`/`type_label`. **Источник
  истины для текста карт — здесь, руками текст не пишем.**
- `Decks` (`decks.gd`) — предустановленные колоды/лоадауты.

### Билдеры представления (статические `Control`-фабрики)
- `CardView` (`card_view.gd`) — лицо карты `face`, тултип `tooltip`, интерактивный
  виджет `widget` (UiCard: face+glow+tooltip+drag-preview — основа руки/пикеров),
  бейджи стоимости/статусов, рамка по типу (`_frame_texture`).
- `HeroView` (`hero_view.gd`) — портрет+hp `portrait_with_hp`, бейдж/тултип пассивки.
- `Chrome` (`chrome.gd`) — баннер хода, мана-блок/пипсы, стопки колоды/кладбища.
- `Ui` (`ui.gd`) — атомы: `label` `glass`/`bordered` (StyleBox) `neon_button`
  `icon` `mana_pip`/`cost_pip`.
- `Tokens` (`tokens.gd`) — `gem` (кристалл-токен `GemNode`), `art` (текстура
  карты), `round_style`, `soft_dot`.
- `Palette` (`palette.gd`) — единственный источник цветов (jewel-тона 5 цветов +
  colorless). `Fonts` (`fonts.gd`) — шкала шрифтов.

### Виджеты-секции борда (строятся из `view`, эмитят намерения вверх)
Транзитные (пересоздаются каждый `_rebuild`), кроме персистентных слоёв, которые
им передаёт `Main`. Запросы — через `Rules`/`CardData`; наружу — сигналы-намерения.
- `BoardRow` (`board_row.gd`, `extends UiCard`) — боевая полоса одной стороны:
  drop-зона + полка аур + существа в переданном `BoardLayer` + ability-док. Сигналы
  `play_requested`/`cast_requested`/`attack_requested`/`activate_requested`. Хуки
  карточек существ **перепривязываются в `_refresh_creature`** каждый ребилд (узлы
  персистентны и переживают транзитный `BoardRow` — иначе замыкание зависнет).
- `HeroMedallion` (`hero_medallion.gd`, `extends UiCard`) — портрет героя + HP/броня
  + пассивка; вражеский — drop-цель атаки в лицо, сигнал `attack_hero_requested`.
- `PilesColumn` (`piles_column.gd`) — правый фланг: мана (height-capped скролл,
  `cap_h`), awaken-чипы / прожектор-превью, стопки колода/сброс, счётчик руки.
  Сигнал `awaken_clicked`; отдаёт `mana_node`/`deck_node`/`grave_node` для пульса.
- Оверлеи матча (`extends Control`, `setup()` до `add_child`): `MulliganPanel`
  (`mulligan_panel.gd`) и `ScryPanel` (`scry_panel.gd`) — сигналы `toggle(index)`/
  `submit` (выбор хранит `Main`); `GameOverPanel` (`game_over_panel.gd`) — `to_menu`.

### Виджеты и слои
- `UiCard` (`ui_card.gd`) — **единственный интерактивный виджет**: драг/дроп/ховер
  через колбэки `can_drop_fn`/`drop_fn`/`highlight_check`/`preview_builder`/
  `tooltip_builder`; статика `active_drag`/`aim_from` для подсветки целей и
  стрелки атаки; `_show_hl_frame`/`_hide_hl_frame` (золотая рамка валидной цели).
- `BoardLayer` (`board_layer.gd`) / `HandRow` (`hand_row.gd`) — узловые модели
  существ/руки, keyed by id (основа для инкрементального апдейта, Фаза D).
- `AbilityButton` (`ability_button.gd`) — кнопка активной способности.
- `Fx` (`fx.gd`) / `FxLayer` (`fx_layer.gd`) — анимации (урон, summon-pulse,
  ready_pulse, полёт спелла); твины биндятся к узлу (`node.create_tween()`).
- `Backdrop` (`backdrop.gd`) — общий фон (энергетический шейдер + мошки), один на
  всё приложение, не ре-сидится при роутинге.

### Оверлеи (модальные)
`ManaPicker` (radial выбор цвета при бэнке), `ManaSpendPicker` (`mana_spend.gd` —
тап-выбор какие кристаллы потратить на generic), `RadialPicker` (общий радиальный),
`ConfirmDialog` (`confirm_dialog.gd` — `setup(title, lines, yes, no)`).

### Прочее
`GemNode` (`gem.gd`) — процедурный кристалл-токен. `LogoEmblem` (`logo_emblem.gd`)
— процедурный логотип (6 граней = 5 цветов + белый, плоские тени).
`Shot.gd`/`ShotMenu.gd` — дев-стенды для скриншотов (мок-view, без сервера; НЕ
шипятся; моки должны держать живые id из `cards.json`).

---

## A5. Контракт протокола (единый источник по JSON)

### Действия клиент → сервер (поле `action`)
| action | поля | метод движка |
|---|---|---|
| `play` | `handIndex`, `target`(0=нет), `pos`(-1=в конец), `genericPay?`{color→n} | `playCard` |
| `awaken` | `manaRowIndex`, `target`, `pos` | `awaken` |
| `placeMana` | `handIndex`, `color` | `placeCardToMana` |
| `activate` | `id` | `activate` |
| `attackCreature` | `attacker`, `target` | `attackCreature` |
| `attackHero` | `attacker` | `attackHero` |
| `endTurn` | — | `endTurn` |
| `mulligan` | `indices`[] | `mulligan` |
| `scryResolve` | `bottom`[] (в низ колоды) | `resolveScry` |
| Лобби | `createRoom`{password, hero?, deck?[]} · `joinRoom`{code, password, hero?, deck?[]} · `leaveRoom` | server `handleLobby` |

`genericPay` — необязательная раскладка generic-части стоимости по цветам
(`{"green":1,"blue":1}`); отсутствует → движок платит generic жадно.

### Сообщения сервер → клиент
- С полем `type`: `roomCreated`{code} · `joinError`{reason: bad_password/no_room/
  room_full} · `matchStart` · `opponentLeft`. Роутятся в `Router._on_message`.
- **Без `type`** = редактированный view матча (см. ниже) → `Main.feed_view`.

### Схема view (`viewJson(g, you)`)
```
turn, current, you, mulligan, over, winner,
scry?            // массив id, только если ждём scry этого игрока
players[2]:
  hero{ hp, armor, card, name, passive[]{id,n?} }       // герой публичен обоим
  mana{ crystals{color→n}, available{color→n} }
  manaRow[]{ color, card?, age? }   // card только для своих awaken-карт,
                                    // либо facet/floodlight раскрывают; age — своё
  hand[]            // только своя рука (у соперника — лишь handCount)
  handCount, heroPowerUsed?, placedMana?, deckCount, graveyardCount,
  pendingCount, mulliganDone
  board[]{ id, card, atk, hp, maxHp, sick, attacked, usedActive,
           frozen, blind, shield, ward, stealth, token }
  auras[]{ card }
```
Приватные поля (`hand`, `heroPowerUsed`, `placedMana`, `age`) — только при
`self`. Идентичности банкнутых карт соперника скрыты, кроме awaken/facet/floodlight.

---

## A6. Каталог ключевиков/эффектов → точки кода

**Инлайн-экшены** (`EffectDef.action`, диспетчер `Game::executeAction`,
текст в `Glossary.effect_text`):

| action | где в движке (`executeAction`) | селекторы/заметки |
|---|---|---|
| `damage` | урон цели или `enemy_hero` | через `applyLingering`/`dealHeroDamage` |
| `damage_all` | урон всем существам обеих сторон | — |
| `destroy` | hp=0, добивает `checkDeaths` | сквозь ward не идёт (absorbWard) |
| `freeze` | `frozenTurns = value` | ward поглощает |
| `blind` | `blindTurns = value` | ward поглощает |
| `flash` | blind всем существам соперника | — |
| `draw` | `draw(owner, value)` | — |
| `scry` | `startScry(owner, value)` | открывает оверлей scry |
| `scatter` | вернуть существо в руку (bounce) | любая сторона; ward поглощает |
| `mirage` | иллюзия-копия цели | — |
| `add_crystal` | добавить colorless-кристалл(ы) | реализован; в текущем сете карт не используется (задел) |

**Ключевики существ** (`KeywordRef.id`; проверка в движке `hasKeyword`/`keywordN`;
текст `Glossary.KW`; иконка в `client-godot/icons/`). Используются картами в сете
(22): `pierce`, `bypass`, `provoke`, `stealth`, `shield`, `ward`,
`self_lifesteal`, `regen`, `growth`, `photosynthesis`, `spores`, `haunt`,
`lingering`, `compost`, `resonance`, `undergrowth`, `split`, `germinate`, `chill`,
`decoy`, `floodlight`, `awaken`. (`germinate` — единственная активная способность:
действие `activate`, призыв ростка N/N за 1 кристалл, раз в ход.) Плюс `delay`
(синие отложенные эффекты: машинерия `processDelayed`/`pending`) — реализован, но
в текущем сете карт не задействован (задел).

**Пассивки героев** (отдельно от ключевиков существ; `game.cpp` + блок heroes в
`sample.json`): `hero_prism`/Ирида → `spectral_shift`; `hero_eclipse`/Эреб →
`lighteater`; `hero_palette`/Тициана → `palette`; `hero_facet`/Гемма → `facet`.
Иконки маппятся в `HeroView._passive_icon`. (`palette`/`facet`/`lighteater`/
`spectral_shift` — это пассивки героев, НЕ ключевики существ.)

**Спроектировано, не реализовано** (кода в `game.cpp` нет; не ссылаться как на
рабочее, см. `BACKLOG.md`): `ambush` (мана-карта авто-вскрывается и вступает в бой
при атаке врага) и `refract` (входящий эффект/атака перенаправляются на случайную
другую цель).

---

## A7. «Где менять X» (кукбук)

1. **Добавить ключевик.** `game.cpp`: вставить проверку `hasKeyword/keywordN` в
   нужную точку (бой → `attackCreature`/`attackHero`; старт хода →
   `applyTurnStartTriggers`; смерть → `reactTo`; контину → `recomputeContinuous`).
   Текст: `Glossary.KW` (+ `keyword_name`). Иконка: `icons/<name>.svg`. Карта в
   обоих json. Тест в `engine/tests/tests.cpp`. Описать в `EFFECTS.md`.
2. **Добавить инлайн-эффект (новый `action`).** Ветка в `Game::executeAction`
   (`game.cpp`). Текст в `Glossary.effect_text`. Использовать в `effects[]` карты
   (оба json). Тест на поведение.
3. **Добавить карту.** Запись в `cards/sample.json` **и** `client-godot/cards.json`
   (поля: `id`, `name.ru`, `text.ru`(flavor), `art`, `type`, `color`[], `cost`
   {generic, <цвет>}, `stats`{atk,hp}, `keywords`[], `effects`[]). Текст правил НЕ
   писать — он генерируется `Glossary` из keywords+effects. Арт: добавить промпт
   через `tools/build_prompts.py`/`ART_PROMPTS.md`, положить png в `art/`. Баланс:
   `python3 tools/balance.py`. Имя — два слова; цвет несёт свойство своего цвета;
   имя↔арт один субъект.
4. **Добавить героя.** Блок heroes в обоих json (`hero_*` + passive-keyword).
   Реализовать пассивку в `game.cpp` (точка зависит от эффекта; примеры:
   `spectral_shift` в розыгрыше, `lighteater` в `attackHero`, `facet` в `awaken`/
   `viewJson`). Иконка пассивки: `icons/` + `HeroView._passive_icon`. Промпт:
   `ART_HEROES.md`.
5. **Добавить действие в протокол.** Ветка в `applyAction` (`protocol.cpp`) →
   новый/существующий метод `Game`. Клиент: собрать JSON в `Main` и `_send`.
   Если меняется view — обновить `playerJson`/`creatureJson` и схему в A5.
6. **Добавить UI-оверлей.** Новый `*.gd` c `class_name` по образцу
   `ConfirmDialog`/`ManaSpendPicker` (модаль + сигнал результата); вызвать из
   соответствующего флоу в `Main`.
7. **Поменять цвет/размер/стиль.** Цвета — только `Palette`. Атомы UI — `Ui`/
   `Tokens`/`Chrome`. Шрифты — `Fonts`. Не хардкодить литералы вне этих модулей.

---

## A8. Конвенции и инварианты

- Текст правил карты **генерируется** из keywords+effects (`Glossary`); руками не
  писать; поле `text.ru` = flavor.
- Имя и арт карты изображают **один субъект**; правишь одно — синхронизируй другое.
- Цветная карта несёт свойство своего цвета (двуцветка ≥2, 5-цветка ≥5 свойств).
- Имена карт — почти всегда из двух слов (RU и EN), без коллизий.
- Без эмодзи/смайликов в UI и игровом тексте — только слова и SVG-иконки.
- `cards/sample.json` ↔ `client-godot/cards.json` держать идентичными.
- Коммиты на английском, без подписи Claude/Co-Authored-By.
- **Комментарии в коде — НУЖНЫ (исключение для Prism):** пояснительные
  комментарии приветствуются; общее правило «без комментариев» сюда НЕ
  распространяется (репо должно быть LLM-friendly).
- Инварианты проверки изменений: движок собирается и `ctest` 83/83 (если трогали
  движок); клиент парсится (`--headless --import`); `Shot.gd`/`ShotMenu.gd`
  рендерятся без `SCRIPT ERROR`.

### Сборка и запуск (шпаргалка)
```
# движок + тесты (ctest = тесты движка + формат-чек)
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build -j && ctest --test-dir build
# сервер (порт + путь к данным карт)
./build/server/prism_server 8080 cards/sample.json
# клиент (импорт + запуск через бандл Godot)
GODOT=client-godot/.godot-bin/Godot_v4.3-stable_linux.x86_64 tools/run_client.sh
# скриншот-стенд
client-godot/.godot-bin/Godot_v4.3-stable_linux.x86_64 --path client-godot -s Shot.gd
```
