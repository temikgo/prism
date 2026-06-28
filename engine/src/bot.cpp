#include "prism/bot.hpp"

#include <algorithm>
#include <memory>

#include "json.hpp"
#include "prism/game.hpp"
#include "prism/protocol.hpp"

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
    const bool harmful = act == "damage" || act == "destroy" ||
                         act == "freeze" || act == "blind" || act == "scatter";
    if (harmful && mine) return -100.0;     // never aim a harmful effect at own
    if (harmful && t->warded) return -5.0;  // ward absorbs it -- wasted
    if (act == "damage") {
      if (t->shield) return -5.0;  // shield eats the damage instance -- wasted
      b += (e.value >= t->hp)
               ? (t->atk + t->hp + 2.0)  // a kill is worth a body
               : e.value;                // else just chip
    } else if (act == "destroy") {
      b += t->atk + t->hp + 3.0;  // remove the biggest threat (ignores shield)
    } else if (act == "freeze" || act == "blind") {
      b += t->atk + 1.0;  // neutralize a big attacker
    } else if (act == "scatter") {
      b += (t->atk + t->hp) * 0.5;  // bounce their biggest
    } else if (act == "mirage") {
      b += (t->atk + t->hp) * 0.5;  // copy the biggest, either side
    }
  }
  return b;
}

// Serialize a chosen Action into the protocol JSON applyAction expects.
std::string serializeAction(const Action& a) {
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
             int onlyPlayable, std::mt19937& rng) {
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
      // Never sacrifice the only card you can actually play this turn -- keep
      // it to develop the board instead of ramping into a dead (e.g.
      // colour-screwed) hand.
      if (a.handIndex == onlyPlayable) return -50.0 + r;
      const CardDef* d = me.hand[a.handIndex].def;
      if (!isCreature(d)) return 0.7 + r;
      return 14.0 - 0.3 * manaValue(d) + r;  // beats any play; cheaper ranks up
    }
    case Action::Type::Activate:
      return 2.0 + r;  // germinate a sprout: free board
    case Action::Type::Awaken:
      return 3.5 + r;
    case Action::Type::Play: {
      const CardDef* d = me.hand[a.handIndex].def;
      // Reach the 1-ply leaf under-credits: burn aimed at the enemy hero and
      // on-death face damage (sear) are guaranteed payoff the greedy rollout
      // would otherwise deprioritize (targetBonus only scores creature
      // targets).
      double reach = 0.0;
      for (const auto& e : d->effects)
        if (e.trigger == "on_play" && e.action == "damage" &&
            e.selector == "enemy_hero")
          reach += e.value;
      if (d->hasKeyword("sear")) reach += 0.5 * d->keywordN("sear", 1);
      return 3.0 + 0.5 * statSum(d) + targetBonus(g, seat, a) + reach + r;
    }
    case Action::Type::AttackCreature: {
      const Creature* at = find(me, a.attacker);
      const Creature* tg = find(foe, a.target);
      if (at == nullptr || tg == nullptr) return r;
      // When the enemy hero is dead this turn, racing beats trading --
      // attacking a creature instead would waste a point of lethal, so rank
      // trades low.
      if (lethal) return 1.0 + r;
      // A shielded target absorbs the whole hit: we deal no real damage but
      // still take its swing back -- a bad trade, so rank it low.
      const bool kills = at->atk >= tg->hp && !tg->shield;
      const bool dies = tg->atk >= at->hp;
      double v = 4.0;
      if (kills)
        v += tg->atk + tg->hp;  // remove their threat
      else if (tg->shield)
        v -= 3.0;                       // popped a shield for nothing
      if (dies) v -= at->atk + at->hp;  // we lose ours
      // Prefer the cheapest sufficient attacker: a small penalty by body size
      // so a 2/2 trades before a 6/6 is thrown at the same target (keep the
      // beaters).
      v -= 0.15 * (at->atk + at->hp);
      // Pierce sends the lethal overkill to the enemy hero -- reward it.
      if (kills && at->def->hasKeyword("pierce")) v += (at->atk - tg->hp) * 0.4;
      return v + r;
    }
    case Action::Type::AttackHero: {
      const Creature* at = find(me, a.attacker);
      const double dmg = at != nullptr ? at->atk : 0.0;
      if (lethal) return 100.0 + dmg;  // close it out: send everything face
      // Race only with a CLEAR board lead or a healthy hero-race margin;
      // otherwise prefer trading to stabilise. At mere board parity the old
      // bot rushed face, which let cheap aggression self-validate -- now
      // over-aggression is answered by efficient trades instead.
      const bool ahead =
          boardPower(me) > boardPower(foe) + 4 || me.heroHp > foe.heroHp + 10;
      return (ahead ? 5.0 : 1.5) + dmg + r;
    }
  }
  return r;
}

