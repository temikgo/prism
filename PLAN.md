# Prism — план: максимальная ориентация в репозитории

> Самодостаточный план (переживает компакт; без ссылок на чат). Цель: после
> выполнения я ориентируюсь и проверяю изменения максимально быстро. **Игровое
> поведение не меняем** (кроме явно оговорённого — здесь такого нет). После
> выполнения этот файл **удаляется** (по правилу «устаревшее в md удаляем»), а
> постоянным артефактом остаётся `ARCHITECTURE.md`.
>
> Порядок фаз: **A (карта) → B (чистка) → C (харнес+тесты) → D (инкрементальный
> борд) → E (стретч)**. Обоснование: A сразу даёт мне карту, B убирает шум,
> C даёт сетку безопасности и быструю проверку, D — глубокий архфикс (и он же
> разблокирует безопасный разнос остатка `Main`), E — полировка.
>
> Инварианты на КАЖДОЙ фазе: (1) движок собирается и `ctest` 83/83, если трогали
> движок; (2) клиент парсится (`--headless --import`); (3) `Shot.gd`/`ShotMenu.gd`
> рендерятся без `SCRIPT ERROR`; (4) новые клиентские тесты зелёные; (5) отдельный
> коммит на английском без подписи Claude; (6) CI зелёный; (7) `ARCHITECTURE.md`
> обновлён, если менялась структура.

---

## Фаза A — `ARCHITECTURE.md` (карта репозитория, «читать первым»)

Создать постоянный документ — единственное, что нужно прочитать, чтобы
сориентироваться. Точные разделы и что в каждом:

- **A1. Дерево репозитория.** По строке на каталог: `engine/` (C++-движок правил +
  тесты), `server/` (WebSocket-менеджер комнат), `client-godot/` (Godot-4 клиент),
  `cards/sample.json` (мастер-данные карт; синхрон-копия — `client-godot/cards.json`),
  `tools/` (`balance.py`, `build_prompts.py`, `run_client.sh`), `*.md` (доки —
  перечислить роль каждого: DESIGN/EFFECTS/ART*/APP_SHELL/REFACTOR/BACKLOG).
- **A2. Поток данных (с именами функций).** Действие игрока → `Main._send` →
  `Net.send` → сервер `route` → `applyAction(Game&, actor, json)` (protocol.cpp) →
  методы `Game` (game.cpp) → `viewJson(g, you)` (редактированный вид под игрока) →
  `Net.message` → `Router._on_message` → `Main.feed_view` → `_ingest_view` →
  `GameState.diff` → `_rebuild` + `Fx._animate_changes`. Нарисовать как нумерованную
  цепочку, отметить где «редакция под игрока» (скрытые мана-ряд/рука).
- **A3. Движок — карта модулей.** По файлу: `types.hpp` (Color/Cost/ManaPool/Stats —
  и `ManaPool::pay`/`canPay`/`pay(cost,genericPay)`), `card.hpp/.cpp` (CardDef/
  EffectDef/KeywordRef + загрузка JSON; флаг `EffectDef.required`), `game.hpp/.cpp`
  (Game-состояние и легальные действия: `playCard`/`playTargetLegal`/`executeAction`/
  `resolveOnPlay`/`attackCreature`/`attackHero`/`awaken`/`startTurn`/`checkDeaths`/
  combat/haunt-иллюзии), `protocol.hpp/.cpp` (`applyAction` + `viewJson`). Для каждого —
  «где расширять».
