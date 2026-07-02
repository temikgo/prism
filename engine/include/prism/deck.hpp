#pragma once
#include <random>
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

// Draft a colour-coherent deck: pick a colour count (weighted toward 2-3,
// capped at maxColors), choose that many colours, then fill `deckSize` slots
// from cards whose every colour is in the chosen set (colourless always
// qualifies), each at most `maxCopies` times. Deterministic in `rng`. The bot
// drafts with maxColors=3 -- coherent and castable, and it excludes 5-colour
// pentas (they need all five colours allowed). Self-play uses maxColors=5 to
// keep sampling rainbow/penta cards.
// `forceColors` (>0) overrides the weighted count and drafts exactly that many
// colours -- lets a balance run force a rainbow (5-colour) meta so otherwise
// rarely-cast multicolour/penta cards actually resolve and can be measured.
std::vector<std::string> draftDeck(const std::vector<const CardDef*>& nonHero,
                                   int deckSize, int maxCopies,
                                   std::mt19937& rng, int maxColors = 5,
                                   int forceColors = 0);

}  // namespace prism
