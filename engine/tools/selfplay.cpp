#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <map>
#include <random>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "json.hpp"
#include "prism/bot.hpp"
#include "prism/card.hpp"
#include "prism/deck.hpp"
#include "prism/game.hpp"
#include "prism/protocol.hpp"

// prism_selfplay: a balance probe. Runs many bot-vs-bot games straight through
// the engine -- no server, no sockets -- and reports where the numbers skew.
//   prism_selfplay [games] [cards.json] [threads] [report.json]
//     [--draft] [--jsonl path] [--report path] [--decksize N] [--maxcopies N]
//
// Two measurement modes:
//   * default (full pool): both seats play the whole singleton pool. Cheap, but
//     every game contains every card -> zero presence-variation, so per-card
//     winrate is pure draw-noise (proven un-measurable). Good only for the
//     structural reads: first-player edge and hero winrate.
//   * --draft: each seat drafts a random colour-coherent deck (decksize cards,
//     <=maxcopies each) and a random hero. Now a card is in some decks and not
//     others, which is the contrast a per-card balance regression needs. Each
//     game is emitted as one JSON line (--jsonl) carrying both decklists,
//     heroes, winner and length; the actual per-card model lives in
//     tools/balance_lab.py (no stats baked into this binary, so the model can
//     evolve without a recompile). This is the games basis for the "build 40
//     from any pool" model.
//
// Every game is a pure function of its seed: deck draft, hero pick, the engine
// shuffle, and the bot's own RNG are all derived from one per-game seed. So a
// run reproduces exactly, and a later card-change A/B can replay the identical
// seed set (common random numbers) to collapse the variance of the difference.

namespace prism {
namespace {

using nlohmann::json;

// Every non-hero card id -- the singleton pool both seats play in full-pool
// mode (mirrors the server's demoDeck). Heroes are picked separately, one per
// seat.
std::vector<std::string> fullPool(const CardLibrary& lib) {
  std::vector<std::string> ids;
  for (const auto& d : lib.all())
    if (d.type != CardType::Hero) ids.push_back(d.id);
  return ids;
}

std::vector<const CardDef*> nonHeroDefs(const CardLibrary& lib) {
  std::vector<const CardDef*> defs;
  for (const auto& d : lib.all())
    if (d.type != CardType::Hero) defs.push_back(&d);
  return defs;
}

std::vector<std::string> heroPool(const CardLibrary& lib) {
  std::vector<std::string> ids;
  for (const auto& d : lib.all())
    if (d.type == CardType::Hero) ids.push_back(d.id);
  return ids;
}

// SplitMix64: turn a game index into a well-scattered 32-bit seed.
// Deterministic, so game i always gets the same seed -> reproducible runs and
// replayable seed sets for common-random-numbers A/B.
std::uint32_t mixSeed(std::uint64_t x) {
  x += 0x9E3779B97F4A7C15ull;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
  x = x ^ (x >> 31);
  return static_cast<std::uint32_t>(x);
}

// draftDeck (colour-coherent deck draft) now lives in the engine lib
// (prism/deck.hpp) so the server can give its bot the same coherent decks.

struct Config {
  long games = 1000;
  std::string cardsPath = "cards/sample.json";
  unsigned threads = std::thread::hardware_concurrency();
  std::string reportPath = "selfplay-report.json";
  std::string jsonlPath;  // per-game records; empty = none
  bool draft = false;
  bool vsGreedy = false;  // seat 1 plays the greedy reflex (head-to-head test)
  int deckSize = 40;
  int maxCopies = 2;
};

// games seen and games won, for one hero or one card.
struct Tally {
  long games = 0;
  long wins = 0;
};

struct RunStats {
  long completed = 0;   // games that reached a winner
  long draws = 0;       // reached over_ with no winner (rare)
  long incomplete = 0;  // hit the step guard without finishing
  long seatWins[2] = {0, 0};
  long long totalTurns = 0;
  std::map<std::string, Tally> heroes;
  std::map<std::string, Tally> cards;

