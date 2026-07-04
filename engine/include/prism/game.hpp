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
inline constexpr int AuraLimit = 5;      // max auras a player may have (UI cap)
inline constexpr int OpeningFirst = 4;   // first player's opening hand
inline constexpr int OpeningSecond = 5;  // second player's hand (its only comp)

using EntityId = int;  // unique per card instance for the whole game

// Sentinel target for effects that may point at the enemy hero rather than a
// creature (selector chosen_any_target, e.g. face burn). Real ids start at 1
// and 0 means "no target", so a negative sentinel can never collide.
inline constexpr EntityId EnemyHeroTarget = -1;

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
  bool strobeUsed = false;  // Yellow strobe: spent its bonus (second) attack
  bool usedActive = false;  // spent its activated ability (germinate) this turn
  int frozenTurns = 0;      // Blue freeze: ticks down at the owner's turn end
  int blindTurns = 0;       // Yellow blind: cannot attack while > 0
  bool token = false;  // created by an ability (e.g. illusions), not a deck
  bool hauntGhost =
      false;  // a Violet haunt rebirth: this body must not haunt again
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

  // Spend one attack. Yellow strobe grants a second strike per turn: the first
  // attack only burns the strobe bonus, leaving the creature able to attack
  // once more before `attacked` finally latches.
  void markAttacked() {
    if (def->hasKeyword("strobe") && !strobeUsed)
      strobeUsed = true;
    else
      attacked = true;
  }
};

// Game events drive reactive triggers (DESIGN §8). The queue currently carries
// Died (for deathrattle-style abilities and death chains); the other types are
// declared as the growth points for future keywords. Turn-start and on_play
// effects are player-initiated and handled directly, not through this queue.
enum class EventType {
  TurnStart,
  TurnEnd,
  Summoned,
  Died,
  DamageDealt,
  SpellCast
};

struct Event {
  EventType type;
  EntityId source = 0;
  EntityId target = 0;
  int amount = 0;
  int player = -1;  // the relevant player (e.g. a dead creature's owner)
  const CardDef* card = nullptr;  // the source card, kept valid after removal
  int pos = -1;  // board slot the source occupied (for death-summon placement)
  bool token = false;  // the dead body was a token/illusion, not a real card
  bool hauntGhost = false;  // the dead body was a haunt rebirth (no re-haunt)
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
  bool summonedThisTurn = false;    // played a creature yet (Violet glimmer)
  bool lensUsedThisTurn = false;    // Blue Lens: first spell each turn focused
  bool echoUsedThisTurn =
      false;  // Penta Echo aura: first spell each turn copied
  // Per-turn use counter for limited hero passives (spectral_shift, palette,
  // ...). A hero has a single passive, so there is no contention. It resets
  // each turn; a passive fires while uses are below its own per-turn limit (1
  // today, could be 2+ for a future hero) and then increments it.
  int heroPowerUses = 0;
  int spellsCastThisTurn = 0;  // counts spells hard-cast this turn (chain_burn)
  bool mulliganDone = false;   // has this player finished its mulligan?
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
    Activate,        // id (the creature), color (which crystal to spend)
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

// Penta "sub-games" (wave 2): a pending decision that pauses play until the
// relevant player(s) submit a choice. Unlike scry (the current player sorts
// cards), these are player-vs-player prompts -- the OPPONENT, or both players,
// answer before play resumes. Deterministic: the game state plus the submitted
// choices fix the outcome; a bot or a timeout resolves via
// defaultDecisionChoice.
enum class DecisionKind { None, Ultimatum, Standoff, Auction };

struct Decision {
  DecisionKind kind = DecisionKind::None;
  int caster = -1;   // the player who cast the card
  int decider = -1;  // who submits next (Standoff: -1, both submit any order)
  int value = 0;     // the card's numeric param (Ultimatum: HP at stake)
  int bid = 0;       // Auction: the current high bid, in HP
  int highBidder = -1;       // Auction: who holds the high bid
  int choice[2] = {-1, -1};  // Standoff: each seat's Strike(0)/Defend(1)
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

  // Penta sub-games (wave 2). While a decision is pending, legalActions() is
  // empty and every normal mutator refuses -- only submitDecision advances
  // play.
  bool decisionPending() const { return decision_.kind != DecisionKind::None; }
  const Decision& decision() const { return decision_; }
  // Who submits the next choice: the decider, or -- for Standoff -- the first
  // seat that has not yet chosen (both submit, in any order); -1 if none pends.
  int decisionActor() const;
  // Submit `player`'s choice. Ultimatum: 0 = sacrifice your strongest creature,
  // 1 = lose the HP. Standoff: 0 = Strike, 1 = Defend (each seat once).
  // Auction: -1 = pass, or a value > the current bid (and < your HP) = raise.
  // Returns false and changes nothing if it is not this player's turn or the
  // choice is illegal; resolves the sub-game once it is complete.
  bool submitDecision(int player, int choice);
  // The deterministic default a bot / timeout uses for `player`.
  int defaultDecisionChoice(int player) const;

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
  bool awaken(
      int manaRowIndex, EntityId target = 0, int pos = -1,
      std::optional<std::array<int, ColorCount>> genericPay = std::nullopt);
  // Green germinate / red spark: a creature's activated ability. Spend 1
  // crystal to summon an N/N sprout (germinate) or flick N at the enemy hero
  // (spark), once per turn. `payColor` chooses which crystal to spend (the
  // player's call, mirrors placeMana); Colorless means "let the engine pick
  // greedily". False if the creature has no ability, already used it this turn,
  // you have no spare crystal (of `payColor`, if named), or germinate has no
  // board slot.
  bool activate(EntityId id, Color payColor = Color::Colorless);
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
  // A deep, independent copy (used by the bot to simulate moves). Routed
  // through serialization because raw copy would leave board creatures pointing
  // into the source's interned token defs; fromJson re-interns them correctly.
  std::unique_ptr<Game> clone() const;

