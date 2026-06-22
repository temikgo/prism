#pragma once

#include <random>
#include <string>

// A server-side opponent for the single-player "training" match. The bot reads
// the authoritative Game (it sits on a seat with full information -- there is
// no separate redacted view) and returns its next move as an action-JSON string
// in the exact shape applyAction parses, so it speaks the same protocol as a
// real client. Call botNextAction repeatedly, applying each move, until it
// returns "" (the turn passed back to the human, or the game is over).
//
// Policy: a 1-ply search. For each candidate move the bot clones the game (see
// Game::clone), simulates it, finishes the turn with a fast greedy reflex,
// lets the opponent take a greedy reply, then scores the resulting position;
// it picks the move leading to the best position. The greedy reflex (develop,
// ramp mana-first, trade up, aim removal well, swing on lethal, race when
// ahead) is the rollout estimator; the search layer fixes overextension and
// the second-player artifact greedy alone showed.

namespace prism {

class Game;

// The bot's next action as protocol JSON, or "" if it is not the bot's turn and
// it has nothing pending. Handles mulligan (keeps all) and scry (keeps the peek
// order) itself, since those are not in legalActions().
std::string botNextAction(const Game& g, int seat, std::mt19937& rng);

// The pure greedy reflex (no search): the bot's old brain, exposed as a weaker
// reference policy for head-to-head strength tests (search should beat it).
std::string botGreedyAction(const Game& g, int seat, std::mt19937& rng);

}  // namespace prism
