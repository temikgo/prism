#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"

// Unit tests for the Phase 1 engine. Each case isolates one rule: mana
// payment, summoning sickness, DEF retaliation, mana gating, the win
// condition, fatigue, and JSON loading. Small self-contained card sets
// (kTestCards) keep the combat tests independent of real card balance.

#include <string>
#include <vector>

#include "prism/card.hpp"
#include "prism/game.hpp"
#include "prism/types.hpp"

using namespace prism;

static const char* kTestCards = R"json([
  { "id": "bear", "name": { "ru": "Медведь" }, "type": "creature",
    "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 3, "def": 2, "hp": 4 } },
  { "id": "wall", "name": { "ru": "Стена" }, "type": "creature",
    "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 0, "def": 4, "hp": 5 } },
  { "id": "redpip", "name": { "ru": "Алый" }, "type": "creature",
    "color": ["red"], "cost": { "generic": 1, "red": 1 },
    "stats": { "atk": 2, "def": 1, "hp": 2 } },
  { "id": "regenbear", "name": { "ru": "Регенератор" }, "type": "creature",
    "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 0, "def": 0, "hp": 5 },
    "keywords": [{ "id": "regen", "n": 2 }] },
  { "id": "piercer", "name": { "ru": "Бур" }, "type": "creature",
    "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 5, "def": 0, "hp": 5 },
    "keywords": [{ "id": "pierce" }] },
  { "id": "smallwall", "name": { "ru": "Барьер" }, "type": "creature",
    "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 0, "def": 2, "hp": 2 } },
  { "id": "guard", "name": { "ru": "Маяк" }, "type": "creature",
    "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 0, "def": 2, "hp": 3 },
    "keywords": [{ "id": "provoke" }] },
  { "id": "frost1", "name": { "ru": "Иней" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "freeze", "value": 1 }] },
  { "id": "photoaura", "name": { "ru": "Корень" }, "type": "aura",
    "color": [], "cost": { "generic": 0 },
    "keywords": [{ "id": "photosynthesis", "n": 1 }] },
  { "id": "splitter", "name": { "ru": "Двойник-фантом" }, "type": "creature",
    "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 2, "def": 0, "hp": 2 },
    "keywords": [{ "id": "split", "n": 2 }] },
  { "id": "sporecarrier", "name": { "ru": "Спороносец" }, "type": "creature",
    "color": [], "cost": { "generic": 0 },
    "stats": { "atk": 2, "def": 0, "hp": 2 },
    "keywords": [{ "id": "spores", "n": 2 }] }
])json";

static CardLibrary testLib() {
  CardLibrary lib;
  lib.loadJsonString(kTestCards);
  return lib;
}

static std::vector<std::string> repeat(const std::string& id, int n) {
  return std::vector<std::string>(n, id);
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

TEST_CASE("defender retaliates with DEF and can kill attacker") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("bear", 30), repeat("wall", 30), 99);
  g.start();
  CHECK(g.playCard(0));
  EntityId bear = g.player(0).board[0].id;
  g.endTurn();
  CHECK(g.playCard(0));
  EntityId wall = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(bear, wall));
  CHECK(g.player(0).board.size() == 0);
  REQUIRE(g.player(1).board.size() == 1);
  CHECK(g.player(1).board[0].hp == 2);
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
  g.start();
  CHECK(g.player(0).fatigue == 1);
  CHECK(g.player(0).heroHp == HeroStartHp - 1);
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

TEST_CASE("photosynthesis adds temporary mana at turn start") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("photoaura", 30), repeat("bear", 30), 55);
  g.start();
  REQUIRE(g.playCard(0));
  g.endTurn();
  g.endTurn();
  CHECK(g.player(0).mana.totalAvailable() == 1);
}

TEST_CASE("split spawns illusions that act now and vanish at turn end") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("splitter", 30), repeat("bear", 30), 66);
  g.start();
  REQUIRE(g.playCard(0));
  REQUIRE(g.player(0).board.size() == 3);  // the splitter plus two illusions
  int illusions = 0;
  EntityId anIllusion = 0;
  for (const auto& c : g.player(0).board)
    if (c.vanish) {
      illusions += 1;
      anIllusion = c.id;
      CHECK(c.hp == 1);
    }
  CHECK(illusions == 2);
  CHECK(g.attackHero(anIllusion));  // un-sick: can attack the turn it is made
  CHECK(g.player(1).heroHp == HeroStartHp - 2);
  g.endTurn();
  CHECK(g.player(0).board.size() == 1);  // illusions gone, only the splitter left
}

TEST_CASE("spores summons sprout tokens when the creature dies") {
  CardLibrary lib = testLib();
  Game g(lib, repeat("sporecarrier", 30), repeat("wall", 30), 77);
  g.start();
  REQUIRE(g.playCard(0));
  EntityId sc = g.player(0).board[0].id;
  g.endTurn();
  REQUIRE(g.playCard(0));
  EntityId w = g.player(1).board[0].id;
  g.endTurn();
  CHECK(g.attackCreature(sc, w));  // sporecarrier dies to the wall's DEF
  REQUIRE(g.player(0).board.size() == 2);
  for (const auto& c : g.player(0).board) {
    CHECK(c.hp == 1);
    CHECK(c.atk == 1);
  }
}

#ifdef PRISM_SAMPLE
TEST_CASE("sample.json loads with expected schema") {
  CardLibrary lib;
  lib.loadFile(PRISM_SAMPLE);
  CHECK(lib.size() == 6);
  const CardDef* borer = lib.find("red_undying_borer");
  REQUIRE(borer != nullptr);
  CHECK(borer->type == CardType::Creature);
  CHECK(borer->cost.generic == 1);
  CHECK(borer->cost.pips[idx(Color::Red)] == 1);
  CHECK(borer->stats.atk == 3);
  CHECK(borer->stats.def == 1);
  CHECK(borer->stats.hp == 3);
  REQUIRE(borer->keywords.size() == 2);
  CHECK(borer->keywords[0].id == "pierce");
  CHECK(borer->keywords[1].id == "regen");
  REQUIRE(borer->keywords[1].n.has_value());
  CHECK(borer->keywords[1].n.value() == 1);

  const CardDef* twin = lib.find("violet_phantom_twin");
  REQUIRE(twin != nullptr);
  CHECK(twin->colors.size() == 1);
  CHECK(twin->colors[0] == Color::Violet);
  CHECK(twin->cost.pips[idx(Color::Violet)] == 1);
}
#endif
