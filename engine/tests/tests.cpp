#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"

// Unit tests for the engine. Each case isolates one rule or keyword: mana,
// combat (mutual ATK), the win condition, fatigue, JSON loading, and every
// implemented keyword/effect. Small self-contained card sets (kTestCards) keep
// the tests independent of real card balance.

#include <string>
#include <vector>

#include "json.hpp"
#include "prism/card.hpp"
#include "prism/game.hpp"
#include "prism/protocol.hpp"
#include "prism/types.hpp"

using namespace prism;

static const char* kTestCards = R"json([
  { "id": "bear", "name": { "ru": "Медведь" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 3, "hp": 4 } },
  { "id": "bruiser", "name": { "ru": "Дробитель" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 4, "hp": 4 } },
  { "id": "wall", "name": { "ru": "Стена" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 0, "hp": 5 } },
  { "id": "redpip", "name": { "ru": "Алый" }, "type": "creature",
    "color": ["red"], "cost": { "generic": 1, "red": 1 },
    "stats": { "atk": 2, "hp": 2 } },
  { "id": "regenbear", "name": { "ru": "Регенератор" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 0, "hp": 5 },
    "keywords": [{ "id": "regen", "n": 2 }] },
  { "id": "piercer", "name": { "ru": "Бур" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 5, "hp": 5 },
    "keywords": [{ "id": "pierce" }] },
  { "id": "smallwall", "name": { "ru": "Барьер" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 0, "hp": 2 } },
  { "id": "guard", "name": { "ru": "Маяк" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 0, "hp": 3 },
    "keywords": [{ "id": "provoke" }] },
  { "id": "bypasser", "name": { "ru": "Сквозьстрой" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 3, "hp": 3 },
    "keywords": [{ "id": "bypass" }] },
  { "id": "lifestealer", "name": { "ru": "Алодар" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 3, "hp": 4 },
    "keywords": [{ "id": "self_lifesteal" }] },
  { "id": "shielded", "name": { "ru": "Светощит" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 2 },
    "keywords": [{ "id": "shield" }] },
  { "id": "warded", "name": { "ru": "Нимбоносец" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 3 },
    "keywords": [{ "id": "ward" }] },
  { "id": "germinator", "name": { "ru": "Прорастатель" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 1, "hp": 3 },
    "keywords": [{ "id": "germinate", "n": 2 }] },
  { "id": "floodaura", "name": { "ru": "Прожектор" }, "type": "aura",
    "color": [], "cost": { "generic": 0 },
    "keywords": [{ "id": "floodlight" }] },
  { "id": "delaybolt", "name": { "ru": "Отложенный луч" }, "type": "spell",
    "color": [], "cost": { "generic": 0 }, "keywords": [{ "id": "delay", "n": 2 }],
    "effects": [{ "trigger": "on_play", "selector": "enemy_hero",
                  "action": "damage", "value": 3 }] },
  { "id": "decoyling", "name": { "ru": "Приманка" }, "type": "creature",
    "color": [], "cost": { "generic": 2 }, "stats": { "atk": 2, "hp": 2 },
    "keywords": [{ "id": "awaken" }, { "id": "decoy", "n": 2 }] },
  { "id": "delaystab", "name": { "ru": "Отложенный удар" }, "type": "spell",
    "color": [], "cost": { "generic": 0 }, "keywords": [{ "id": "delay", "n": 1 }],
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "damage", "value": 5 }] },
  { "id": "purebait", "name": { "ru": "Чистая приманка" }, "type": "creature",
    "color": [], "cost": { "generic": 2 }, "stats": { "atk": 2, "hp": 2 },
    "keywords": [{ "id": "decoy", "n": 2 }] },
  { "id": "lingerer", "name": { "ru": "Неугасимый страж" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 3 },
    "keywords": [{ "id": "lingering" }] },
  { "id": "lingerbolt", "name": { "ru": "Неугасимый росчерк" }, "type": "spell",
    "color": [], "cost": { "generic": 0 }, "keywords": [{ "id": "lingering" }],
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "damage", "value": 2 }] },
  { "id": "hider", "name": { "ru": "Незримка" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 2 },
    "keywords": [{ "id": "stealth" }] },
  { "id": "grower", "name": { "ru": "Подрост" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 1, "hp": 3 },
    "keywords": [{ "id": "growth", "n": 1 }] },
  { "id": "composter", "name": { "ru": "Перегной" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 1, "hp": 4 },
    "keywords": [{ "id": "compost", "n": 2 }] },
  { "id": "haunter", "name": { "ru": "Морок-зверь" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 2 },
    "keywords": [{ "id": "haunt" }] },
  { "id": "sporehaunter", "name": { "ru": "Спорный-морок" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 2 },
    "keywords": [{ "id": "spores", "n": 2 }, { "id": "haunt" }] },
  { "id": "chillaura", "name": { "ru": "Стужа-аура" }, "type": "aura",
    "color": [], "cost": { "generic": 0 },
    "keywords": [{ "id": "chill", "n": 1 }] },
  { "id": "dispelspell", "name": { "ru": "Разрыв" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "action": "dispel", "value": 1 }] },
  { "id": "undergrowther", "name": { "ru": "Подлесок-зверь" },
    "type": "creature", "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 1, "hp": 4 }, "keywords": [{ "id": "undergrowth", "n": 1 }] },
  { "id": "resonator", "name": { "ru": "Резонатор" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 1, "hp": 4 },
    "keywords": [{ "id": "resonance", "n": 1 }] },
  { "id": "frost1", "name": { "ru": "Иней" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "freeze", "value": 1 }] },
  { "id": "blindspell", "name": { "ru": "Слепота" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "blind", "value": 1 }] },
  { "id": "sacrifice", "name": { "ru": "Жертва" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_friendly_minion",
                  "action": "damage", "value": 99, "required": true }] },
  { "id": "flashspell", "name": { "ru": "Вспышка" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "action": "flash", "value": 1 }] },
  { "id": "boltspell", "name": { "ru": "Луч-удар" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "enemy_hero",
                  "action": "damage", "value": 3 }] },
  { "id": "meltspell", "name": { "ru": "Луч-резак" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "damage", "value": 2 }] },
  { "id": "sweepspell", "name": { "ru": "Выметание" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "action": "damage_all", "value": 2 }] },
  { "id": "destroyspell", "name": { "ru": "Устранение" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "destroy", "value": 0 }] },
  { "id": "drawspell", "name": { "ru": "Добор" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "action": "draw", "value": 2 }] },
  { "id": "scryspell", "name": { "ru": "Прозрение" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "action": "scry", "value": 2 }] },
  { "id": "rampspell", "name": { "ru": "Накопитель" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "action": "add_crystal", "value": 1 }] },
  { "id": "bouncespell", "name": { "ru": "Рассеяние" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "scatter", "value": 0 }] },
  { "id": "miragespell", "name": { "ru": "Мираж" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "action": "mirage", "value": 0 }] },
  { "id": "photoaura", "name": { "ru": "Корень" }, "type": "aura",
    "color": [], "cost": { "generic": 0 },
    "keywords": [{ "id": "photosynthesis", "n": 1 }] },
  { "id": "splitter", "name": { "ru": "Двойник-фантом" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 2 },
    "keywords": [{ "id": "split", "n": 2 }] },
  { "id": "sporecarrier", "name": { "ru": "Спороносец" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 2 },
    "keywords": [{ "id": "spores", "n": 2 }] },
  { "id": "sleeper", "name": { "ru": "Спящий-фантом" }, "type": "creature",
    "color": [], "cost": { "generic": 2 }, "stats": { "atk": 3, "hp": 3 },
    "keywords": [{ "id": "awaken" }] },
  { "id": "violetsleeper", "name": { "ru": "Фиалка-фантом" }, "type": "creature",
    "color": ["violet"], "cost": { "generic": 1, "violet": 1 },
    "stats": { "atk": 2, "hp": 2 }, "keywords": [{ "id": "awaken" }] },
  { "id": "selffreeze", "name": { "ru": "Само-лёд" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_friendly_minion",
                  "action": "freeze", "value": 2 }] },
  { "id": "anyfreeze", "name": { "ru": "Обще-лёд" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_any_minion",
                  "action": "freeze", "value": 2 }] },
  { "id": "yellowbody", "name": { "ru": "Жёлтое тело" }, "type": "creature",
    "color": ["yellow"], "cost": { "generic": 0 }, "stats": { "atk": 1, "hp": 1 } },
  { "id": "redonly", "name": { "ru": "Алый зов" }, "type": "creature",
    "color": ["red"], "cost": { "red": 1 }, "stats": { "atk": 2, "hp": 2 } },
  { "id": "dual", "name": { "ru": "Двуцвет" }, "type": "creature",
    "color": ["red", "blue"], "cost": { "red": 1, "blue": 1 },
    "stats": { "atk": 2, "hp": 2 } },
  { "id": "hero_prism", "name": { "ru": "Ирида" }, "type": "hero",
    "keywords": [{ "id": "spectral_shift" }] },
  { "id": "hero_palette", "name": { "ru": "Тициана" }, "type": "hero",
    "keywords": [{ "id": "palette" }] },
  { "id": "hero_facet", "name": { "ru": "Гемма" }, "type": "hero",
    "keywords": [{ "id": "facet" }] },
  { "id": "hero_lighteater", "name": { "ru": "Эреб" }, "type": "hero",
    "keywords": [{ "id": "lighteater" }] }
])json";

static CardLibrary testLib() {
  CardLibrary lib;
  lib.loadJsonString(kTestCards);
  return lib;
}

static std::vector<std::string> repeat(const std::string& id, int n) {
  return std::vector<std::string>(n, id);
}

// Index of the first hand card with the given id (the deck is shuffled, so we
// locate cards by id rather than by position).
static int handIndexOf(Game& g, int player, const std::string& id) {
  const auto& h = g.player(player).hand;
  for (std::size_t i = 0; i < h.size(); ++i)
    if (h[i].def->id == id) return static_cast<int>(i);
  return -1;
}

// start() now stops in the mulligan phase; most tests just want play to begin.
// This deals, keeps both opening hands, and lets player 0's first turn start.
static void begin(Game& g) {
  g.start();
  g.mulligan(0, {});
  g.mulligan(1, {});
}

