#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

#include "prism/card.hpp"
#include "prism/protocol.hpp"

// prism_replay: re-run a recorded game and print its outcome. A dev tool for
// reproducing a dumped replay (from the server log or the fuzz harness) -- the
// engine is deterministic, so this lands on the exact same final state.
//   prism_replay <cards.json> <replay.json> [--view]
// Without --view it prints a one-line summary; with it, both players' final
// views (useful for inspecting a crash/desync the replay was captured for).

static std::string slurp(const char* path) {
  std::ifstream f(path);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <cards.json> <replay.json> [--view]\n",
                 argv[0]);
    return 2;
  }
  bool showView = argc > 3 && std::string(argv[3]) == "--view";

  prism::CardLibrary lib;
  lib.loadFile(argv[1]);
  std::string replay = slurp(argv[2]);
  if (replay.empty()) {
    std::fprintf(stderr, "replay file empty or unreadable: %s\n", argv[2]);
    return 1;
  }

  int applied = 0;
  std::unique_ptr<prism::Game> g = prism::runReplay(lib, replay, &applied);

  std::printf("replay: applied %d actions | turn=%d over=%s winner=%d\n",
              applied, g->turn(), g->isOver() ? "true" : "false", g->winner());
  if (showView) {
    std::printf("--- view (player 0) ---\n%s\n", viewJson(*g, 0).c_str());
    std::printf("--- view (player 1) ---\n%s\n", viewJson(*g, 1).c_str());
  }
  return 0;
}
