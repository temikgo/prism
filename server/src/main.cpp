#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

#include "json.hpp"
#include "prism/card.hpp"
#include "prism/game.hpp"
#include "prism/protocol.hpp"
#include "ws.hpp"

// Local game server: many private rooms over WebSocket, one process. A socket
// first does the WebSocket handshake, then sits in a lobby until it creates a
// room (server-generated code + password) or joins one by code+password. When a
// room has two players the engine match begins; each client receives its
// redacted view after every applied action. Rules live in prism_engine, framing
// in ws.hpp; this file is the room manager + lobby protocol (see APP_SHELL.md).

using namespace prism;
using nlohmann::json;

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

// Temporary test deck: one copy of every designed (non-hero) card, no 30-card
// cap. Real deck-model (limits/curve/selection) is a later task.
std::vector<std::string> demoDeck(const CardLibrary& lib) {
  std::vector<std::string> deck;
  for (const auto& d : lib.all())
    if (d.type != CardType::Hero) deck.push_back(d.id);
  return deck;
}

// Every hero ID the library knows (cards of type Hero), for the random pick.
std::vector<std::string> heroPool(const CardLibrary& lib) {
  std::vector<std::string> ids;
  for (const auto& d : lib.all())
    if (d.type == CardType::Hero) ids.push_back(d.id);
  return ids;
}

enum class Phase { Lobby, Waiting, Playing };

// A connected socket and where it is in the flow. `room` is the code of the
// room it created/joined (empty in the bare lobby); `seat` is 0/1 within it.
struct Client {
  Phase phase = Phase::Lobby;
  std::string room;
  int seat = -1;
  std::string buf;  // raw bytes awaiting WebSocket frame parsing
};

// A private match slot. Holds the shared secret, the two player sockets, and
// each player's chosen loadout (hero id + deck). The engine game is created
// when the second player joins.
struct Room {
  std::string password;
  int fd[2] = {-1, -1};
  std::string hero[2];               // chosen hero id per seat ("" = random)
  std::vector<std::string> deck[2];  // chosen deck per seat (empty = default)
  std::unique_ptr<Game> game;
  bool playing = false;
};

std::unordered_map<int, Client> g_clients;
std::unordered_map<std::string, Room> g_rooms;

void sendJson(int fd, const json& j) { sendAll(fd, ws::textFrame(j.dump())); }

void sendType(int fd, const std::string& type) {
  sendJson(fd, json{{"type", type}});
}

// A short room code from an unambiguous alphabet (no 0/O/1/I), unique among the
// live rooms.
std::string makeCode(std::mt19937& rng) {
  static const char* kAlphabet =
      "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";  // 32 chars
  std::string code;
  do {
    code.clear();
    for (int i = 0; i < 4; ++i) code += kAlphabet[rng() % 32];
  } while (g_rooms.count(code) != 0);
  return code;
}

void broadcastRoom(const Room& r) {
  sendAll(r.fd[0], ws::textFrame(viewJson(*r.game, 0)));
  sendAll(r.fd[1], ws::textFrame(viewJson(*r.game, 1)));
}

// Two players are in: pick heroes, seed, build and start the engine game, tell
// both the match begins, then send the first views.
void startMatch(Room& r, const CardLibrary& lib, std::mt19937& rng) {
  std::uint32_t seed = rng();
  std::vector<std::string> heroes = heroPool(lib);
  // Each seat uses its chosen hero/deck; fall back to a random hero and the
  // full-pool default deck if a client sent none (older client / empty pick).
  auto heroFor = [&](int seat) -> std::string {
    if (!r.hero[seat].empty()) return r.hero[seat];
    return heroes.empty() ? std::string{} : heroes[rng() % heroes.size()];
  };
  auto deckFor = [&](int seat) -> std::vector<std::string> {
    return r.deck[seat].empty() ? demoDeck(lib) : r.deck[seat];
  };
  std::string h0 = heroFor(0);
  std::string h1 = heroFor(1);
  r.game = std::make_unique<Game>(lib, deckFor(0), deckFor(1), seed, h0, h1);
  r.game->start();
  r.playing = true;
  sendType(r.fd[0], "matchStart");
  sendType(r.fd[1], "matchStart");
  broadcastRoom(r);
  std::printf("Match started (heroes %s / %s, seed %u)\n", h0.c_str(),
              h1.c_str(), seed);
  std::fflush(stdout);
}

// Detach a socket from its room without closing it: cancel a waiting room, or
// end a live match and notify the opponent. The socket returns to the lobby.
void leaveRoom(int fd) {
  Client& c = g_clients[fd];
  if (c.room.empty()) return;
  auto it = g_rooms.find(c.room);
  if (it != g_rooms.end()) {
    Room& r = it->second;
    int other = (r.fd[0] == fd) ? r.fd[1] : r.fd[0];
    if (r.playing && other != -1) {
      sendType(other, "opponentLeft");
      Client& oc = g_clients[other];
      oc.phase = Phase::Lobby;
      oc.room.clear();
      oc.seat = -1;
    }
    g_rooms.erase(it);
  }
  c.phase = Phase::Lobby;
  c.room.clear();
  c.seat = -1;
}

// Read a player's chosen loadout (hero id + deck card list) from a lobby
// message into the room seat. Both are optional -- startMatch falls back if
// missing.
void readLoadout(const json& j, Room& r, int seat) {
  r.hero[seat] = j.value("hero", std::string{});
  r.deck[seat].clear();
  if (j.contains("deck") && j["deck"].is_array())
    for (const auto& id : j["deck"])
      if (id.is_string()) r.deck[seat].push_back(id.get<std::string>());
}