TEST_CASE("mana pool pays colored and generic") {
  ManaPool p;
  p.addCrystal(Color::Red);
  p.addCrystal(Color::Colorless);
  Cost c;
  c.generic = 1;
  c.pips[idx(Color::Red)] = 1;
  CHECK(p.canPay(c));
  CHECK(p.pay(c));
  CHECK(p.totalAvailable() == 0);
}

TEST_CASE("mana pool rejects when short") {
  ManaPool p;
  p.addCrystal(Color::Red);
  Cost c;
  c.generic = 1;
  c.pips[idx(Color::Red)] = 1;
  CHECK_FALSE(p.canPay(c));
}

TEST_CASE("explicit generic breakdown spends the chosen crystals") {
  ManaPool p;
  p.addCrystal(Color::Red);
  p.addCrystal(Color::Red);
  p.addCrystal(Color::Green);
  p.addCrystal(Color::Blue);
  Cost c;
  c.generic = 2;
  c.pips[idx(Color::Red)] = 1;  // one red is reserved for the pip
  // Pay the 2 generic with green + blue, keeping the second red crystal.
  std::array<int, ColorCount> gp{};
  gp[idx(Color::Green)] = 1;
  gp[idx(Color::Blue)] = 1;
  CHECK(p.pay(c, gp));
  CHECK(p.available[idx(Color::Red)] == 1);    // 2 - 1 pip
  CHECK(p.available[idx(Color::Green)] == 0);  // spent on generic
  CHECK(p.available[idx(Color::Blue)] == 0);   // spent on generic

  // A breakdown that does not sum to the generic cost is rejected, unchanged.
  ManaPool q;
  q.addCrystal(Color::Red);
  q.addCrystal(Color::Green);
  Cost c2;
  c2.generic = 2;
  std::array<int, ColorCount> bad{};
  bad[idx(Color::Red)] = 1;  // sums to 1, not 2
  CHECK_FALSE(q.pay(c2, bad));
  CHECK(q.totalAvailable() == 2);  // nothing spent

  // Asking to spend more of a color than is available is rejected.
  std::array<int, ColorCount> over{};
  over[idx(Color::Red)] = 2;  // only one red available
  CHECK_FALSE(q.pay(c2, over));
  CHECK(q.totalAvailable() == 2);
}

TEST_CASE("play honours a chosen generic breakdown over the greedy default") {
  CardLibrary lib = testLib();
  // "sleeper" costs 2 generic (no colored pips). With greens and colorless both
  // available, the greedy default would spend colorless first; here we choose
  // to spend the greens and keep the colorless crystals instead.
  Game g(lib, repeat("sleeper", 30), repeat("sleeper", 30), 1234);
  g.start();
  ManaPool& m = g.player(0).mana;
  m.available = {};
  m.available[idx(Color::Green)] = 2;
  m.available[idx(Color::Colorless)] = 2;
  std::array<int, ColorCount> gp{};
  gp[idx(Color::Green)] = 2;  // pay both generic with green, keep colorless
  CHECK(g.playCard(0, 0, -1, gp));
  CHECK(g.player(0).mana.available[idx(Color::Green)] == 0);
  CHECK(g.player(0).mana.available[idx(Color::Colorless)] == 2);  // kept
}

TEST_CASE("optional targeted effect skips with no target; required blocks") {
  CardLibrary lib = testLib();
  // frost1 freezes a chosen enemy minion (optional). With no enemy minion it
  // still plays -- the freeze just skips -- and the card is consumed.
  Game g(lib, repeat("frost1", 30), repeat("bear", 30), 1234);
  g.start();
  int before = static_cast<int>(g.player(0).hand.size());
  CHECK(g.playCard(0));  // target 0, empty enemy board -> plays, effect skipped
  CHECK(static_cast<int>(g.player(0).hand.size()) == before - 1);

  // sacrifice requires a friendly target (a cost). With no friendly minion it
  // cannot be played at all.
  Game g2(lib, repeat("sacrifice", 30), repeat("bear", 30), 1234);
  g2.start();
  int b2 = static_cast<int>(g2.player(0).hand.size());
  CHECK_FALSE(g2.playCard(0));  // required, no friendly minion -> blocked
  CHECK(static_cast<int>(g2.player(0).hand.size()) == b2);  // unchanged

  // A supplied-but-illegal target is rejected even for an optional effect (so
  // stealth etc. can't be bypassed by aiming at a hidden creature).
  CHECK_FALSE(g.playCard(0, 999999));  // nonexistent enemy id -> illegal
}

TEST_CASE("summoning sickness blocks attack on summon turn") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 1234);
  g.start();
  CHECK(g.playCard(0));
  EntityId bear = g.player(0).board[0].id;
  CHECK_FALSE(g.attackHero(bear));
  CHECK(g.player(1).heroHp == HeroStartHp);
  g.endTurn();
  g.endTurn();
  CHECK(g.attackHero(bear));
  CHECK(g.player(1).heroHp == HeroStartHp - 3);
}

TEST_CASE("combat is mutual: both deal ATK, the attacker can die too") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bruiser", 30), 99);
  g.start();
  CHECK(g.playCard(0));
  EntityId bear = g.player(0).board[0].id;
  g.endTurn();
  CHECK(g.playCard(0));
  EntityId bruiser = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(bear, bruiser));
  CHECK(g.player(0).board.size() == 0);  // bear (hp 4) took the bruiser's 4
  REQUIRE(g.player(1).board.size() == 1);
  CHECK(g.player(1).board[0].hp == 1);  // bruiser (hp 4) took the bear's 3
}

TEST_CASE("cannot pay a 2-cost with one crystal, can with two") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("redpip", 30), repeat("bear", 30), 7);
  g.start();
  CHECK(g.placeCardToMana(0, Color::Red));
  CHECK_FALSE(g.playCard(0));
  CHECK(g.player(0).board.empty());
  g.endTurn();
  g.endTurn();
  CHECK(g.placeCardToMana(0, Color::Red));
  CHECK(g.playCard(0));
  CHECK(g.player(0).board.size() == 1);
}

TEST_CASE("hero reaching zero ends the game") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 42);
  g.start();
  CHECK(g.playCard(0));
  EntityId bear = g.player(0).board[0].id;
  g.player(1).heroHp = 3;
  g.endTurn();
  g.endTurn();
  CHECK(g.attackHero(bear));
  CHECK(g.isOver());
  CHECK(g.winner() == 0);
}

TEST_CASE("drawing from an empty deck deals fatigue") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 4), repeat("bear", 30), 5);
  begin(g);
  CHECK(g.player(0).fatigue == 1);
  CHECK(g.player(0).heroHp == HeroStartHp - 1);
}

TEST_CASE("overdrawing into a full hand discards the card to the graveyard") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 5);
  begin(g);
  // Accumulate to a full hand by passing turns (1 draw per own turn), never
  // playing or losing a creature, so the graveyard stays empty until overdraw.
  while (static_cast<int>(g.player(0).hand.size()) < HandLimit) {
    g.endTurn();
    g.endTurn();
  }
  REQUIRE(g.player(0).hand.size() == HandLimit);
  REQUIRE(g.player(0).graveyard.empty());
  int deck = static_cast<int>(g.player(0).deck.size());
  g.endTurn();
  g.endTurn();  // next own turn start draws into a full hand -> overdraw
  CHECK(g.player(0).hand.size() == HandLimit);  // hand stays full
  CHECK(g.player(0).deck.size() == deck - 1);   // the card left the deck
  CHECK(g.player(0).graveyard.size() == 1);     // and went to the graveyard
}

TEST_CASE("a token's death does not add to the graveyard") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("splitter", 30), repeat("bruiser", 30), 4);
  begin(g);
  REQUIRE(g.playCard(handIndexOf(g, 0, "splitter")));  // splitter + 2 illusions
  REQUIRE(g.player(0).board.size() == 3);
  REQUIRE(g.player(0).graveyard.empty());
  EntityId tok = -1;
  for (const auto& c : g.player(0).board)
    if (c.token) tok = c.id;
  REQUIRE(tok != -1);
  g.endTurn();
  REQUIRE(g.playCard(handIndexOf(g, 1, "bruiser")));  // 4/4
  EntityId br = g.player(1).board[0].id;
  g.endTurn();                           // P0 turn 3
  g.endTurn();                           // P1 turn 4, bruiser awake
  CHECK(g.attackCreature(br, tok));      // bruiser kills the 1-HP token
  CHECK(g.player(0).graveyard.empty());  // token was never a real card
}

TEST_CASE("regen heals at the owner's turn start up to max") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("regenbear", 30), repeat("bear", 30), 11);
  g.start();
  REQUIRE(g.playCard(0));
  g.player(0).board[0].hp = 1;
  g.endTurn();
  g.endTurn();
  CHECK(g.player(0).board[0].hp == 3);
}

TEST_CASE("pierce sends lethal excess to the enemy hero") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("piercer", 30), repeat("smallwall", 30), 22);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId p = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId w = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(p, w));
  CHECK(g.player(1).board.empty());
  CHECK(g.player(1).heroHp == HeroStartHp - 3);
}

TEST_CASE("provoke forces attackers onto the provoker") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("guard", 30), 33);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId atk = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId guardId = g.player(1).board[0].id;
  g.player(1).hand.push_back(CardInstance{777, lib.find("bear")});
  REQUIRE(g.playCard(static_cast<int>(g.player(1).hand.size()) - 1));
  EntityId plainId = g.player(1).board.back().id;
  g.endTurn();
  CHECK_FALSE(g.attackHero(atk));
  CHECK_FALSE(g.attackCreature(atk, plainId));
  CHECK(g.attackCreature(atk, guardId));
}

TEST_CASE("freeze stops a creature from attacking, then thaws") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("frost1", 30), repeat("bear", 30), 44);
  g.start();
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId bear = g.player(1).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0, bear));
  CHECK(g.player(1).board[0].frozenTurns == 1);
  g.endTurn();
  CHECK_FALSE(g.attackHero(bear));
  g.endTurn();
  g.endTurn();
  CHECK(g.attackHero(bear));
  CHECK(g.player(0).heroHp == HeroStartHp - 3);
}

