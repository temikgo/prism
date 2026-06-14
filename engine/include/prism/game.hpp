#pragma once
#include <array>
#include <cstdint>
#include <deque>
#include <memory>
#include <optional>
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
// `age` counts the owner's turns it has waited (for Violet `decoy`).
struct ManaCard {
  CardInstance card;
  Color color;
  int age = 0;
};

// An effect waiting to resolve at the start of the owner's turn (Blue `delay`).
// turnsLeft ticks down each of the owner's turns; it fires at zero.
struct DelayedEffect {
  EffectDef effect;
  int turnsLeft;
  EntityId target = 0;  // target chosen at play time (0 = none), kept so a
                        // targeted delayed effect still hits the right creature
                        // when it resolves (fizzles if it has since gone)
  const CardDef* src = nullptr;  // source card, for lingering on delayed damage
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
  int baseMaxHp;  // max hp WITHOUT the continuous undergrowth layer (recompute
                  // base)
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
  int pos = -1;  // board slot the source occupied (for death-summon placement)
  bool token = false;  // the dead body was a token/illusion, not a real card
};

// Everything one player owns. Hidden information (hand/deck) is kept here; a
// per-player redacted view for the network is a later phase.
struct Player {
  int index = 0;
  int heroHp = HeroStartHp;
  int heroArmor = 0;
  const CardDef* hero = nullptr;    // the chosen hero (its passive = a keyword)
  int fatigue = 0;                  // damage of the NEXT empty-deck draw
  bool placedManaThisTurn = false;  // one card -> mana row per turn
  // Per-turn use counter for limited hero passives (spectral_shift, palette,
  // ...). A hero has a single passive, so there is no contention. It resets
  // each turn; a passive fires while uses are below its own per-turn limit (1
  // today, could be 2+ for a future hero) and then increments it.
  int heroPowerUses = 0;
  bool mulliganDone = false;  // has this player finished its mulligan?
  ManaPool mana;
  std::vector<CardInstance> hand;
  std::vector<CardInstance> deck;
  std::vector<ManaCard> manaRow;  // sacrificed cards = crystals (face-down)
  std::vector<Creature> board;
  std::vector<const CardDef*> auras;
  // Spent real cards: played spells, dead non-token creatures, dispelled auras,
  // bounced/overdrawn cards that had nowhere to go. NOTE: currently purely
  // informational -- only its size is shown to the client (the deck/graveyard
  // pile). No keyword/effect reads the graveyard yet (no reanimation,
  // "cards-in-graveyard-matter", etc.); it is a hook for future mechanics.
  std::vector<const CardDef*> graveyard;
  std::vector<DelayedEffect>
      pending;  // Blue delay: effects awaiting their turn
};

// One discrete legal move in the active play phase, as enumerated by
// Game::legalActions and consumed by applyAction (via the protocol layer, which
// maps it to/from the wire JSON). This is the engine-side "move" type -- no
// JSON dependency -- so a bot can evaluate moves structurally. Only the fields
// used by a given `type` are meaningful (see protocol.cpp actionJson for the
// mapping).
struct Action {
  enum class Type {
    EndTurn,         // -
    PlaceMana,       // handIndex, color
    Play,            // handIndex, target (0 = none)
    Awaken,          // manaRowIndex, target (0 = none)
    Activate,        // id (the germinating creature)
    AttackCreature,  // attacker, target (the enemy creature)
    AttackHero,      // attacker
  };
  Type type = Type::EndTurn;
  int handIndex = -1;
  Color color = Color::Colorless;
  int manaRowIndex = -1;
  EntityId target = 0;  // play/awaken effect target, or attack defender
  int pos = -1;         // play/awaken board slot (-1 = append); not enumerated
  EntityId attacker = 0;  // attacking creature
  EntityId id = 0;        // activate: the creature
};

class Game {
 public:
  // Builds both decks from card IDs (resolved against `lib`). Nothing is dealt
  // until start(). `lib` must outlive the Game. `hero0`/`hero1` are the
  // players' chosen hero IDs (resolved against `lib`); empty/unknown means no
  // hero (the game just runs without a passive). Picking the heroes is the
  // caller's job (the server randomizes them), so the engine stays
  // deterministic.
  Game(const CardLibrary& lib, const std::vector<std::string>& deck0,
       const std::vector<std::string>& deck1, std::uint32_t seed,
       const std::string& hero0 = "", const std::string& hero1 = "");

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

  // Blue scry: after a scry effect, the top cards are peeked and held here
  // until the player chooses (by index) which to send to the bottom; the rest
  // return to the top in order. No other action is legal until it is resolved.
  bool resolveScry(int player, const std::vector<int>& toBottom);
  bool inScry() const { return scryPlayer_ >= 0; }
  int scryPlayer() const { return scryPlayer_; }
  const std::vector<CardInstance>& scryPeek() const { return scryPeek_; }

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
  bool playCard(
      int handIndex, EntityId target = 0, int pos = -1,
      std::optional<std::array<int, ColorCount>> genericPay = std::nullopt);
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

