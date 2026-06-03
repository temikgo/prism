#pragma once
#include <string>

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
std::string viewJson(const Game& g, int you);

// Apply a client action (JSON) on behalf of `actor`. Returns false if it is not
// the actor's turn, or the action is malformed or illegal. Action shapes:
//   {"action":"placeMana","handIndex":0,"color":"red"}
//   {"action":"play","handIndex":2,"target":7,"pos":3}
//       // target optional (0 = none); pos optional (board slot, -1 = append)
//   {"action":"awaken","manaRowIndex":0,"target":0,"pos":-1}
//   {"action":"attackCreature","attacker":5,"target":9}
//   {"action":"attackHero","attacker":5}
//   {"action":"endTurn"}
bool applyAction(Game& g, int actor, const std::string& actionJson);

}  // namespace prism
