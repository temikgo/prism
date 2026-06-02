#include "prism/game.hpp"

#include <algorithm>

namespace prism {

Game::Game(const CardLibrary& lib, const std::vector<std::string>& deck0,
           const std::vector<std::string>& deck1, std::uint32_t seed)
    : lib_(lib), rng_(seed) {
  players_[0].index = 0;
  players_[1].index = 1;
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
  startTurn();
}

// Turn order (DESIGN §1): refill mana -> start triggers -> draw -> main phase.
void Game::startTurn() {
  Player& p = players_[current_];
  p.mana.refill();
  p.placedManaThisTurn = false;
  for (auto& c : p.board) {
    c.sick = false;
    c.attacked = false;
  }
  applyTurnStartTriggers(p);
  draw(p, 1);
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
  return true;
}

bool Game::playCard(int handIndex, EntityId target) {
  if (over_) return false;
  Player& p = players_[current_];
  if (handIndex < 0 || handIndex >= static_cast<int>(p.hand.size()))
    return false;
  CardInstance ci = p.hand[handIndex];
  const CardDef* def = ci.def;
  if (!p.mana.canPay(def->cost)) return false;
  if (def->type == CardType::Creature &&
      static_cast<int>(p.board.size()) >= BoardLimit)
    return false;
  if (!playTargetLegal(def, p, target)) return false;
  p.mana.pay(def->cost);
  p.hand.erase(p.hand.begin() + handIndex);
  playResolved(p, ci, target);
  return true;
}

// Put an already-paid-for card into play. Creatures enter summoning sick;
// auras stay in play; spells resolve and go to the graveyard. Any on_play
// effect runs against `target`.
void Game::playResolved(Player& p, const CardInstance& ci, EntityId target) {
  const CardDef* def = ci.def;
  if (def->type == CardType::Creature) {
    p.board.push_back(makeCreature(ci.id, def, /*sick=*/true, /*token=*/false,
                                   /*hpOverride=*/-1));
    // Violet split: spawn N permanent illusion copies of this card -- same atk
    // and keywords but 1 HP, normal summoning sickness. summonToken does not
    // run on_play/split, so they never re-trigger. Their only weakness is
    // fragility.
    int copies = def->keywordN("split");
    for (int i = 0; i < copies && static_cast<int>(p.board.size()) < BoardLimit;
         ++i)
      summonToken(p, def, /*sick=*/true, /*hpOverride=*/1);
  } else if (def->type == CardType::Aura) {
    p.auras.push_back(def);  // sits in play; its static effects are read live
  }
  resolveOnPlay(def, p, target);
  if (def->type == CardType::Spell) p.graveyard.push_back(def);
  checkDeaths();  // an on_play effect may have damaged or destroyed creatures
}

// Violet awaken: play a card straight from the mana row. The banked crystal is
// consumed -- it pays 1 generic toward the cost, and the remainder is paid from
// the player's other available crystals. Net cost: (cost - 1) plus the lost
// slot.
bool Game::awaken(int manaRowIndex, EntityId target) {
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
  if (!playTargetLegal(def, p, target)) return false;
  Cost eff = def->cost;
  eff.generic = eff.generic > 0 ? eff.generic - 1 : 0;
  ManaPool sim = p.mana;
  sim.crystals[c] -= 1;
  sim.available[c] -= 1;
  if (!sim.pay(eff)) return false;  // remainder unaffordable -> nothing changes
  p.mana = sim;
  p.manaRow.erase(p.manaRow.begin() + manaRowIndex);
  playResolved(p, mc.card, target);
  return true;
}

bool Game::enemyHasProvoke(const Player& opp) const {
  for (const auto& c : opp.board)
    if (c.def->hasKeyword("provoke")) return true;
  return false;
}

// Mutual, simultaneous combat (DESIGN §2): both creatures deal their atk to
// each other at once, so both can die. Provoke forces the attacker onto a
// provoker; Pierce sends lethal excess to the enemy hero; Stealth hides a
// creature from being targeted; lifesteal heals the attacker for the damage it
// dealt.
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
  damageCreature(*a, b->atk, b);  // simultaneous retaliation
  if (a->def->hasKeyword("pierce")) {
    int overflow = dealt - targetHpBefore;
    if (overflow > 0) dealHeroDamage(opp, overflow);
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
  dealHeroDamage(opp, a->atk);
  if (a->def->hasKeyword("self_lifesteal")) healCreature(*a, a->atk);
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
        deaths.push_back(Event{EventType::Died, c.id, 0, 0, p.index, c.def});
      }
    }
    p.board.swap(survivors);
  }
  for (const auto& e : deaths) emit(e);
  processEvents();
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
  // Green spores: the dead creature leaves N 1/1 sprout tokens behind.
  int n = e.card->keywordN("spores");
  if (n > 0) {
    const CardDef* sprout = internToken("sprout", Stats{1, 1});
    for (int i = 0; i < n && static_cast<int>(owner.board.size()) < BoardLimit;
         ++i)
      summonToken(owner, sprout, /*sick=*/true, /*hpOverride=*/-1);
  }
  // Green compost: each surviving ally with Compost grows when an ally dies.
  for (auto& c : owner.board) {
    int cm = c.def->keywordN("compost");
    if (cm > 0) buffStats(c, cm);
  }
  // Violet haunt: the dead creature leaves a 1 HP illusion of itself (an
  // illusion copies the original card, keywords included).
  if (e.card->hasKeyword("haunt") &&
      static_cast<int>(owner.board.size()) < BoardLimit)
    summonToken(owner, e.card, /*sick=*/true, /*hpOverride=*/1);
}

