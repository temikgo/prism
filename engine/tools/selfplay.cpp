#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <map>
#include <mutex>
#include <random>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "json.hpp"
#include "prism/bot.hpp"
#include "prism/card.hpp"
#include "prism/game.hpp"
#include "prism/protocol.hpp"

// prism_selfplay: a balance probe. Runs many bot-vs-bot games straight through
// the engine -- no server, no sockets -- and reports where the numbers skew.
//   prism_selfplay [games=1000] [cards=cards/sample.json] [threads=hw]
//   [out.json]
//
// Both seats draft the same full singleton pool and a random hero, so a single
// run measures three things honestly: the first-player edge (turn order), each
// hero's winrate, and -- because a 30-turn game only ever draws a subset of an
// 80-card deck -- each card's winrate when it actually reached play. That last
// signal is the per-card balance read: a card that wins well above 50% whenever
// it hits the board is overtuned, one well below is dead weight. It is NOT a
// meta-of-decks measurement (every deck is the same pile); that waits on real
// deckbuilding (M4). The bot is full-information and 1-ply, so this is a coarse
// strength estimate, not a solver -- read the columns, not the third decimal.

namespace prism {
namespace {

using nlohmann::json;

// Every non-hero card id -- the singleton pool both seats play (mirrors the
// server's demoDeck). Heroes are picked separately, one per seat.
std::vector<std::string> fullPool(const CardLibrary& lib) {
  std::vector<std::string> ids;
  for (const auto& d : lib.all())
    if (d.type != CardType::Hero) ids.push_back(d.id);
  return ids;
}

std::vector<std::string> heroPool(const CardLibrary& lib) {
  std::vector<std::string> ids;
  for (const auto& d : lib.all())
    if (d.type == CardType::Hero) ids.push_back(d.id);
  return ids;
}

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

// Which card id a chosen action puts into play (a play from hand or an awaken
// from the mana row), or "" for anything else. Resolved BEFORE the action is
// applied, while the hand/mana indices still point where the action expects.
std::string playedCardId(const Game& g, int seat, const std::string& js) {
  json j = json::parse(js, nullptr, false);
  if (j.is_discarded() || !j.contains("action")) return "";
  const std::string a = j["action"].get<std::string>();
  const Player& p = g.player(seat);
  if (a == "play") {
    int hi = j.value("handIndex", -1);
    if (hi >= 0 && hi < static_cast<int>(p.hand.size()))
      return p.hand[hi].def->id;
  } else if (a == "awaken") {
    int mi = j.value("manaRowIndex", -1);
    if (mi >= 0 && mi < static_cast<int>(p.manaRow.size()))
      return p.manaRow[mi].card.def->id;
  }
  return "";
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
                 const std::vector<std::string>& heroes, std::uint32_t seed,
                 std::mt19937& rng, RunStats& acc) {
  const std::string h0 = heroes.empty() ? "" : heroes[rng() % heroes.size()];
  const std::string h1 = heroes.empty() ? "" : heroes[rng() % heroes.size()];
  Game g(lib, pool, pool, seed, h0, h1);
  g.start();

  std::array<std::set<std::string>, 2> played;  // cards each seat got into play
  const std::string endTurn = json{{"action", "endTurn"}}.dump();
  bool stalled = false;
  for (int guard = 0; guard < 6000 && !g.isOver(); ++guard) {
    const int seat = actingSeat(g);
    if (seat < 0) {
      stalled = true;
      break;
    }
    const std::string js = botNextAction(g, seat, rng);
    if (js.empty()) {  // nothing to offer mid-turn: force the pass, never spin
      if (!applyAction(g, seat, endTurn)) {
        stalled = true;
        break;
      }
      continue;
    }
    const std::string cid = playedCardId(g, seat, js);
    if (!applyAction(g, seat, js)) {  // illegal move: pass rather than loop
      if (!applyAction(g, seat, endTurn)) {
        stalled = true;
        break;
      }
      continue;
    }
    if (!cid.empty()) played[seat].insert(cid);
  }

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
    for (const auto& cid : played[seat]) {
      acc.cards[cid].games++;
      if (w == seat) acc.cards[cid].wins++;
    }
  }
}

double pct(long w, long n) { return n > 0 ? 100.0 * w / n : 0.0; }

void writeJson(const std::string& path, const RunStats& s, long games,
               unsigned threads, const std::string& cards, double secs) {
  json j;
  j["games_requested"] = games;
  j["completed"] = s.completed;
  j["draws"] = s.draws;
  j["incomplete"] = s.incomplete;
  j["threads"] = threads;
  j["card_set"] = cards;
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
  const long games = argc > 1 ? std::atol(argv[1]) : 1000;
  const std::string cardsPath = argc > 2 ? argv[2] : "cards/sample.json";
  unsigned threads = argc > 3 ? static_cast<unsigned>(std::atol(argv[3]))
                              : std::thread::hardware_concurrency();
  const std::string outJson = argc > 4 ? argv[4] : "selfplay-report.json";
  if (threads < 1) threads = 1;
  if (static_cast<long>(threads) > games)
    threads = static_cast<unsigned>(games);
  if (games <= 0) {
    std::fprintf(stderr, "games must be positive\n");
    return 2;
  }

  CardLibrary lib;
  lib.loadFile(cardsPath);
  const std::vector<std::string> pool = fullPool(lib);
  const std::vector<std::string> heroes = heroPool(lib);
  if (pool.empty()) {
    std::fprintf(stderr, "no cards loaded from %s\n", cardsPath.c_str());
    return 1;
  }
  std::printf("prism_selfplay: %ld games, %u threads, %zu cards, %zu heroes\n",
              games, threads, pool.size(), heroes.size());
  std::fflush(stdout);

  std::vector<RunStats> shards(threads);
  std::atomic<long> done{0};
  const auto t0 = std::chrono::steady_clock::now();
  std::vector<std::thread> pool_threads;
  for (unsigned ti = 0; ti < threads; ++ti) {
    const long base = games / threads;
    const long extra = ti < static_cast<unsigned>(games % threads) ? 1 : 0;
    const long count = base + extra;
    pool_threads.emplace_back([&, ti, count] {
      std::mt19937 rng(0x5EEDu + ti * 0x9E3779B9u);
      for (long i = 0; i < count; ++i) {
        playOneGame(lib, pool, heroes, rng(), rng, shards[ti]);
        done.fetch_add(1, std::memory_order_relaxed);
      }
    });
  }
  while (done.load(std::memory_order_relaxed) < games) {
    std::printf("\r  %ld / %ld", done.load(std::memory_order_relaxed), games);
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
      s.completed, s.draws, s.incomplete, secs, secs > 0 ? games / secs : 0.0);
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

  const long lowN = 30;
  std::printf("\ncards (winrate when played; <%ld samples = noisy):\n", lowN);
  for (const auto& [id, t] : sortedByWinrate(s.cards))
    std::printf("  %-28s %5.1f%%   n=%-6ld%s\n", id.c_str(),
                pct(t.wins, t.games), t.games,
                t.games < lowN ? "  (low n)" : "");

  if (!outJson.empty()) {
    writeJson(outJson, s, games, threads, cardsPath, secs);
    std::printf("\nreport written: %s\n", outJson.c_str());
  }
  return 0;
}
