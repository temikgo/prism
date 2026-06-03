#pragma once
#include <array>
#include <cstdint>
#include <deque>
#include <random>
#include <string>
#include <vector>

#include "prism/card.hpp"
#include "prism/types.hpp"

// The authoritative game state and the legal-action API. The engine is
// deterministic given the same seed and the same sequence of action calls,
// which is what the tests rely on. See README.md for the implemented keyword
// set and what is still deferred.

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

// A card sacrificed into the mana row. It became a crystal of `color`, but its
// identity is kept face-down so Violet `awaken` can later wake it from there.
struct ManaCard {
  CardInstance card;
  Color color;
};

// A creature in play. atk/hp are the live (buffable, woundable) values; they
// start from def->stats. `sick` blocks attacking on the summon turn (summoning
// sickness); `attacked` enforces one attack per turn. Both flags are cleared at
// the owner's turn start. The status fields below back the colored keywords.
struct Creature {
  EntityId id;
  const CardDef* def;
  int atk;      // effective attack = baseAtk + live continuous modifiers
  int baseAtk;  // printed + permanent buffs (growth/compost); auras add on top
  int hp;
  int maxHp;
  bool sick = true;
  bool attacked = false;
  bool usedActive = false;  // spent its activated ability (germinate) this turn
  int frozenTurns = 0;      // Blue freeze: ticks down at the owner's turn end
  int blindTurns = 0;       // Yellow blind: cannot attack while > 0
  bool token = false;   // created by an ability (e.g. illusions), not a deck
  bool shield = false;  // Yellow shield: absorbs the next instance of damage
  bool warded = false;  // Yellow ward: absorbs the next harmful targeted effect
  bool stealthed = false;  // Violet stealth: untargetable until it attacks
  int unhealable = 0;      // Red lingering wounds that healing cannot restore

  // May this creature attack right now? It must be un-sick, not have attacked,
  // not be frozen or blinded, and have positive atk (0-atk creatures are
  // walls).
  bool canAttack() const {
    return !sick && !attacked && frozenTurns == 0 && blindTurns == 0 && atk > 0;
  }
};

// Game events drive reactive triggers (DESIGN §8). The queue currently carries
// Died (for deathrattle-style abilities and death chains); the other types are
// declared as the growth points for future keywords. Turn-start and on_play
// effects are player-initiated and handled directly, not through this queue.
enum class EventType { TurnStart, TurnEnd, Summoned, Died, DamageDealt };

struct Event {
  EventType type;
  EntityId source = 0;
  EntityId target = 0;
  int amount = 0;
  int player = -1;  // the relevant player (e.g. a dead creature's owner)
  const CardDef* card = nullptr;  // the source card, kept valid after removal
};

// Everything one player owns. Hidden information (hand/deck) is kept here; a
// per-player redacted view for the network is a later phase.
struct Player {
  int index = 0;
  int heroHp = HeroStartHp;
  int heroArmor = 0;
  int fatigue = 0;                  // damage of the NEXT empty-deck draw
  bool placedManaThisTurn = false;  // one card -> mana row per turn
  bool mulliganDone = false;        // has this player finished its mulligan?
  ManaPool mana;
  std::vector<CardInstance> hand;
  std::vector<CardInstance> deck;
  std::vector<ManaCard> manaRow;  // sacrificed cards = crystals (face-down)
  std::vector<Creature> board;
  std::vector<const CardDef*> auras;
  std::vector<const CardDef*> graveyard;
};

class Game {
 public:
  // Builds both decks from card IDs (resolved against `lib`). Nothing is dealt
  // until start(). `lib` must outlive the Game.
  Game(const CardLibrary& lib, const std::vector<std::string>& deck0,
       const std::vector<std::string>& deck1, std::uint32_t seed);

  // Shuffles and deals opening hands, then enters the mulligan phase. Player
  // 0's first turn begins once both players have finished their mulligan.
  void start();

  // Mulligan: replace the chosen opening-hand cards (by index) -- they go back
  // into the deck, it is reshuffled, and the same number is redrawn. Pass an
  // empty list to keep the hand. Either player may call it, once. When both are
  // done, play begins. Returns false (no change) if not in the mulligan phase,
  // already done, or an index is out of range.
  bool mulligan(int player, const std::vector<int>& indices);
  bool inMulligan() const { return mulliganPhase_; }
  bool mulliganDone(int player) const { return players_[player].mulliganDone; }

  // --- Legal actions for the player whose turn it is. Each returns false and
  // changes nothing if the action is illegal (so callers can probe safely). ---

