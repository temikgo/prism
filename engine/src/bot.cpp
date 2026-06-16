#include "prism/bot.hpp"

#include "json.hpp"
#include "prism/game.hpp"

namespace prism {

using nlohmann::json;

namespace {

const Creature* find(const Player& p, EntityId id) {
  for (const auto& c : p.board)
    if (c.id == id) return &c;
  return nullptr;
}

int statSum(const CardDef* d) {
  return (d && d->hasStats) ? d->stats.atk + d->stats.hp : 0;
}

bool isCreature(const CardDef* d) {
  return d != nullptr && d->type == CardType::Creature;
}

// Total mana value of a card (generic + every colored pip).
int manaValue(const CardDef* d) {
  return d == nullptr ? 0 : d->cost.generic + d->cost.colored();
}

// Crude board strength: total atk + hp across a side. Used to decide whether
// the bot is ahead enough to race the enemy hero rather than keep trading.
int boardPower(const Player& p) {
  int s = 0;
  for (const auto& c : p.board) s += c.atk + c.hp;
  return s;
}

// Sum of crystals (any colour) -- a rough "what can I cast soon" for scry.
int crystalCount(const Player& p) {
  int n = 0;
  for (int v : p.mana.crystals) n += v;
  return n;
}

// How good is a targeted play's chosen target? legalActions enumerates one Play
// per legal target, so scoring the target lets the best one rise (instead of
// the old random pick). A harmful effect aimed at the bot's own creature
// returns a big penalty, so the enemy-target (or no-target) variant always
// wins.
double targetBonus(const Game& g, int seat, const Action& a) {
  if (a.target == 0) return 0.0;  // untargeted play (or effect skipped)
  const Player& me = g.player(seat);
  const Player& foe = g.player(1 - seat);
  const CardDef* d = me.hand[a.handIndex].def;
  const Creature* t = find(me, a.target);
  const bool mine = t != nullptr;
  if (t == nullptr) t = find(foe, a.target);
  if (t == nullptr) return 0.0;
  double b = 0.0;
  for (const auto& e : d->effects) {
    if (e.trigger != "on_play") continue;
    const std::string& act = e.action;
    if (act == "damage") {
      if (mine) return -100.0;  // never burn your own
      b += (e.value >= t->hp)
               ? (t->atk + t->hp + 2.0)  // a kill is worth a body
               : e.value;                // else just chip
    } else if (act == "destroy") {
      if (mine) return -100.0;
      b += t->atk + t->hp + 3.0;  // remove the biggest threat
    } else if (act == "freeze" || act == "blind") {
      if (mine) return -100.0;
      b += t->atk + 1.0;  // neutralize a big attacker
    } else if (act == "scatter") {
      if (mine) return -100.0;      // bouncing your own loses tempo
      b += (t->atk + t->hp) * 0.5;  // bounce their biggest
    } else if (act == "mirage") {
      b += (t->atk + t->hp) * 0.5;  // copy the biggest, either side
    }
  }
  return b;
}

// Serialize a chosen Action into the protocol JSON applyAction expects.
std::string actionJson(const Action& a) {
  json j;
  switch (a.type) {
    case Action::Type::EndTurn:
      j["action"] = "endTurn";
      break;
    case Action::Type::PlaceMana:
      j = {{"action", "placeMana"},
           {"handIndex", a.handIndex},
           {"color", std::string(colorName(a.color))}};
      break;
    case Action::Type::Play:
      j = {{"action", "play"},
           {"handIndex", a.handIndex},
           {"target", a.target},
           {"pos", a.pos}};
      break;
    case Action::Type::Awaken:
      j = {{"action", "awaken"},
           {"manaRowIndex", a.manaRowIndex},
           {"target", a.target},
           {"pos", a.pos}};
      break;
    case Action::Type::Activate:
      j = {{"action", "activate"}, {"id", a.id}};
      break;
    case Action::Type::AttackCreature:
      j = {{"action", "attackCreature"},
           {"attacker", a.attacker},
           {"target", a.target}};
      break;
    case Action::Type::AttackHero:
      j = {{"action", "attackHero"}, {"attacker", a.attacker}};
      break;
  }
  return j.dump();
}

// Score a move (higher = take sooner). EndTurn scores ~0, so it is the fallback
// once nothing else scores positive. Every other action spends a one-shot
// resource (a hand card, a creature's attack, the once-per-turn mana drop), so
// the legal set strictly shrinks and the bot always ends its turn. One greedy
// policy: develop the board, ramp, trade up, and race the hero when ahead.
double score(const Action& a, const Game& g, int seat, bool lethal,
             std::mt19937& rng) {
  const Player& me = g.player(seat);
  const Player& foe = g.player(1 - seat);
  std::uniform_real_distribution<double> jitter(0.0, 0.5);
  const double r = jitter(rng);  // tie-break + a little unpredictability

  switch (a.type) {
    case Action::Type::EndTurn:
      return 0.0;
    case Action::Type::PlaceMana: {
      // Mana grows ONLY by sacrificing one card per turn, so the bot ramps
      // every turn -- and does it FIRST: the fresh crystal is usable this turn
      // and the drop never blocks a play (it only adds mana for the
      // plays/answers that follow). It gives up its cheapest CREATURE (cheap
      // bodies are the most replaceable). Spells/auras are protected: when only
      // those are in hand the drop drops to low priority, so the bot plays its
      // answers before ever sacrificing one to mana.
      const CardDef* d = me.hand[a.handIndex].def;
      if (!isCreature(d)) return 0.7 + r;
      return 14.0 - 0.3 * manaValue(d) + r;  // beats any play; cheaper ranks up
    }
    case Action::Type::Activate:
      return 2.0 + r;  // germinate a sprout: free board
    case Action::Type::Awaken:
      return 3.5 + r;
    case Action::Type::Play:
      return 3.0 + 0.5 * statSum(me.hand[a.handIndex].def) +
             targetBonus(g, seat, a) + r;
    case Action::Type::AttackCreature: {
      const Creature* at = find(me, a.attacker);
      const Creature* tg = find(foe, a.target);
      if (at == nullptr || tg == nullptr) return r;
      // When the enemy hero is dead this turn, racing beats trading --
      // attacking a creature instead would waste a point of lethal, so rank
      // trades low.
      if (lethal) return 1.0 + r;
      double v = 4.0;
      if (at->atk >= tg->hp) v += tg->atk + tg->hp;  // kills their threat
      if (tg->atk >= at->hp) v -= at->atk + at->hp;  // we lose ours
      return v + r;
    }
    case Action::Type::AttackHero: {
      const Creature* at = find(me, a.attacker);
      const double dmg = at != nullptr ? at->atk : 0.0;
      if (lethal) return 100.0 + dmg;  // close it out: send everything face
      // Otherwise race only when ahead on board strength; else prefer trading.
      const bool ahead = boardPower(me) >= boardPower(foe);
      return (ahead ? 5.0 : 2.0) + dmg + r;
    }
  }
  return r;
}

}  // namespace

std::string botNextAction(const Game& g, int seat, std::mt19937& rng) {
  if (g.isOver()) return "";
  // Mulligan: toss the cards too dear to play early, keeping a low curve.
  if (g.inMulligan()) {
    if (g.mulliganDone(seat)) return "";
    json idx = json::array();
    const Player& me = g.player(seat);
    for (int i = 0; i < static_cast<int>(me.hand.size()); ++i)
      if (manaValue(me.hand[i].def) >= 4) idx.push_back(i);
    return json{{"action", "mulligan"}, {"indices", idx}}.dump();
  }
  // Scry: bury the cards we cannot cast in the next turn or two, keep the rest
  // on top (so the next draws are playable). Adapts to our mana as the game
  // grows.
  if (g.inScry()) {
    if (g.scryPlayer() != seat) return "";
    json bottom = json::array();
    const Player& me = g.player(seat);
    const int reach = crystalCount(me) + 1;
    const std::vector<CardInstance>& peek = g.scryPeek();
    for (int i = 0; i < static_cast<int>(peek.size()); ++i)
      if (manaValue(peek[i].def) > reach) bottom.push_back(i);
    return json{{"action", "scryResolve"}, {"bottom", bottom}}.dump();
  }
  if (g.current() != seat) return "";
  std::vector<Action> acts = g.legalActions();
  if (acts.empty()) return "";
  // Lethal check: if every creature that can hit the face together deals enough
  // to kill the enemy hero this turn, swing everything in (handled in score).
  int faceDmg = 0;
  for (const auto& a : acts)
    if (a.type == Action::Type::AttackHero) {
      const Creature* at = find(g.player(seat), a.attacker);
      if (at != nullptr) faceDmg += at->atk;
    }
  const Player& foe = g.player(1 - seat);
  const bool lethal = faceDmg > 0 && faceDmg >= foe.heroHp + foe.heroArmor;

  const Action* best = &acts.front();
  double bestScore = -1e18;
  for (const auto& a : acts) {
    const double s = score(a, g, seat, lethal, rng);
    if (s > bestScore) {
      bestScore = s;
      best = &a;
    }
  }
  return actionJson(*best);
}

}  // namespace prism
