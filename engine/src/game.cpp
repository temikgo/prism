#include "prism/game.hpp"

#include <algorithm>

namespace prism {

Game::Game(const CardLibrary& lib, const std::vector<std::string>& deck0,
           const std::vector<std::string>& deck1, std::uint32_t seed,
           const std::string& hero0, const std::string& hero1)
    : lib_(lib), rng_(seed) {
  players_[0].index = 0;
  players_[1].index = 1;
  players_[0].hero = lib_.find(hero0);  // null if empty/unknown -> no passive
  players_[1].hero = lib_.find(hero1);
  // Each listed ID becomes one card instance with a unique EntityId. Unknown
  // IDs are skipped (deck validation is the caller's job for now).
  auto build = [&](Player& p, const std::vector<std::string>& ids) {
    for (const auto& id : ids) {
      const CardDef* def = lib_.find(id);
      if (def) p.deck.push_back(CardInstance{nextId_++, def});
    }
  };
  build(players_[0], deck0);
  build(players_[1], deck1);
}

void Game::start() {
  std::shuffle(players_[0].deck.begin(), players_[0].deck.end(), rng_);
  std::shuffle(players_[1].deck.begin(), players_[1].deck.end(), rng_);
  // Asymmetric opening hands are the second player's only compensation; there
  // is no Coin (any card can be sacrificed for mana, so a Coin card breaks).
  draw(players_[0], OpeningFirst);
  draw(players_[1], OpeningSecond);
  current_ = 0;
  turn_ = 1;
  mulliganPhase_ = true;  // wait for both mulligans before the first turn
}

bool Game::mulligan(int player, const std::vector<int>& indices) {
  if (!mulliganPhase_ || player < 0 || player > 1) return false;
  Player& p = players_[player];
  if (p.mulliganDone) return false;

  std::vector<int> idx = indices;
  std::sort(idx.begin(), idx.end());
  idx.erase(std::unique(idx.begin(), idx.end()), idx.end());
  for (int i : idx)
    if (i < 0 || i >= static_cast<int>(p.hand.size())) return false;

  // Set the chosen cards aside, draw their replacements from the deck, and only
  // then shuffle the set-aside cards back in -- so a mulliganed card can never
  // be redrawn within the same mulligan. Erase from the back so earlier indices
  // stay valid.
  std::vector<CardInstance> setAside;
  for (auto it = idx.rbegin(); it != idx.rend(); ++it) {
    setAside.push_back(p.hand[*it]);
    p.hand.erase(p.hand.begin() + *it);
  }
  draw(p, static_cast<int>(idx.size()));
  for (const auto& ci : setAside) p.deck.push_back(ci);
  std::shuffle(p.deck.begin(), p.deck.end(), rng_);

  p.mulliganDone = true;
  if (players_[0].mulliganDone && players_[1].mulliganDone) {
    mulliganPhase_ = false;
    startTurn();  // player 0's first turn now begins
  }
  return true;
}

// Turn order (DESIGN §1): refill mana -> start triggers -> draw -> main phase.
void Game::startTurn() {
  Player& p = players_[current_];
  p.mana.refill();
  p.placedManaThisTurn = false;
  p.shiftUsed = false;  // Prism: the spectral-shift swap recharges each turn
  for (auto& c : p.board) {
    c.sick = false;
    c.attacked = false;
    c.usedActive = false;
  }
  for (auto& mc : p.manaRow) mc.age += 1;  // banked cards age for Violet decoy
  applyTurnStartTriggers(p);
  processDelayed(p);  // Blue delay: effects scheduled for this turn fire now
  checkDeaths();      // a delayed sweep/bolt may have killed creatures
  recomputeContinuous();  // growth changed bases; refresh the live layer
  draw(p, 1);
}

// Blue scry: lift the top n cards off the deck and hold them for the player to
// sort. Nothing else may happen until resolveScry() is called.
void Game::startScry(Player& p, int n) {
  int take = std::min(n, static_cast<int>(p.deck.size()));
  for (int i = 0; i < take; ++i) {
    scryPeek_.push_back(p.deck.back());  // deck back == top; peek[0] is topmost
    p.deck.pop_back();
  }
  if (!scryPeek_.empty()) scryPlayer_ = p.index;  // nothing to sort -> no-op
}

// Finish a scry: the chosen peeked cards (by index) go to the bottom of the
// deck; the rest return to the top in their original order.
bool Game::resolveScry(int player, const std::vector<int>& toBottom) {
  if (scryPlayer_ != player) return false;
  Player& p = players_[player];
  std::vector<CardInstance> keep;
  for (int i = 0; i < static_cast<int>(scryPeek_.size()); ++i) {
    bool bottom =
        std::find(toBottom.begin(), toBottom.end(), i) != toBottom.end();
    if (bottom)
      p.deck.insert(p.deck.begin(), scryPeek_[i]);  // front == bottom
    else
      keep.push_back(scryPeek_[i]);
  }
  // Restore kept cards so keep[0] (the topmost peek) ends on top (deck back).
  for (auto it = keep.rbegin(); it != keep.rend(); ++it) p.deck.push_back(*it);
  scryPeek_.clear();
  scryPlayer_ = -1;
  return true;
}

// Tick every pending delayed effect; the ones that reach zero resolve now (with
// no target -- delayed effects are the non-targeted kind).
void Game::processDelayed(Player& p) {
  std::vector<DelayedEffect> still;
  for (auto& d : p.pending) {
    d.turnsLeft -= 1;
    if (d.turnsLeft <= 0)
      executeAction(d.effect, p, 0);
    else
      still.push_back(d);
  }
  p.pending = still;
}

// OnTurnStart triggers. Regen heals up to max; Growth adds +N/+N;
// Photosynthesis (on creatures or auras) adds temporary mana for this turn
// only.
void Game::applyTurnStartTriggers(Player& p) {
  for (auto& c : p.board) {
    int r = c.def->keywordN("regen");
    if (r > 0) healCreature(c, r);
    int g = c.def->keywordN("growth");
    if (g > 0) buffStats(c, g);
  }
  int ramp = 0;
  for (const auto& c : p.board) ramp += c.def->keywordN("photosynthesis");
  for (const auto* a : p.auras) ramp += a->keywordN("photosynthesis");
  if (ramp > 0) p.mana.addTemporary(Color::Colorless, ramp);
}

// Freeze and blind tick down at the end of the affected creature's owner's
// turn, so "freeze N" / "blind N" makes it sit out N of its own turns.
void Game::tickStatuses(Player& p) {
  for (auto& c : p.board) {
    if (c.frozenTurns > 0) c.frozenTurns -= 1;
    if (c.blindTurns > 0) c.blindTurns -= 1;
  }
}

void Game::draw(Player& p, int n) {
  for (int i = 0; i < n; ++i) {
    if (p.deck.empty()) {
      // Fatigue: each draw from an empty deck hurts the hero for an
      // ever-increasing amount (1, 2, 3, ...), guaranteeing the game ends.
      p.fatigue += 1;
      dealHeroDamage(p, p.fatigue);
    } else {
      CardInstance ci = p.deck.back();
      p.deck.pop_back();
      // Drawing into a full hand burns the card unseen (HS rule).
      if (static_cast<int>(p.hand.size()) < HandLimit) p.hand.push_back(ci);
    }
  }
}

// Eclipse umbra softens a creature's attack on the enemy hero by 1 (floor 0).
// Applies to a direct face hit and to pierce overflow alike, so pierce does not
// slip past the passive.
int Game::heroHitDamage(const Player& opp, int raw) const {
  if (opp.hero && opp.hero->hasKeyword("umbra")) return raw > 1 ? raw - 1 : 0;
  return raw;
}

void Game::dealHeroDamage(Player& p, int amount) {
  int remaining = amount;
  int absorbed = remaining < p.heroArmor ? remaining : p.heroArmor;
  p.heroArmor -= absorbed;
  remaining -= absorbed;
  p.heroHp -= remaining;
  if (p.heroHp <= 0 && !over_) {
    over_ = true;
    winner_ = 1 - p.index;
  }
}

bool Game::placeCardToMana(int handIndex, Color color) {
  if (over_) return false;
  Player& p = players_[current_];
  if (p.placedManaThisTurn) return false;
  if (handIndex < 0 || handIndex >= static_cast<int>(p.hand.size()))
    return false;
  const CardDef* def = p.hand[handIndex].def;
  // A neutral card can only become a Colorless crystal; a colored card may
  // become a crystal of any one of its colors (chosen here).
  bool ok;
  if (def->colors.empty())
    ok = (color == Color::Colorless);
  else
    ok = std::find(def->colors.begin(), def->colors.end(), color) !=
         def->colors.end();
  if (!ok) return false;
  CardInstance card = p.hand[handIndex];
  p.hand.erase(p.hand.begin() + handIndex);
  p.manaRow.push_back(ManaCard{card, color});  // keep identity for awaken
  p.mana.addCrystal(color);
  p.placedManaThisTurn = true;
  recomputeContinuous();  // crystal count changed -> refresh resonance
  return true;
}

// Prism `spectral_shift`: retune one available crystal to a spectrum-adjacent
// color (R-Y-G-B-V are enum 0..4 contiguous; Colorless 5 has no neighbour).
// Returns the swapped pool (canPay then holds) only when the swap is what makes
// the cost affordable -- the caller has already checked it is unpayable
// plainly.
std::optional<ManaPool> Game::shiftedPool(const ManaPool& pool,
                                          const Cost& cost) const {
  for (int x = 0; x < 5; ++x) {    // the color a pip is short of
    for (int y = 0; y < 5; ++y) {  // a neighbour crystal we retune into it
      int d = x - y;
      if (d != 1 && d != -1) continue;
      if (pool.available[y] < 1) continue;
      ManaPool sim = pool;
      sim.available[y] -= 1;
      sim.available[x] += 1;
      if (sim.canPay(cost)) return sim;
    }
  }
  return std::nullopt;
}

bool Game::playCard(int handIndex, EntityId target, int pos) {
  if (over_) return false;
  Player& p = players_[current_];
  if (handIndex < 0 || handIndex >= static_cast<int>(p.hand.size()))
    return false;
  CardInstance ci = p.hand[handIndex];
  const CardDef* def = ci.def;
  // Affordable normally, or via the Prism hero's once-per-turn spectral shift?
  bool normal = p.mana.canPay(def->cost);
  std::optional<ManaPool> shifted;
  if (!normal && p.hero && p.hero->hasKeyword("spectral_shift") && !p.shiftUsed)
    shifted = shiftedPool(p.mana, def->cost);
  if (!normal && !shifted) return false;
  if (def->type == CardType::Creature &&
      static_cast<int>(p.board.size()) >= BoardLimit)
    return false;
  if (def->type == CardType::Aura && hasAura(p, def->id)) return false;
  if (!playTargetLegal(def, p, target)) return false;
  // Pay last, after every legality check, so a rejected play never spends mana.
  if (normal) {
    p.mana.pay(def->cost);
  } else {
    ManaPool np = *shifted;
    np.pay(def->cost);
    p.mana = np;
    p.shiftUsed = true;  // the spectral shift is spent for this turn
  }
  p.hand.erase(p.hand.begin() + handIndex);
  playResolved(p, ci, target, pos);
  return true;
}

// Put an already-paid-for card into play. Creatures enter summoning sick;
// auras stay in play; spells resolve and go to the graveyard. Any on_play
// effect runs against `target`.
void Game::playResolved(Player& p, const CardInstance& ci, EntityId target,
                        int pos) {
  const CardDef* def = ci.def;
  if (def->type == CardType::Creature) {
    Creature nc =
        makeCreature(ci.id, def, /*sick=*/true, /*token=*/false, /*hp=*/-1);
    // Snapshot the HP part of undergrowth/resonance at summon. Only atk is
    // continuous (recomputed live); HP is baked once to avoid shrinking HP and
    // cascade deaths. (Continuous HP is a later upgrade -- see README.)
    int allies = static_cast<int>(p.board.size());  // the other creatures
    int crystals = 0;
    for (int v : p.mana.crystals) crystals += v;
    // Resonance is charged ONCE at summon (a snapshot of your crystals), not
    // continuously, so a cheap body cannot run away to 12/12 in the late game.
    // Both its atk and hp are baked here; undergrowth keeps a continuous atk
    // part (recomputeContinuous) and only snapshots its hp here.
    int resBonus = def->keywordN("resonance") * crystals;
    int hpBonus = def->keywordN("undergrowth") * allies + resBonus;
    if (hpBonus > 0) {
      nc.maxHp += hpBonus;
      nc.hp += hpBonus;
    }
    if (resBonus > 0) {
      nc.baseAtk += resBonus;
      nc.atk += resBonus;
    }
    // Insert at the chosen slot (default: append to the right).
    int at = (pos >= 0 && pos <= static_cast<int>(p.board.size()))
                 ? pos
                 : static_cast<int>(p.board.size());
    p.board.insert(p.board.begin() + at, nc);
    // Violet split: spawn N permanent illusion copies of this card -- same atk
    // and keywords but 1 HP, normal summoning sickness. summonToken does not
    // run on_play/split, so they never re-trigger. Their only weakness is
    // fragility.
    int copies = def->keywordN("split");
    for (int i = 0; i < copies && static_cast<int>(p.board.size()) < BoardLimit;
         ++i)
      summonToken(p, def, /*sick=*/true, /*hpOverride=*/1, at + 1 + i);
  } else if (def->type == CardType::Aura) {
    p.auras.push_back(def);  // sits in play; its static effects are read live
  }
  if (def->hasKeyword("delay")) {
    // Blue delay: schedule the on_play effects instead of running them now.
    int n = def->keywordN("delay", 1);
    for (const auto& e : def->effects)
      if (e.trigger == "on_play") p.pending.push_back(DelayedEffect{e, n});
  } else {
    resolveOnPlay(def, p, target);
  }
  if (def->type == CardType::Spell) p.graveyard.push_back(def);
  checkDeaths();  // an on_play effect may have damaged or destroyed creatures
}

// Violet awaken: play a card straight from the mana row. The banked crystal is
// consumed -- it pays 1 of the cost in its own color (or 1 generic if that
// color isn't required), and the remainder is paid from the player's other
// available crystals. Net cost: (cost - 1) plus the lost slot.
bool Game::awaken(int manaRowIndex, EntityId target, int pos) {
  if (over_) return false;
  Player& p = players_[current_];
  if (manaRowIndex < 0 || manaRowIndex >= static_cast<int>(p.manaRow.size()))
    return false;
  ManaCard mc = p.manaRow[manaRowIndex];
  const CardDef* def = mc.card.def;
  if (!def->hasKeyword("awaken")) return false;
  int c = idx(mc.color);
  if (p.mana.available[c] < 1) return false;  // its own crystal must be unspent
  if (def->type == CardType::Creature &&
      static_cast<int>(p.board.size()) >= BoardLimit)
    return false;
  if (def->type == CardType::Aura && hasAura(p, def->id)) return false;
  if (!playTargetLegal(def, p, target)) return false;
  Cost eff = def->cost;
  // The banked crystal pays 1 of the cost in its OWN color (it became a crystal
  // of that color when sacrificed). Only if the cost doesn't ask for that color
  // does it fall back to covering 1 generic. This is the real discount: a
  // Violet card banked as Violet covers its own Violet pip instead of being
  // wasted.
  if (eff.pips[c] > 0)
    eff.pips[c] -= 1;
  else if (eff.generic > 0)
    eff.generic -= 1;
  // Violet decoy: a banked card that has lain long enough awakens for free --
  // only its own crystal is spent. The longer the bluff sits, the bigger the
  // payoff.
  if (def->hasKeyword("decoy") && mc.age >= def->keywordN("decoy"))
    eff = Cost{};
  ManaPool sim = p.mana;
  sim.crystals[c] -= 1;  // the banked crystal leaves the pool
  sim.available[c] -= 1;
  if (!sim.pay(eff)) return false;  // remainder unaffordable -> nothing changes
  p.mana = sim;
  p.manaRow.erase(p.manaRow.begin() + manaRowIndex);
  playResolved(p, mc.card, target, pos);
  return true;
}

bool Game::enemyHasProvoke(const Player& opp) const {
  for (const auto& c : opp.board)
    if (c.def->hasKeyword("provoke")) return true;
  return false;
}

bool Game::hasAura(const Player& p, const std::string& id) const {
  for (const auto* a : p.auras)
    if (a->id == id) return true;
  return false;
}

// Mutual, simultaneous combat (DESIGN §2): both creatures deal their atk to
// each other at once, so both can die. Provoke forces the attacker onto a
// provoker; Pierce sends lethal excess to the enemy hero; Stealth hides a
// creature from being targeted; lifesteal heals the attacker for the damage it
// dealt.
bool Game::activate(EntityId id) {
  if (over_) return false;
  Player& p = players_[current_];
  Creature* c = findCreature(p, id);
  if (!c) return false;
  int n = c->def->keywordN("germinate");
  if (n <= 0 || c->usedActive) return false;
  if (static_cast<int>(p.board.size()) >= BoardLimit) return false;
  Cost one;
  one.generic = 1;  // costs 1 crystal of any color
  if (!p.mana.canPay(one)) return false;
  p.mana.pay(one);
  c->usedActive = true;
  // The sprout enters right beside the creature that germinated it.
  int idx = static_cast<int>(c - p.board.data());
  const CardDef* sprout =
      internToken("token_sprout" + std::to_string(n), Stats{n, n});
  summonToken(p, sprout, /*sick=*/true, /*hpOverride=*/-1, idx + 1);
  recomputeContinuous();  // the new body shifts undergrowth totals
  return true;
}

bool Game::attackCreature(EntityId attacker, EntityId target) {
  if (over_) return false;
  Player& me = players_[current_];
  Player& opp = players_[1 - current_];
  Creature* a = findCreature(me, attacker);
  Creature* b = findCreature(opp, target);
  if (!a || !b) return false;
  if (!a->canAttack()) return false;
  if (b->stealthed) return false;  // a hidden creature cannot be targeted
  if (enemyHasProvoke(opp) && !b->def->hasKeyword("provoke")) return false;
  int targetHpBefore = b->hp;
  int dealt = damageCreature(*b, a->atk, a);
  // Blind (Yellow) puts out a creature's combat damage entirely: a blinded
  // defender cannot land its blow, so it deals no retaliation. Freeze (Blue)
  // only stops a creature from initiating -- it still hits back when attacked.
  int retaliation = b->blindTurns > 0 ? 0 : b->atk;
  damageCreature(*a, retaliation, b);  // simultaneous retaliation
  if (a->def->hasKeyword("pierce")) {
    int overflow = dealt - targetHpBefore;
    // Eclipse umbra softens this face damage too -- pierce does not slip past
    // it.
    if (overflow > 0) dealHeroDamage(opp, heroHitDamage(opp, overflow));
  }
  if (a->def->hasKeyword("self_lifesteal")) healCreature(*a, dealt);
  a->stealthed = false;  // attacking reveals a stealthed creature
  a->attacked = true;
  checkDeaths();
  return true;
}

bool Game::attackHero(EntityId attacker) {
  if (over_) return false;
  Player& me = players_[current_];
  Player& opp = players_[1 - current_];
  Creature* a = findCreature(me, attacker);
  if (!a || !a->canAttack()) return false;
  // Provoke blocks the face unless the attacker has Bypass (Red).
  if (enemyHasProvoke(opp) && !a->def->hasKeyword("bypass")) return false;
  int dmg = heroHitDamage(opp, a->atk);  // Eclipse umbra softens it by 1
  dealHeroDamage(opp, dmg);
  if (a->def->hasKeyword("self_lifesteal")) healCreature(*a, dmg);
  a->stealthed = false;
  a->attacked = true;
  return true;
}

// State-based death check: every creature at <=0 hp leaves play, then its Died
// event is processed (which may summon tokens, e.g. Green spores). Tokens that
// vanish (illusions) are not removed here -- that happens at turn end.
void Game::checkDeaths() {
  std::vector<Event> deaths;
  for (auto& p : players_) {
    std::vector<Creature> survivors;
    survivors.reserve(p.board.size());
    for (auto& c : p.board) {
      if (c.hp > 0) {
        survivors.push_back(c);
      } else {
        p.graveyard.push_back(c.def);
        // Slot among the survivors so far: where this body sat, so a death-
        // triggered token (spores/haunt) lands where the creature was.
        int slot = static_cast<int>(survivors.size());
        deaths.push_back(
            Event{EventType::Died, c.id, 0, 0, p.index, c.def, slot});
      }
    }
    p.board.swap(survivors);
  }
  for (const auto& e : deaths) emit(e);
  processEvents();
  recomputeContinuous();  // board changed -> refresh continuous attack
}

void Game::processEvents() {
  while (!events_.empty()) {
    Event e = events_.front();
    events_.pop_front();
    reactTo(e);
  }
}

void Game::reactTo(const Event& e) {
  if (e.type != EventType::Died || !e.card) return;
  Player& owner = players_[e.player];
  // Compost first, on the survivors only -- before any spawn, so a freshly
  // summoned copy/sprout never gets buffed by the same death that made it.
  for (auto& c : owner.board) {
    int cm = c.def->keywordN("compost");
    if (cm > 0) buffStats(c, cm);
  }
  // Bodies are spawned where the creature died, filling rightward from `slot`.
  int slot = e.pos;
  // Violet haunt: a 1 HP illusion of the creature itself. Spawned BEFORE spores
  // so that, when the board is nearly full, the self-copy keeps its slot and
  // the sprouts fill whatever remains (priority decided with the user).
  if (e.card->hasKeyword("haunt") &&
      static_cast<int>(owner.board.size()) < BoardLimit) {
    summonToken(owner, e.card, /*sick=*/true, /*hpOverride=*/1, slot);
    ++slot;
  }
  // Green spores: N 1/1 sprouts beside where it died, after the self-copy.
  int n = e.card->keywordN("spores");
  if (n > 0) {
    const CardDef* sprout = internToken("token_sprout", Stats{1, 1});
    for (int i = 0; i < n && static_cast<int>(owner.board.size()) < BoardLimit;
         ++i, ++slot)
      summonToken(owner, sprout, /*sick=*/true, /*hpOverride=*/-1, slot);
  }
}

EntityId Game::summonToken(Player& p, const CardDef* def, bool sick,
                           int hpOverride, int at) {
  EntityId id = nextId_++;
  Creature nc = makeCreature(id, def, sick, /*token=*/true, hpOverride);
  // Place next to the source (`at`) so spawned bodies appear where they belong,
  // not always at the far right. Out-of-range / -1 falls back to appending.
  if (at >= 0 && at <= static_cast<int>(p.board.size()))
    p.board.insert(p.board.begin() + at, nc);
  else
    p.board.push_back(nc);
  return id;
}

Creature Game::makeCreature(EntityId id, const CardDef* def, bool sick,
                            bool token, int hpOverride) {
  int hp = hpOverride >= 0 ? hpOverride : def->stats.hp;
  Creature c{};
  c.id = id;
  c.def = def;
  c.atk = def->stats.atk;
  c.baseAtk = def->stats.atk;
  c.hp = hp;
  c.maxHp = hp;
  c.sick = sick;
  c.token = token;
  // Illusions reference the original card, so they inherit its keywords -- that
  // is the point of illusions. (Sprouts use a vanilla token def, so none.)
  c.shield = def->hasKeyword("shield");
  c.warded = def->hasKeyword("ward");
  c.stealthed = def->hasKeyword("stealth");
  return c;
}

bool Game::absorbWard(Creature& t) {
  if (!t.warded) return false;
  t.warded = false;  // the halo flares once and is spent
  return true;
}

int Game::damageCreature(Creature& target, int amount, const Creature* source) {
  if (amount <= 0) return 0;
  if (target.shield) {
    target.shield = false;  // divine shield absorbs the whole instance
    return 0;
  }
  target.hp -= amount;
  if (source && source->def && source->def->hasKeyword("lingering"))
    target.unhealable = std::min(target.maxHp, target.unhealable + amount);
  return amount;
}

void Game::healCreature(Creature& c, int amount) {
  if (amount <= 0) return;
  int cap = c.maxHp - c.unhealable;  // lingering wounds cannot be healed back
  if (cap < 0) cap = 0;
  int want = c.hp + amount;
  if (want > cap) want = cap;
  if (want > c.hp) c.hp = want;
}

void Game::buffStats(Creature& c, int n) {
  c.baseAtk += n;  // permanent: the live layer is added on top of this
  c.atk += n;
  c.maxHp += n;
  c.hp += n;
}

void Game::recomputeContinuous() {
  for (int pi = 0; pi < 2; ++pi) {
    Player& me = players_[pi];
    Player& opp = players_[1 - pi];
    int enemyChill = 0;
    for (const auto* a : opp.auras) enemyChill += a->keywordN("chill");
    int allies = static_cast<int>(me.board.size());
    for (auto& c : me.board) {
      // Resonance is a summon-time snapshot (see playResolved), so it is NOT
      // part of the live layer here -- only undergrowth and enemy chill are.
      int cont = c.def->keywordN("undergrowth") * (allies - 1) - enemyChill;
      int eff = c.baseAtk + cont;
      c.atk = eff < 0 ? 0 : eff;
    }
  }
}

void Game::bounceCreature(EntityId id) {
  for (auto& pl : players_) {
    for (std::size_t i = 0; i < pl.board.size(); ++i) {
      if (pl.board[i].id != id) continue;
      Creature c = pl.board[i];
      pl.board.erase(pl.board.begin() + i);
      // Tokens cease to exist when bounced; real cards return to hand (or burn
      // if the hand is full).
      if (!c.token) {
        if (static_cast<int>(pl.hand.size()) < HandLimit)
          pl.hand.push_back(CardInstance{c.id, c.def});
        else
          pl.graveyard.push_back(c.def);
      }
      return;
    }
  }
}

void Game::makeMirage(Player& owner, EntityId target) {
  for (auto& pl : players_) {
    for (const auto& c : pl.board) {
      if (c.id != target) continue;
      // A 1 HP illusion copy of the target card (keywords included).
      if (static_cast<int>(owner.board.size()) < BoardLimit)
        summonToken(owner, c.def, /*sick=*/true, /*hpOverride=*/1);
      return;
    }
  }
}

const CardDef* Game::internToken(const std::string& id, Stats s) {
  for (auto& d : tokenDefs_)
    if (d.id == id) return &d;
  CardDef d;
  d.id = id;
  d.type = CardType::Creature;
  d.hasStats = true;
  d.stats = s;
  tokenDefs_.push_back(d);
  return &tokenDefs_.back();
}

// An on_play effect that picks an enemy creature needs a real, non-stealthed
// target; otherwise the whole play is illegal (checked before paying).
bool Game::playTargetLegal(const CardDef* def, Player& owner, EntityId target) {
  Player& opp = players_[1 - owner.index];
  for (const auto& e : def->effects) {
    if (e.trigger != "on_play") continue;
    if (e.selector == "chosen_enemy_minion") {
      Creature* t = findCreature(opp, target);
      if (!t || t->stealthed) return false;  // a hidden enemy cannot be chosen
    } else if (e.selector == "chosen_friendly_minion") {
      if (!findCreature(owner, target)) return false;
    } else if (e.selector == "chosen_any_minion") {
      Creature* f = findCreature(owner, target);
      Creature* o = findCreature(opp, target);
      if (!f && (!o || o->stealthed)) return false;
    }
  }
  return true;
}

// Dispatch the inline effect grammar (DESIGN §8):
// [trigger]+[selector]->[action]. Only the actions used by current cards are
// implemented; adding a new action is a new branch here plus a new selector
// case if needed.
void Game::resolveOnPlay(const CardDef* def, Player& owner, EntityId target) {
  for (const auto& e : def->effects)
    if (e.trigger == "on_play") executeAction(e, owner, target);
}

void Game::executeAction(const EffectDef& e, Player& owner, EntityId target) {
  Player& opp = players_[1 - owner.index];
  const std::string& a = e.action;
  if (a == "freeze") {
    if (Creature* t = findSelected(e.selector, owner, target))
      if (!absorbWard(*t)) t->frozenTurns = e.value;
  } else if (a == "blind") {
    if (Creature* t = findSelected(e.selector, owner, target))
      if (!absorbWard(*t)) t->blindTurns = e.value;
  } else if (a == "flash") {
    for (auto& c : opp.board) c.blindTurns = e.value;  // blind every enemy
  } else if (a == "damage") {
    if (e.selector == "enemy_hero")
      dealHeroDamage(opp, e.value);
    else if (Creature* t = findSelected(e.selector, owner, target))
      if (!absorbWard(*t)) damageCreature(*t, e.value, nullptr);
  } else if (a == "damage_all") {
    for (auto& pl : players_)
      for (auto& c : pl.board) damageCreature(c, e.value, nullptr);
  } else if (a == "destroy") {
    if (Creature* t = findSelected(e.selector, owner, target))
      if (!absorbWard(*t)) t->hp = 0;  // checkDeaths reaps
  } else if (a == "draw") {
    draw(owner, e.value);
  } else if (a == "add_crystal") {
    for (int k = 0; k < e.value; ++k) owner.mana.addCrystal(Color::Colorless);
  } else if (a == "scry") {
    startScry(owner, e.value);
  } else if (a == "dispel") {
    // Blue dispel: strip the opponent's auras (they are unique per player, so
    // this is usually the one they control). The cards go to their graveyard.
    for (const auto* aura : opp.auras) opp.graveyard.push_back(aura);
    opp.auras.clear();
    recomputeContinuous();  // a removed chill aura un-shrinks enemy attack
  } else if (a == "scatter") {
    Creature* t = findCreature(owner, target);
    if (!t) t = findCreature(opp, target);
    if (t && !absorbWard(*t)) bounceCreature(target);
  } else if (a == "mirage") {
    makeMirage(owner, target);
  }
}

Creature* Game::findCreature(Player& p, EntityId id) {
  for (auto& c : p.board)
    if (c.id == id) return &c;
  return nullptr;
}

Creature* Game::findSelected(const std::string& selector, Player& owner,
                             EntityId target) {
  Player& opp = players_[1 - owner.index];
  if (selector == "chosen_friendly_minion") return findCreature(owner, target);
  if (selector == "chosen_any_minion") {
    Creature* c = findCreature(owner, target);
    return c ? c : findCreature(opp, target);
  }
  return findCreature(opp, target);  // chosen_enemy_minion / default
}

void Game::endTurn() {
  if (over_) return;
  tickStatuses(players_[current_]);  // ending player's freeze/blind tick down
  current_ = 1 - current_;
  turn_ += 1;
  startTurn();
}

}  // namespace prism