  void merge(const RunStats& o) {
    completed += o.completed;
    draws += o.draws;
    incomplete += o.incomplete;
    seatWins[0] += o.seatWins[0];
    seatWins[1] += o.seatWins[1];
    totalTurns += o.totalTurns;
    for (const auto& [k, t] : o.heroes) {
      heroes[k].games += t.games;
      heroes[k].wins += t.wins;
    }
    for (const auto& [k, t] : o.cards) {
      cards[k].games += t.games;
      cards[k].wins += t.wins;
    }
  }
};

// Union every card id currently in `seat`'s hand into `seen`. Called each step
// so the accumulated set is every card the seat ever held -- opening hand,
// every draw, and any card bounced back (scatter). This is the games-in-hand
// basis.
void recordHand(const Game& g, int seat, std::set<std::string>& seen) {
  for (const auto& ci : g.player(seat).hand) seen.insert(ci.def->id);
}

// Whose move is it? In the parameterized phases priority is not current() --
// either player may still owe a mulligan, and scry belongs to scryPlayer.
int actingSeat(const Game& g) {
  if (g.inMulligan()) {
    if (!g.mulliganDone(0)) return 0;
    if (!g.mulliganDone(1)) return 1;
    return -1;
  }
  if (g.inScry()) return g.scryPlayer();
  return g.current();
}

void playOneGame(const CardLibrary& lib, const std::vector<std::string>& pool,
                 const std::vector<const CardDef*>& nonHero,
                 const std::vector<std::string>& heroes, const Config& cfg,
                 std::uint32_t gameSeed, RunStats& acc,
                 std::vector<std::string>* records) {
  std::mt19937 setupRng(
      gameSeed);  // hero pick + deck draft, from the game seed
  const std::string h0 =
      heroes.empty() ? "" : heroes[setupRng() % heroes.size()];
  const std::string h1 =
      heroes.empty() ? "" : heroes[setupRng() % heroes.size()];
  std::vector<std::string> d0, d1;
  if (cfg.draft) {
    d0 = draftDeck(nonHero, cfg.deckSize, cfg.maxCopies, setupRng);
    d1 = draftDeck(nonHero, cfg.deckSize, cfg.maxCopies, setupRng);
  } else {
    d0 = pool;
    d1 = pool;
  }
  Game g(lib, d0, d1, gameSeed, h0, h1);
  g.start();
  // A fresh bot RNG per game, seeded from the game seed: so a paired A/B run on
  // the same seed feeds the bot the same stream (CRN) -- divergence comes only
  // from the card change, not from RNG drift.
  std::mt19937 botRng(gameSeed ^ 0x9E3779B9u);

  std::array<std::set<std::string>, 2>
      seen;  // cards each seat ever held in hand
  const std::string endTurn = json{{"action", "endTurn"}}.dump();
  bool stalled = false;
  for (int guard = 0; guard < 6000 && !g.isOver(); ++guard) {
    recordHand(g, 0, seen[0]);
    recordHand(g, 1, seen[1]);
    const int seat = actingSeat(g);
    if (seat < 0) {
      stalled = true;
      break;
    }
    const std::string js = (cfg.vsGreedy && seat == 1)
                               ? botGreedyAction(g, seat, botRng)
                               : botNextAction(g, seat, botRng);
    if (js.empty()) {  // nothing to offer mid-turn: force the pass, never spin
      if (!applyAction(g, seat, endTurn)) {
        stalled = true;
        break;
      }
      continue;
    }
    if (!applyAction(g, seat, js)) {  // illegal move: pass rather than loop
      if (!applyAction(g, seat, endTurn)) {
        stalled = true;
        break;
      }
      continue;
    }
  }
  recordHand(g, 0, seen[0]);  // final state, after the last draw/turn
  recordHand(g, 1, seen[1]);

  acc.totalTurns += g.turn();
  if (!g.isOver() || stalled) {
    acc.incomplete++;
    return;
  }
  const int w = g.winner();
  acc.completed++;
  if (w < 0)
    acc.draws++;
  else
    acc.seatWins[w]++;
  const std::array<std::string, 2> hero = {h0, h1};
  for (int seat = 0; seat < 2; ++seat) {
    if (!hero[seat].empty()) {
      acc.heroes[hero[seat]].games++;
      if (w == seat) acc.heroes[hero[seat]].wins++;
    }
    for (const auto& cid : seen[seat]) {
      acc.cards[cid].games++;
      if (w == seat) acc.cards[cid].wins++;
    }
  }

  if (records != nullptr) {
    json dm0 = json::object(), dm1 = json::object();
    for (const auto& id : d0) dm0[id] = dm0.value(id, 0) + 1;
    for (const auto& id : d1) dm1[id] = dm1.value(id, 0) + 1;
    json rec = {{"seed", gameSeed}, {"hero0", h0},       {"hero1", h1},
                {"winner", w},      {"turns", g.turn()}, {"deck0", dm0},
                {"deck1", dm1},     {"gih0", seen[0]},   {"gih1", seen[1]}};
    records->push_back(rec.dump());
  }
}

double pct(long w, long n) { return n > 0 ? 100.0 * w / n : 0.0; }

void writeJson(const std::string& path, const RunStats& s, const Config& cfg,
               double secs) {
  json j;
  j["games_requested"] = cfg.games;
  j["completed"] = s.completed;
  j["draws"] = s.draws;
  j["incomplete"] = s.incomplete;
  j["threads"] = cfg.threads;
  j["card_set"] = cfg.cardsPath;
  j["mode"] = cfg.draft ? "draft" : "fullpool";
  j["seconds"] = secs;
  const long decided = s.seatWins[0] + s.seatWins[1];
  j["first_player_winrate"] = pct(s.seatWins[0], decided);
  j["avg_turns"] =
      s.completed + s.incomplete > 0
          ? static_cast<double>(s.totalTurns) / (s.completed + s.incomplete)
          : 0.0;
  for (const auto& [k, t] : s.heroes)
    j["heroes"][k] = {{"games", t.games}, {"winrate", pct(t.wins, t.games)}};
  for (const auto& [k, t] : s.cards)
    j["cards"][k] = {{"games", t.games}, {"winrate", pct(t.wins, t.games)}};
  std::ofstream f(path);
  if (f) f << j.dump(2) << "\n";
}

}  // namespace
}  // namespace prism