- **A4. Клиент — карта модулей.** По `.gd`-файлу: `class_name`, ответственность,
  **чистота** (читает ли `view`/`cards`/глобалы), ключевые функции. Обязательно
  расписать **секции `Main.gd`** как под-карту (он 1.6k строк): координатор
  (`_ingest_view`/`bind`/`feed_view`/`_animate_changes`), view-запросы (`_my_turn`/
  `_has_legal_target`/`_target_*`/`_valid_attack_target`/`_enemy_has_provoke`/
  `_is_playable`/`_can_afford*`), сборка борда (`_rebuild`/`_player_half`/
  `_hero_medallion`/`_piles_column`/`_board_row`/`_creature_card`/`_hand_row`/
  `_manarow_view`/`_awaken_chip`), play-флоу (`_dispatch_play`/`_play_at_drop`/
  `_play_payload`/`_generic_choices`/`_confirm_lost_effect`), оверлеи (мулиган/скрай/
  гейм-овер), закреплённый UI (`_topbar`/`_end_btn`). Плюс модули: `Router`, экраны
  (`main_menu`/`play_menu`/`create_room`/`join_room`/`room_wait`/`loadout_select`/
  `settings_screen`), `Net`, `GameState`, `CardData`, `CardView`, `HeroView`, `Chrome`,
  `Ui`, `Tokens`, `Palette`, `Gem`/`LogoEmblem`, `Backdrop`, `Fx`/`FxLayer`, `UiCard`,
  `BoardLayer`, `HandRow`, `ManaPicker`, `RadialPicker`, `ManaSpendPicker`,
  `ConfirmDialog`, `Glossary`, `Fonts`, `Decks`.
- **A5. Контракт протокола (единый источник по JSON).** Список **действий** с полями:
  `play{handIndex,target,pos,genericPay?}`, `awaken{manaRowIndex,target,pos}`,
  `placeMana{handIndex,color}`, `attackCreature{attacker,target}`, `attackHero{attacker}`,
  `endTurn`, `mulligan{indices}`, `scryResolve{bottom}`, лобби
  `createRoom`/`joinRoom`/`leaveRoom`. Схема **view**: `turn/current/you/mulligan/over/
  winner/scry?`, `players[2]{hero{hp,armor,card,name,passive[]},mana{crystals,available},
  manaRow[]{color,card?,age?},hand?/handCount,heroPowerUsed?,deckCount,graveyardCount,
  pendingCount,mulliganDone,board[]{id,card,atk,hp,maxHp,sick,attacked,frozen,blind,
  shield,ward,stealth,token,...},auras[]}`. (Свериться с `protocol.cpp::viewJson`.)
- **A6. Каталог ключевиков/эффектов → точки кода (таблица).** Колонки: ключевик/экшен
  · цвет · где в движке (combat / `executeAction`-ветка / `applyTurnStartTriggers` /
  `checkDeaths`-реакции) · где в клиенте (`Glossary.KW` текст + иконка в `icons/` +
  отрисовка в `card_view`). Перечислить все реализованные (red/yellow/green/blue/violet
  ключевики + инлайн-эффекты damage/damage_all/destroy/draw/freeze/blind/flash/scatter/
  scry/dispel/mirage + герои spectral_shift/lighteater/palette/facet). Отметить
  нереализованные `ambush`/`refract`.
- **A7. «Где менять X» (кукбук, по шагам и файлам).** Минимум рецептов:
  (1) добавить ключевик; (2) добавить инлайн-эффект (новый `action`); (3) добавить карту
  (json + арт-промпт + проверка баланса `tools/balance.py`); (4) добавить героя;
  (5) добавить действие в протокол; (6) добавить UI-оверлей; (7) поменять цвет/размер
  (Palette/Tokens). Каждый рецепт — точные файлы/функции по порядку + где тест.
- **A8. Конвенции и инварианты.** Текст правил карты **генерируется** из keywords+effects
  (руками не писать; `text` = flavor); имя↔арт один субъект; цветная карта несёт свойство
  цвета; без эмодзи в UI; имена карт из двух слов; коммиты на английском без подписи.
  **Комментарии в коде — НУЖНЫ (исключение для Prism):** пояснительные комментарии
  приветствуются (общее правило «без комментариев» на этот проект НЕ распространяется).

**Критерий A:** читаю только `ARCHITECTURE.md` и нахожу любой модуль/действие/ключевик и
точку правки без grep-разведки. Коммит: «Add ARCHITECTURE.md: repo map + protocol +
cookbook».

---

## Фаза B — Удаление мёртвого кода и мёртвых планов

