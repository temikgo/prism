#include "prism/deck.hpp"

#include <unordered_map>

namespace prism {

DeckCheck validateDeck(const CardLibrary& lib,
                       const std::vector<std::string>& ids) {
  if (static_cast<int>(ids.size()) != kDeckSize)
    return {false, "size",
            std::to_string(ids.size()) + "/" + std::to_string(kDeckSize)};
  std::unordered_map<std::string, int> counts;
  for (const auto& id : ids) {
    const CardDef* def = lib.find(id);
    if (!def) return {false, "unknown", id};
    if (def->type == CardType::Hero) return {false, "hero", id};
    if (++counts[id] > kMaxCopies) return {false, "copies", id};
  }
  return {true, "", ""};
}

}  // namespace prism
