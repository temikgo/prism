#pragma once
#include <array>
#include <cstdint>
#include <random>
#include <string>
#include <vector>
#include "prism/card.hpp"
#include "prism/types.hpp"

// The authoritative game state and the legal-action API. The engine is
// deterministic given the same seed and the same sequence of action calls,
// which is what the tests rely on. Phase 1 = the bare loop (no keyword/effect
// execution yet); see README.md for scope.

namespace prism {

// MVP rule constants (DESIGN §2/§3/§7). Tunable defaults, not yet final.
inline constexpr int HeroStartHp = 30;
inline constexpr int HandLimit = 10;     // overdraw past this is burned unseen
inline constexpr int BoardLimit = 8;     // max creatures a player may have
inline constexpr int OpeningFirst = 4;   // first player's opening hand
inline constexpr int OpeningSecond = 5;  // second player's hand (its only comp)

using EntityId = int;  // unique per card instance for the whole game

// A card sitting in a hand or deck: just its identity plus its template.
struct CardInstance {
  EntityId id;
  const CardDef* def;
};

// A creature in play. atk/def_/hp are the live (buffable, woundable) values;
// they start from def->stats. `sick` blocks attacking on the summon turn
// (summoning sickness); `attacked` enforces one attack per turn. Both flags
// are cleared at the owner's turn start.
struct Creature {
  EntityId id;
  const CardDef* def;
  int atk;
  int def_;
  int hp;
  int maxHp;
  bool sick = true;
  bool attacked = false;
  int frozenTurns = 0;  // Blue freeze status; ticks down at the owner's turn end

  // May this creature attack right now? It must be un-sick, not have attacked,
  // not frozen, and have positive atk (0-atk creatures are pure walls).
  bool canAttack() const {
    return !sick && !attacked && frozenTurns == 0 && atk > 0;
  }
};

// Everything one player owns. Hidden information (hand/deck) is kept here; a
// per-player redacted view for the network is a later phase.
struct Player {
  int index = 0;
  int heroHp = HeroStartHp;
  int heroArmor = 0;
  int fatigue = 0;                  // damage of the NEXT empty-deck draw
  bool placedManaThisTurn = false;  // one card -> mana row per turn
  ManaPool mana;
  std::vector<CardInstance> hand;
  std::vector<CardInstance> deck;
  std::vector<Creature> board;
  std::vector<const CardDef*> auras;       // inert in Phase 1
  std::vector<const CardDef*> graveyard;
};

class Game {
 public:
  // Builds both decks from card IDs (resolved against `lib`). Nothing is dealt
  // until start(). `lib` must outlive the Game.
  Game(const CardLibrary& lib, const std::vector<std::string>& deck0,
       const std::vector<std::string>& deck1, std::uint32_t seed);

  // Shuffles, deals opening hands, and begins player 0's first turn.
  void start();

  // --- Legal actions for the player whose turn it is. Each returns false and
  // changes nothing if the action is illegal (so callers can probe safely). ---

  // Sacrifice a hand card into the mana row as a permanent crystal of `color`.
  // `color` must be one of the card's colors, or Colorless for a neutral card.
  bool placeCardToMana(int handIndex, Color color);
  // Pay a card's cost and resolve it: creatures enter the board (summoning
  // sick), auras stay in play, spells resolve and go to the graveyard. Any
  // on_play effect runs against `target` (e.g. the enemy creature to freeze);
  // pass 0 for cards that need no target.
  bool playCard(int handIndex, EntityId target = 0);
  // Attacker deals its atk to the target; the target retaliates with its def.
  bool attackCreature(EntityId attacker, EntityId target);
  // Attacker hits the enemy hero (no retaliation; heroes have no def).
  bool attackHero(EntityId attacker);
  // Pass priority to the other player and begin their turn.
  void endTurn();

  Player& player(int i) { return players_[i]; }
  const Player& player(int i) const { return players_[i]; }
  int current() const { return current_; }
  int turn() const { return turn_; }
  bool isOver() const { return over_; }
  int winner() const { return winner_; }

 private:
  void startTurn();  // refill mana, unsick creatures, start triggers, draw one
  void draw(Player& p, int n);
  void dealHeroDamage(Player& p, int amount);  // armor first, then hp; may win
  void checkDeaths();  // move creatures at <=0 hp to the graveyard
  Creature* findCreature(Player& p, EntityId id);

  // Phase 2: keyword/effect execution.
  void applyTurnStartTriggers(Player& p);  // regen heal, photosynthesis ramp
  void tickFreeze(Player& p);              // decrement freeze at the turn's end
  bool enemyHasProvoke(const Player& opp) const;  // taunt: must be attacked first
  void resolveOnPlay(const CardDef* def, Player& owner, EntityId target);
  void executeAction(const EffectDef& e, Player& owner, EntityId target);

  const CardLibrary& lib_;
  std::array<Player, 2> players_;
  int current_ = 0;
  int turn_ = 0;
  bool over_ = false;
  int winner_ = -1;
  EntityId nextId_ = 1;
  std::mt19937 rng_;  // seeded -> deterministic shuffles
};

}  // namespace prism
