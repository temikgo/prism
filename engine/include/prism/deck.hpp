#pragma once
#include <string>
#include <vector>

#include "prism/card.hpp"

namespace prism {

// The single deck-legality rule, owned by the engine and enforced by the server
// (the client UI mirrors it for live feedback at build time, but the server is
// the authority -- a broken or hostile client cannot start a match with an
// illegal deck). A legal deck is exactly kDeckSize cards, each appearing at
// most kMaxCopies times, every id a real non-hero card. Decks are larger than
// the usual 30 because any card can be spent as mana (DESIGN §7).
inline constexpr int kDeckSize = 40;
inline constexpr int kMaxCopies = 2;

struct DeckCheck {
  bool ok = false;
  std::string reason;  // "" when ok, else: size | copies | unknown | hero
  std::string detail;  // count for size, offending id otherwise
};

// Validate a deck (list of card ids) against the rule. Returns the first
// violation found, or {true,"",""} if legal.
DeckCheck validateDeck(const CardLibrary& lib,
                       const std::vector<std::string>& ids);

}  // namespace prism