  // Every discrete legal move for the current player in the active play phase.
  // Empty when the game is over or a parameterized phase is pending (mulligan /
  // scry) -- those choices are subsets, not discrete moves, and are driven via
  // mulligan() / resolveScry(). Mirrors the legality checks in playCard /
  // awaken / activate / attack*; each returned Action, fed back through
  // applyAction, is accepted. `pos` (board slot) and the play genericPay
  // breakdown are free parameters, not enumerated here (append / greedy payment
  // are always legal).
  std::vector<Action> legalActions() const;

  // Full-state serialization (engine/src/serialize.cpp). toJson captures every
  // field needed to resume the exact game -- both players, the phase flags, the
  // RNG state (so future shuffles match), and any interned token defs
  // (germinate sprouts, which are not library cards). fromJson rebuilds an
  // independent Game against the same library; it is returned by unique_ptr so
  // the object never moves (board creatures hold raw pointers into its
  // interned-token storage). The transient event queue is empty at action
  // boundaries and is not stored.
  std::string toJson() const;
  static std::unique_ptr<Game> fromJson(const CardLibrary& lib,
                                        const std::string& json);

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
  const Creature* findCreature(const Player& p, EntityId id) const;
  // Resolve a targeted effect's creature based on its selector side:
  // chosen_friendly_minion -> owner, chosen_any_minion -> either,
  // anything else (chosen_enemy_minion) -> the opponent.
  Creature* findSelected(const std::string& selector, Player& owner,
                         EntityId target);

  // Phase 2: keyword/effect execution.
  void applyTurnStartTriggers(Player& p);  // regen heal, growth, photosynthesis
  void processDelayed(Player& p);    // fire Blue delay effects that are due
  void startScry(Player& p, int n);  // peek the top n cards, await a choice
  void tickStatuses(Player& p);      // decrement freeze/blind at the turn's end
  bool enemyHasProvoke(
      const Player& opp) const;  // taunt: must be attacked first
  bool hasAura(const Player& p,
               const std::string& id) const;  // already controls this aura?
  void resolveOnPlay(const CardDef* def, Player& owner, EntityId target);
  void executeAction(const EffectDef& e, Player& owner, EntityId target,
                     const CardDef* src = nullptr);
  void applyLingering(Creature& t, int dealt, const CardDef* src);
  // True if `target` is a legal target for the card's on_play effects (a
  // chosen_enemy_minion must exist and not be stealthed). Const: a pure check,
  // shared by playCard / awaken (committing) and legalActions (enumerating).
  bool playTargetLegal(const CardDef* def, const Player& owner,
                       EntityId target) const;
  // Put an already-paid-for card into play and run its effects. Shared by
  // playCard (from hand) and awaken (from the mana row).
  void playResolved(Player& p, const CardInstance& ci, EntityId target,
                    int pos);

  // Prism `spectral_shift`: if `cost` is unpayable normally but becomes payable
  // by retuning ONE available crystal to a spectrum-adjacent color (R-Y-G-B-V),
  // return the swapped pool (canPay is then true). Empty otherwise. The caller
  // pays from it and counts a hero-power use.
  std::optional<ManaPool> shiftedPool(const ManaPool& pool,
                                      const Cost& cost) const;

  // Shared legality/cost helpers (const), used by both the committing mutators
  // and legalActions so the two never diverge.
  // Can `p` pay `cost` -- plainly, or via the Prism hero's once-per-turn shift?
  bool affordableToPlay(const Player& p, const Cost& cost) const;
  // The pool that remains after awakening `mc` from p's mana row (its own
  // crystal pays 1 of the cost in its color, decoy may zero it), or nullopt if
  // unaffordable. awaken() commits the returned pool; legalActions just checks.
  std::optional<ManaPool> awakenCost(const Player& p, const ManaCard& mc) const;
  // The set of legal `target` values for the card's on_play effects: {0} plus
  // every creature id that playTargetLegal accepts (0 stays only when no
  // required target blocks it). Used to enumerate play/awaken targets.
  std::vector<EntityId> legalTargets(const CardDef* def,
                                     const Player& owner) const;

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
  // `at` is the board slot to insert at; -1 appends to the right.
  EntityId summonToken(Player& p, const CardDef* def, bool sick, int hpOverride,
                       int at = -1);
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
  int scryPlayer_ = -1;         // who is mid-scry (-1 = nobody)
  std::vector<CardInstance> scryPeek_;  // top cards peeked, awaiting a choice
  int winner_ = -1;
  EntityId nextId_ = 1;
  std::mt19937 rng_;               // seeded -> deterministic shuffles
  std::deque<Event> events_;       // reactive events awaiting processing
  std::deque<CardDef> tokenDefs_;  // stable storage for synthesized token cards
};

}  // namespace prism
