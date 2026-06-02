#include "prism/card.hpp"

#include <fstream>
#include <sstream>
#include <stdexcept>

#include "json.hpp"

// Parses the cards/*.json schema into CardDef. Missing optional fields default
// to empty/zero; an unknown card type throws. Keyword/effect blocks are read
// verbatim into the def but are not yet interpreted by the engine.

namespace prism {

using nlohmann::json;

static CardDef parseCard(const json& j) {
  CardDef d;
  d.id = j.at("id").get<std::string>();
  if (j.contains("name") && j["name"].contains("ru"))
    d.nameRu = j["name"]["ru"].get<std::string>();
  if (j.contains("text") && j["text"].contains("ru"))
    d.textRu = j["text"]["ru"].get<std::string>();
  if (j.contains("art")) d.art = j["art"].get<std::string>();

  auto t = cardTypeFromString(j.at("type").get<std::string>());
  if (!t) throw std::runtime_error("unknown card type for id " + d.id);
  d.type = *t;

  if (j.contains("color")) {
    for (const auto& c : j["color"]) {
      auto col = colorFromString(c.get<std::string>());
      if (col) d.colors.push_back(*col);
    }
  }

  if (j.contains("cost")) {
    for (auto it = j["cost"].begin(); it != j["cost"].end(); ++it) {
      if (it.key() == "generic") {
        d.cost.generic = it.value().get<int>();
      } else {
        auto col = colorFromString(it.key());
        if (col) d.cost.pips[idx(*col)] += it.value().get<int>();
      }
    }
  }

  if (j.contains("stats")) {
    d.hasStats = true;
    d.stats.atk = j["stats"].value("atk", 0);
    d.stats.hp = j["stats"].value("hp", 0);
  }

  if (j.contains("keywords")) {
    for (const auto& k : j["keywords"]) {
      KeywordRef kw;
      kw.id = k.at("id").get<std::string>();
      if (k.contains("n")) kw.n = k["n"].get<int>();
      d.keywords.push_back(kw);
    }
  }

  if (j.contains("effects")) {
    for (const auto& e : j["effects"]) {
      EffectDef ef;
      ef.trigger = e.value("trigger", std::string{});
      ef.selector = e.value("selector", std::string{});
      ef.action = e.value("action", std::string{});
      ef.value = e.value("value", 0);
      d.effects.push_back(ef);
    }
  }

  return d;
}

void CardLibrary::loadJsonString(const std::string& text) {
  json j = json::parse(text);
  for (const auto& c : j) defs_.push_back(parseCard(c));
}

void CardLibrary::loadFile(const std::string& path) {
  std::ifstream f(path);
  if (!f) throw std::runtime_error("cannot open card file " + path);
  std::stringstream ss;
  ss << f.rdbuf();
  loadJsonString(ss.str());
}

const CardDef* CardLibrary::find(const std::string& id) const {
  for (const auto& d : defs_)
    if (d.id == id) return &d;
  return nullptr;
}

}  // namespace prism
