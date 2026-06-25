#include <algorithm>
#include <sstream>
#include <unordered_map>

#include "json.hpp"
#include "prism/game.hpp"

// Full-state (de)serialization for Game (declared in game.hpp). Kept in its own
// translation unit so the core game.cpp stays free of the JSON dependency,
// while these member functions still have full access to the private engine
// state (rng_, tokenDefs_, nextId_, the phase flags).
//
// Pointer model: every `const CardDef*` is stored as its string id and resolved
// on load via the library, falling back to the interned token defs (germinate
// sprouts -- synthesized N/N creatures that are not library cards). The
// interned defs are captured verbatim under "tokens" and re-created first, so
// creature def references always resolve. The mt19937 state is dumped textually
// so future shuffles reproduce exactly. The event queue is transient (empty
// between actions) and is not stored.

namespace prism {

using nlohmann::json;

namespace {

json manaArr(const std::array<int, ColorCount>& a) {
  return json(std::vector<int>(a.begin(), a.end()));
}

std::array<int, ColorCount> manaArrFrom(const json& j) {
  std::array<int, ColorCount> a{};
  for (int i = 0; i < ColorCount && i < static_cast<int>(j.size()); ++i)
    a[i] = j[i].get<int>();
  return a;
}

json instJson(const CardInstance& ci) {
  return json{{"id", ci.id}, {"def", ci.def->id}};
}

json creatureJson(const Creature& c) {
  return json{{"id", c.id},
              {"def", c.def->id},
              {"atk", c.atk},
              {"baseAtk", c.baseAtk},
              {"hp", c.hp},
              {"maxHp", c.maxHp},
              {"baseMaxHp", c.baseMaxHp},
              {"sick", c.sick},
              {"attacked", c.attacked},
              {"strobeUsed", c.strobeUsed},
              {"usedActive", c.usedActive},
              {"frozen", c.frozenTurns},
              {"blind", c.blindTurns},
              {"token", c.token},
              {"shield", c.shield},
              {"warded", c.warded},
              {"stealthed", c.stealthed},
              {"unhealable", c.unhealable}};
}

json effectJson(const EffectDef& e) {
  return json{{"trigger", e.trigger},
              {"selector", e.selector},
              {"action", e.action},
              {"value", e.value},
              {"required", e.required}};
}

EffectDef effectFrom(const json& j) {
  EffectDef e;
  e.trigger = j.value("trigger", std::string{});
  e.selector = j.value("selector", std::string{});
  e.action = j.value("action", std::string{});
  e.value = j.value("value", 0);
  e.required = j.value("required", false);
  return e;
}

json playerJson(const Player& p) {
  json j;
  j["index"] = p.index;
  j["heroHp"] = p.heroHp;
  j["heroArmor"] = p.heroArmor;
  j["hero"] = p.hero ? p.hero->id : std::string{};
  j["fatigue"] = p.fatigue;
  j["placedManaThisTurn"] = p.placedManaThisTurn;
  j["summonedThisTurn"] = p.summonedThisTurn;
  j["heroPowerUses"] = p.heroPowerUses;
  j["mulliganDone"] = p.mulliganDone;
  j["mana"] = {{"crystals", manaArr(p.mana.crystals)},
               {"available", manaArr(p.mana.available)}};
  json hand = json::array();
  for (const auto& ci : p.hand) hand.push_back(instJson(ci));
  j["hand"] = hand;
  json deck = json::array();
  for (const auto& ci : p.deck) deck.push_back(instJson(ci));
  j["deck"] = deck;
  json row = json::array();
  for (const auto& mc : p.manaRow)
    row.push_back(json{{"id", mc.card.id},
                       {"def", mc.card.def->id},
                       {"color", std::string(colorName(mc.color))},
                       {"age", mc.age}});
  j["manaRow"] = row;
  json board = json::array();
  for (const auto& c : p.board) board.push_back(creatureJson(c));
  j["board"] = board;
  json auras = json::array();
  for (const auto* a : p.auras) auras.push_back(a->id);
  j["auras"] = auras;
  json grave = json::array();
  for (const auto* g : p.graveyard) grave.push_back(g->id);
  j["graveyard"] = grave;
  json pending = json::array();
  for (const auto& d : p.pending)
    pending.push_back(json{{"effect", effectJson(d.effect)},
                           {"turnsLeft", d.turnsLeft},
                           {"target", d.target},
                           {"src", d.src ? d.src->id : std::string{}}});
  j["pending"] = pending;
  return j;
}

}  // namespace

std::string Game::toJson() const {
  json j;
  j["current"] = current_;
  j["turn"] = turn_;
  j["over"] = over_;
  j["winner"] = winner_;
  j["mulliganPhase"] = mulliganPhase_;
  j["scryPlayer"] = scryPlayer_;
  j["nextId"] = nextId_;
  std::ostringstream rng;
  rng << rng_;
  j["rng"] = rng.str();
  json peek = json::array();
  for (const auto& ci : scryPeek_) peek.push_back(instJson(ci));
  j["scryPeek"] = peek;
  // Interned synthesized defs (germinate/spores sprouts): id + N/N stats, all
  // an internToken def carries. Re-created first on load so creatures resolve.
  json tokens = json::array();
  for (const auto& d : tokenDefs_)
    tokens.push_back(
        json{{"id", d.id}, {"atk", d.stats.atk}, {"hp", d.stats.hp}});
  j["tokens"] = tokens;
  j["players"] =
      json::array({playerJson(players_[0]), playerJson(players_[1])});
  return j.dump();
}

std::unique_ptr<Game> Game::fromJson(const CardLibrary& lib,
                                     const std::string& jsonStr) {
  json j = json::parse(jsonStr);
  // Heap-allocate once and populate in place: the object never moves, so the
  // raw CardDef* that board creatures hold into tokenDefs_ stay valid.
  auto g = std::make_unique<Game>(lib, std::vector<std::string>{},
                                  std::vector<std::string>{}, std::uint32_t{0});

  g->current_ = j.value("current", 0);
  g->turn_ = j.value("turn", 0);
  g->over_ = j.value("over", false);
  g->winner_ = j.value("winner", -1);
  g->mulliganPhase_ = j.value("mulliganPhase", false);
  g->scryPlayer_ = j.value("scryPlayer", -1);
  g->nextId_ = j.value("nextId", 1);
  if (j.contains("rng")) {
    std::istringstream rng(j["rng"].get<std::string>());
    rng >> g->rng_;
  }

  // Re-intern token defs first, then resolve any def id: library card, else an
  // interned token (synthesized sprout). Heroes serialize as "" -> nullptr.
  for (const auto& t : j.value("tokens", json::array()))
    g->internToken(t.value("id", std::string{}),
                   Stats{t.value("atk", 0), t.value("hp", 0)});
  auto resolve = [&](const std::string& id) -> const CardDef* {
    if (id.empty()) return nullptr;
    if (const CardDef* d = lib.find(id)) return d;
    for (auto& d : g->tokenDefs_)
      if (d.id == id) return &d;
    return nullptr;  // unknown id: card removed from the set (treated as
                     // absent)
  };
  auto instFrom = [&](const json& ji) {
    return CardInstance{ji.value("id", 0),
                        resolve(ji.value("def", std::string{}))};
  };

  g->scryPeek_.clear();
  for (const auto& ji : j.value("scryPeek", json::array()))
    g->scryPeek_.push_back(instFrom(ji));

  const json& players = j.at("players");
  for (int pi = 0; pi < 2; ++pi) {
    const json& pj = players[pi];
    Player& p = g->players_[pi];
    p.index = pj.value("index", pi);
    p.heroHp = pj.value("heroHp", HeroStartHp);
    p.heroArmor = pj.value("heroArmor", 0);
    p.hero = resolve(pj.value("hero", std::string{}));
    p.fatigue = pj.value("fatigue", 0);
    p.placedManaThisTurn = pj.value("placedManaThisTurn", false);
    p.summonedThisTurn = pj.value("summonedThisTurn", false);
    p.heroPowerUses = pj.value("heroPowerUses", 0);
    p.mulliganDone = pj.value("mulliganDone", false);
    const json& mj = pj.at("mana");
    p.mana.crystals = manaArrFrom(mj.at("crystals"));
    p.mana.available = manaArrFrom(mj.at("available"));

    p.hand.clear();
    for (const auto& ji : pj.value("hand", json::array()))
      p.hand.push_back(instFrom(ji));
    p.deck.clear();
    for (const auto& ji : pj.value("deck", json::array()))
      p.deck.push_back(instFrom(ji));
    p.manaRow.clear();
    for (const auto& mcj : pj.value("manaRow", json::array())) {
      auto col = colorFromString(mcj.value("color", std::string{}));
      p.manaRow.push_back(
          ManaCard{CardInstance{mcj.value("id", 0),
                                resolve(mcj.value("def", std::string{}))},
                   col.value_or(Color::Colorless), mcj.value("age", 0)});
    }
    p.board.clear();
    for (const auto& cj : pj.value("board", json::array())) {
      Creature c;
      c.id = cj.value("id", 0);
      c.def = resolve(cj.value("def", std::string{}));
      c.atk = cj.value("atk", 0);
      c.baseAtk = cj.value("baseAtk", 0);
      c.hp = cj.value("hp", 0);
      c.maxHp = cj.value("maxHp", 0);
      c.baseMaxHp = cj.value("baseMaxHp", c.maxHp);
      c.sick = cj.value("sick", false);
      c.attacked = cj.value("attacked", false);
      c.strobeUsed = cj.value("strobeUsed", false);
      c.usedActive = cj.value("usedActive", false);
      c.frozenTurns = cj.value("frozen", 0);
      c.blindTurns = cj.value("blind", 0);
      c.token = cj.value("token", false);
      c.shield = cj.value("shield", false);
      c.warded = cj.value("warded", false);
      c.stealthed = cj.value("stealthed", false);
      c.unhealable = cj.value("unhealable", 0);
      p.board.push_back(c);
    }
    p.auras.clear();
    for (const auto& a : pj.value("auras", json::array()))
      if (const CardDef* d = resolve(a.get<std::string>()))
        p.auras.push_back(d);
    p.graveyard.clear();
    for (const auto& gv : pj.value("graveyard", json::array()))
      if (const CardDef* d = resolve(gv.get<std::string>()))
        p.graveyard.push_back(d);
    p.pending.clear();
    for (const auto& dj : pj.value("pending", json::array()))
      p.pending.push_back(DelayedEffect{
          effectFrom(dj.at("effect")), dj.value("turnsLeft", 0),
          dj.value("target", 0), resolve(dj.value("src", std::string{}))});
  }
  return g;
}

std::unique_ptr<Game> Game::clone() const {
  // Native deep copy -- far cheaper than a JSON round-trip (the bot clones
  // heavily). The implicit copy constructor duplicates every zone and the token
  // deque; the only fix-up is the raw CardDef* that board creatures / instances
  // hold into tokenDefs_ (synthesized sprouts): those still point into THIS
  // game's deque and must be remapped to the copy's. Library defs are shared
  // and stable (they live in lib_), so they need no fix-up. tokenDefs_ is a
  // deque, so element addresses in the copy are stable too.
  auto g = std::make_unique<Game>(*this);
  if (tokenDefs_.empty()) return g;  // common case: no synthesized tokens
  std::unordered_map<const CardDef*, const CardDef*> remap;
  auto io = tokenDefs_.begin();
  auto in = g->tokenDefs_.begin();
  for (; io != tokenDefs_.end(); ++io, ++in) remap[&*io] = &*in;
  auto fix = [&](const CardDef*& d) {
    auto it = remap.find(d);
    if (it != remap.end()) d = it->second;
  };
  for (auto& p : g->players_) {
    for (auto& ci : p.hand) fix(ci.def);
    for (auto& ci : p.deck) fix(ci.def);
    for (auto& mc : p.manaRow) fix(mc.card.def);
    for (auto& c : p.board) fix(c.def);
    for (auto& a : p.auras) fix(a);
    for (auto& gd : p.graveyard) fix(gd);
    for (auto& pe : p.pending) fix(pe.src);
  }
  for (auto& ci : g->scryPeek_) fix(ci.def);
  return g;
}

std::unique_ptr<Game> Game::determinize(int forSeat, std::mt19937& rng) const {
  std::unique_ptr<Game> g = clone();
  const int opp = 1 - forSeat;
  Player& p = g->players_[opp];
  // The plausible pool: every non-hero card (we do not know the opponent's
  // deck, so any designed card is fair game). v1 samples with replacement -- it
  // ignores copy limits and cards already seen public; good enough for a first
  // honest pass. Keep each instance's id (still unique); only its identity is
  // resampled.
  std::vector<const CardDef*> pool;
  for (const auto& d : lib_.all())
    if (d.type != CardType::Hero) pool.push_back(&d);
  if (pool.empty()) return g;
  std::uniform_int_distribution<std::size_t> pick(0, pool.size() - 1);
  for (auto& ci : p.hand) ci.def = pool[pick(rng)];
  for (auto& ci : p.deck) ci.def = pool[pick(rng)];
  // The bot's OWN deck: a player knows its contents but NOT the draw order, so
  // reshuffle it (keep the cards, randomize the order). Otherwise the rollout
  // peeks at its real upcoming draws -- a cheat. Hand stays (you see your
  // hand).
  Player& me = g->players_[forSeat];
  std::shuffle(me.deck.begin(), me.deck.end(), rng);
  return g;
}

}  // namespace prism
