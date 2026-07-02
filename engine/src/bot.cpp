#include "prism/bot.hpp"

#include <algorithm>
#include <cmath>
#include <memory>

#include "json.hpp"
#include "prism/game.hpp"
#include "prism/protocol.hpp"

namespace prism {

using nlohmann::json;

// Per-thread keyword-awareness scale: 1 = full, 0 = blind to v2 keywords. Set
// by the --vsblind A/B harness per moving seat; default full. thread_local so
// self-play worker threads stay independent.
static thread_local double g_kwScale = 1.0;
void setBotKeywordScale(double scale) { g_kwScale = scale; }

// Determinized-world budget for the main-phase search (see botNextAction). Per
// thread so self-play workers stay independent. The speed<->strength knob.
static thread_local int g_searchWorlds = 4;
void setBotSearchWorlds(int n) { g_searchWorlds = n < 1 ? 1 : n; }

// How many turn-plays the search leaf rolls both sides out before reading the
// result (0 = no rollout, just the static eval). Per thread. Speed<->depth
// knob.
static thread_local int g_rolloutDepth = 4;
void setBotRolloutDepth(int n) { g_rolloutDepth = n < 0 ? 0 : n; }

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

// Standalone heuristic value of a card's keywords that raw atk+hp and the LIVE
// continuous recompute do NOT already capture: repeatable/compounding engines,
// reach, persistent control auras, death payoffs, combat utility. Magnitudes
// are in "effective stat points" (same unit as boardPower). The live anthems
// (incandescence / chill / undergrowth / resonance) return 0 here -- they are
// already folded into boardPower, so crediting them again would double-count.
// Used by both score(Play) (play priority) and evalState (board/aura presence).
double keywordValue(const CardDef* d) {
  if (d == nullptr) return 0.0;
  auto kw = [&](const char* id) {
    return d->hasKeyword(id) ? std::max(1, d->keywordN(id, 1)) : 0;
  };
  double v = 0.0;
  // Compounding / repeatable engines:
  v += 2.5 * kw("photosynthesis");  // ramp, compounds every turn
  v += 2.0 * kw("growth");          // +N/+N each turn
  v += 1.0 * kw("compost");         // grows on ally death
  v += 1.5 * kw("germinate");       // a fresh body each turn
  v += 0.8 * kw("mulch");           // heal a wounded ally each turn
  // Reach / inevitability (ignores the board):
  v += 2.0 * kw("spark");  // repeatable face damage
  v += 0.5 * kw("sear");   // on-death face damage
  v += 0.6 * kw("flare");  // on-death blind
  // Death / persistence payoffs:
  v += 0.9 * kw("spores");  // death -> sprouts
  v += 1.2 * kw("haunt");   // reborn once
  v += 0.5 * kw("split");   // illusory copies
  // Combat survivability / utility:
  v += 0.6 * kw("regen");
  v += 1.0 * kw("self_lifesteal") + 1.0 * kw("cauterize");
  v += 1.0 * kw("provoke") + 1.5 * kw("shield") + 1.0 * kw("ward");
  v += 0.8 * kw("stealth") + 0.9 * kw("firststrike") + 1.2 * kw("strobe");
  v += 0.5 * kw("pierce") + 0.6 * kw("bypass");
  // Control / utility auras (persistent, not in boardPower):
  v += 1.5 * kw("haze");  // taxes enemy spells
  v += 0.6 * kw("glimmer") + 0.8 * kw("refract");
  v += 0.3 * kw("birefringence") +
       0.3 * kw("pinpoint");  // spell support (few spells)
  v += 0.8 *
       kw("brittle");     // frozen enemy shatters on any damage (freeze->kill)
  v += 0.6 * kw("lens");  // first spell each turn +1
  v += 0.3 * kw("awaken") + 0.4 * kw("decoy");
  v += 0.1 * kw("floodlight");  // near-useless tech
  return v * g_kwScale;         // blind bot (scale 0) values no keywords
}

// Score a move (higher = take sooner). EndTurn scores ~0, so it is the fallback
// once nothing else scores positive. Every other action spends a one-shot
// resource (a hand card, a creature's attack, the once-per-turn mana drop), so
// the legal set strictly shrinks and the bot always ends its turn. One greedy
// policy: develop the board, ramp, trade up, and race the hero when ahead.
double score(const Action& a, const Game& g, int seat, bool lethal,
             int onlyPlayable, const std::vector<bool>& canPlay,
             std::mt19937& rng) {
  const Player& me = g.player(seat);
  const Player& foe = g.player(1 - seat);
  std::uniform_real_distribution<double> jitter(0.0, 0.5);
  const double r = jitter(rng);  // tie-break + a little unpredictability

  switch (a.type) {
    case Action::Type::EndTurn:
      return 0.0;
    case Action::Type::PlaceMana: {
      // Mana grows ONLY by sacrificing one card per turn. Feed that ramp with
      // the LEAST useful card so the castable curve stays in hand to develop
      // the board (the old "sac the cheapest creature" threw away exactly what
      // we could have played). Best fuel: cards dead THIS turn (unaffordable
      // now) and low-value cards; spare cheap playable bodies and high-value
      // bombs. When everything in hand is castable and good, sac scores fall
      // below plays, so the bot develops instead of ramping -- as a human stops
      // ramping once flush.
      if (a.handIndex == onlyPlayable) return -50.0 + r;  // keep the only play
      const CardDef* d = me.hand[a.handIndex].def;
      const bool playableNow = a.handIndex < static_cast<int>(canPlay.size()) &&
                               canPlay[a.handIndex];
      double s = 9.0;             // ramp still beats most plays
      if (playableNow) s -= 3.0;  // keep what we can play now
      if (isCreature(d) && playableNow) s -= 2.0;  // especially castable bodies
      s -= 0.4 * (keywordValue(d) + 0.5 * statSum(d));  // spare our best cards
      // Colour: among this card's colours, prefer the one we have least of, so
      // a two-colour deck unsticks its casting instead of flooding one colour.
      int least = me.mana.crystals[0];
      for (int v : me.mana.crystals) least = std::min(least, v);
      if (me.mana.crystals[static_cast<int>(a.color)] == least) s += 0.6;
      return s + r;
    }
    case Action::Type::Activate:
      return 2.0 + r;  // germinate a sprout: free board
    case Action::Type::Awaken:
      return 3.5 + r;
    case Action::Type::Play: {
      const CardDef* d = me.hand[a.handIndex].def;
      // Reach the 1-ply leaf under-credits: burn aimed at the enemy hero is
      // guaranteed payoff the greedy rollout would otherwise deprioritize
      // (targetBonus only scores creature targets). keywordValue() then adds
      // the engine/control/keyword worth (ramp, spark reach, death payoffs,
      // combat utility, sear, ...) that raw stats miss, so the bot prioritizes
      // those.
      double reach = 0.0;
      for (const auto& e : d->effects)
        if (e.trigger == "on_play" && e.action == "damage" &&
            e.selector == "enemy_hero")
          reach += e.value;
      return 3.0 + 0.5 * statSum(d) + targetBonus(g, seat, a) + reach +
             keywordValue(d) + r;
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
  // Persistent keyword worth (engines / control / auras) that boardPower's raw
  // atk+hp does not capture. Owner-beneficial, so mine adds and foe subtracts.
  for (const auto& c : me.board) v += keywordValue(c.def);
  for (const auto& c : foe.board) v -= keywordValue(c.def);
  for (const auto* a : me.auras) v += keywordValue(a);
  for (const auto* a : foe.auras) v -= keywordValue(a);
  // A frozen/blinded enemy cannot attack this turn -- discount its threat,
  // since boardPower still counts its full attack.
  for (const auto& c : foe.board)
    if (c.frozenTurns > 0 || c.blindTurns > 0) v += 0.5 * c.atk;
  return v;
}

// The cheap reflex policy: the single best action by static scoring, or "" if
// nothing to do / not this seat's move. This is the bot's old greedy brain; the
// search below uses it to roll a turn out to its end.
// The greedy main-phase pick: the highest static-score legal action (computing
// the lethal flag and the single-playable card that score() needs). Assumes
// acts is non-empty and it is seat's main phase. Shared by the reflex policy
// and the search (which uses it to keep mana ramp off the myopic 1-ply leaf).
// Score every legal action with the greedy policy (the lethal flag and the
// single-playable card are computed once). Shared by the reflex pick and the
// PUCT prior, so the tree is guided by the same hand-authored policy.
std::vector<double> scoreAll(const Game& g, int seat,
                             const std::vector<Action>& acts,
                             std::mt19937& rng) {
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

  std::vector<double> out(acts.size());
  for (size_t i = 0; i < acts.size(); ++i)
    out[i] = score(acts[i], g, seat, lethal, onlyPlayable, canPlay, rng);
  return out;
}

Action greedyMainChoice(const Game& g, int seat,
                        const std::vector<Action>& acts, std::mt19937& rng) {
  const std::vector<double> s = scoreAll(g, seat, acts, rng);
  int best = 0;
  for (int i = 1; i < static_cast<int>(s.size()); ++i)
    if (s[i] > s[best]) best = i;
  return acts[best];
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

// Value of a position from `seat`'s view: play both sides out with the greedy
// reflex for up to `turnCap` turn-plays, then read the result. A finished game
// is +1 win / 0 draw / -1 loss; a truncated one falls back to a squashed static
// eval (bounded, so it never outweighs a real decisive outcome). This is the
// search leaf -- value emerges from the rules actually resolving the cards, so
// it stays correct as the card set changes (no per-card tuning).
double rolloutValue(Game& g, int seat, std::mt19937& rng, int turnCap) {
  for (int t = 0, actor = seat; t < turnCap && !g.isOver(); ++t, actor ^= 1)
    rollout(g, actor, rng);
  if (g.isOver())
    return g.winner() == seat ? 1.0 : (g.winner() < 0 ? 0.0 : -1.0);
  return std::tanh(evalState(g, seat) / 50.0);
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
  const int kWorlds = g_searchWorlds;
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
      total += rolloutValue(*sim, seat, lrng, g_rolloutDepth);
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