EntityId Game::summonToken(Player& p, const CardDef* def, bool sick,
                           int hpOverride) {
  EntityId id = nextId_++;
  p.board.push_back(makeCreature(id, def, sick, /*token=*/true, hpOverride));
  return id;
}

Creature Game::makeCreature(EntityId id, const CardDef* def, bool sick,
                            bool token, int hpOverride) {
  int hp = hpOverride >= 0 ? hpOverride : def->stats.hp;
  Creature c{};
  c.id = id;
  c.def = def;
  c.atk = def->stats.atk;
  c.hp = hp;
  c.maxHp = hp;
  c.sick = sick;
  c.token = token;
  // Illusions reference the original card, so they inherit its keywords -- that
  // is the point of illusions. (Sprouts use a vanilla token def, so none.)
  c.shield = def->hasKeyword("shield");
  c.stealthed = def->hasKeyword("stealth");
  return c;
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
  c.atk += n;
  c.maxHp += n;
  c.hp += n;
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
      if (!t || t->stealthed) return false;
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
    if (Creature* t = findCreature(opp, target)) t->frozenTurns = e.value;
  } else if (a == "blind") {
    if (Creature* t = findCreature(opp, target)) t->blindTurns = e.value;
  } else if (a == "flash") {
    for (auto& c : opp.board) c.blindTurns = e.value;  // blind every enemy
  } else if (a == "damage") {
    if (e.selector == "enemy_hero")
      dealHeroDamage(opp, e.value);
    else if (Creature* t = findCreature(opp, target))
      damageCreature(*t, e.value, nullptr);
  } else if (a == "damage_all") {
    for (auto& pl : players_)
      for (auto& c : pl.board) damageCreature(c, e.value, nullptr);
  } else if (a == "destroy") {
    if (Creature* t = findCreature(opp, target))
      t->hp = 0;  // checkDeaths reaps
  } else if (a == "draw") {
    draw(owner, e.value);
  } else if (a == "scatter") {
    bounceCreature(target);
  } else if (a == "mirage") {
    makeMirage(owner, target);
  }
}

Creature* Game::findCreature(Player& p, EntityId id) {
  for (auto& c : p.board)
    if (c.id == id) return &c;
  return nullptr;
}

void Game::endTurn() {
  if (over_) return;
  tickStatuses(players_[current_]);  // ending player's freeze/blind tick down
  current_ = 1 - current_;
  turn_ += 1;
  startTurn();
}

}  // namespace prism