Метод (применять к каждому пункту): для символа — `grep` имени по всему репо; если нет
ссылок (кроме объявления) — удалить. Ничего «на всякий случай».

- **B1. Мёртвый код (клиент/движок).** Прогнать по каждому `func`/`var`/`const`/
  `class_name`/`static func`. Известные кандидаты (проверить ссылки!): `MainMenu._prism_bar`
  и его единственный потребитель `COLORS` (после процедурного логотипа `_prism_bar` не
  зовётся), дублирующиеся `_gap`-хелперы (свести в один общий), любые остатки удалённых
  фич (`umbra`/`clairvoyance`/`lens` в `glossary.gd`/`icons/`/`hero_view`), неиспользуемые
  ветки. Удалить подтверждённо-мёртвое.
  - **Подтверждено при сверке для ARCHITECTURE.md (удалить):** инлайн-экшен `dispel`
    — ветка в `Game::executeAction` (`game.cpp`) + строка `"dispel"` в `glossary.gd`;
    реализован, но ни одна карта не использует (решение пользователя — выпилить, при
    надобности вернётся тривиально). **Оставить (задел, НЕ трогать):** `add_crystal`
    и ключевик `delay` (`processDelayed`/`pending`) — тоже без карт в сете, но сохраняем
    намеренно.
- **B2. Мёртвые ассеты.** Скрипт: собрать множество живых id (все `id` из `cards.json` +
  `tokens.json` + `hero_*` + `ui/`-референсы в коде); для каждого `client-godot/art/*.png`
  проверить, что его id в множестве; вывести сирот. Удалить сиротские арты (напр. от
  переименованных/удалённых карт). **Отдельно решить:** `hero_lens.png` (Кьяра —
  отложенный кандидат: оставить, помечено в `ART_HEROES.md`); дев-скрины
  (`_shot/_menu/_play/_join/...png`) — решить: оставить трекать или в `.gitignore`
  (они перезаписываются стендами). **Решено: НЕ трекать — добавить в `.gitignore` и
  `git rm --cached` уже закоммиченные дев-скрины** (`_shot/_menu/_play/_join/_wait/
  _create/_settings/_over/_pill/_tip/_recon/_death/_def/_hv/_heroes/_dmg.png` и пр.).
- **B3. Мёртвые планы/описания в md.** `REFACTOR.md`: срезать тумбстоуны выполненных фаз
  (оставить «Целевую архитектуру» §3 и план «инкрементальный борд» §5 + решение об
  остановке дробления — они живые). Финальный свип по всем md на устаревшее. (Прочее md
  уже чищено ранее — добить остаток.)
- **B4. `tools/`.** Проверить, что `build_prompts.py`/`ART_PROMPTS.md` соответствуют
  текущему сету (id/имена из `cards.json`); `balance.py` указывает на актуальный json.
  Устаревшее — удалить/поправить.

**Критерий B:** `grep` удалённых символов — пусто; движок собран, клиент парсится, `Shot`
рендерится. Коммит(ы): «Remove dead code / orphan art / stale plan text».

---

## Фаза C — Дев-харнес + клиентские тесты (сетка безопасности и проверка)

Сейчас клиентских тестов **0**, и я каждый раз пишу/удаляю одноразовые `Shot*.gd` — хрупко
(мок в `Shot.gd` уже отставал от сета → «пустой арт»). Чиним:

- **C1. Переиспользуемый харнес `client-godot/devkit.gd`** (`class_name DevKit` или
  SceneTree-хелпер): поднять `Main` с мок-вью; API: `make_view(opts)` — строит **валидный**
  view (id-ы карт сверяются с `cards.json`, иначе ошибка — моки не протухают);
  `feed(view)`; `node_count`/`find` хелперы; `screenshot(path)`. На нём переписать `Shot.gd`/
  `ShotMenu.gd` (и удалить будущие одноразовые стенды).
