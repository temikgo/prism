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
              {"usedActive", c.usedActive},
              {"frozen", c.frozenTurns},
              {"blind", c.blindTurns},
              {"shield", c.shield},
              {"ward", c.warded},
              {"stealth", c.stealthed},
              {"token", c.token}};
}

// `self` = this is the viewing player's own side, so private info is included.
// `revealMana` = the viewer controls a Yellow floodlight aura, so this player's
// banked mana-card identities are exposed even though it is the opponent.
static json playerJson(const Player& p, bool self, bool revealMana) {
  json j;
  json hero = {{"hp", p.heroHp}, {"armor", p.heroArmor}};
  // The chosen hero is public to both players: its id, name, and passive
  // keyword(s) so each side can read the other's hero power.
  if (p.hero) {
    hero["card"] = p.hero->id;
    hero["name"] = p.hero->nameRu;
    json passive = json::array();
    for (const auto& k : p.hero->keywords) {
      json kj = {{"id", k.id}};
      if (k.n) kj["n"] = *k.n;
      passive.push_back(kj);
    }
    hero["passive"] = passive;
  }
  j["hero"] = hero;
  j["mana"] = {{"crystals", manaObj(p.mana.crystals)},
               {"available", manaObj(p.mana.available)}};

  json row = json::array();
  for (const auto& mc : p.manaRow) {
    json slot = {{"color", std::string(colorName(mc.color))}};
    // You may peek your own awaken cards; floodlight reveals all of an enemy's.
    if ((self && mc.card.def->hasKeyword("awaken")) || revealMana)
      slot["card"] = mc.card.def->id;
    if (self) slot["age"] = mc.age;  // turns banked, for the decoy discount
    row.push_back(slot);
  }
  j["manaRow"] = row;

  j["handCount"] = static_cast<int>(p.hand.size());
  if (self) {
    json hand = json::array();
    for (const auto& ci : p.hand) hand.push_back(ci.def->id);
    j["hand"] = hand;  // opponent's hand is intentionally omitted (count only)
  }
  if (self) j["shiftUsed"] = p.shiftUsed;  // Prism: spent its swap this turn?
  if (self) j["placedMana"] = p.placedManaThisTurn;  // already banked a card?
  j["deckCount"] = static_cast<int>(p.deck.size());
  // Lens clairvoyance: you always see the identity of your own top card.
  if (self && p.hero && p.hero->hasKeyword("clairvoyance") && !p.deck.empty())
    j["topCard"] = p.deck.back().def->id;  // deck back == top of deck
  j["graveyardCount"] = static_cast<int>(p.graveyard.size());
  j["pendingCount"] = static_cast<int>(p.pending.size());  // delayed effects
  j["mulliganDone"] = p.mulliganDone;

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
  j["mulligan"] = g.inMulligan();  // true while both players still mulligan
  j["over"] = g.isOver();
  j["winner"] = g.winner();
  // Blue scry: if it is the viewer's pending scry, surface the peeked cards so
  // the client can show the sort picker.
  if (g.inScry() && g.scryPlayer() == you) {
    json peek = json::array();
    for (const auto& ci : g.scryPeek()) peek.push_back(ci.def->id);
    j["scry"] = peek;
  }
  // Does the viewer control floodlight (on an aura or a creature)? If so, the
  // opponent's banked mana cards are revealed to them.
  bool floodlight = false;
  for (const auto* a : g.player(you).auras)
    if (a->hasKeyword("floodlight")) floodlight = true;
  for (const auto& c : g.player(you).board)
    if (c.def->hasKeyword("floodlight")) floodlight = true;
  json players = json::array();
  for (int i = 0; i < 2; ++i) {
    bool self = (i == you);
    players.push_back(
        playerJson(g.player(i), self, /*revealMana=*/!self && floodlight));
  }
  j["players"] = players;
  return j.dump();
}

bool applyAction(Game& g, int actor, const std::string& actionJson) {
  json j;
  try {
    j = json::parse(actionJson);
  } catch (...) {
    return false;
  }
  const std::string a = j.value("action", std::string{});
  // Mulligan precedes the first turn; either player may submit theirs, in any
  // order, so it is handled before the "active player only" gate below.
  if (a == "mulligan") {
    std::vector<int> indices;
    if (j.contains("indices") && j["indices"].is_array())
      for (const auto& v : j["indices"])
        if (v.is_number_integer()) indices.push_back(v.get<int>());
    return g.mulligan(actor, indices);
  }
  if (g.inMulligan()) return false;  // no normal actions until mulligan is over
  // A pending scry blocks everything else until the player sorts the peek.
  if (a == "scryResolve") {
    std::vector<int> bottom;
    if (j.contains("bottom") && j["bottom"].is_array())
      for (const auto& v : j["bottom"])
        if (v.is_number_integer()) bottom.push_back(v.get<int>());
    return g.resolveScry(actor, bottom);
  }
  if (g.inScry()) return false;
  if (actor != g.current()) return false;  // only the active player may act
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
  if (a == "activate") return g.activate(j.value("id", 0));
  if (a == "attackCreature")
    return g.attackCreature(j.value("attacker", 0), j.value("target", 0));
  if (a == "attackHero") return g.attackHero(j.value("attacker", 0));
  return false;
}

}  // namespace prism