TEST_CASE("blind suppresses retaliation, unlike freeze") {
  CardLibrary lib = testLib();
  // p0 carries an attacker and a blind spell; p1 brings a creature to blind.
  // Tiny decks so the opening hand is deterministic.
  Game g(lib, {"bear", "blindspell", "bear", "bear"},
         {"bear", "bear", "bear", "bear", "bear"}, 7);
  begin(g);
  REQUIRE(g.playCard(handIndexOf(g, 0, "bear")));  // attacker A enters (sick)
  EntityId atkId = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(handIndexOf(g, 1, "bear")));  // defender B
  EntityId defId = g.player(1).board[0].id;
  g.endTurn();  // back to p0; A is no longer sick
  REQUIRE(g.playCard(handIndexOf(g, 0, "blindspell"), defId));
  CHECK(g.player(1).board[0].blindTurns == 1);
  REQUIRE(g.attackCreature(atkId, defId));
  // A (3/4) deals 3 to B (4 hp -> 1) but takes NO retaliation: B is blinded.
  CHECK(g.player(1).board[0].hp == 1);
  CHECK(g.player(0).board[0].hp == 4);
}

TEST_CASE("ward absorbs the next harmful targeted effect, then is spent") {
  CardLibrary lib = testLib();
  Game g(lib, {"warded", "bear", "bear", "bear"},
         {"destroyspell", "frost1", "bear", "bear", "bear"}, 13);
  begin(g);
  REQUIRE(g.playCard(handIndexOf(g, 0, "warded")));
  EntityId w = g.player(0).board[0].id;
  CHECK(g.player(0).board[0].warded);
  g.endTurn();  // p1's turn
  REQUIRE(g.playCard(handIndexOf(g, 1, "destroyspell"), w));
  REQUIRE(g.player(0).board.size() == 1);    // the ward ate the destroy
  CHECK_FALSE(g.player(0).board[0].warded);  // ...and is now spent
  REQUIRE(g.playCard(handIndexOf(g, 1, "frost1"), w));
  CHECK(g.player(0).board[0].frozenTurns == 1);  // the next effect lands
}

TEST_CASE("germinate spends a crystal for an N/N sprout, once per turn") {
  CardLibrary lib = testLib();
  Game g(lib, {"germinator", "bear", "bear", "bear"}, repeat("bear", 30), 22);
  begin(g);
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "bear"), Color::Colorless));
  REQUIRE(g.playCard(handIndexOf(g, 0, "germinator")));
  EntityId gid = g.player(0).board[0].id;
  REQUIRE(g.activate(gid));
  REQUIRE(g.player(0).board.size() == 2);  // germinator + sprout
  const Creature& sprout = g.player(0).board[1];
  CHECK(sprout.token);
  CHECK(sprout.atk == 2);
  CHECK(sprout.hp == 2);
  CHECK(g.player(0).mana.totalAvailable() == 0);  // the crystal was spent
  CHECK_FALSE(g.activate(gid));                   // only once per turn
}

TEST_CASE("floodlight reveals the enemy's banked mana cards") {
  CardLibrary lib = testLib();
  Game g(lib, {"floodaura", "bear", "bear", "bear"}, repeat("bear", 30), 31);
  begin(g);
  REQUIRE(g.playCard(handIndexOf(g, 0, "floodaura")));  // p0 gains floodlight
  g.endTurn();                                          // p1's turn
  REQUIRE(g.placeCardToMana(handIndexOf(g, 1, "bear"), Color::Colorless));
  auto v0 = nlohmann::json::parse(viewJson(g, 0));  // viewer has floodlight
  auto v1 = nlohmann::json::parse(viewJson(g, 1));  // owner, no floodlight
  CHECK(v0["players"][1]["manaRow"][0].contains("card"));  // revealed
  CHECK(v0["players"][1]["manaRow"][0]["card"] == "bear");
  CHECK_FALSE(v1["players"][1]["manaRow"][0].contains("card"));  // stays hidden
}

TEST_CASE("delay schedules an effect for a later turn") {
  CardLibrary lib = testLib();
  Game g(lib, {"delaybolt", "bear", "bear", "bear"}, repeat("bear", 30), 32);
  begin(g);
  REQUIRE(g.playCard(handIndexOf(g, 0, "delaybolt")));
  CHECK(g.player(1).heroHp == HeroStartHp);  // nothing happens yet
  g.endTurn();
  g.endTurn();  // p0's 2nd turn: ticks to 1, still nothing
  CHECK(g.player(1).heroHp == HeroStartHp);
  g.endTurn();
  g.endTurn();  // p0's 3rd turn: the bolt lands
  CHECK(g.player(1).heroHp == HeroStartHp - 3);
}

TEST_CASE("decoy lets an aged banked card awaken for free") {
  CardLibrary lib = testLib();
  Game g(lib, {"decoyling", "bear", "bear", "bear"}, repeat("bear", 30), 33);
  begin(g);
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "decoyling"), Color::Colorless));
  CHECK_FALSE(
      g.awaken(0));  // age 0: the lone banked crystal can't pay the rest
  g.endTurn();
  g.endTurn();               // p0 turn 3: age 1
  CHECK_FALSE(g.awaken(0));  // still not aged enough
  g.endTurn();
  g.endTurn();           // p0 turn 5: age 2 -> decoy ready
  REQUIRE(g.awaken(0));  // free awaken
  CHECK(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].def->id == "decoyling");
}

TEST_CASE(
    "decoy implies wakeability: a banked decoy card with no awaken wakes") {
  CardLibrary lib = testLib();
  // purebait has decoy but NOT awaken (the 5-colour prismatic case). It must
  // still be wakeable from the mana row once matured -- otherwise its decoy is
  // dead weight.
  Game g(lib, {"purebait", "bear", "bear", "bear"}, repeat("bear", 30), 35);
  begin(g);
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "purebait"), Color::Colorless));
  g.endTurn();
  g.endTurn();
  g.endTurn();
  g.endTurn();           // p0 turn 5: age 2 -> matured
  REQUIRE(g.awaken(0));  // free awaken despite no awaken keyword
  CHECK(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].def->id == "purebait");
}

TEST_CASE("delay keeps its chosen target and hits it when it resolves") {
  CardLibrary lib = testLib();
  Game g(lib, {"delaystab", "bear", "bear", "bear"}, repeat("bear", 30), 36);
  begin(g);
  g.endTurn();
  REQUIRE(g.playCard(handIndexOf(g, 1, "bear")));  // p1 puts up a target
  EntityId tgt = g.player(1).board[0].id;
  int hp0 = g.player(1).board[0].hp;
  g.endTurn();
  // Schedule the stab at the chosen enemy minion; nothing happens this turn.
  REQUIRE(g.playCard(handIndexOf(g, 0, "delaystab"), tgt));
  CHECK(g.player(1).board[0].hp == hp0);
  g.endTurn();
  g.endTurn();  // p0's next turn: the delayed stab lands on the chosen creature
  REQUIRE(g.player(1).board.empty());  // bear (hp 4) took 5 and died
}

TEST_CASE("scry peeks the top cards and the player sorts them") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 41);
  begin(g);
  int deck_before = static_cast<int>(g.player(0).deck.size());
  g.player(0).hand.push_back(CardInstance{900, lib.find("scryspell")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1));
  CHECK(g.inScry());
  CHECK(g.scryPlayer() == 0);
  CHECK(g.scryPeek().size() == 2);
  CHECK(static_cast<int>(g.player(0).deck.size()) == deck_before - 2);
  // ...but the reported deckCount stays full: the peeked cards still belong to
  // the deck (scry only reorders the top), so the pile count must not dip.
  auto vs = nlohmann::json::parse(viewJson(g, 0));
  CHECK(vs["players"][0]["deckCount"].get<int>() == deck_before);
  // Everything else is blocked until the scry is resolved.
  CHECK_FALSE(applyAction(g, 0, R"({"action":"endTurn"})"));
  // Resolve via the protocol: one card to the bottom, the deck returns to full.
  CHECK(applyAction(g, 0, R"({"action":"scryResolve","bottom":[1]})"));
  CHECK_FALSE(g.inScry());
  CHECK(static_cast<int>(g.player(0).deck.size()) == deck_before);
}

TEST_CASE("mulligan reshuffles the chosen cards and gates the first turn") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 123);
  g.start();
  REQUIRE(g.inMulligan());
  // No normal action is accepted until both players have mulliganed.
  CHECK_FALSE(applyAction(g, 0, R"({"action":"play","handIndex":0})"));
  CHECK(applyAction(g, 0, R"({"action":"mulligan","indices":[0,1]})"));
  CHECK(g.mulliganDone(0));
  CHECK(g.player(0).hand.size() == OpeningFirst);  // redrew what it tossed
  CHECK(g.inMulligan());                           // still waiting on p1
  CHECK_FALSE(applyAction(g, 0, R"({"action":"mulligan","indices":[]})"));
  CHECK(applyAction(g, 1, R"({"action":"mulligan","indices":[]})"));
  CHECK_FALSE(g.inMulligan());  // both done -> play begins
  CHECK(g.mulliganDone(1));
  CHECK(applyAction(g, 0, R"({"action":"play","handIndex":0})"));
}

TEST_CASE("mulligan rejects bad indices and leaves the hand untouched") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 5);
  g.start();
  CHECK_FALSE(g.mulligan(0, {0, 99}));  // out of range -> whole call rejected
  CHECK_FALSE(g.mulliganDone(0));
  CHECK(g.player(0).hand.size() == OpeningFirst);
}

TEST_CASE("a mulliganed card cannot come back in the same mulligan") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 99);
  g.start();
  // Every instance has a unique id even though they are all "bear": record the
  // ids of the whole opening hand, then mulligan all of it.
  std::vector<EntityId> tossed;
  std::vector<int> idx;
  for (int i = 0; i < static_cast<int>(g.player(0).hand.size()); ++i) {
    tossed.push_back(g.player(0).hand[i].id);
    idx.push_back(i);
  }
  REQUIRE(g.mulligan(0, idx));
  CHECK(g.player(0).hand.size() == OpeningFirst);
  // Replacements are drawn before the tossed cards go back, so none return.
  for (const auto& c : g.player(0).hand)
    for (EntityId t : tossed) CHECK(c.id != t);
}

TEST_CASE("photosynthesis adds temporary mana at turn start") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("photoaura", 30), repeat("bear", 30), 55);
  g.start();
  REQUIRE(g.playCard(0));
  g.endTurn();
  g.endTurn();
  CHECK(g.player(0).mana.totalAvailable() == 1);
}

