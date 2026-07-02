#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "prism/game.hpp"

// The network protocol layer: turning game state into a per-player JSON view
// (with hidden information redacted) and turning a client's JSON action back
// into an engine call. Pure logic, no sockets -- the server (server/) wraps
// this over WebSocket. Both functions are covered by the engine tests.

namespace prism {

// Serialize the game from player `you`'s perspective. Public info (both boards,
// heroes, crystal colors/counts, graveyards) is always included; hidden info is
// redacted: the opponent's hand is only a count, and mana-row card identities
// are shown only for your own awaken cards (floodlight will reveal enemy ones).
// `eventJson`, if non-empty, is spliced in as the view's `event` field: the
// public action that just produced this state (see publicEventJson), so the
// client can play the opponent's turn out step by step. Pass "" for a plain
// state sync (reconnect, rejected action).
std::string viewJson(const Game& g, int you, const std::string& eventJson = "");

// The PUBLIC annotation of a client action, as a JSON object string, or "" for
// actions that must stay hidden (mulligan / scryResolve / decision) or are
// unknown. Computed against the CURRENT state, so it MUST be called BEFORE
// applyAction (a play/awaken resolves handIndex/manaRowIndex -> the card id
// while the card is still in hand / the mana row). Shape:
//   {seat, action, card?, target?, attacker?, id?, color?}
// `card` is included for play/awaken (this is what drives the card reveal);
// placeMana carries only its `color` (the banked card stays face-down).
std::string publicEventJson(const Game& g, int seat,
                            const std::string& actionJson);

// The wire JSON for a single engine Action (the shape applyAction parses back).
std::string actionJson(const Action& a);

// Every legal move for the current player as a JSON array of action objects
// (each accepted by applyAction). The discrete-move surface for bots, the admin
// panel, and the fuzz harness; empty in over / mulligan / scry phases. See
// Game::legalActions for the enumerated surface and its boundaries.
std::string legalActionsJson(const Game& g);

// A replay is everything needed to reproduce a game bit-for-bit: the setup
// (seed, both decks, both hero ids) plus the ordered list of accepted actions
// (each {actor, action}). The engine is deterministic, so re-running the setup
// and applying the actions in order yields the identical final state. This is
// the format the server logs per room (for reconnect / replays) and the fuzz
// harness dumps on a failure. `actions` is a list of (actor, actionJsonString).
std::string makeReplay(std::uint32_t seed,
                       const std::vector<std::string>& deck0,
                       const std::vector<std::string>& deck1,
                       const std::string& hero0, const std::string& hero1,
                       const std::vector<std::pair<int, std::string>>& actions);

// Rebuild the game described by a replay JSON: construct it, start(), and apply
// every logged action in order. Returns the final Game (unique_ptr; the object
// never moves -- see fromJson). `applied`, if non-null, receives the count of
// actions that applyAction accepted (== actions.size() for an intact replay).
std::unique_ptr<Game> runReplay(const CardLibrary& lib,
                                const std::string& replayJson,
                                int* applied = nullptr);

// Apply a client action (JSON) on behalf of `actor`. Returns false if it is not
// the actor's turn, or the action is malformed or illegal. Action shapes:
//   {"action":"mulligan","indices":[0,2]}
//       // replace those opening-hand cards; [] keeps the hand. Either player,
//       // once, before the first turn (see Game::mulligan).
//   {"action":"placeMana","handIndex":0,"color":"red"}
//   {"action":"play","handIndex":2,"target":7,"pos":3}
//       // target optional (0 = none); pos optional (board slot, -1 = append)
//   {"action":"awaken","manaRowIndex":0,"target":0,"pos":-1}
//   {"action":"activate","id":5}   // germinate: spend 1 crystal -> N/N sprout
//   {"action":"scryResolve","bottom":[0,2]}  // send peeked cards to the bottom
//   {"action":"attackCreature","attacker":5,"target":9}
//   {"action":"attackHero","attacker":5}
//   {"action":"endTurn"}
bool applyAction(Game& g, int actor, const std::string& actionJson);

}  // namespace prism