int main(int argc, char** argv) {
  using namespace prism;
  Config cfg;
  if (cfg.threads < 1) cfg.threads = 1;
  std::vector<std::string> pos;
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--draft")
      cfg.draft = true;
    else if (a == "--vsgreedy")
      cfg.vsGreedy = true;
    else if (a == "--jsonl" && i + 1 < argc)
      cfg.jsonlPath = argv[++i];
    else if (a == "--report" && i + 1 < argc)
      cfg.reportPath = argv[++i];
    else if (a == "--decksize" && i + 1 < argc)
      cfg.deckSize = std::atoi(argv[++i]);
    else if (a == "--maxcopies" && i + 1 < argc)
      cfg.maxCopies = std::atoi(argv[++i]);
    else
      pos.push_back(a);
  }
  if (pos.size() >= 1) cfg.games = std::atol(pos[0].c_str());
  if (pos.size() >= 2) cfg.cardsPath = pos[1];
  if (pos.size() >= 3)
    cfg.threads = static_cast<unsigned>(std::atoi(pos[2].c_str()));
  if (pos.size() >= 4) cfg.reportPath = pos[3];
  if (cfg.threads < 1) cfg.threads = 1;
  if (static_cast<long>(cfg.threads) > cfg.games)
    cfg.threads = static_cast<unsigned>(cfg.games);
  if (cfg.draft && cfg.jsonlPath.empty())
    cfg.jsonlPath = "selfplay-games.jsonl";
  if (cfg.games <= 0) {
    std::fprintf(stderr, "games must be positive\n");
    return 2;
  }

  CardLibrary lib;
  lib.loadFile(cfg.cardsPath);
  const std::vector<std::string> pool = fullPool(lib);
  const std::vector<const CardDef*> nonHero = nonHeroDefs(lib);
  const std::vector<std::string> heroes = heroPool(lib);
  if (pool.empty()) {
    std::fprintf(stderr, "no cards loaded from %s\n", cfg.cardsPath.c_str());
    return 1;
  }
  std::printf(
      "prism_selfplay: %ld games, %u threads, %zu cards, %zu heroes, mode=%s\n",
      cfg.games, cfg.threads, pool.size(), heroes.size(),
      cfg.draft ? "draft" : "fullpool");
  if (cfg.draft)
    std::printf("  draft decks: %d cards, <=%d copies, colour-coherent\n",
                cfg.deckSize, cfg.maxCopies);
  std::fflush(stdout);

  std::vector<RunStats> shards(cfg.threads);
  std::vector<std::vector<std::string>> shardRecords(cfg.threads);
  std::atomic<long> done{0};
  const auto t0 = std::chrono::steady_clock::now();
  std::vector<std::thread> pool_threads;
  for (unsigned ti = 0; ti < cfg.threads; ++ti) {
    const long base = cfg.games / cfg.threads;
    const long extra =
        ti < static_cast<unsigned>(cfg.games % cfg.threads) ? 1 : 0;
    const long lo = ti * base + std::min<long>(ti, cfg.games % cfg.threads);
    const long hi = lo + base + extra;
    pool_threads.emplace_back([&, ti, lo, hi] {
      std::vector<std::string>* rec =
          cfg.jsonlPath.empty() ? nullptr : &shardRecords[ti];
      for (long i = lo; i < hi; ++i) {
        const std::uint32_t gs = mixSeed(static_cast<std::uint64_t>(i) + 1);
        playOneGame(lib, pool, nonHero, heroes, cfg, gs, shards[ti], rec);
        done.fetch_add(1, std::memory_order_relaxed);
      }
    });
  }
  while (done.load(std::memory_order_relaxed) < cfg.games) {
    std::printf("\r  %ld / %ld", done.load(std::memory_order_relaxed),
                cfg.games);
    std::fflush(stdout);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
  }
  for (auto& t : pool_threads) t.join();

  RunStats s;
  for (const auto& sh : shards) s.merge(sh);
  const double secs =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
          .count();

  const long decided = s.seatWins[0] + s.seatWins[1];
  std::printf(
      "\rcompleted %ld (%ld draws, %ld incomplete) in %.1fs (%.2f g/s)\n",
      s.completed, s.draws, s.incomplete, secs,
      secs > 0 ? cfg.games / secs : 0.0);
  std::printf("seat skew: P1 %.1f%%  P2 %.1f%%  (first-player edge %+.1f pp)\n",
              pct(s.seatWins[0], decided), pct(s.seatWins[1], decided),
              pct(s.seatWins[0], decided) - 50.0);
  if (s.completed + s.incomplete > 0)
    std::printf(
        "avg game length: %.1f turns\n",
        static_cast<double>(s.totalTurns) / (s.completed + s.incomplete));

  auto sortedByWinrate = [](const std::map<std::string, Tally>& m) {
    std::vector<std::pair<std::string, Tally>> v(m.begin(), m.end());
    std::sort(v.begin(), v.end(), [](const auto& a, const auto& b) {
      return pct(a.second.wins, a.second.games) >
             pct(b.second.wins, b.second.games);
    });
    return v;
  };

  std::printf("\nheroes (winrate when piloting):\n");
  for (const auto& [id, t] : sortedByWinrate(s.heroes))
    std::printf("  %-24s %5.1f%%   n=%ld\n", id.c_str(), pct(t.wins, t.games),
                t.games);

  if (!cfg.draft) {
    const long lowN = 30;
    std::printf("\ncards (winrate when drawn; <%ld samples = noisy):\n", lowN);
    for (const auto& [id, t] : sortedByWinrate(s.cards))
      std::printf("  %-28s %5.1f%%   n=%-6ld%s\n", id.c_str(),
                  pct(t.wins, t.games), t.games,
                  t.games < lowN ? "  (low n)" : "");
  } else {
    std::printf(
        "\n(draft mode: per-card balance is computed by tools/balance_lab.py "
        "from the per-game records, not from this aggregate)\n");
  }

  if (!cfg.reportPath.empty()) {
    writeJson(cfg.reportPath, s, cfg, secs);
    std::printf("\nreport written: %s\n", cfg.reportPath.c_str());
  }
  if (!cfg.jsonlPath.empty()) {
    std::ofstream f(cfg.jsonlPath);
    long nrec = 0;
    for (const auto& sr : shardRecords)
      for (const auto& line : sr) {
        f << line << "\n";
        ++nrec;
      }
    std::printf("per-game records: %ld -> %s\n", nrec, cfg.jsonlPath.c_str());
  }
  return 0;
}