// Static position evaluation from `seat`'s point of view (higher = better for
// seat). Used as the leaf evaluation of the 1-ply search. A finished game is
// +/- huge. Otherwise: the enemy hero's health is the main axis (closing it
// wins), plus board presence, card advantage and developed mana.
double evalState(const Game& g, int seat) {
  if (g.isOver()) return g.winner() == seat ? 1e6 : -1e6;
  const Player& me = g.player(seat);
  const Player& foe = g.player(1 - seat);
  double v = 0.0;
  v += 4.0 * (me.heroHp - foe.heroHp);  // race the enemy hero down
  // Hero HP is convex near death: a low own hero is dangerous
  // (defend/stabilise), a low enemy is worth pressing. The linear race stays,
  // but letting our own hero get raced down is punished -- so aggression must
  // be answered, not free.
  v -= 1.5 * std::max(0, 12 - me.heroHp);
  v += 1.5 * std::max(0, 12 - foe.heroHp);
  v += boardPower(me) - boardPower(foe);
  v += 1.2 * (static_cast<int>(me.board.size()) -
              static_cast<int>(foe.board.size()));  // board presence (count)
  v += 1.5 * (static_cast<int>(me.hand.size()) -
              static_cast<int>(foe.hand.size()));     // card advantage
  v += 0.8 * (crystalCount(me) - crystalCount(foe));  // developed mana
  return v;
}

// The cheap reflex policy: the single best action by static scoring, or "" if
// nothing to do / not this seat's move. This is the bot's old greedy brain; the
// search below uses it to roll a turn out to its end.
// The greedy main-phase pick: the highest static-score legal action (computing
// the lethal flag and the single-playable card that score() needs). Assumes
// acts is non-empty and it is seat's main phase. Shared by the reflex policy
// and the search (which uses it to keep mana ramp off the myopic 1-ply leaf).
Action greedyMainChoice(const Game& g, int seat,
                        const std::vector<Action>& acts, std::mt19937& rng) {
  int faceDmg = 0;
  for (const auto& a : acts)
    if (a.type == Action::Type::AttackHero) {
      const Creature* at = find(g.player(seat), a.attacker);
      if (at != nullptr) faceDmg += at->atk;
    }
  const Player& foe = g.player(1 - seat);
  const bool lethal = faceDmg > 0 && faceDmg >= foe.heroHp + foe.heroArmor;

  const Player& me = g.player(seat);
  std::vector<bool> canPlay(me.hand.size(), false);
  for (const auto& a : acts)
    if (a.type == Action::Type::Play && a.handIndex >= 0 &&
        a.handIndex < static_cast<int>(canPlay.size()))
      canPlay[a.handIndex] = true;
  int playableCount = 0, onlyPlayable = -1;
  for (int i = 0; i < static_cast<int>(canPlay.size()); ++i)
    if (canPlay[i]) {
      ++playableCount;
      onlyPlayable = i;
    }
  if (playableCount != 1) onlyPlayable = -1;

  const Action* best = &acts.front();
  double bestScore = -1e18;
  for (const auto& a : acts) {
    const double s = score(a, g, seat, lethal, onlyPlayable, rng);
    if (s > bestScore) {
      bestScore = s;
      best = &a;
    }
  }
  return *best;
}