TEST_CASE("add_crystal permanently grows the mana pool") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("rampspell", 30), repeat("bear", 30), 71);
  begin(g);
  REQUIRE(g.playCard(0));  // cost 0; adds one permanent colorless crystal
  CHECK(g.player(0).mana.crystals[idx(Color::Colorless)] == 1);
  CHECK(g.player(0).mana.totalAvailable() == 1);  // usable the same turn
  g.endTurn();
  g.endTurn();  // back to p0: the refill keeps the permanent crystal
  CHECK(g.player(0).mana.crystals[idx(Color::Colorless)] == 1);
  CHECK(g.player(0).mana.totalAvailable() >= 1);
}

TEST_CASE("split spawns permanent 1 HP illusion copies") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("splitter", 30), repeat("bear", 30), 66);
  g.start();
  REQUIRE(g.playCard(0));
  REQUIRE(g.player(0).board.size() == 3);  // the splitter plus two illusions
  int illusions = 0;
  EntityId anIllusion = 0;
  for (const auto& c : g.player(0).board)
    if (c.token) {
      illusions += 1;
      anIllusion = c.id;
      CHECK(c.hp == 1);
      CHECK(c.atk == 2);  // copies the splitter's atk
    }
  CHECK(illusions == 2);
  CHECK_FALSE(g.attackHero(anIllusion));  // summoning sick the turn it is made
  g.endTurn();
  CHECK(g.player(0).board.size() == 3);  // permanent: illusions stay on board
  g.endTurn();  // back to p0: illusions are un-sick now
  CHECK(g.attackHero(anIllusion));
  CHECK(g.player(1).heroHp == HeroStartHp - 2);
}

TEST_CASE("spores summons sprout tokens when the creature dies") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("sporecarrier", 30), repeat("bruiser", 30), 77);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId sc = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId b = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(sc, b));  // sporecarrier dies to the bruiser's ATK
  REQUIRE(g.player(0).board.size() == 2);
  for (const auto& c : g.player(0).board) {
    CHECK(c.hp == 1);
    CHECK(c.atk == 1);
  }
}

TEST_CASE(
    "a death-summoned token lands where the creature died, not at the end") {
  CardLibrary lib = testLib();
  // All sporecarriers: the two flanking bodies are non-tokens, so the sprouts
  // from the middle one are easy to spot by position.
  Game g(lib, repeat("sporecarrier", 30), repeat("bruiser", 30), 91);
  g.start();
  REQUIRE(g.playCard(handIndexOf(g, 0, "sporecarrier")));
  REQUIRE(g.playCard(handIndexOf(g, 0, "sporecarrier")));
  REQUIRE(g.playCard(handIndexOf(g, 0, "sporecarrier")));
  EntityId left = g.player(0).board[0].id;
  EntityId mid = g.player(0).board[1].id;
  EntityId right = g.player(0).board[2].id;
  g.endTurn();
  REQUIRE(g.playCard(handIndexOf(g, 1, "bruiser")));
  EntityId br = g.player(1).board[0].id;
  g.endTurn();                       // P0 turn 3
  g.endTurn();                       // P1 turn 4: the bruiser is no longer sick
  CHECK(g.attackCreature(br, mid));  // the middle creature dies
  REQUIRE(g.player(0).board.size() == 4);
  CHECK(g.player(0).board[0].id == left);
  CHECK(
      g.player(0).board[1].token);  // sprouts land where it died, not far right
  CHECK(g.player(0).board[2].token);
  CHECK(g.player(0).board[3].id == right);
}

TEST_CASE("spores + haunt: the self-copy is summoned before the sprouts") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("sporehaunter", 30), repeat("bruiser", 30), 42);
  g.start();
  REQUIRE(g.playCard(handIndexOf(g, 0, "sporehaunter")));
  REQUIRE(g.playCard(handIndexOf(g, 0, "sporehaunter")));
  REQUIRE(g.playCard(handIndexOf(g, 0, "sporehaunter")));
  EntityId left = g.player(0).board[0].id;
  EntityId mid = g.player(0).board[1].id;
  EntityId right = g.player(0).board[2].id;
  g.endTurn();
  REQUIRE(g.playCard(handIndexOf(g, 1, "bruiser")));
  EntityId br = g.player(1).board[0].id;
  g.endTurn();                       // P0 turn 3
  g.endTurn();                       // P1 turn 4
  CHECK(g.attackCreature(br, mid));  // the middle sporehaunter dies
  REQUIRE(g.player(0).board.size() == 5);
  CHECK(g.player(0).board[0].id == left);
  // The haunt copy takes the death slot first, then the two sprouts.
  CHECK(g.player(0).board[1].token);
  CHECK(g.player(0).board[1].def->id == "sporehaunter");
  CHECK(g.player(0).board[2].def->id == "token_sprout");
  CHECK(g.player(0).board[3].def->id == "token_sprout");
  CHECK(g.player(0).board[4].id == right);
}

TEST_CASE(
    "on a full board, spores + haunt yields the self-copy, not a sprout") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("sporehaunter", 30), repeat("bruiser", 30), 7);
  g.start();
  auto board0 = [&]() { return static_cast<int>(g.player(0).board.size()); };
  auto playAll = [&]() {
    int i;
    while (board0() < BoardLimit &&
           (i = handIndexOf(g, 0, "sporehaunter")) >= 0)
      REQUIRE(g.playCard(i));
  };
  playAll();  // turn 1: the opening hand
  g.endTurn();
  REQUIRE(g.playCard(handIndexOf(g, 1, "bruiser")));  // an attacker for later
  EntityId br = g.player(1).board[0].id;
  g.endTurn();  // P0 turn 3
  while (board0() < BoardLimit) {
    playAll();
    if (board0() < BoardLimit) {
      g.endTurn();
      g.endTurn();  // next P0 turn draws one more
    }
  }
  REQUIRE(board0() == BoardLimit);  // a full board of sporehaunters
  EntityId victim = g.player(0).board[3].id;
  g.endTurn();  // hand back to P1
  CHECK(g.attackCreature(br, victim));
  REQUIRE(board0() == BoardLimit);  // one died, exactly one body replaced it
  bool hasCopy = false;
  bool hasSprout = false;
  for (const auto& c : g.player(0).board) {
    if (c.token && c.def->id == "sporehaunter") hasCopy = true;
    if (c.def->id == "token_sprout") hasSprout = true;
  }
  CHECK(hasCopy);          // the haunt copy claimed the only free slot
  CHECK_FALSE(hasSprout);  // no room left for the spores
}

TEST_CASE("awaken plays a banked card; its crystal pays 1 and is consumed") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("sleeper", 30), repeat("bear", 30), 88);
  g.start();
  REQUIRE(g.placeCardToMana(0, Color::Colorless));  // turn 1: bank a sleeper
  g.endTurn();
  g.endTurn();  // back to p0 (turn 3)
  REQUIRE(
      g.placeCardToMana(0, Color::Colorless));  // bank another -> 2 crystals
  REQUIRE(g.awaken(0));                         // wake the first sleeper
  REQUIRE(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].def->id == "sleeper");
  CHECK(g.player(0).manaRow.size() == 1);  // one banked card consumed
  CHECK(g.player(0).mana.crystals[idx(Color::Colorless)] == 1);
}

TEST_CASE("awaken needs mana beyond the banked crystal") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("sleeper", 30), repeat("bear", 30), 99);
  g.start();
  REQUIRE(g.placeCardToMana(0, Color::Colorless));
  CHECK_FALSE(g.awaken(0));  // one crystal: nothing left to pay the remainder
  CHECK(g.player(0).manaRow.size() == 1);
}

TEST_CASE("awaken's banked crystal pays its own colored pip") {
  CardLibrary lib = testLib();
  // A Violet awaken card banked as Violet should cover its own Violet pip, so
  // it needs only 1 extra (generic) crystal -- not a second Violet.
  Game g(lib, {"violetsleeper", "bear", "bear", "bear"}, repeat("bear", 30),
         77);
  begin(g);
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "violetsleeper"), Color::Violet));
  g.endTurn();
  g.endTurn();  // back to p0 with the Violet crystal refilled
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "bear"), Color::Colorless));
  // Banked Violet pays the Violet pip; the leftover generic 1 comes from the
  // Colorless crystal. Under the old "discount only generic" rule this failed
  // (it still demanded a second Violet).
  REQUIRE(g.awaken(0));
  CHECK(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].def->id == "violetsleeper");
  CHECK(g.player(0).manaRow.size() == 1);  // the Violet crystal was consumed
}

TEST_CASE("only awaken cards can be played from the mana row") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 101);
  g.start();
  REQUIRE(g.placeCardToMana(0, Color::Colorless));
  g.endTurn();
  g.endTurn();
  REQUIRE(g.placeCardToMana(
      0, Color::Colorless));  // 2 crystals, but bear has no awaken
  CHECK_FALSE(g.awaken(0));
}

TEST_CASE("bypass attacks the hero through a provoker") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bypasser", 30), repeat("guard", 30), 201);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId a = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));  // enemy provoker
  g.endTurn();
  CHECK(g.attackHero(a));
  CHECK(g.player(1).heroHp == HeroStartHp - 3);
}

TEST_CASE("self_lifesteal heals the attacker for damage dealt") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("lifestealer", 30), repeat("wall", 30), 202);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId a = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId w = g.player(1).board[0].id;
  g.endTurn();
  g.player(0).board[0].hp = 1;
  CHECK(g.attackCreature(a, w));
  CHECK(g.player(0).board[0].hp == 4);  // healed by the 3 it dealt
}

TEST_CASE("shield absorbs the next instance of damage") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("shielded", 30), repeat("bruiser", 30), 203);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId s = g.player(0).board[0].id;
  CHECK(g.player(0).board[0].shield);
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId br = g.player(1).board[0].id;
  g.endTurn();
  g.endTurn();  // bruiser un-sick
  CHECK(g.attackCreature(br, s));
  REQUIRE(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].hp == 2);  // shield ate the bruiser's 4
  CHECK_FALSE(g.player(0).board[0].shield);
}

