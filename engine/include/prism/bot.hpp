#pragma once

#include <random>
#include <string>

// A server-side opponent for the single-player "training" match. The bot reads
// the authoritative Game (it sits on a seat with full information -- there is
// no separate redacted view) and returns its next move as an action-JSON string
// in the exact shape applyAction parses, so it speaks the same protocol as a
// real client. Call botNextAction repeatedly, applying each move, until it
// returns "" (the turn passed back to the human, or the game is over). One
// greedy policy over Game::legalActions() -- plays cheaply, trades up, races
// when ahead.

namespace prism {

class Game;

// The bot's next action as protocol JSON, or "" if it is not the bot's turn and
// it has nothing pending. Handles mulligan (keeps all) and scry (keeps the peek
// order) itself, since those are not in legalActions().
std::string botNextAction(const Game& g, int seat, std::mt19937& rng);

}  // namespace prism
