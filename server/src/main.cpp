#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "prism/card.hpp"
#include "prism/game.hpp"
#include "prism/protocol.hpp"
#include "ws.hpp"

// Minimal local game server: a single room of two players over WebSocket. Each
// client receives its redacted view (a WebSocket text frame of JSON) after
// every applied action, and sends JSON actions as text frames. Thin transport
// over the engine -- all rules live in prism_engine, all framing in ws.hpp.

using namespace prism;

namespace {

void sendAll(int fd, const std::string& data) {
  size_t sent = 0;
  while (sent < data.size()) {
    ssize_t n = send(fd, data.data() + sent, data.size() - sent, 0);
    if (n <= 0) return;
    sent += static_cast<size_t>(n);
  }
}

// Read the client's HTTP upgrade request and complete the WebSocket handshake.
bool doHandshake(int fd) {
  std::string req;
  char tmp[2048];
  while (req.find("\r\n\r\n") == std::string::npos) {
    ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
    if (n <= 0) return false;
    req.append(tmp, static_cast<size_t>(n));
    if (req.size() > 16384) return false;
  }
  std::string response;
  if (!ws::handshake(req, response)) return false;
  sendAll(fd, response);
  return true;
}

// A 30-card demo deck cycling through every playable card the library knows
// (heroes are not deck cards, so they are excluded).
std::vector<std::string> demoDeck(const CardLibrary& lib) {
  std::vector<std::string> ids;
  for (const auto& d : lib.all())
    if (d.type != CardType::Hero) ids.push_back(d.id);
  std::vector<std::string> deck;
  if (ids.empty()) return deck;
  for (int i = 0; i < 30; ++i) deck.push_back(ids[i % ids.size()]);
  return deck;
}

// Every hero ID the library knows (cards of type Hero), for the random pick.
std::vector<std::string> heroPool(const CardLibrary& lib) {
  std::vector<std::string> ids;
  for (const auto& d : lib.all())
    if (d.type == CardType::Hero) ids.push_back(d.id);
  return ids;
}

void broadcast(const Game& g, const int fd[2]) {
  sendAll(fd[0], ws::textFrame(viewJson(g, 0)));
  sendAll(fd[1], ws::textFrame(viewJson(g, 1)));
}

}  // namespace

int main(int argc, char** argv) {
  int port = argc > 1 ? std::atoi(argv[1]) : 8080;
  std::string cardsPath = argc > 2 ? argv[2] : "cards/sample.json";

  CardLibrary lib;
  try {
    lib.loadFile(cardsPath);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "cannot load cards from %s: %s\n", cardsPath.c_str(),
                 e.what());
    return 1;
  }

  int srv = socket(AF_INET, SOCK_STREAM, 0);
  int opt = 1;
  setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (bind(srv, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
    std::perror("bind");
    return 1;
  }
  listen(srv, 2);
  // Bound to INADDR_ANY: reachable on every interface. The host's own client
  // connects to ws://127.0.0.1:<port>; a friend on the LAN uses the host's LAN
  // IP, over the internet a forwarded/tunnelled address.
  std::printf(
      "Prism server on port %d (all interfaces). Connect 2 players to "
      "ws://<host>:%d ...\n",
      port, port);
  std::fflush(stdout);

  int fd[2];
  for (int i = 0; i < 2; ++i) {
    fd[i] = accept(srv, nullptr, nullptr);
    if (fd[i] < 0 || !doHandshake(fd[i])) {
      std::fprintf(stderr, "handshake with player %d failed\n", i);
      return 1;
    }
    std::printf("Player %d connected\n", i);
    std::fflush(stdout);
  }

  // Fresh randomness each game: a non-fixed seed (tests still pass explicit
  // seeds for determinism, but a real match should differ every time).
  std::random_device rd;
  std::uint32_t seed = rd();

  // Each player gets a random hero (no lobby/picker yet -- DESIGN §6).
  std::vector<std::string> heroes = heroPool(lib);
  std::string h0, h1;
  if (!heroes.empty()) {
    std::mt19937 pick(rd());
    h0 = heroes[pick() % heroes.size()];
    h1 = heroes[pick() % heroes.size()];
    std::printf("Heroes: P0=%s  P1=%s\n", h0.c_str(), h1.c_str());
    std::fflush(stdout);
  }
  std::printf("Game seed: %u\n", seed);
  std::fflush(stdout);
  Game g(lib, demoDeck(lib), demoDeck(lib), seed, h0, h1);
  g.start();
  broadcast(g, fd);

  std::string buf[2];
  pollfd fds[2] = {{fd[0], POLLIN, 0}, {fd[1], POLLIN, 0}};
  bool running = true;
  while (running) {
    if (poll(fds, 2, -1) < 0) break;
    for (int i = 0; i < 2 && running; ++i) {
      if (fds[i].revents & (POLLHUP | POLLERR)) {
        running = false;
        break;
      }
      if (!(fds[i].revents & POLLIN)) continue;
      char tmp[4096];
      ssize_t n = recv(fd[i], tmp, sizeof(tmp), 0);
      if (n <= 0) {
        running = false;
        break;
      }
      buf[i].append(tmp, static_cast<size_t>(n));
      while (true) {
        ws::Frame frame = ws::parse(buf[i]);
        if (frame.op == ws::Op::Incomplete) break;
        buf[i].erase(0, frame.consumed);
        if (frame.op == ws::Op::Close) {
          running = false;
          break;
        }
        if (frame.op == ws::Op::Ping) {
          sendAll(fd[i], ws::frame(ws::Op::Pong, frame.payload));
          continue;
        }
        if (frame.op == ws::Op::Text) {
          applyAction(g, i, frame.payload);
          broadcast(g, fd);
        }
      }
    }
  }

  std::printf("A player disconnected; shutting down.\n");
  close(fd[0]);
  close(fd[1]);
  close(srv);
  return 0;
}