TEST_CASE("lingering wounds cannot be healed by regen") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("lingerer", 30), repeat("regenbear", 30), 204);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId l = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId r = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(l, r));  // regenbear 5 -> 3, 2 unhealable
  CHECK(g.player(1).board[0].hp == 3);
  g.endTurn();                          // regenbear's turn start: regen tries
  CHECK(g.player(1).board[0].hp == 3);  // capped at maxHp - unhealable = 3
}

TEST_CASE("lingering on a spell makes its damage unhealable") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("lingerbolt", 30), repeat("regenbear", 30), 251);
  g.start();
  g.endTurn();
  REQUIRE(g.playCard(0));  // p1 plays a regenbear (5 hp, regen)
  EntityId r = g.player(1).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(handIndexOf(g, 0, "lingerbolt"), r));  // 2 dmg, lingering
  CHECK(g.player(1).board[0].hp == 3);  // 5 -> 3, 2 unhealable
  g.endTurn();                          // regenbear's turn: regen tries to heal
  CHECK(g.player(1).board[0].hp == 3);  // capped at maxHp - unhealable = 3
}

TEST_CASE("growth adds +1/+1 at the owner's turn start") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("grower", 30), repeat("bear", 30), 205);
  g.start();
  REQUIRE(g.playCard(0));
  CHECK(g.player(0).board[0].atk == 1);
  g.endTurn();
  g.endTurn();
  CHECK(g.player(0).board[0].atk == 2);
  CHECK(g.player(0).board[0].hp == 4);
}

TEST_CASE("compost grows surviving allies when an ally dies") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("composter", 30), repeat("bruiser", 30), 206);
  g.start();
  REQUIRE(g.playCard(0));
  g.player(0).hand.push_back(CardInstance{900, lib.find("bear")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1));
  EntityId bearId = g.player(0).board[1].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId br = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(bearId, br));  // bear dies -> compost triggers
  REQUIRE(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].atk == 3);  // 1 + 2
  CHECK(g.player(0).board[0].hp == 6);   // 4 + 2
}

TEST_CASE("blind stops a creature from attacking for a turn") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("blindspell", 30), repeat("bear", 30), 207);
  g.start();
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId bear = g.player(1).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0, bear));
  CHECK(g.player(1).board[0].blindTurns == 1);
  g.endTurn();
  CHECK_FALSE(g.attackHero(bear));
}

TEST_CASE("flash blinds every enemy creature") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("flashspell", 30), repeat("bear", 30), 208);
  g.start();
  g.endTurn();
  REQUIRE(g.playCard(0));
  g.player(1).hand.push_back(CardInstance{901, lib.find("bear")});
  REQUIRE(g.playCard(static_cast<int>(g.player(1).hand.size()) - 1));
  g.endTurn();
  REQUIRE(g.playCard(0));
  REQUIRE(g.player(1).board.size() == 2);
  for (const auto& c : g.player(1).board) CHECK(c.blindTurns == 1);
}

TEST_CASE("stealth makes a creature untargetable until it attacks") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("hider", 30), repeat("bear", 30), 209);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId h = g.player(0).board[0].id;
  CHECK(g.player(0).board[0].stealthed);
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId bear = g.player(1).board[0].id;
  g.endTurn();                             // p0
  g.endTurn();                             // p1, bear un-sick
  CHECK_FALSE(g.attackCreature(bear, h));  // hidden -> illegal target
  g.endTurn();                             // p0, hider un-sick
  CHECK(g.attackHero(h));                  // attacking reveals it
  CHECK_FALSE(g.player(0).board[0].stealthed);
}

TEST_CASE("damage action hits the enemy hero") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("boltspell", 30), repeat("bear", 30), 210);
  g.start();
  REQUIRE(g.playCard(0));
  CHECK(g.player(1).heroHp == HeroStartHp - 3);
}

TEST_CASE("damage action can kill an enemy creature") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("meltspell", 30), repeat("smallwall", 30), 211);
  g.start();
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId w = g.player(1).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0, w));
  CHECK(g.player(1).board.empty());
}

TEST_CASE("destroy removes a creature outright") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("destroyspell", 30), repeat("wall", 30), 212);
  g.start();
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId w = g.player(1).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0, w));
  CHECK(g.player(1).board.empty());
}

TEST_CASE("damage_all hits every creature on both sides") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("smallwall", 30), 213);
  g.start();
  REQUIRE(g.playCard(0));  // bear
  g.endTurn();
  REQUIRE(g.playCard(0));  // smallwall
  g.endTurn();
  g.player(0).hand.push_back(CardInstance{902, lib.find("sweepspell")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1));
  REQUIRE(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].hp == 2);  // bear 4 -> 2
  CHECK(g.player(1).board.empty());     // smallwall 2 -> 0
}

TEST_CASE("draw action adds cards to hand") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("drawspell", 30), repeat("bear", 30), 214);
  g.start();
  int before = static_cast<int>(g.player(0).hand.size());
  REQUIRE(g.playCard(0));  // -1 spell, +2 drawn = net +1
  CHECK(static_cast<int>(g.player(0).hand.size()) == before + 1);
}

TEST_CASE("scatter returns a creature to its owner's hand") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bouncespell", 30), repeat("bear", 30), 215);
  g.start();
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId bear = g.player(1).board[0].id;
  int hb = static_cast<int>(g.player(1).hand.size());
  g.endTurn();
  REQUIRE(g.playCard(0, bear));
  CHECK(g.player(1).board.empty());
  CHECK(static_cast<int>(g.player(1).hand.size()) == hb + 1);
}

TEST_CASE("mirage creates a 1 HP illusion copy of a creature") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 216);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId bear = g.player(0).board[0].id;
  g.player(0).hand.push_back(CardInstance{903, lib.find("miragespell")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1, bear));
  REQUIRE(g.player(0).board.size() == 2);
  const Creature& ill = g.player(0).board[1];
  CHECK(ill.token);
  CHECK(ill.atk == 3);
  CHECK(ill.hp == 1);
}

TEST_CASE("haunt leaves an illusion when the creature dies") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("haunter", 30), repeat("bruiser", 30), 217);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId h = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId br = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(h, br));  // haunter dies -> haunt
  REQUIRE(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].token);
  CHECK(g.player(0).board[0].atk == 2);
  CHECK(g.player(0).board[0].hp == 1);
}

TEST_CASE(
    "haunt rebirth happens only once: the illusion does not haunt again") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("haunter", 30), repeat("bruiser", 30), 217);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId h = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId br = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(h, br));  // 2/2 haunter dies -> one illusion
  REQUIRE(g.player(0).board.size() == 1);
  REQUIRE(g.player(0).board[0].token);
  EntityId ill = g.player(0).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(br, ill));  // the illusion dies in turn
  CHECK(g.player(0).board.empty());  // no second illusion -- reborn only once
}

TEST_CASE("illusions inherit the original's keywords") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("shielded", 30), repeat("bear", 30), 220);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId s = g.player(0).board[0].id;
  g.player(0).hand.push_back(CardInstance{905, lib.find("miragespell")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1, s));
  REQUIRE(g.player(0).board.size() == 2);
  const Creature& ill = g.player(0).board[1];
  CHECK(ill.token);
  CHECK(ill.hp == 1);
  CHECK(ill.shield);  // copied the original's shield keyword
}

TEST_CASE("a stealthed creature cannot be targeted by enemy spells") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("frost1", 30), repeat("hider", 30), 221);
  g.start();
  g.endTurn();
  REQUIRE(g.playCard(0));  // p1 summons a hider (stealthed)
  EntityId h = g.player(1).board[0].id;
  g.endTurn();
  CHECK_FALSE(g.playCard(0, h));  // freeze on a hidden creature is illegal
  CHECK(g.player(1).board[0].frozenTurns == 0);
}

TEST_CASE("chill aura lowers enemy attack and reverses when removed") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("chillaura", 30), repeat("bear", 30), 230);
  g.start();
  REQUIRE(g.playCard(0));  // p0 plays the chill aura
  g.endTurn();
  REQUIRE(g.playCard(0));                // p1 summons a bear (atk 3)
  CHECK(g.player(1).board[0].atk == 2);  // chilled by 1
  g.player(0).auras.clear();             // aura gone
  g.endTurn();                           // a turn start recomputes
  CHECK(g.player(1).board[0].atk == 3);  // attack restored
}

TEST_CASE("dispel strips an enemy aura and lifts its effect at once") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("chillaura", 30), repeat("bear", 30), 240);
  g.start();
  REQUIRE(g.playCard(0));  // p0 plays the chill aura
  g.endTurn();
  REQUIRE(g.playCard(0));                // p1 summons a bear (atk 3)
  CHECK(g.player(1).board[0].atk == 2);  // chilled by 1
  REQUIRE(g.player(0).auras.size() == 1);
  // p1 dispels the enemy aura; the bear's attack returns within the resolve.
  g.player(1).hand.push_back(CardInstance{920, lib.find("dispelspell")});
  REQUIRE(g.playCard(static_cast<int>(g.player(1).hand.size()) - 1));
  CHECK(g.player(0).auras.empty());
  CHECK(g.player(1).board[0].atk == 3);
}

TEST_CASE("undergrowth scales attack AND hp with your other creatures") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("undergrowther", 30), repeat("bear", 30), 231);
  g.start();
  REQUIRE(g.playCard(0));
  CHECK(g.player(0).board[0].atk == 1);  // 1 + 1*(0 others)
  CHECK(g.player(0).board[0].hp == 4);   // 4 + 1*(0 others)
  g.player(0).hand.push_back(CardInstance{910, lib.find("bear")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1));
  CHECK(g.player(0).board[0].atk == 2);  // 1 + 1*(1 other)
  CHECK(g.player(0).board[0].hp == 5);   // hp is continuous now, not baked
}

TEST_CASE("undergrowth hp shrinks back when an ally leaves the board") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("undergrowther", 30), repeat("bear", 30), 557);
  g.start();
  REQUIRE(g.playCard(0));  // undergrowther alone -> 1/4
  g.player(0).hand.push_back(CardInstance{910, lib.find("bear")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) -
                     1));  // +bear -> 2/5
  REQUIRE(g.player(0).board.size() == 2);
  REQUIRE(g.player(0).board[0].hp == 5);
  EntityId bear = g.player(0).board[1].id;
  g.player(0).hand.push_back(CardInstance{911, lib.find("sacrifice")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1, bear));
  REQUIRE(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].atk == 1);  // back to 1 + 1*(0 others)
  CHECK(g.player(0).board[0].hp == 4);   // hp followed the ally down
}

