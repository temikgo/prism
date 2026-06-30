#include "prism/protocol.hpp"

#include <array>
#include <optional>

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
// `deckHeld` = cards this player is currently holding mid-scry; they belong to
// the deck (scry only reorders the top), so count them as still in it.
static json playerJson(const Player& p, bool self, bool revealMana,
                       int deckHeld) {
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

  // The Facet hero (Gemma) may wake ANY of its banked cards, not only the
  // awaken-keyword ones, so reveal them all to its own view.
  bool facet = self && p.hero && p.hero->hasKeyword("facet");
  json row = json::array();
  for (const auto& mc : p.manaRow) {
    json slot = {{"color", std::string(colorName(mc.color))}};
    // You may peek your own wakeable cards (awaken OR decoy -- both can be
    // woken from the mana row, see Game::awaken); floodlight reveals all of an
    // enemy's.
    const bool wakeable =
        mc.card.def->hasKeyword("awaken") || mc.card.def->hasKeyword("decoy");
    if ((self && wakeable) || facet || revealMana)
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
  // Whether a limited hero passive has been used this turn (e.g. Prism's swap).
  if (self) j["heroPowerUsed"] = p.heroPowerUses > 0;
  if (self) j["placedMana"] = p.placedManaThisTurn;  // already banked a card?
  j["deckCount"] = static_cast<int>(p.deck.size()) + deckHeld;
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
    int deckHeld = (g.inScry() && g.scryPlayer() == i)
                       ? static_cast<int>(g.scryPeek().size())
                       : 0;
    players.push_back(playerJson(g.player(i), self,
                                 /*revealMana=*/!self && floodlight, deckHeld));
  }
  j["players"] = players;
  return j.dump();
}

static json actionObj(const Action& a) {
  switch (a.type) {
    case Action::Type::EndTurn:
      return json{{"action", "endTurn"}};
    case Action::Type::PlaceMana:
      return json{{"action", "placeMana"},
                  {"handIndex", a.handIndex},
                  {"color", std::string(colorName(a.color))}};
    case Action::Type::Play: {
      json j{{"action", "play"}, {"handIndex", a.handIndex}};
      if (a.target) j["target"] = a.target;
      return j;
    }
    case Action::Type::Awaken: {
      json j{{"action", "awaken"}, {"manaRowIndex", a.manaRowIndex}};
      if (a.target) j["target"] = a.target;
      return j;
    }
    case Action::Type::Activate:
      return json{{"action", "activate"},
                  {"id", a.id},
                  {"color", std::string(colorName(a.color))}};
    case Action::Type::AttackCreature:
      return json{{"action", "attackCreature"},
                  {"attacker", a.attacker},
                  {"target", a.target}};
    case Action::Type::AttackHero:
      return json{{"action", "attackHero"}, {"attacker", a.attacker}};
  }
  return json::object();
}

std::string actionJson(const Action& a) { return actionObj(a).dump(); }

std::string legalActionsJson(const Game& g) {
  json arr = json::array();
  for (const Action& a : g.legalActions()) arr.push_back(actionObj(a));
  return arr.dump();
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
  if (a == "play") {
    // Optional player-chosen breakdown of the generic cost: {"genericPay":
    // {"green":1,"blue":1}}. Absent -> the engine pays the generic part
    // greedily.
    std::optional<std::array<int, ColorCount>> genericPay;
    if (j.contains("genericPay") && j["genericPay"].is_object()) {
      std::array<int, ColorCount> gp{};
      for (auto it = j["genericPay"].begin(); it != j["genericPay"].end(); ++it)
        if (auto col = colorFromString(it.key());
            col && it.value().is_number_integer())
          gp[idx(*col)] += it.value().get<int>();
      genericPay = gp;
    }
    return g.playCard(j.value("handIndex", -1), j.value("target", 0),
                      j.value("pos", -1), genericPay);
  }
  if (a == "awaken")
    return g.awaken(j.value("manaRowIndex", -1), j.value("target", 0),
                    j.value("pos", -1));
  if (a == "activate")
    return g.activate(j.value("id", 0),
                      colorFromString(j.value("color", std::string{}))
                          .value_or(Color::Colorless));
  if (a == "attackCreature")
    return g.attackCreature(j.value("attacker", 0), j.value("target", 0));
  if (a == "attackHero") return g.attackHero(j.value("attacker", 0));
  return false;
}

std::string makeReplay(
    std::uint32_t seed, const std::vector<std::string>& deck0,
    const std::vector<std::string>& deck1, const std::string& hero0,
    const std::string& hero1,
    const std::vector<std::pair<int, std::string>>& actions) {
  json j;
  j["seed"] = seed;
  j["decks"] = json::array({deck0, deck1});
  j["heroes"] = json::array({hero0, hero1});
  json acts = json::array();
  for (const auto& [actor, action] : actions)
    acts.push_back(json{{"actor", actor}, {"action", json::parse(action)}});
  j["actions"] = acts;
  return j.dump();
}

std::unique_ptr<Game> runReplay(const CardLibrary& lib,
                                const std::string& replayJson, int* applied) {
  json j = json::parse(replayJson);
  auto decks = j.value("decks", json::array({json::array(), json::array()}));
  auto heroes = j.value("heroes", json::array({"", ""}));
  auto g = std::make_unique<Game>(
      lib, decks[0].get<std::vector<std::string>>(),
      decks[1].get<std::vector<std::string>>(), j.value("seed", 0u),
      heroes[0].get<std::string>(), heroes[1].get<std::string>());
  g->start();
  int ok = 0;
  for (const auto& a : j.value("actions", json::array()))
    if (applyAction(*g, a.value("actor", 0), a.at("action").dump())) ++ok;
  if (applied) *applied = ok;
  return g;
}

}  // namespace prism