std::string botStepGreedy(const Game& g, int seat, std::mt19937& rng) {
  if (g.isOver()) return "";
  // Mulligan: toss the cards too dear to play early, keeping a low curve -- but
  // never throw the WHOLE hand away; keep the two cheapest so there is always
  // something to do on the opening turns.
  if (g.inMulligan()) {
    if (g.mulliganDone(seat)) return "";
    const Player& me = g.player(seat);
    const int n = static_cast<int>(me.hand.size());
    std::vector<int> toss;
    for (int i = 0; i < n; ++i)
      if (manaValue(me.hand[i].def) >= 4) toss.push_back(i);
    if (static_cast<int>(toss.size()) == n && n > 0) {
      std::sort(toss.begin(), toss.end(), [&](int x, int y) {
        return manaValue(me.hand[x].def) < manaValue(me.hand[y].def);
      });
      toss.erase(toss.begin(),
                 toss.begin() + std::min(2, n));  // keep 2 cheapest
    }
    json idx = json::array();
    for (int i : toss) idx.push_back(i);
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
  return serializeAction(greedyMainChoice(g, seat, acts, rng));
}

// Play out `seat`'s reflex moves on `g` until its turn passes or the game ends.
void rollout(Game& g, int seat, std::mt19937& rng) {
  for (int guard = 0; guard < 400 && !g.isOver(); ++guard) {
    std::string js = botStepGreedy(g, seat, rng);
    if (js.empty()) break;  // not seat's move any more -> its turn is over
    applyAction(g, seat, js);
  }
}

}  // namespace

std::string botNextAction(const Game& g, int seat, std::mt19937& rng) {
  if (g.isOver()) return "";
  // Search applies only to the main-phase decision; mulligan/scry/off-turn are
  // reflexive (nothing to simulate).
  if (g.inMulligan() || g.inScry() || g.current() != seat)
    return botStepGreedy(g, seat, rng);
  std::vector<Action> acts = g.legalActions();
  if (acts.empty()) return "";
  if (acts.size() == 1) return serializeAction(acts.front());

  // Mana ramp is a strategic constant, not a tactical choice: the once-per-turn
  // crystal pays off many turns out, far past the 1-ply leaf -- whose static
  // eval values a hand card (1.5) above a crystal (0.8) and so myopically
  // hoards the card whenever the new mana cannot be cashed into a play THIS
  // turn. Decide the mana drop with the greedy reflex (which ramps almost every
  // turn, sparing only score()'s exceptions), and only hand the tactical
  // plays/attacks to search.
  const Action gb = greedyMainChoice(g, seat, acts, rng);
  if (gb.type == Action::Type::PlaceMana || acts.size() > 60)
    return serializeAction(gb);  // ramp now (or stay snappy on huge branching)

  // 1-ply search: for each candidate first move, simulate it, finish this turn
  // greedily, let the opponent take its greedy reply, then evaluate the
  // position. Pick the candidate leading to the best position. Tempo/ramp pays
  // off (a bigger play this turn shows in the end state) and overextension is
  // punished (the opponent's reply is included). Each later tick re-searches,
  // so the whole turn is search-driven; the greedy reflex is only the rollout
  // estimator.
  std::mt19937 lrng(0xC0FFEEu);  // local rng for rollouts; never touch caller's
  std::uniform_real_distribution<double> tie(0.0, 0.01);

  // The bot must not read the opponent's real hidden cards. Draw K determinized
  // worlds up front (the opponent's hand/deck resampled to plausible cards),
  // the SAME worlds reused across every candidate so the comparison is
  // apples-to- apples (common random numbers). Each candidate is scored as its
  // mean leaf value over those worlds -- a Monte-Carlo marginalization over
  // what the opponent might be holding.
  constexpr int kWorlds = 4;
  std::vector<std::unique_ptr<Game>> worlds;
  for (int k = 0; k < kWorlds; ++k) {
    std::unique_ptr<Game> w = g.determinize(seat, lrng);
    if (w) worlds.push_back(std::move(w));
  }
  if (worlds.empty())
    return botStepGreedy(g, seat, rng);  // fell through -> reflex

  const Action* best = &acts.front();
  double bestVal = -1e18;
  for (const auto& a : acts) {
    double total = 0.0;
    for (const auto& w : worlds) {
      std::unique_ptr<Game> sim = w->clone();
      applyAction(*sim, seat, serializeAction(a));
      rollout(*sim, seat, lrng);      // finish my turn
      rollout(*sim, 1 - seat, lrng);  // the opponent's plausible greedy reply
      total += evalState(*sim, seat);
    }
    const double v = total / static_cast<double>(worlds.size()) + tie(rng);
    if (v > bestVal) {
      bestVal = v;
      best = &a;
    }
  }
  return serializeAction(*best);
}

std::string botGreedyAction(const Game& g, int seat, std::mt19937& rng) {
  return botStepGreedy(g, seat, rng);
}

}  // namespace prism