- **C2. Хедлесс-тест-раннер `client-godot/tests/run.gd`** (SceneTree, печатает `PASS k/n`,
  ненулевой код при провале). Покрыть **чистую логику**: `CardData` (`target_side`/
  `needs_target`/`target_required`/`targeted_effect_texts`/`can_afford`), `GameState.diff`/
  `departed`, и Main-хелперы через мок-вью (`_generic_choices`, `_mana_cap_h`,
  `_has_legal_target`, `_valid_attack_target`, `_diff_hero_hp`). Запуск:
  `godot --headless --path . -s tests/run.gd`.
- **C3. CI.** Расширить `.github/workflows/ci.yml`: помимо движка/смоука — прогон
  `tests/run.gd` headless (нужен Godot в CI или battery — оценить; как минимум добавить
  парс-чек проекта `--headless --import`). Стенды `Shot/ShotMenu` — сверка мок-id с
  `cards.json` (падать громко при протухании).

**Критерий C:** `godot --headless -s tests/run.gd` → `PASS n/n`; одноразовые стенды больше
не нужны; CI гоняет клиентские проверки. Коммит: «Add client dev harness + headless tests».

---

## Фаза D — Инкрементальный апдейт борда (архитектурный; разблокирует разнос)

Корень хрупкости раскладки/анимаций и причина, по которой `REFACTOR.md` остановил
дробление. Заменить полный `_rebuild` на каждый `view` дифф-реконсиляцией.

- **D1.** Узловая модель уже есть для существ/руки (`BoardLayer`/`HandRow`, keyed by id).
  Распространить на стабильные узлы: медальоны героев, колонки стопок, баннер — обновлять
  по месту, не пересоздавая.
- **D2.** Ввести явную **шину намерений** (сигналы attack/play/place_mana/awaken) вместо
  closures, дёргающих методы `Main` — это снимет «host-инъекцию с непроверяемыми вызовами»,
  из-за которой остановили разнос.
- **D3.** После D1–D2 — **безопасно вынести** оставшиеся builder-ы (`BoardRow`/`HandRow`/
  `PilesColumn`/`ManaRow`/оверлеи) в свои модули с тестами. `Main` ужать до координатора
  (~250 строк, цель из `REFACTOR.md §3`).
- **D4.** Заодно чинит фрагильную раскладку (текущие частичные фиксы — мана-cap-скролл,
  закреплённая кнопка хода — заменятся ограниченной моделью; связано с BACKLOG «адаптив»).

**Критерий D:** поведение идентично (харнес/скрины); межсостоянные анимации (карта рука→
стол) возможны; `Main` ≤ ~300 строк; новые виджет-модули покрыты тестами. **Высокий объём —
бить на под-коммиты.**

---

## Фаза E — (стретч) типизированная модель + дизайн-токены

Снизить primitive-obsession: обёртки `Card`/`Creature` (вместо голых `Dictionary`),
таблица токенов (палитра/типошкала/радиусы/тени) вместо разбросанных литералов. Не
блокирует; делать при наличии запала.

---

## Durable-артефакты (что остаётся для ориентации после выполнения)

- `ARCHITECTURE.md` — карта + кукбук + контракт протокола (читать ПЕРВЫМ).
- `BACKLOG.md` — что делаем/решили (читать первым после компакта).
- `REFACTOR.md` — урезан: целевая архитектура + план инкрементального борда.
- `client-godot/devkit.gd` + `client-godot/tests/` — харнес и тесты.
- `cards/sample.json` ↔ `client-godot/cards.json` — данные карт (держать в синхроне).
- Память (`MEMORY.md` и файлы) — предпочтения пользователя.
- `PLAN.md` (этот файл) — **удалить по завершении инициативы.**

## Решения (зафиксировано с пользователем)

1. **Комментарии в коде — НУЖНЫ** для Prism (исключение из общего правила). См. §A8.
2. **Дев-скрины не трекаем** — `.gitignore` + `git rm --cached` (часть фазы B2).
3. **Объём — весь план A→E.** Делаем рефакторинг (эту инициативу) **полностью до конца**, и
   только потом — остальные (не-рефакторинг) задачи. Не вклинивать фичи в середину.