  // A determinized clone for honest (non-cheating) bot search: a deep copy with
  // the OTHER seat's hidden zones (hand + deck) resampled from the library
  // pool, so `forSeat`'s search does not read the opponent's real hand. The
  // resample is belief-conditioned: cards are weighted toward the colors the
  // opponent has already revealed (board + auras + graveyard), Laplace-smoothed
  // so early game it is uniform and unseen colors stay reachable -- the search
  // imagines plausible hands, not uniform-random ones. Public state (boards,
  // crystals, graveyard, heroes, hand/deck SIZES) is preserved; only the hidden
  // identities change. Sample several and average to marginalize over the
  // unknown. `forSeat`'s own zones are left intact (its deck is reshuffled --
  // it knows the contents but not the draw order).
  std::unique_ptr<Game> determinize(int forSeat, std::mt19937& rng) const;

  Player& player(int i) { return players_[i]; }
  const Player& player(int i) const { return players_[i]; }
  int current() const { return current_; }
  int turn() const { return turn_; }
  bool isOver() const { return over_; }
  int winner() const { return winner_; }

 private:
  void startTurn();  // refill mana, unsick creatures, start triggers, draw one
  void draw(Player& p, int n);
  // armor first, then hp; may win. fromOpponent=false marks self-inflicted
  // damage (fatigue) so Prism Mirror does not reflect it.
  void dealHeroDamage(Player& p, int amount, bool fromOpponent = true);
  void checkDeaths();  // move creatures at <=0 hp to the graveyard
  Creature* findCreature(Player& p, EntityId id);
  const Creature* findCreature(const Player& p, EntityId id) const;
  // Resolve a targeted effect's creature based on its selector side:
  // chosen_friendly_minion -> owner, chosen_any_minion -> either,
  // anything else (chosen_enemy_minion) -> the opponent.
  Creature* findSelected(const std::string& selector, Player& owner,
                         EntityId target);

  // Penta Rainbow Colossus (keyword `cleave`): when `src` attacks, its blow
  // refracts across the enemy line -- N damage to every other enemy creature
  // (`skip` is the primary combat target, 0 when it struck the hero).
  void dealCleave(const Creature& src, Player& opp, EntityId skip);

  // Violet refract: a hit aimed at `hit` (an enemy creature) bends onto a
  // random other non-stealthed creature on `opp`'s board; returns the new
  // target, or `hit` unchanged when there is no other creature to bend onto.
  Creature* refractTarget(Player& opp, Creature* hit);

  // Resolve a selector to its full target list. Single-pick selectors yield 0
  // or 1 creature; the area selectors yield many: "all_enemies" = the
  // opponent's board, "all_creatures" = both boards. This is what makes AoE a
  // selector, not a separate action -- so blind/damage/freeze each have one
  // implementation that scales from one target to a board wipe.
  std::vector<Creature*> selectTargets(const std::string& selector,
                                       Player& owner, EntityId target);