TEST_CASE(
    "undergrowth shrink starves a wounded creature when its thicket clears") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("undergrowther", 30), repeat("bear", 30), 558);
  g.start();
  REQUIRE(g.playCard(0));
  g.player(0).hand.push_back(CardInstance{910, lib.find("bear")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1));  // 2/5
  REQUIRE(g.player(0).board.size() == 2);
  g.player(0).board[0].hp = 1;  // wound it: maxHp 5, 4 damage taken
  EntityId bear = g.player(0).board[1].id;
  g.player(0).hand.push_back(CardInstance{911, lib.find("sacrifice")});
  REQUIRE(g.playCard(static_cast<int>(g.player(0).hand.size()) - 1, bear));
  // maxHp drops 5->4 as the ally leaves; the 4 damage now exceeds it -> it
  // dies.
  CHECK(g.player(0).board.empty());
}

TEST_CASE("resonance charges from your crystals at summon") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("resonator", 30), repeat("bear", 30), 232);
  g.start();
  REQUIRE(g.placeCardToMana(0, Color::Colorless));  // 1 crystal
  REQUIRE(g.playCard(0));
  CHECK(g.player(0).board[0].atk == 2);  // 1 + 1*(1 crystal) snapshot
}

TEST_CASE("resonance is a snapshot and does not grow after summon") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("resonator", 30), repeat("bear", 30), 233);
  begin(g);
  REQUIRE(g.placeCardToMana(0, Color::Colorless));  // 1 crystal
  REQUIRE(g.playCard(0));
  CHECK(g.player(0).board[0].atk == 2);    // charged once at summon
  CHECK(g.player(0).board[0].maxHp == 5);  // hp also snapshot: 4 + 1
  g.endTurn();
  g.endTurn();                                      // back to player 0
  REQUIRE(g.placeCardToMana(0, Color::Colorless));  // a second crystal
  CHECK(g.player(0).board[0].atk == 2);  // unchanged -- resonance never grows
}

TEST_CASE("view redacts hidden information per player") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("sleeper", 30), repeat("bear", 30), 300);
  g.start();
  REQUIRE(g.placeCardToMana(0, Color::Colorless));  // p0 banks an awaken card
  nlohmann::json v0 = nlohmann::json::parse(viewJson(g, 0));
  nlohmann::json v1 = nlohmann::json::parse(viewJson(g, 1));
  // Own view: hand listed, own awaken card visible in the mana row.
  CHECK(v0["players"][0].contains("hand"));
  CHECK(v0["players"][0]["manaRow"][0].contains("card"));
  CHECK(v0["players"][0]["manaRow"][0]["card"] == "sleeper");
  // Opponent's view of player 0: hand hidden (count only), identity hidden.
  CHECK_FALSE(v1["players"][0].contains("hand"));
  CHECK(v1["players"][0]["handCount"].get<int>() >= 0);
  CHECK_FALSE(v1["players"][0]["manaRow"][0].contains("card"));
  CHECK(v1["players"][0]["manaRow"][0]["color"] == "colorless");
}

TEST_CASE("applyAction dispatches JSON actions and enforces the turn") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 301);
  begin(g);
  CHECK_FALSE(applyAction(g, 1, R"({"action":"endTurn"})"));  // not p1's turn
  CHECK(applyAction(g, 0, R"({"action":"play","handIndex":0})"));
  CHECK(g.player(0).board.size() == 1);
  CHECK(applyAction(g, 0, R"({"action":"endTurn"})"));
  CHECK(g.current() == 1);
  CHECK(applyAction(
      g, 1, R"({"action":"placeMana","handIndex":0,"color":"colorless"})"));
  CHECK(g.player(1).mana.crystals[idx(Color::Colorless)] == 1);
}

// --- Heroes (passive powers, DESIGN §6) --------------------------------------

TEST_CASE("hero identity and passive are public in both players' views") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 3, "hero_prism",
         "hero_lighteater");
  begin(g);
  nlohmann::json v = nlohmann::json::parse(viewJson(g, 0));
  CHECK(v["players"][0]["hero"]["card"] == "hero_prism");
  CHECK(v["players"][0]["hero"]["passive"][0]["id"] == "spectral_shift");
  // The opponent's hero is public too, so you can read their passive.
  CHECK(v["players"][1]["hero"]["card"] == "hero_lighteater");
  CHECK(v["players"][1]["hero"]["passive"][0]["id"] == "lighteater");
}

TEST_CASE("Prism spectral_shift pays a foreign pip with a neighbour crystal") {
  CardLibrary lib = testLib();
  // A red pip with only a yellow crystal: Yellow is adjacent to Red on the
  // spectrum, so the Prism can retune it. Without the Prism it stays unpayable.
  Game prism(lib, {"yellowbody", "redonly", "yellowbody", "yellowbody"},
             repeat("bear", 30), 7, "hero_prism", "");
  begin(prism);
  CHECK(prism.placeCardToMana(handIndexOf(prism, 0, "yellowbody"),
                              Color::Yellow));
  CHECK(prism.playCard(handIndexOf(prism, 0, "redonly")));  // shifted Y->R
  CHECK(prism.player(0).board.size() == 1);

  Game plain(lib, {"yellowbody", "redonly", "yellowbody", "yellowbody"},
             repeat("bear", 30), 7);  // no hero
  begin(plain);
  CHECK(plain.placeCardToMana(handIndexOf(plain, 0, "yellowbody"),
                              Color::Yellow));
  CHECK_FALSE(plain.playCard(handIndexOf(plain, 0, "redonly")));  // no shift
  CHECK(plain.player(0).board.empty());
}

TEST_CASE("Prism spectral_shift is spent once per turn") {
  CardLibrary lib = testLib();
  Game g(lib, {"redonly", "redonly", "yellowbody", "yellowbody"},
         repeat("bear", 30), 7, "hero_prism", "");
  begin(g);
  // Turn 1: bank one yellow crystal, pass.
  CHECK(g.placeCardToMana(handIndexOf(g, 0, "yellowbody"), Color::Yellow));
  g.endTurn();  // -> P1
  g.endTurn();  // -> P0, turn 2; shift recharges
  // Turn 2: bank a second yellow crystal -> two yellow available.
  CHECK(g.placeCardToMana(handIndexOf(g, 0, "yellowbody"), Color::Yellow));
  CHECK(g.playCard(handIndexOf(g, 0, "redonly")));  // first uses the shift
  CHECK_FALSE(g.playCard(handIndexOf(g, 0, "redonly")));  // shift already spent
  CHECK(g.player(0).board.size() == 1);
}

TEST_CASE("Palette draws a card the first time you play a multicolor card") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("dual", 30), repeat("dual", 30), 11, "hero_palette", "");
  begin(g);
  // Bank a Red then a Blue crystal so a dual (red+blue) becomes affordable.
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "dual"), Color::Red));
  g.endTurn();
  g.endTurn();
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "dual"), Color::Blue));
  g.endTurn();
  g.endTurn();
  int before = static_cast<int>(g.player(0).hand.size());
  REQUIRE(g.playCard(handIndexOf(g, 0, "dual")));  // multicolor card
  CHECK(g.player(0).hand.size() == before);  // -1 played, +1 drawn by Palette
}

TEST_CASE("Facet wakes any banked card, entering +1/+1") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 22, "hero_facet", "");
  begin(g);
  // Bank a bear (3/4) as a Colorless crystal; bear has no awaken keyword.
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "bear"), Color::Colorless));
  g.endTurn();
  g.endTurn();           // P0 turn 3: the banked crystal is available again
  REQUIRE(g.awaken(0));  // Facet lets a non-awaken card be woken
  REQUIRE(g.player(0).board.size() == 1);
  CHECK(g.player(0).board[0].def->id == "bear");
  CHECK(g.player(0).board[0].atk == 4);    // 3 +1
  CHECK(g.player(0).board[0].maxHp == 5);  // 4 +1
}

TEST_CASE("Facet reveals every banked card in its own view (any is wakeable)") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 5, "hero_facet", "");
  begin(g);
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "bear"), Color::Colorless));
  nlohmann::json v = nlohmann::json::parse(viewJson(g, 0));
  REQUIRE(v["players"][0]["manaRow"].size() == 1);
  CHECK(v["players"][0]["manaRow"][0]["card"] == "bear");  // bear has no awaken
  // A non-Facet hero keeps a banked non-awaken card hidden.
  Game g2(lib, repeat("bear", 30), repeat("bear", 30), 5, "hero_prism", "");
  begin(g2);
  REQUIRE(g2.placeCardToMana(handIndexOf(g2, 0, "bear"), Color::Colorless));
  nlohmann::json v2 = nlohmann::json::parse(viewJson(g2, 0));
  CHECK_FALSE(v2["players"][0]["manaRow"][0].contains("card"));
}

TEST_CASE("Lighteater devours 1 ATK from a creature that strikes the hero") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 33, "hero_prism",
         "hero_lighteater");
  begin(g);
  REQUIRE(g.playCard(handIndexOf(g, 0, "bear")));  // P0 bear 3/4
  EntityId bear = g.player(0).board[0].id;
  g.endTurn();
  g.endTurn();                                   // P0 turn 3: bear awake
  REQUIRE(g.attackHero(bear));                   // strikes the lighteater hero
  CHECK(g.player(1).heroHp == HeroStartHp - 3);  // full 3 this hit
  CHECK(g.player(0).board[0].atk == 2);          // then -1 ATK forever
  g.endTurn();
  g.endTurn();  // P0 turn 5
  REQUIRE(g.attackHero(bear));
  CHECK(g.player(1).heroHp == HeroStartHp - 5);  // 3 + 2
  CHECK(g.player(0).board[0].atk == 1);
}

// --- legalActions (M1) -------------------------------------------------------

