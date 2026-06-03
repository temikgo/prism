#pragma once
#include <array>
#include <optional>
#include <string>
#include <string_view>

// Core value types for the Prism rules engine: colors, card stats, mana cost,
// and the mana pool. See ../../DESIGN.md (§3 mana, §11 palette) for the design.

namespace prism {

// The five spectral aspects of Prism plus Colorless. Colorless is the
// "generic" / neutral (white) crystal: it pays generic cost but never a
// colored pip. The five colored values index both Cost::pips and ManaPool.
enum class Color { Red, Yellow, Green, Blue, Violet, Colorless };
inline constexpr int ColorCount = 6;

inline constexpr int idx(Color c) { return static_cast<int>(c); }

// Language-neutral color token <-> enum. Tokens are the internal IDs used in
// cards/*.json; player-visible names live in name/text locale fields instead.
inline std::optional<Color> colorFromString(std::string_view s) {
  if (s == "red") return Color::Red;
  if (s == "yellow") return Color::Yellow;
  if (s == "green") return Color::Green;
  if (s == "blue") return Color::Blue;
  if (s == "violet") return Color::Violet;
  if (s == "colorless") return Color::Colorless;
  return std::nullopt;
}

inline std::string_view colorName(Color c) {
  switch (c) {
    case Color::Red:
      return "red";
    case Color::Yellow:
      return "yellow";
    case Color::Green:
      return "green";
    case Color::Blue:
      return "blue";
    case Color::Violet:
      return "violet";
    case Color::Colorless:
      return "colorless";
  }
  return "colorless";
}

// Card supertypes (DESIGN §5). Only Creature fights; Spell resolves once,
// Aura stays in play. Hero is never in a deck: it is a player's chosen
// character, carrying a passive keyword (its hero power, DESIGN §6).
enum class CardType { Creature, Spell, Aura, Hero };

inline std::optional<CardType> cardTypeFromString(std::string_view s) {
  if (s == "creature") return CardType::Creature;
  if (s == "spell") return CardType::Spell;
  if (s == "aura") return CardType::Aura;
  if (s == "hero") return CardType::Hero;
  return std::nullopt;
}

// Creature combat profile (DESIGN §2). atk is the damage it deals; hp is its
// life, wounds persisting across turns. Combat is mutual: when one creature
// attacks another, both deal their atk to each other simultaneously.
struct Stats {
  int atk = 0;
  int hp = 0;
};

// Full MTG-style cost: `generic` is paid by any crystal; `pips[color]` must be
// paid by a crystal of that exact color. pips[Colorless] is unused (generic
// already represents the colorless requirement).
struct Cost {
  int generic = 0;
  std::array<int, ColorCount> pips{};

  int colored() const {
    int s = 0;
    for (int v : pips) s += v;
    return s;
  }
  int total() const { return generic + colored(); }
};

// A player's mana. `crystals` is the permanent stock (one is added per turn by
// sacrificing a card to the mana row; there is no automatic ramp). `available`
// is what is unspent this turn and is reset to `crystals` at every turn start.
struct ManaPool {
  std::array<int, ColorCount> crystals{};
  std::array<int, ColorCount> available{};

  void refill() { available = crystals; }

  // A freshly placed crystal is usable the same turn (MTG land-like, DESIGN
  // §3): it bumps both the permanent stock and what is available right now.
  void addCrystal(Color c) {
    crystals[idx(c)] += 1;
    available[idx(c)] += 1;
  }

  // Mana for this turn only (does not persist past the next refill). Used by
  // green ramp such as Photosynthesis, which tops up each turn rather than
  // permanently growing the crystal count.
  void addTemporary(Color c, int n) { available[idx(c)] += n; }

  int totalAvailable() const {
    int s = 0;
    for (int v : available) s += v;
    return s;
  }

  // Payable iff every colored pip has a matching crystal AND the crystals left
  // after reserving those pips still cover the generic part.
  bool canPay(const Cost& cost) const {
    int coloredSum = 0;
    for (int i = 0; i < ColorCount; ++i) {
      if (available[i] < cost.pips[i]) return false;
      coloredSum += cost.pips[i];
    }
    return totalAvailable() - coloredSum >= cost.generic;
  }

  // Spend the cost. Colored pips come from their own color; the generic part is
  // paid greedily, Colorless first, to keep colored crystals free for later
  // colored pips this turn. Returns false (and changes nothing) if unpayable.
  bool pay(const Cost& cost) {
    if (!canPay(cost)) return false;
    std::array<int, ColorCount> a = available;
    for (int i = 0; i < ColorCount; ++i) a[i] -= cost.pips[i];
    int need = cost.generic;
    const int order[ColorCount] = {idx(Color::Colorless), idx(Color::Red),
                                   idx(Color::Yellow),    idx(Color::Green),
                                   idx(Color::Blue),      idx(Color::Violet)};
    for (int oi = 0; oi < ColorCount && need > 0; ++oi) {
      int i = order[oi];
      int take = a[i] < need ? a[i] : need;
      a[i] -= take;
      need -= take;
    }
    available = a;
    return true;
  }
};

}  // namespace prism