  // Sacrifice a hand card into the mana row as a permanent crystal of `color`.
  // `color` must be one of the card's colors, or Colorless for a neutral card.
  bool placeCardToMana(int handIndex, Color color);
  // Pay a card's cost and resolve it: creatures enter the board (summoning
  // sick), auras stay in play, spells resolve and go to the graveyard. Any
  // on_play effect runs against `target` (e.g. the enemy creature to freeze);
  // pass 0 for cards that need no target.
  // `pos` is where a creature is inserted on the board (0..board size); -1 (the
  // default) appends to the right.
  bool playCard(int handIndex, EntityId target = 0, int pos = -1);
  // Violet awaken: play a card straight from the mana row. The banked crystal
  // pays 1 of the cost in its own color (or 1 generic if that color isn't
  // required); the remainder is paid from your other available crystals, and
  // that crystal/slot is consumed. Only cards carrying the `awaken` keyword
  // qualify.
  bool awaken(int manaRowIndex, EntityId target = 0, int pos = -1);
  // Green germinate: a creature's activated ability. Spend 1 crystal (any
  // color) to summon an N/N sprout, once per turn. False if the creature has no
  // germinate, already used it this turn, you have no spare crystal, or the
  // board is full.
  bool activate(EntityId id);
  // Both creatures deal their atk to each other simultaneously.
  bool attackCreature(EntityId attacker, EntityId target);
  // Attacker hits the enemy hero (no retaliation; heroes do not fight back).
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
  // Resolve a targeted effect's creature based on its selector side:
  // chosen_friendly_minion -> owner, chosen_any_minion -> either,
  // anything else (chosen_enemy_minion) -> the opponent.
  Creature* findSelected(const std::string& selector, Player& owner,
                         EntityId target);

  // Phase 2: keyword/effect execution.
  void applyTurnStartTriggers(Player& p);  // regen heal, growth, photosynthesis
  void tickStatuses(Player& p);  // decrement freeze/blind at the turn's end
  bool enemyHasProvoke(
      const Player& opp) const;  // taunt: must be attacked first
  bool hasAura(const Player& p,
               const std::string& id) const;  // already controls this aura?
  void resolveOnPlay(const CardDef* def, Player& owner, EntityId target);
  void executeAction(const EffectDef& e, Player& owner, EntityId target);
  // True if `target` is a legal target for the card's on_play effects (a
  // chosen_enemy_minion must exist and not be stealthed).
  bool playTargetLegal(const CardDef* def, Player& owner, EntityId target);
  // Put an already-paid-for card into play and run its effects. Shared by
  // playCard (from hand) and awaken (from the mana row).
  void playResolved(Player& p, const CardInstance& ci, EntityId target,
                    int pos);

  // Combat / stat helpers.
  Creature makeCreature(EntityId id, const CardDef* def, bool sick, bool token,
                        int hpOverride);
  // Yellow ward: if `t` is warded, spend the ward and return true (the harmful
  // targeted effect is absorbed); otherwise return false.
  bool absorbWard(Creature& t);
  // Apply `amount` damage to a creature, honouring shield (absorbs the
  // instance) and lingering (the wound becomes unhealable). Returns damage
  // dealt to hp.
  int damageCreature(Creature& target, int amount, const Creature* source);
  void healCreature(Creature& c, int amount);  // capped by maxHp - unhealable
  void buffStats(Creature& c, int n);  // permanent "+n/+n" (base atk +n)
  // Recompute every creature's effective atk from baseAtk plus the live
  // continuous layer: undergrowth (+N per other ally), resonance (+N per
  // crystal), and enemy chill auras (-N). Run after any board/crystal/aura
  // change. Only atk is continuous, so this never causes deaths.
  void recomputeContinuous();
  void bounceCreature(EntityId id);  // return a creature to its hand
  void makeMirage(Player& owner, EntityId target);  // illusion copy of a target

  // Tokens, illusions, and the death-event queue.
  EntityId summonToken(Player& p, const CardDef* def, bool sick,
                       int hpOverride);
  const CardDef* internToken(const std::string& id,
                             Stats s);  // owns a token def
  void emit(const Event& e) { events_.push_back(e); }
  void processEvents();          // drain the queue, running reactions
  void reactTo(const Event& e);  // built-in reactions (Died -> spores, ...)

  const CardLibrary& lib_;
  std::array<Player, 2> players_;
  int current_ = 0;
  int turn_ = 0;
  bool over_ = false;
  bool mulliganPhase_ = false;  // true between dealing and the first turn
  int winner_ = -1;
  EntityId nextId_ = 1;
  std::mt19937 rng_;               // seeded -> deterministic shuffles
  std::deque<Event> events_;       // reactive events awaiting processing
  std::deque<CardDef> tokenDefs_;  // stable storage for synthesized token cards
};

}  // namespace prism