// Inject a board creature in a known state (the legalActions tests build
// precise positions directly; ids well above any dealt card avoid collisions).
static EntityId putCreature(Game& g, int player, const CardLibrary& lib,
                            const char* id, bool sick) {
  const CardDef* d = lib.find(id);
  Creature c;
  c.id = 1000 + player * 100 + static_cast<int>(g.player(player).board.size());
  c.def = d;
  c.baseAtk = d->stats.atk;
  c.atk = d->stats.atk;
  c.hp = d->stats.hp;
  c.maxHp = d->stats.hp;
  c.baseMaxHp = d->stats.hp;
  c.sick = sick;
  g.player(player).board.push_back(c);
  return c.id;
}

TEST_CASE("legalActions: none mid-mulligan; every enumerated move applies") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 7);
  g.start();
  CHECK(g.legalActions().empty());  // parameterized phase -> no discrete moves
  g.mulligan(0, {});
  g.mulligan(1, {});
  auto acts = g.legalActions();
  CHECK_FALSE(acts.empty());
  int ends = 0;
  for (const auto& a : acts)
    if (a.type == Action::Type::EndTurn) ++ends;
  CHECK(ends == 1);  // endTurn is always present, exactly once
  // Soundness: each enumerated action, replayed on a fresh copy of this exact
  // state, is accepted by applyAction. (Copy-construction is safe here: no
  // interned token defs are on the board, and the original outlives each copy.)
  for (const auto& a : acts) {
    Game c = g;
    CHECK(applyAction(c, g.current(), actionJson(a)));
  }
}

TEST_CASE("legalActions: attacks honour ready / provoke / stealth / bypass") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 7);
  begin(g);  // player 0 to act

  EntityId mine = putCreature(g, 0, lib, "bear", /*sick=*/false);  // 3/4 ready
  EntityId sick = putCreature(g, 0, lib, "bear", /*sick=*/true);
  EntityId enemy = putCreature(g, 1, lib, "bear", /*sick=*/false);

  auto has = [&](Action::Type t, EntityId atk, EntityId tgt) {
    for (const auto& a : g.legalActions())
      if (a.type == t && a.attacker == atk && a.target == tgt) return true;
    return false;
  };
  // No provoke: ready creature may hit the enemy creature and the face; the
  // summoning-sick one can do neither.
  CHECK(has(Action::Type::AttackCreature, mine, enemy));
  CHECK(has(Action::Type::AttackHero, mine, 0));
  CHECK_FALSE(has(Action::Type::AttackCreature, sick, enemy));
  CHECK_FALSE(has(Action::Type::AttackHero, sick, 0));

  // Enemy gains a provoker: attacks are forced onto it; the face is blocked.
  EntityId guard = putCreature(g, 1, lib, "guard", /*sick=*/false);  // provoke
  CHECK(has(Action::Type::AttackCreature, mine, guard));
  CHECK_FALSE(has(Action::Type::AttackCreature, mine, enemy));
  CHECK_FALSE(has(Action::Type::AttackHero, mine, 0));

  // A Bypass creature ignores provoke for the face.
  EntityId byp = putCreature(g, 0, lib, "bypasser", /*sick=*/false);
  CHECK(has(Action::Type::AttackHero, byp, 0));

  // A stealthed enemy cannot be targeted at all.
  EntityId hidden = putCreature(g, 1, lib, "hider", /*sick=*/false);
  CHECK_FALSE(has(Action::Type::AttackCreature, mine, hidden));
}

TEST_CASE("legalActions: placeMana colors, play targets, board-full gating") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 7);
  begin(g);

  // A known hand: a neutral creature, a red creature, and a targeted spell.
  auto& hand = g.player(0).hand;
  hand.clear();
  hand.push_back(CardInstance{2001, lib.find("bear")});
  hand.push_back(CardInstance{2002, lib.find("redpip")});
  hand.push_back(CardInstance{2003, lib.find("frost1")});  // chosen_enemy, opt.

  auto acts = g.legalActions();
  auto placeColor = [&](int handIndex) -> std::vector<Color> {
    std::vector<Color> cs;
    for (const auto& a : acts)
      if (a.type == Action::Type::PlaceMana && a.handIndex == handIndex)
        cs.push_back(a.color);
    return cs;
  };
  // Neutral -> Colorless only; the red card -> Red only (one option each).
  CHECK(placeColor(0) == std::vector<Color>{Color::Colorless});
  CHECK(placeColor(1) == std::vector<Color>{Color::Red});

  auto playTargets = [&](std::vector<Action> as, int handIndex) {
    std::vector<EntityId> ts;
    for (const auto& a : as)
      if (a.type == Action::Type::Play && a.handIndex == handIndex)
        ts.push_back(a.target);
    return ts;
  };
  // frost1 is a generic:0 targeted spell. With no enemy creature its effect is
  // optional, so the only play has target 0 (the effect skips).
  CHECK(playTargets(acts, 2) == std::vector<EntityId>{0});
  // With an enemy creature present, both "skip" (0) and "hit it" are offered.
  EntityId foe = putCreature(g, 1, lib, "bear", /*sick=*/false);
  auto ts = playTargets(g.legalActions(), 2);
  CHECK(ts.size() == 2);
  CHECK(std::find(ts.begin(), ts.end(), EntityId{0}) != ts.end());
  CHECK(std::find(ts.begin(), ts.end(), foe) != ts.end());

  // Fill the board to the limit: the neutral creature can no longer be played,
  // but the spell still can (it does not enter the board).
  while (static_cast<int>(g.player(0).board.size()) < BoardLimit)
    putCreature(g, 0, lib, "bear", /*sick=*/false);
  auto full = g.legalActions();
  bool creaturePlay = false, spellPlay = false;
  for (const auto& a : full)
    if (a.type == Action::Type::Play) {
      if (a.handIndex == 0) creaturePlay = true;  // bear (creature)
      if (a.handIndex == 2) spellPlay = true;     // frost1 (spell)
    }
  CHECK_FALSE(creaturePlay);
  CHECK(spellPlay);
}

// --- serialization (M1) ------------------------------------------------------

TEST_CASE("serialize: round-trips a rich mid-game state exactly") {
  CardLibrary lib = testLib();
  // A deck that lets P0 reach a state exercising the tricky parts: an interned
  // token (germinate sprout), the mana row (a banked card), a pending delayed
  // effect, a spent-vs-available mana split, and a populated graveyard.
  std::vector<std::string> d0;
  for (int i = 0; i < 15; ++i) {
    d0.push_back("germinator");
    d0.push_back("delaybolt");
  }
  Game g(lib, d0, repeat("bear", 30), 4242);
  begin(g);

  // P0 turn 1: bank a germinator to mana, then play one.
  REQUIRE(g.placeCardToMana(handIndexOf(g, 0, "germinator"), Color::Colorless));
  REQUIRE(g.playCard(handIndexOf(g, 0, "germinator")));
  g.endTurn();  // -> P1
  g.endTurn();  // -> P0 (the germinator is no longer summoning sick)

  // Activate germinate (interns a token_sprout2 and summons it), then play a
  // delayed bolt (schedules a pending effect; the spell goes to the graveyard).
  EntityId gid = 0;
  for (const auto& c : g.player(0).board)
    if (c.def->id == "germinator") gid = c.id;
  REQUIRE(gid != 0);
  REQUIRE(g.activate(gid));
  REQUIRE(g.playCard(handIndexOf(g, 0, "delaybolt")));
  REQUIRE(g.player(0).board.size() == 2);      // germinator + sprout token
  REQUIRE(g.player(0).manaRow.size() == 1);    // a banked card
  REQUIRE(g.player(0).pending.size() == 1);    // a delayed bolt
  REQUIRE(g.player(0).graveyard.size() == 1);  // the spent delaybolt

  std::string saved = g.toJson();
  auto g2 = Game::fromJson(lib, saved);

  // Identical observable state from both perspectives, identical legal moves,
  // and re-serializing is byte-identical (every field round-tripped, incl. the
  // RNG state, nextId, and the interned token def).
  CHECK(viewJson(g, 0) == viewJson(*g2, 0));
  CHECK(viewJson(g, 1) == viewJson(*g2, 1));
  CHECK(legalActionsJson(g) == legalActionsJson(*g2));
  CHECK(g2->toJson() == saved);

  // The restored game continues identically: the same action yields the same
  // resulting view on both (the end-of-turn draw exercises deck order).
  CHECK(applyAction(g, 0, R"({"action":"endTurn"})"));
  CHECK(applyAction(*g2, 0, R"({"action":"endTurn"})"));
  CHECK(viewJson(g, 0) == viewJson(*g2, 0));
  CHECK(viewJson(g, 1) == viewJson(*g2, 1));
}

TEST_CASE("replay: a recorded game reproduces the exact final state") {
  CardLibrary lib = testLib();
  std::uint32_t seed = 777;
  std::vector<std::string> d0;
  for (int i = 0; i < 15; ++i) {
    d0.push_back("germinator");
    d0.push_back("redpip");
  }
  std::vector<std::string> d1 = repeat("bear", 30);

  Game g(lib, d0, d1, seed);
  g.start();
  std::vector<std::pair<int, std::string>> log;
  auto act = [&](int actor, const std::string& a) {
    REQUIRE(applyAction(g, actor, a));
    log.push_back({actor, a});
  };
  act(0, R"({"action":"mulligan","indices":[]})");
  act(1, R"({"action":"mulligan","indices":[]})");

  // Drive ~40 deterministic moves across several turns. Each turn: prefer to
  // play / activate / attack / bank, ending the turn only when nothing else is
  // offered -- a varied sequence that exercises every action kind in the log.
  const Action::Type pref[] = {
      Action::Type::Play,       Action::Type::Activate,
      Action::Type::AttackHero, Action::Type::AttackCreature,
      Action::Type::PlaceMana,  Action::Type::EndTurn};
  for (int step = 0; step < 40 && !g.isOver(); ++step) {
    auto la = g.legalActions();
    const Action* pick = nullptr;
    for (Action::Type want : pref) {
      for (const auto& a : la)
        if (a.type == want) {
          pick = &a;
          break;
        }
      if (pick) break;
    }
    REQUIRE(pick != nullptr);  // endTurn is always available -> never stuck
    act(g.current(), actionJson(*pick));
  }
  std::string finalState = g.toJson();
  REQUIRE(log.size() > 10);  // a non-trivial game was recorded

  std::string replay = makeReplay(seed, d0, d1, "", "", log);
  int applied0 = 0, applied1 = 0;
  auto r1 = runReplay(lib, replay, &applied0);
  auto r2 = runReplay(lib, replay, &applied1);
  CHECK(applied0 == static_cast<int>(log.size()));  // every action re-applied
  CHECK(r1->toJson() == finalState);  // reproduces the exact final state
  CHECK(r2->toJson() == finalState);  // and is deterministic across runs
}

