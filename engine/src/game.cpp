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
  p.summonedThisTurn = false;
  p.heroPowerUses = 0;  // limited hero passives recharge each turn
  for (auto& c : p.board) {
    c.sick = false;
    c.attacked = false;
    c.strobeUsed = false;
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

// Tick every pending delayed effect; the ones that reach zero resolve now,
// against the target and source captured when the card was played (a targeted
// bomb still finds its creature, or fizzles harmlessly if it has since gone).
void Game::processDelayed(Player& p) {
  std::vector<DelayedEffect> still;
  for (auto& d : p.pending) {
    d.turnsLeft -= 1;
    if (d.turnsLeft <= 0)
      executeAction(d.effect, p, d.target, d.src);
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
  // Green mulch: a slow regrowth field mends your single most-wounded ally.
  bool hasMulch = false;
  for (const auto* a : p.auras)
    if (a->hasKeyword("mulch")) hasMulch = true;
  if (hasMulch) {
    Creature* worst = nullptr;
    for (auto& c : p.board)
      if (c.hp < c.maxHp && (!worst || c.hp < worst->hp)) worst = &c;
    if (worst) healCreature(*worst, 1);
  }
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
      // Drawing into a full hand discards the card: it has left the deck, so it
      // goes to the graveyard (a spent card) rather than vanishing untracked.
      if (static_cast<int>(p.hand.size()) < HandLimit)
        p.hand.push_back(ci);
      else
        p.graveyard.push_back(ci.def);
    }
  }
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

bool Game::playCard(int handIndex, EntityId target, int pos,
                    std::optional<std::array<int, ColorCount>> genericPay) {
  if (over_) return false;
  Player& p = players_[current_];
  if (handIndex < 0 || handIndex >= static_cast<int>(p.hand.size()))
    return false;
  CardInstance ci = p.hand[handIndex];
  const CardDef* def = ci.def;
  // Blue haze: an enemy aura surcharges this card's cost if it is a spell.
  const Cost cost = effectiveCost(p, def);
  // Affordable normally, or via the Prism hero's once-per-turn spectral shift?
  bool normal = p.mana.canPay(cost);
  std::optional<ManaPool> shifted;
  if (!normal && p.hero && p.hero->hasKeyword("spectral_shift") &&
      p.heroPowerUses < 1)
    shifted = shiftedPool(p.mana, cost);
  if (!normal && !shifted) return false;
  if (def->type == CardType::Creature &&
      static_cast<int>(p.board.size()) >= BoardLimit)
    return false;
  if (def->type == CardType::Aura && hasAura(p, def->id)) return false;
  if (!playTargetLegal(def, p, target)) return false;
  // Pay last, after every legality check, so a rejected play never spends mana.
  if (normal) {
    // Honour the player's chosen generic breakdown if one was given and is
    // valid; otherwise fall back to the greedy default (which is also the only
    // result when the payment is forced).
    if (!(genericPay && p.mana.pay(cost, *genericPay))) p.mana.pay(cost);
  } else {
    ManaPool np = *shifted;
    np.pay(cost);
    p.mana = np;
    p.heroPowerUses += 1;  // the spectral shift counts as a hero-power use
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
    // Resonance is charged ONCE at summon (a snapshot of your crystals) so a
    // cheap body cannot run away to 12/12 in the late game -- baked into base
    // atk/hp here. Undergrowth is NOT baked: it is continuous for BOTH atk and
    // hp (recomputeContinuous, run by the checkDeaths after the board insert
    // below), so a thicket creature grows and shrinks with your board.
    int crystals = 0;
    for (int v : p.mana.crystals) crystals += v;
    int resBonus = def->keywordN("resonance") * crystals;
    if (resBonus > 0) {
      nc.baseAtk += resBonus;
      nc.atk += resBonus;
      nc.baseMaxHp += resBonus;
      nc.maxHp += resBonus;
      nc.hp += resBonus;
    }
    // Insert at the chosen slot (default: append to the right).
    int at = (pos >= 0 && pos <= static_cast<int>(p.board.size()))
                 ? pos
                 : static_cast<int>(p.board.size());
    p.board.insert(p.board.begin() + at, nc);
    // Violet glimmer: the first creature you play each turn slips in unseen.
    if (!p.summonedThisTurn)
      for (const auto* a : p.auras)
        if (a->hasKeyword("glimmer")) {
          p.board[at].stealthed = true;
          break;
        }
    p.summonedThisTurn = true;
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
    // Capture the chosen target and source card so a targeted delayed effect
    // (e.g. damage a chosen enemy minion) still resolves against it -- and
    // keeps its source for lingering -- when it fires N turns later.
    for (const auto& e : def->effects)
      if (e.trigger == "on_play")
        p.pending.push_back(DelayedEffect{e, n, target, def});
  } else {
    resolveOnPlay(def, p, target);
  }
  if (def->type == CardType::Spell) p.graveyard.push_back(def);
  checkDeaths();  // an on_play effect may have damaged or destroyed creatures
  // Palette hero (Tiziana): the first card you play each turn whose cost needs
  // 2+ different colours draws a card. Uses the shared hero-power counter.
  if (p.hero && p.hero->hasKeyword("palette") && p.heroPowerUses < 1) {
    int distinct = 0;
    for (int v : def->cost.pips)
      if (v > 0) ++distinct;
    if (distinct >= 2) {
      p.heroPowerUses += 1;
      draw(p, 1);
    }
  }
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
  // Normally only cards with the awaken keyword can be woken from the mana row.
  // Decoy implies awaken-ability: a decoy card is meant to be banked and later
  // woken (free once matured, awakenCost handles the discount), so it counts as
  // wakeable even without the awaken keyword. Facet hero (Gemma) wakes ANY
  // card.
  bool facet = p.hero && p.hero->hasKeyword("facet");
  bool wakeable = def->hasKeyword("awaken") || def->hasKeyword("decoy");
  if (!wakeable && !facet) return false;
  if (def->type == CardType::Creature &&
      static_cast<int>(p.board.size()) >= BoardLimit)
    return false;
  if (def->type == CardType::Aura && hasAura(p, def->id)) return false;
  if (!playTargetLegal(def, p, target)) return false;
  // The banked crystal + discount math lives in awakenCost (shared with
  // legalActions); it returns the resulting pool, or nullopt if unaffordable.
  std::optional<ManaPool> sim = awakenCost(p, mc);
  if (!sim) return false;  // remainder unaffordable -> nothing changes
  p.mana = *sim;
  p.manaRow.erase(p.manaRow.begin() + manaRowIndex);
  playResolved(p, mc.card, target, pos);
  // Facet hero (Gemma): a woken creature enters sharpened, +1/+1.
  if (facet && def->type == CardType::Creature) {
    Creature* nc = findCreature(p, mc.card.id);
    if (nc) {
      buffStats(*nc, 1);
      recomputeContinuous();
    }
  }
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
  // Violet refract: an attack aimed at this creature bends onto a random other
  // enemy creature (the strike never reaches the one that bent it).
  if (b->def->hasKeyword("refract")) {
    std::vector<Creature*> others;
    for (auto& c : opp.board)
      if (c.id != b->id && !c.stealthed) others.push_back(&c);
    if (!others.empty()) b = others[rng_() % others.size()];
  }
  int targetHpBefore = b->hp;
  int dealt = damageCreature(*b, a->atk, a);
  // Blind (Yellow) puts out a creature's combat damage entirely: a blinded
  // defender cannot land its blow, so it deals no retaliation. Freeze (Blue)
  // only stops a creature from initiating -- it still hits back when attacked.
  int retaliation = b->blindTurns > 0 ? 0 : b->atk;
  // Yellow firststrike: light lands first -- if this blow kills the defender,
  // it never strikes back.
  if (a->def->hasKeyword("firststrike") && b->hp <= 0) retaliation = 0;
  damageCreature(*a, retaliation, b);  // otherwise simultaneous
  if (a->def->hasKeyword("pierce")) {
    int overflow = dealt - targetHpBefore;
    if (overflow > 0) dealHeroDamage(opp, overflow);
  }
  if (a->def->hasKeyword("self_lifesteal")) healCreature(*a, dealt);
  // Red cauterize: this creature's combat damage seals the wielder's hero.
  if (a->def->hasKeyword("cauterize"))
    me.heroHp = std::min(HeroStartHp, me.heroHp + dealt);
  a->stealthed = false;  // attacking reveals a stealthed creature
  a->markAttacked();
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
  int dmg = a->atk;
  dealHeroDamage(opp, dmg);
  if (a->def->hasKeyword("self_lifesteal")) healCreature(*a, dmg);
  if (a->def->hasKeyword("cauterize"))
    me.heroHp = std::min(HeroStartHp, me.heroHp + dmg);
  a->stealthed = false;
  a->markAttacked();
  // Eclipse 'lighteater' (Erebus): a creature that strikes this hero has its
  // light devoured -- it permanently loses 1 ATK (down to 0).
  if (opp.hero && opp.hero->hasKeyword("lighteater") && a->baseAtk > 0) {
    a->baseAtk -= 1;
    recomputeContinuous();
  }
  return true;
}

// State-based death check: every creature at <=0 hp leaves play, then its Died
// event is processed (which may summon tokens, e.g. Green spores). Tokens that
// vanish (illusions) are not removed here -- that happens at turn end.
void Game::checkDeaths() {
  // Loop: a death shrinks the board, and recomputeContinuous then lowers the
  // undergrowth HP of the survivors -- which can itself drop one to <=0. So the
  // sweep repeats until the board is stable (a thicket can collapse on itself).
  while (true) {
    std::vector<Event> deaths;
    for (auto& p : players_) {
      std::vector<Creature> survivors;
      survivors.reserve(p.board.size());
      for (auto& c : p.board) {
        if (c.hp > 0) {
          survivors.push_back(c);
        } else {
          // On death the card goes to the graveyard -- tokens/illusions too, so
          // the pile counts every body that died (matches bounce, which also
          // hands a token's card back rather than voiding it).
          p.graveyard.push_back(c.def);
          // Slot among the survivors so far: where this body sat, so a death-
          // triggered token (spores/haunt) lands where the creature was.
          int slot = static_cast<int>(survivors.size());
          deaths.push_back(Event{EventType::Died, c.id, 0, 0, p.index, c.def,
                                 slot, c.token});
        }
      }
      p.board.swap(survivors);
    }
    for (const auto& e : deaths) emit(e);
    processEvents();
    recomputeContinuous();  // board changed -> refresh continuous atk AND hp
    bool more = false;
    for (auto& p : players_)
      for (const auto& c : p.board)
        if (c.hp <= 0) more = true;
    if (!more) break;
  }
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
  // Violet haunt: a 1 HP illusion of the creature itself. Only a real creature
  // haunts -- the illusion it leaves is a token and does not haunt again, so a
  // creature is reborn exactly once. Spawned BEFORE spores so that, when the
  // board is nearly full, the self-copy keeps its slot and the sprouts fill
  // whatever remains (priority decided with the user).
  if (!e.token && e.card->hasKeyword("haunt") &&
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
  // Red sear: residual heat reaches the enemy hero as this body dies.
  int sr = e.card->keywordN("sear");
  if (sr > 0) dealHeroDamage(players_[1 - e.player], sr);
  // Yellow flare: a dying flash blinds N random enemy creatures for one turn.
  int fl = e.card->keywordN("flare");
  if (fl > 0) {
    Player& enemy = players_[1 - e.player];
    std::vector<int> idx(enemy.board.size());
    for (std::size_t i = 0; i < idx.size(); ++i) idx[i] = static_cast<int>(i);
    std::shuffle(idx.begin(), idx.end(), rng_);
    for (int i = 0; i < fl && i < static_cast<int>(idx.size()); ++i)
      if (!absorbWard(enemy.board[idx[i]])) enemy.board[idx[i]].blindTurns = 1;
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
  c.baseMaxHp = hp;
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

int Game::damageCreature(Creature& target, int amount, const Creature* source,
                         bool pierceShield) {
  if (amount <= 0) return 0;
  // Blue pinpoint (a spell keyword) threads a needle-fine beam through a
  // shield.
  if (target.shield && !pierceShield) {
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
  c.baseMaxHp += n;
  c.maxHp += n;
  c.hp += n;
}

void Game::recomputeContinuous() {
  for (int pi = 0; pi < 2; ++pi) {
    Player& me = players_[pi];
    Player& opp = players_[1 - pi];
    int enemyChill = 0;
    for (const auto* a : opp.auras) enemyChill += a->keywordN("chill");
    int myIncand = 0;  // Red Накал: your auras add attack to your whole board
    for (const auto* a : me.auras) myIncand += a->keywordN("incandescence");
    int allies = static_cast<int>(me.board.size());
    for (auto& c : me.board) {
      // Resonance is a summon-time snapshot (see playResolved); only
      // undergrowth, enemy chill and own incandescence are live here.
      // Undergrowth is +N per OTHER ally.
      int under = c.def->keywordN("undergrowth") * (allies - 1);
      int eff =
          c.baseAtk + under - enemyChill + myIncand;  // chill -atk, накал +atk
      c.atk = eff < 0 ? 0 : eff;
      // Undergrowth HP is continuous too: recompute the live max and carry the
      // same delta onto current hp, so damage is preserved. A shrinking board
      // can push hp <= 0 -- checkDeaths reaps it and loops, so the shrink can
      // cascade.
      int newMaxHp = c.baseMaxHp + under;
      c.hp += newMaxHp - c.maxHp;
      c.maxHp = newMaxHp;
    }
  }
}

void Game::bounceCreature(EntityId id) {
  for (auto& pl : players_) {
    for (std::size_t i = 0; i < pl.board.size(); ++i) {
      if (pl.board[i].id != id) continue;
      Creature c = pl.board[i];
      pl.board.erase(pl.board.begin() + i);
      // A bounced creature returns its card to the owner's hand -- even an
      // illusion token hands back the card it copies (design choice: scatter is
      // never pure removal). Burns to the graveyard if the hand is full.
      if (static_cast<int>(pl.hand.size()) < HandLimit)
        pl.hand.push_back(CardInstance{c.id, c.def});
      else
        pl.graveyard.push_back(c.def);
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
bool Game::playTargetLegal(const CardDef* def, const Player& owner,
                           EntityId target) const {
  const Player& opp = players_[1 - owner.index];
  for (const auto& e : def->effects) {
    if (e.trigger != "on_play") continue;
    bool chooses = e.selector == "chosen_enemy_minion" ||
                   e.selector == "chosen_friendly_minion" ||
                   e.selector == "chosen_any_minion";
    if (!chooses) continue;
    // Is the supplied target a legal pick for this selector?
    const Creature* t = nullptr;
    if (e.selector == "chosen_enemy_minion") {
      t = findCreature(opp, target);
      if (t && t->stealthed) t = nullptr;  // a hidden enemy cannot be chosen
    } else if (e.selector == "chosen_friendly_minion") {
      t = findCreature(owner, target);
    } else {  // chosen_any_minion
      t = findCreature(owner, target);
      if (!t) {
        t = findCreature(opp, target);
        if (t && t->stealthed) t = nullptr;
      }
    }
    if (t) continue;  // a valid target was chosen -> fine
    // No valid target. If the player did supply one (non-zero) it was illegal,
    // so reject regardless. With no target chosen, an optional effect just
    // skips (the card still plays); only a `required` cost effect blocks the
    // play.
    if (target != 0 || e.required) return false;
  }
  return true;
}

// --- legal-action enumeration (mirrors the mutators above) -------------------

Cost Game::effectiveCost(const Player& p, const CardDef* def) const {
  Cost c = def->cost;
  // Blue haze: each enemy haze aura makes your spells cost that much more.
  if (def->type == CardType::Spell)
    for (const auto* a : players_[1 - p.index].auras)
      if (a->hasKeyword("haze")) c.generic += a->keywordN("haze", 1);
  return c;
}

bool Game::affordableToPlay(const Player& p, const Cost& cost) const {
  if (p.mana.canPay(cost)) return true;
  // Prism spectral_shift: one foreign pip may be paid by retuning a
  // spectrum-adjacent crystal, once per turn (matches playCard).
  return p.hero && p.hero->hasKeyword("spectral_shift") &&
         p.heroPowerUses < 1 && shiftedPool(p.mana, cost).has_value();
}

std::optional<ManaPool> Game::awakenCost(const Player& p,
                                         const ManaCard& mc) const {
  const CardDef* def = mc.card.def;
  int c = idx(mc.color);
  if (p.mana.available[c] < 1) return std::nullopt;  // own crystal must be free
  Cost eff = def->cost;
  // The banked crystal pays 1 of the cost in its OWN color, else 1 generic.
  if (eff.pips[c] > 0)
    eff.pips[c] -= 1;
  else if (eff.generic > 0)
    eff.generic -= 1;
  // Violet decoy aged long enough awakens for free -- only its crystal is
  // spent.
  if (def->hasKeyword("decoy") && mc.age >= def->keywordN("decoy"))
    eff = Cost{};
  ManaPool sim = p.mana;
  sim.crystals[c] -= 1;  // the banked crystal leaves the pool
  sim.available[c] -= 1;
  if (!sim.pay(eff)) return std::nullopt;
  return sim;
}

std::vector<EntityId> Game::legalTargets(const CardDef* def,
                                         const Player& owner) const {
  std::vector<EntityId> out;
  // Candidate ids: "no target" (0) plus every creature on either board. Keep
  // the ones playTargetLegal accepts -- this reuses the single source of target
  // truth, so enumeration can never diverge from what playCard/awaken allow.
  if (playTargetLegal(def, owner, 0)) out.push_back(0);
  for (const Player& side : players_)
    for (const Creature& c : side.board)
      if (playTargetLegal(def, owner, c.id)) out.push_back(c.id);
  return out;
}

std::vector<Action> Game::legalActions() const {
  std::vector<Action> out;
  // Parameterized / terminal phases have no discrete move list (see the
  // header): mulligan and scry are subset choices driven via mulligan() /
  // resolveScry().
  if (over_ || mulliganPhase_ || scryPlayer_ >= 0) return out;
  const Player& p = players_[current_];
  const Player& opp = players_[1 - current_];

  out.push_back(Action{Action::Type::EndTurn});

  // placeMana: one card -> the mana row per turn (mirrors placeCardToMana). A
  // neutral card can only become Colorless; a colored card any one of its
  // colors.
  if (!p.placedManaThisTurn) {
    for (int i = 0; i < static_cast<int>(p.hand.size()); ++i) {
      const CardDef* def = p.hand[i].def;
      Action a;
      a.type = Action::Type::PlaceMana;
      a.handIndex = i;
      if (def->colors.empty()) {
        a.color = Color::Colorless;
        out.push_back(a);
      } else {
        for (Color col : def->colors) {
          a.color = col;
          out.push_back(a);
        }
      }
    }
  }

  // play: affordable (incl. spectral shift), board/aura room, per legal target
  // (mirrors playCard). pos and genericPay are free parameters, not enumerated.
  for (int i = 0; i < static_cast<int>(p.hand.size()); ++i) {
    const CardDef* def = p.hand[i].def;
    if (!affordableToPlay(p, effectiveCost(p, def))) continue;
    if (def->type == CardType::Creature &&
        static_cast<int>(p.board.size()) >= BoardLimit)
      continue;
    if (def->type == CardType::Aura && hasAura(p, def->id)) continue;
    for (EntityId t : legalTargets(def, p)) {
      Action a;
      a.type = Action::Type::Play;
      a.handIndex = i;
      a.target = t;
      out.push_back(a);
    }
  }

  // awaken: a banked card from the mana row (mirrors awaken).
  bool facet = p.hero && p.hero->hasKeyword("facet");
  for (int i = 0; i < static_cast<int>(p.manaRow.size()); ++i) {
    const ManaCard& mc = p.manaRow[i];
    const CardDef* def = mc.card.def;
    bool wakeable = def->hasKeyword("awaken") || def->hasKeyword("decoy");
    if (!wakeable && !facet) continue;
    if (def->type == CardType::Creature &&
        static_cast<int>(p.board.size()) >= BoardLimit)
      continue;
    if (def->type == CardType::Aura && hasAura(p, def->id)) continue;
    if (!awakenCost(p, mc)) continue;
    for (EntityId t : legalTargets(def, p)) {
      Action a;
      a.type = Action::Type::Awaken;
      a.manaRowIndex = i;
      a.target = t;
      out.push_back(a);
    }
  }

  // activate: Green germinate (mirrors activate). Costs 1 crystal of any color.
  Cost one;
  one.generic = 1;
  bool boardFull = static_cast<int>(p.board.size()) >= BoardLimit;
  if (!boardFull && p.mana.canPay(one)) {
    for (const Creature& c : p.board)
      if (c.def->keywordN("germinate") > 0 && !c.usedActive) {
        Action a;
        a.type = Action::Type::Activate;
        a.id = c.id;
        out.push_back(a);
      }
  }

  // attacks: each ready creature onto any legal target, or the face (mirrors
  // attackCreature / attackHero, incl. provoke / stealth / bypass).
  bool prov = enemyHasProvoke(opp);
  for (const Creature& a0 : p.board) {
    if (!a0.canAttack()) continue;
    for (const Creature& b : opp.board) {
      if (b.stealthed) continue;
      if (prov && !b.def->hasKeyword("provoke")) continue;
      Action a;
      a.type = Action::Type::AttackCreature;
      a.attacker = a0.id;
      a.target = b.id;
      out.push_back(a);
    }
    if (!prov || a0.def->hasKeyword("bypass")) {
      Action a;
      a.type = Action::Type::AttackHero;
      a.attacker = a0.id;
      out.push_back(a);
    }
  }
  return out;
}

// Dispatch the inline effect grammar (DESIGN §8):
// [trigger]+[selector]->[action]. Only the actions used by current cards are
// implemented; adding a new action is a new branch here plus a new selector
// case if needed.
void Game::resolveOnPlay(const CardDef* def, Player& owner, EntityId target) {
  for (const auto& e : def->effects)
    if (e.trigger == "on_play") executeAction(e, owner, target, def);
}

// Mark spell/effect damage as unhealable when the source card has lingering
// (Red). Mirrors damageCreature's source-creature path for spells, which carry
// no Creature source.
void Game::applyLingering(Creature& t, int dealt, const CardDef* src) {
  if (src && dealt > 0 && src->hasKeyword("lingering"))
    t.unhealable = std::min(t.maxHp, t.unhealable + dealt);
}

void Game::executeAction(const EffectDef& e, Player& owner, EntityId target,
                         const CardDef* src) {
  Player& opp = players_[1 - owner.index];
  const std::string& a = e.action;
  if (a == "freeze") {
    for (Creature* t : selectTargets(e.selector, owner, target))
      if (!absorbWard(*t)) t->frozenTurns = e.value;
  } else if (a == "blind") {
    for (Creature* t : selectTargets(e.selector, owner, target))
      if (!absorbWard(*t)) t->blindTurns = e.value;
  } else if (a == "damage") {
    if (e.selector == "enemy_hero") {
      dealHeroDamage(opp, e.value);
    } else {
      bool pin = src && src->hasKeyword("pinpoint");  // spell: through Щит+Нимб
      for (Creature* t : selectTargets(e.selector, owner, target))
        if (pin || !absorbWard(*t))
          applyLingering(*t, damageCreature(*t, e.value, nullptr, pin), src);
    }
  } else if (a == "destroy") {
    for (Creature* t : selectTargets(e.selector, owner, target))
      if (!absorbWard(*t)) t->hp = 0;  // checkDeaths reaps
  } else if (a == "draw") {
    draw(owner, e.value);
  } else if (a == "add_crystal") {
    for (int k = 0; k < e.value; ++k) owner.mana.addCrystal(Color::Colorless);
  } else if (a == "scry") {
    startScry(owner, e.value);
  } else if (a == "scatter") {
    Creature* t = findCreature(owner, target);
    if (!t) t = findCreature(opp, target);
    if (t && !absorbWard(*t)) bounceCreature(target);
  } else if (a == "mirage") {
    makeMirage(owner, target);
  } else if (a == "dispel") {
    // A universal answer to auras (which otherwise never leave play): strip the
    // opponent's auras, newest first. value <= 0 clears all; value N removes
    // the N most recent. The trailing checkDeaths/recomputeContinuous lifts any
    // chill this removed, so a suppressed attack returns at once.
    if (e.value <= 0)
      opp.auras.clear();
    else
      for (int k = 0; k < e.value && !opp.auras.empty(); ++k)
        opp.auras.pop_back();
  }
}

Creature* Game::findCreature(Player& p, EntityId id) {
  for (auto& c : p.board)
    if (c.id == id) return &c;
  return nullptr;
}

const Creature* Game::findCreature(const Player& p, EntityId id) const {
  for (const auto& c : p.board)
    if (c.id == id) return &c;
  return nullptr;
}

std::vector<Creature*> Game::selectTargets(const std::string& selector,
                                           Player& owner, EntityId target) {
  std::vector<Creature*> out;
  if (selector == "all_enemies") {
    for (auto& c : players_[1 - owner.index].board) out.push_back(&c);
  } else if (selector == "all_creatures") {
    for (auto& pl : players_)
      for (auto& c : pl.board) out.push_back(&c);
  } else if (Creature* t = findSelected(selector, owner, target)) {
    Player& opp = players_[1 - owner.index];
    // Violet refract: an enemy effect aimed at this creature bends onto a
    // random other enemy creature instead.
    if (selector == "chosen_enemy_minion" && t->def->hasKeyword("refract")) {
      std::vector<Creature*> others;
      for (auto& c : opp.board)
        if (c.id != t->id && !c.stealthed) others.push_back(&c);
      if (!others.empty()) t = others[rng_() % others.size()];
    }
    out.push_back(t);
    // Blue birefringence: the caster's targeted effect splits onto a second
    // random valid target of the same side (the beam is doubly refracted).
    if (selector.rfind("chosen_", 0) == 0 && ownerHasBirefringence(owner)) {
      std::vector<Creature*> pool;
      auto gather = [&](Player& pl) {
        for (auto& c : pl.board)
          if (c.id != out[0]->id && !c.stealthed) pool.push_back(&c);
      };
      if (selector == "chosen_friendly_minion")
        gather(owner);
      else if (selector == "chosen_enemy_minion")
        gather(opp);
      else {
        gather(owner);
        gather(opp);
      }
      if (!pool.empty()) out.push_back(pool[rng_() % pool.size()]);
    }
  }
  return out;
}

bool Game::ownerHasBirefringence(const Player& p) const {
  for (const auto& c : p.board)
    if (c.def->hasKeyword("birefringence")) return true;
  for (const auto* a : p.auras)
    if (a->hasKeyword("birefringence")) return true;
  return false;
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