// Handle one lobby-phase command (create/join/leave a room).
void handleLobby(int fd, const json& j, const CardLibrary& lib,
                 std::mt19937& rng) {
  const std::string action = j.value("action", std::string{});
  Client& c = g_clients[fd];
  if (action == "createRoom") {
    if (c.phase != Phase::Lobby) return;
    const std::string pw = j.value("password", std::string{});
    if (pw.empty()) {
      sendJson(fd, json{{"type", "joinError"}, {"reason", "bad_password"}});
      return;
    }
    std::string code = makeCode(rng);
    Room& r = g_rooms[code];
    r.password = pw;
    r.fd[0] = fd;
    readLoadout(j, r, 0);  // host's chosen hero + deck
    c.phase = Phase::Waiting;
    c.room = code;
    c.seat = 0;
    sendJson(fd, json{{"type", "roomCreated"}, {"code", code}});
    std::printf("Room %s created\n", code.c_str());
    std::fflush(stdout);
  } else if (action == "joinRoom") {
    if (c.phase != Phase::Lobby) return;
    std::string code = j.value("code", std::string{});
    for (char& ch : code) ch = static_cast<char>(std::toupper(ch));
    const std::string pw = j.value("password", std::string{});
    auto it = g_rooms.find(code);
    if (it == g_rooms.end()) {
      sendJson(fd, json{{"type", "joinError"}, {"reason", "no_room"}});
      return;
    }
    Room& r = it->second;
    if (r.password != pw) {
      sendJson(fd, json{{"type", "joinError"}, {"reason", "bad_password"}});
      return;
    }
    if (r.playing || r.fd[1] != -1) {
      sendJson(fd, json{{"type", "joinError"}, {"reason", "room_full"}});
      return;
    }
    r.fd[1] = fd;
    readLoadout(j, r, 1);  // guest's chosen hero + deck
    c.phase = Phase::Playing;
    c.room = code;
    c.seat = 1;
    g_clients[r.fd[0]].phase = Phase::Playing;
    startMatch(r, lib, rng);
  } else if (action == "leaveRoom") {
    leaveRoom(fd);
  }
}

// Route one text frame: lobby commands in any phase, otherwise a game action
// for a player whose match is live.
void handleText(int fd, const std::string& payload, const CardLibrary& lib,
                std::mt19937& rng) {
  json j;
  try {
    j = json::parse(payload);
  } catch (...) {
    return;
  }
  const std::string action = j.value("action", std::string{});
  if (action == "createRoom" || action == "joinRoom" || action == "leaveRoom") {
    handleLobby(fd, j, lib, rng);
    return;
  }
  Client& c = g_clients[fd];
  if (c.phase != Phase::Playing || c.room.empty()) return;
  auto it = g_rooms.find(c.room);
  if (it == g_rooms.end() || !it->second.game) return;
  applyAction(*it->second.game, c.seat, payload);
  broadcastRoom(it->second);
}

// A socket dropped (close/EOF/error): tear down its room if any and forget it.
void dropClient(int fd) {
  if (g_clients.count(fd) != 0) leaveRoom(fd);
  close(fd);
  g_clients.erase(fd);
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
  listen(srv, 16);
  // Bound to INADDR_ANY: reachable on every interface. The host's own client
  // connects to ws://127.0.0.1:<port>; a friend uses the host's LAN IP, or a
  // forwarded/tunnelled address over the internet. Rooms partition the server.
  std::printf("Prism server on port %d (all interfaces). Rooms by code.\n",
              port);
  std::fflush(stdout);

  std::random_device rd;
  std::mt19937 rng(rd());

  while (true) {
    std::vector<pollfd> fds;
    fds.push_back({srv, POLLIN, 0});
    for (const auto& [fd, c] : g_clients) fds.push_back({fd, POLLIN, 0});

    if (poll(fds.data(), static_cast<nfds_t>(fds.size()), -1) < 0) break;

    std::vector<int> dropped;
    for (const pollfd& pf : fds) {
      if (pf.fd == srv) {
        if (pf.revents & POLLIN) {
          int fd = accept(srv, nullptr, nullptr);
          if (fd >= 0) {
            if (doHandshake(fd))
              g_clients[fd];  // default Client in the lobby
            else
              close(fd);
          }
        }
        continue;
      }
      if (g_clients.count(pf.fd) == 0) continue;  // dropped earlier this pass
      if (pf.revents & (POLLHUP | POLLERR)) {
        dropped.push_back(pf.fd);
        continue;
      }
      if (!(pf.revents & POLLIN)) continue;
      char tmp[4096];
      ssize_t n = recv(pf.fd, tmp, sizeof(tmp), 0);
      if (n <= 0) {
        dropped.push_back(pf.fd);
        continue;
      }
      g_clients[pf.fd].buf.append(tmp, static_cast<size_t>(n));
      bool drop = false;
      while (true) {
        ws::Frame frame = ws::parse(g_clients[pf.fd].buf);
        if (frame.op == ws::Op::Incomplete) break;
        g_clients[pf.fd].buf.erase(0, frame.consumed);
        if (frame.op == ws::Op::Close) {
          drop = true;
          break;
        }
        if (frame.op == ws::Op::Ping) {
          sendAll(pf.fd, ws::frame(ws::Op::Pong, frame.payload));
          continue;
        }
        if (frame.op == ws::Op::Text) {
          handleText(pf.fd, frame.payload, lib, rng);
          if (g_clients.count(pf.fd) == 0) break;  // handler dropped us
        }
      }
      if (drop) dropped.push_back(pf.fd);
    }
    for (int fd : dropped)
      if (g_clients.count(fd) != 0) dropClient(fd);
  }

  close(srv);
  return 0;
}