// --- fuzz (M1) ---------------------------------------------------------------

TEST_CASE("fuzz: random games hold invariants and legalActions stays sound") {
  CardLibrary lib = testLib();
  // A broad card pool so games exercise targets, tokens, statuses, scry, delay,
  // awaken, auras, walls and provoke.
  const char* pool[] = {"bear",     "redpip",    "guard",       "hider",
                        "bypasser", "shielded",  "warded",      "germinator",
                        "frost1",   "sacrifice", "delaybolt",   "decoyling",
                        "grower",   "composter", "lifestealer", "piercer",
                        "wall",     "scryspell", "floodaura",   "lingerer",
                        "regenbear"};
  const int poolN = static_cast<int>(sizeof(pool) / sizeof(pool[0]));
  auto makeDeck = [&](std::mt19937& r) {
    std::vector<std::string> d;
    for (int i = 0; i < 30; ++i) d.push_back(pool[r() % poolN]);
    return d;
  };

  const int kGames = 200;
  for (int gi = 0; gi < kGames; ++gi) {
    // The fuzzer's own RNG is seeded per game, so any failing game reproduces;
    // the recorded `log` also replays it via runReplay regardless.
    std::mt19937 fr(1000 + gi);
    std::uint32_t seed = fr();
    std::vector<std::string> d0 = makeDeck(fr), d1 = makeDeck(fr);
    Game g(lib, d0, d1, seed);
    g.start();

    std::vector<std::pair<int, std::string>> log;
    auto apply = [&](int actor, const std::string& a) {
      bool ok = applyAction(g, actor, a);
      if (ok) log.emplace_back(actor, a);
      return ok;
    };
    auto subset = [&](int n) {  // a random subset of [0, n) for mulligan/scry
      std::vector<int> v;
      for (int i = 0; i < n; ++i)
        if (fr() % 2) v.push_back(i);
      return v;
    };
    auto dump = [&]() { return makeReplay(seed, d0, d1, "", "", log); };

    for (int step = 0; step < 500 && !g.isOver(); ++step) {
      if (g.inMulligan()) {
        int p = g.mulliganDone(0) ? 1 : 0;
        nlohmann::json mj{
            {"action", "mulligan"},
            {"indices", subset(static_cast<int>(g.player(p).hand.size()))}};
        if (!apply(p, mj.dump())) FAIL("mulligan rejected\n" << dump());
      } else if (g.inScry()) {
        int p = g.scryPlayer();
        nlohmann::json sj{
            {"action", "scryResolve"},
            {"bottom", subset(static_cast<int>(g.scryPeek().size()))}};
        if (!apply(p, sj.dump())) FAIL("scryResolve rejected\n" << dump());
      } else {
        std::vector<Action> la = g.legalActions();
        if (la.empty()) FAIL("no legal action in an active phase\n" << dump());
        const Action& a = la[fr() % la.size()];
        if (!apply(g.current(), actionJson(a)))
          FAIL("legalActions offered an action applyAction rejected\n"
               << dump());
      }

      // Invariants that must hold after every applied action.
      for (int pi = 0; pi < 2; ++pi) {
        const Player& p = g.player(pi);
        if (p.heroHp > HeroStartHp) FAIL("heroHp above start\n" << dump());
        if (p.heroArmor < 0) FAIL("negative armor\n" << dump());
        if (static_cast<int>(p.board.size()) > BoardLimit)
          FAIL("board over the limit\n" << dump());
        if (static_cast<int>(p.hand.size()) > HandLimit)
          FAIL("hand over the limit\n" << dump());
        for (int i = 0; i < ColorCount; ++i)
          if (p.mana.crystals[i] < 0 || p.mana.available[i] < 0)
            FAIL("negative mana\n" << dump());
        for (const auto& c : p.board) {
          if (c.hp <= 0)
            FAIL("a dead creature is still on the board\n" << dump());
          if (c.hp > c.maxHp) FAIL("hp above maxHp\n" << dump());
          if (c.atk < 0) FAIL("negative atk\n" << dump());
        }
      }
    }

    // The recorded game replays to the exact same final state (serialization +
    // replay exercised on every fuzzed game).
    auto r = runReplay(lib, dump());
    if (r->toJson() != g.toJson())
      FAIL("replay diverged from the fuzzed game\n" << dump());
  }
}

#ifdef PRISM_SAMPLE
TEST_CASE("sample.json loads with expected schema") {
  CardLibrary lib;
  lib.loadFile(PRISM_SAMPLE);
  CHECK(lib.size() >= 6);  // monos, bicolor pairs, neutrals, penta and heroes
  const CardDef* glint = lib.find("red_stinging_glint");
  REQUIRE(glint != nullptr);
  CHECK(glint->type == CardType::Creature);
  CHECK(glint->cost.generic == 0);
  CHECK(glint->cost.pips[idx(Color::Red)] == 1);
  CHECK(glint->stats.atk == 2);
  CHECK(glint->stats.hp == 1);
  REQUIRE(glint->keywords.size() == 1);
  CHECK(glint->keywords[0].id == "pierce");

  const CardDef* bonfire = lib.find("red_undying_bonfire");
  REQUIRE(bonfire != nullptr);
  REQUIRE(bonfire->keywords.size() == 2);
  CHECK(bonfire->keywords[0].id == "regen");
  REQUIRE(bonfire->keywords[0].n.has_value());
  CHECK(bonfire->keywords[0].n.value() == 2);

  const CardDef* gleam = lib.find("violet_dim_gleam");
  REQUIRE(gleam != nullptr);
  CHECK(gleam->colors.size() == 1);
  CHECK(gleam->colors[0] == Color::Violet);
  CHECK(gleam->cost.pips[idx(Color::Violet)] == 1);

  const CardDef* knight = lib.find("red_yellow_sunset_knight");
  REQUIRE(knight != nullptr);
  CHECK(knight->colors.size() == 2);
  CHECK(knight->cost.generic == 1);
  CHECK(knight->cost.pips[idx(Color::Red)] == 1);
  CHECK(knight->cost.pips[idx(Color::Yellow)] == 1);
}

TEST_CASE("a duplicate aura cannot be played") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("photoaura", 30), repeat("bear", 30), 7);
  g.start();
  CHECK(g.playCard(0));  // first aura enters play
  CHECK(g.player(0).auras.size() == 1);
  CHECK_FALSE(g.playCard(0));  // an identical aura is rejected
  CHECK(g.player(0).auras.size() == 1);
}

TEST_CASE("a friendly-target spell freezes your own creature") {
  CardLibrary lib = testLib();
  // A 4-card deck means the opening hand of 4 is the whole deck, so both the
  // bear and the spell are in hand regardless of the shuffle.
  Game g(lib, {"bear", "bear", "selffreeze", "selffreeze"}, repeat("bear", 30),
         11);
  g.start();
  CHECK(g.playCard(handIndexOf(g, 0, "bear")));  // play a bear
  EntityId mine = g.player(0).board[0].id;
  CHECK(g.playCard(handIndexOf(g, 0, "selffreeze"), mine));  // freeze your own
  CHECK(g.player(0).board[0].frozenTurns == 2);
  // A friendly-target spell with no such friendly creature is illegal.
  CHECK_FALSE(g.playCard(handIndexOf(g, 0, "selffreeze"), 9999));
}

TEST_CASE("an any-target spell can hit your own creature") {
  CardLibrary lib = testLib();
  Game g(lib, {"bear", "bear", "anyfreeze", "anyfreeze"}, repeat("bear", 30),
         13);
  g.start();
  CHECK(g.playCard(handIndexOf(g, 0, "bear")));
  EntityId mine = g.player(0).board[0].id;
  CHECK(
      g.playCard(handIndexOf(g, 0, "anyfreeze"), mine));  // friendly is allowed
  CHECK(g.player(0).board[0].frozenTurns == 2);
}

TEST_CASE("a creature can be placed at a chosen board slot") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("bear", 30), 5);
  g.start();
  CHECK(g.playCard(0));
  EntityId a = g.player(0).board[0].id;
  CHECK(g.playCard(0));  // appended to the right by default
  EntityId b = g.player(0).board[1].id;
  CHECK(g.playCard(0, 0, 1));  // insert between a and b
  REQUIRE(g.player(0).board.size() == 3);
  EntityId c = g.player(0).board[1].id;
  CHECK(g.player(0).board[0].id == a);
  CHECK(g.player(0).board[2].id == b);
  CHECK(c != a);
  CHECK(c != b);
  // An out-of-range slot simply appends.
  CHECK(g.playCard(0, 0, 99));
  CHECK(g.player(0).board.size() == 4);
}

TEST_CASE("a positioned summon inserts there; its split tokens sit beside it") {
  CardLibrary lib = testLib();
  Game g(lib, {"bear", "bear", "splitter", "splitter"}, repeat("bear", 30), 3);
  g.start();
  CHECK(g.playCard(handIndexOf(g, 0, "bear")));
  EntityId bear0 = g.player(0).board[0].id;
  // splitter carries split:2; play it at the front (slot 0).
  CHECK(g.playCard(handIndexOf(g, 0, "splitter"), 0, 0));
  REQUIRE(g.player(0).board.size() == 4);  // splitter + 2 illusions + bear
  CHECK(g.player(0).board[0].def->id == "splitter");  // inserted at the front
  CHECK(g.player(0).board[1].token);  // split tokens cluster next to the parent
  CHECK(g.player(0).board[2].token);
  CHECK(g.player(0).board[3].id == bear0);  // the old neighbour shifts right
}

TEST_CASE("an enemy-target spell cannot hit your own creature") {
  CardLibrary lib = testLib();
  Game g(lib, {"bear", "bear", "frost1", "frost1"}, repeat("bear", 30), 17);
  g.start();
  CHECK(g.playCard(handIndexOf(g, 0, "bear")));
  EntityId mine = g.player(0).board[0].id;
  CHECK_FALSE(g.playCard(handIndexOf(g, 0, "frost1"), mine));  // enemy-only
  CHECK(g.player(0).board[0].frozenTurns == 0);
}
#endif
