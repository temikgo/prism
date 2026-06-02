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

// Turn order (DESIGN §1): refill mana -> (start triggers) -> draw -> main phase.
void Game::startTurn() {
  Player& p = players_[current_];
  p.mana.refill();
  p.placedManaThisTurn = false;
  for (auto& c : p.board) {
    c.sick = false;
    c.attacked = false;
  }
  draw(p, 1);
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
  if (handIndex < 0 || handIndex >= static_cast<int>(p.hand.size())) return false;
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
  p.hand.erase(p.hand.begin() + handIndex);
  p.mana.addCrystal(color);
  p.placedManaThisTurn = true;
  return true;
}

bool Game::playCard(int handIndex) {
  if (over_) return false;
  Player& p = players_[current_];
  if (handIndex < 0 || handIndex >= static_cast<int>(p.hand.size())) return false;
  CardInstance ci = p.hand[handIndex];
  const CardDef* def = ci.def;
  if (!p.mana.canPay(def->cost)) return false;
  if (def->type == CardType::Creature &&
      static_cast<int>(p.board.size()) >= BoardLimit)
    return false;
  p.mana.pay(def->cost);
  p.hand.erase(p.hand.begin() + handIndex);
  if (def->type == CardType::Creature) {
    // Enters summoning sick; live stats start from the template.
    p.board.push_back(Creature{ci.id, def, def->stats.atk, def->stats.def,
                               def->stats.hp, def->stats.hp, true, false});
  } else if (def->type == CardType::Aura) {
    p.auras.push_back(def);  // sits in play; no continuous effect yet
  } else {
    p.graveyard.push_back(def);  // spell: resolves to nothing yet
  }
  return true;
}

// Mutual, simultaneous combat (DESIGN §2): the attacker uses its atk, the
// defender retaliates with its def (not its atk). Both can die at once.
bool Game::attackCreature(EntityId attacker, EntityId target) {
  if (over_) return false;
  Player& me = players_[current_];
  Player& opp = players_[1 - current_];
  Creature* a = findCreature(me, attacker);
  Creature* b = findCreature(opp, target);
  if (!a || !b) return false;
  if (a->sick || a->attacked || a->atk <= 0) return false;
  b->hp -= a->atk;
  a->hp -= b->def_;
  a->attacked = true;
  checkDeaths();
  return true;
}

bool Game::attackHero(EntityId attacker) {
  if (over_) return false;
  Player& me = players_[current_];
  Player& opp = players_[1 - current_];
  Creature* a = findCreature(me, attacker);
  if (!a || a->sick || a->attacked || a->atk <= 0) return false;
  dealHeroDamage(opp, a->atk);
  a->attacked = true;
  return true;
}

void Game::checkDeaths() {
  for (auto& p : players_) {
    std::vector<Creature> survivors;
    survivors.reserve(p.board.size());
    for (auto& c : p.board) {
      if (c.hp > 0)
        survivors.push_back(c);
      else
        p.graveyard.push_back(c.def);
    }
    p.board.swap(survivors);
  }
}

Creature* Game::findCreature(Player& p, EntityId id) {
  for (auto& c : p.board)
    if (c.id == id) return &c;
  return nullptr;
}

void Game::endTurn() {
  if (over_) return;
  current_ = 1 - current_;
  turn_ += 1;
  startTurn();
}

}  // namespace prism