  // Phase 2: keyword/effect execution.
  void applyTurnStartTriggers(Player& p);  // regen heal, growth, photosynthesis
  void processDelayed(Player& p);    // fire Blue delay effects that are due
  void startScry(Player& p, int n);  // peek the top n cards, await a choice
  void tickStatuses(Player& p);      // decrement freeze/blind at the turn's end
  bool enemyHasProvoke(
      const Player& opp) const;  // taunt: must be attacked first
  bool hasAura(const Player& p,
               const std::string& id) const;  // already controls this aura?
  // Blue Lens: this player has a Lens source in play (its first spell each turn
  // resolves with +1 to its effect values).
  bool hasLens(const Player& p) const;
  // Blue Brittle: a frozen creature shatters (dies) on any damage when the
  // OPPONENT of its owner has a Brittle source in play. True if `target` is
  // frozen and should be shattered by incoming damage.
  bool brittleShatters(const Creature& target) const;
  void resolveOnPlay(const CardDef* def, Player& owner, EntityId target);
  void executeAction(const EffectDef& e, Player& owner, EntityId target,
                     const CardDef* src = nullptr);
  // Fire one card's data-driven `trigger` effects (owner controls it). The
  // reacting card is not itself the chosen target, so its effects use
  // auto-resolving selectors (enemy_hero, all_friendly, ...).
  void fireCardTrigger(const CardDef* def, Player& owner,
                       const std::string& trigger);
  // Same, for every creature on `p`'s board -- the board-scan triggers
  // (on_spell_cast, start_of_turn).
  void fireBoardTrigger(Player& p, const std::string& trigger);
  // Penta sub-games: open a decision and (once submitted) resolve each kind.
  void startDecision(DecisionKind k, int caster, int value);
  // Run a deferred Echo copy of a sub-game spell now that its decision cleared.
  void fireDeferredEcho();
  void resolveUltimatum(int choice);
  void resolveStandoff();
  void resolveAuction(int winner);
  // Index of the highest-attack creature on p's board (ties: first), or -1.
  int highestAtkCreature(const Player& p) const;
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
  // A card's cost as actually paid: base cost plus the Blue haze surcharge that
  // the opponent's auras add to your spells.
  Cost effectiveCost(const Player& p, const CardDef* def) const;
  // Does this player have Blue birefringence (a creature or aura that forks
  // their targeted effects onto a second target)?
  bool ownerHasBirefringence(const Player& p) const;
  // The pool that remains after awakening `mc` from p's mana row (its own
  // crystal pays 1 of the cost in its color, decoy may zero it), or nullopt if
  // unaffordable. awaken() commits the returned pool; legalActions just checks.
  std::optional<ManaPool> awakenCost(const Player& p, const ManaCard& mc,
                                     std::optional<std::array<int, ColorCount>>
                                         genericPay = std::nullopt) const;
  // The set of legal `target` values for the card's on_play effects: {0} plus
  // every creature id that playTargetLegal accepts (0 stays only when no
  // required target blocks it). Used to enumerate play/awaken targets.
  std::vector<EntityId> legalTargets(const CardDef* def,
                                     const Player& owner) const;
  // legalActions() enumerates each action kind into `out` through these
  // per-kind appenders, called in the order the mutators apply so the move list
  // stays deterministic; they keep the enumerator a short, readable dispatch.
  void appendManaActions(std::vector<Action>& out, const Player& p) const;
  void appendPlayActions(std::vector<Action>& out, const Player& p) const;
  void appendAwakenActions(std::vector<Action>& out, const Player& p) const;
  void appendActivateActions(std::vector<Action>& out, const Player& p) const;
  void appendAttackActions(std::vector<Action>& out, const Player& p,
                           const Player& opp) const;

  // Combat / stat helpers.
  Creature makeCreature(EntityId id, const CardDef* def, bool sick, bool token,
                        int hpOverride, bool hauntGhost = false);
  // Yellow ward: if `t` is warded, spend the ward and return true (the harmful
  // targeted effect is absorbed); otherwise return false.
  bool absorbWard(Creature& t);
  // Apply `amount` damage to a creature, honouring shield (absorbs the
  // instance) and lingering (the wound becomes unhealable). Returns damage
  // dealt to hp.
  int damageCreature(Creature& target, int amount, const Creature* source,
                     bool pierceShield = false);
  // capped by maxHp - unhealable; a heal that raises hp fires on_heal on
  // `owner`
  void healCreature(Creature& c, int amount, Player& owner);
  // clamp a hero back up to full; a heal that raises hp fires on_heal
  void healHero(Player& p, int amount);
  // Reaction to any heal on `healed`'s side: Reflux keyword + data on_heal
  // effects. Re-entrancy is guarded so a reaction's own healing cannot re-fire.
  void onHealed(Player& healed);
  // Move up to n random creature cards from p's graveyard back to hand (Green
  // Renewal / the reclaim action), respecting the hand cap; overflow stays.
  void reclaimFromGrave(Player& p, int n);
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
                       int at = -1, bool hauntGhost = false);
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
  bool mirrorReflecting_ = false;  // guards Prism Mirror's reflect from looping
  bool healReacting_ = false;      // guards on_heal (Reflux) from re-entering
  bool mulliganPhase_ = false;     // true between dealing and the first turn
  int scryPlayer_ = -1;            // who is mid-scry (-1 = nobody)
  std::vector<CardInstance> scryPeek_;  // top cards peeked, awaiting a choice
  Decision decision_;                   // pending penta sub-game (wave 2)
  // Penta Echo doubling a sub-game spell: the copy cannot resolve while the
  // first cast's decision is pending, so it waits here and fires when that
  // decision clears (the opponent then faces the second sub-game in turn).
  struct EchoDeferred {
    const CardDef* def = nullptr;
    int owner = -1;
    EntityId target = 0;
  } echoDeferred_;
  int winner_ = -1;
  EntityId nextId_ = 1;
  std::mt19937 rng_;               // seeded -> deterministic shuffles
  std::deque<Event> events_;       // reactive events awaiting processing
  std::deque<CardDef> tokenDefs_;  // stable storage for synthesized token cards
};

}  // namespace prism
