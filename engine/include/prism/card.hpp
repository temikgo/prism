#pragma once
#include <optional>
#include <string>
#include <string_view>
#include <vector>
#include "prism/types.hpp"

// Static card definitions and the library that loads them from JSON.
// A CardDef is immutable template data shared by every copy of a card; runtime
// per-instance state lives in game.hpp (CardInstance / Creature).

namespace prism {

// A named keyword on a card, e.g. {"id":"regen","n":1}. `n` is the single
// numeric parameter shown on the card. The keyword catalog is in ../../EFFECTS.md.
// Phase 1 parses keywords but does not execute them yet.
struct KeywordRef {
  std::string id;
  std::optional<int> n;
};

// An inline primitive effect: [trigger] + [selector] -> [action](value).
// This mirrors the effect grammar in DESIGN §8. Also parsed-but-inert in Phase 1.
struct EffectDef {
  std::string trigger;
  std::string selector;
  std::string action;
  int value = 0;
};

// One card template, mirroring the cards/*.json schema. `colors` is the card's
// color identity (its colored pips); empty means a neutral/white card.
struct CardDef {
  std::string id;
  std::string nameRu;
  std::string textRu;
  std::string art;
  CardType type = CardType::Creature;
  std::vector<Color> colors;
  Cost cost;
  bool hasStats = false;
  Stats stats;
  std::vector<KeywordRef> keywords;
  std::vector<EffectDef> effects;

  // Keyword lookup helpers used by the rules (e.g. "does this creature have
  // pierce?", "what is its regen N?"). Static keywords (pierce, provoke) are
  // queried during combat; numeric keywords (regen, photosynthesis) via keywordN.
  const KeywordRef* keyword(std::string_view id) const {
    for (const auto& k : keywords)
      if (k.id == id) return &k;
    return nullptr;
  }
  bool hasKeyword(std::string_view id) const { return keyword(id) != nullptr; }
  int keywordN(std::string_view id, int fallback = 0) const {
    const KeywordRef* k = keyword(id);
    if (k && k->n) return *k->n;
    return fallback;
  }
};

// Loads and owns every CardDef. Pointers returned by find() are stable for the
// library's lifetime, so the game stores raw `const CardDef*` into it.
class CardLibrary {
 public:
  void loadFile(const std::string& path);
  void loadJsonString(const std::string& text);
  const CardDef* find(const std::string& id) const;
  std::size_t size() const { return defs_.size(); }
  const std::vector<CardDef>& all() const { return defs_; }

 private:
  std::vector<CardDef> defs_;
};

}  // namespace prism
