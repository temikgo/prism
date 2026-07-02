#include "prism/deck.hpp"

#include <algorithm>
#include <array>
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

std::vector<std::string> draftDeck(const std::vector<const CardDef*>& nonHero,
                                   int deckSize, int maxCopies,
                                   std::mt19937& rng, int maxColors,
                                   int forceColors) {
  // Colour count picked like a human deckbuilder: mostly mono/two-colour, with
  // a thin tail to greedy 4-5 colour piles. mono 30% / 2-colour 35% / 3 20% / 4
  // 5% / 5 10%.
  static const int kCounts[] = {1, 2, 3, 4, 5};
  static const double kCum[] = {0.30, 0.65, 0.85, 0.90, 1.00};
  std::uniform_real_distribution<double> u(0.0, 1.0);
  const double r = u(rng);
  int k = 5;
  for (int i = 0; i < 5; ++i)
    if (r <= kCum[i]) {
      k = kCounts[i];
      break;
    }
  if (k > maxColors) k = maxColors;
  if (k < 1) k = 1;
  if (forceColors > 0) k = forceColors > 5 ? 5 : forceColors;
  std::array<Color, 5> colors = {Color::Red, Color::Yellow, Color::Green,
                                 Color::Blue, Color::Violet};
  std::shuffle(colors.begin(), colors.end(), rng);
  std::array<bool, ColorCount> allowed{};
  for (int i = 0; i < k; ++i) allowed[static_cast<int>(colors[i])] = true;

  std::vector<std::string> bag;
  for (const CardDef* d : nonHero) {
    bool ok = true;
    for (Color c : d->colors)
      if (!allowed[static_cast<int>(c)]) {
        ok = false;
        break;
      }
    if (ok)
      for (int i = 0; i < maxCopies; ++i) bag.push_back(d->id);
  }
  std::shuffle(bag.begin(), bag.end(), rng);
  if (static_cast<int>(bag.size()) > deckSize) bag.resize(deckSize);
  return bag;
}

}  // namespace prism
