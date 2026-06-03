#include "prism/protocol.hpp"

#include <array>

#include "json.hpp"

namespace prism {

using nlohmann::json;

static json manaObj(const std::array<int, ColorCount>& a) {
  json o = json::object();
  for (int i = 0; i < ColorCount; ++i)
    o[std::string(colorName(static_cast<Color>(i)))] = a[i];
  return o;
}

static json creatureJson(const Creature& c) {
  return json{{"id", c.id},
              {"card", c.def->id},
              {"atk", c.atk},
              {"hp", c.hp},
              {"maxHp", c.maxHp},
              {"sick", c.sick},
              {"attacked", c.attacked},
              {"frozen", c.frozenTurns},
              {"blind", c.blindTurns},
              {"shield", c.shield},
              {"stealth", c.stealthed},
              {"token", c.token}};
}

// `self` = this is the viewing player's own side, so private info is included.
static json playerJson(const Player& p, bool self) {
  json j;
  j["hero"] = {{"hp", p.heroHp}, {"armor", p.heroArmor}};
  j["mana"] = {{"crystals", manaObj(p.mana.crystals)},
               {"available", manaObj(p.mana.available)}};

  json row = json::array();
  for (const auto& mc : p.manaRow) {
    json slot = {{"color", std::string(colorName(mc.color))}};
    // You may peek your own awaken cards; everything else stays face-down.
    if (self && mc.card.def->hasKeyword("awaken"))
      slot["card"] = mc.card.def->id;
    row.push_back(slot);
  }
  j["manaRow"] = row;

  j["handCount"] = static_cast<int>(p.hand.size());
  if (self) {
    json hand = json::array();
    for (const auto& ci : p.hand) hand.push_back(ci.def->id);
    j["hand"] = hand;  // opponent's hand is intentionally omitted (count only)
  }
  j["deckCount"] = static_cast<int>(p.deck.size());
  j["graveyardCount"] = static_cast<int>(p.graveyard.size());

  json board = json::array();
  for (const auto& c : p.board) board.push_back(creatureJson(c));
  j["board"] = board;

  json auras = json::array();
  for (const auto* a : p.auras) auras.push_back(json{{"card", a->id}});
  j["auras"] = auras;
  return j;
}

std::string viewJson(const Game& g, int you) {
  json j;
  j["turn"] = g.turn();
  j["current"] = g.current();
  j["you"] = you;
  j["over"] = g.isOver();
  j["winner"] = g.winner();
  json players = json::array();
  for (int i = 0; i < 2; ++i)
    players.push_back(playerJson(g.player(i), i == you));
  j["players"] = players;
  return j.dump();
}

bool applyAction(Game& g, int actor, const std::string& actionJson) {
  if (actor != g.current()) return false;  // only the active player may act
  json j;
  try {
    j = json::parse(actionJson);
  } catch (...) {
    return false;
  }
  const std::string a = j.value("action", std::string{});
  if (a == "endTurn") {
    g.endTurn();
    return true;
  }
  if (a == "placeMana") {
    auto col = colorFromString(j.value("color", std::string{}));
    if (!col) return false;
    return g.placeCardToMana(j.value("handIndex", -1), *col);
  }
  if (a == "play")
    return g.playCard(j.value("handIndex", -1), j.value("target", 0),
                      j.value("pos", -1));
  if (a == "awaken")
    return g.awaken(j.value("manaRowIndex", -1), j.value("target", 0),
                    j.value("pos", -1));
  if (a == "attackCreature")
    return g.attackCreature(j.value("attacker", 0), j.value("target", 0));
  if (a == "attackHero") return g.attackHero(j.value("attacker", 0));
  return false;
}

}  // namespace prism
