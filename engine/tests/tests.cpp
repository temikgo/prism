#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"

// Unit tests for the engine. Each case isolates one rule or keyword: mana,
// combat (mutual ATK), the win condition, fatigue, JSON loading, and every
// implemented keyword/effect. Small self-contained card sets (kTestCards) keep
// the tests independent of real card balance.

#include <string>
#include <vector>

#include "prism/card.hpp"
#include "prism/game.hpp"
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
  { "id": "lingerer", "name": { "ru": "Неугас" }, "type": "creature",
    "color": [], "cost": { "generic": 0 }, "stats": { "atk": 2, "hp": 3 },
    "keywords": [{ "id": "lingering" }] },
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
  { "id": "frost1", "name": { "ru": "Иней" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "freeze", "value": 1 }] },
  { "id": "blindspell", "name": { "ru": "Слепота" }, "type": "spell",
    "color": [], "cost": { "generic": 0 },
    "effects": [{ "trigger": "on_play", "selector": "chosen_enemy_minion",
                  "action": "blind", "value": 1 }] },
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
    "keywords": [{ "id": "awaken" }] }
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
