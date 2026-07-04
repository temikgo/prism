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
#include <ctime>
#include <filesystem>
#include <fstream>
#include <memory>
#include <random>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "json.hpp"
#include "prism/bot.hpp"
#include "prism/card.hpp"
#include "prism/deck.hpp"
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
  std::string code;  // this room's own code (for session bookkeeping)
  std::string password;
  int fd[2] = {-1, -1};
  std::string hero[2];               // chosen hero id per seat ("" = random)
  std::vector<std::string> deck[2];  // chosen deck per seat (empty = default)
  std::unique_ptr<Game> game;
  bool playing = false;
  // Reconnect (release-independent, same process): each human seat gets a
  // bearer token at match start. On a socket drop during a live match the seat
  // detaches (fd = -1) instead of destroying the room; the player rejoins with
  // the token within the grace window. `disconnectAt` = when a human seat last
  // dropped (0 = all present); a room past the window is GC'd.
  std::string token[2];
  std::time_t disconnectAt = 0;
  // Action log for the live match: the resolved setup (seed/heroes/decks) plus
  // every accepted action, so the room can emit a deterministic replay (M1) --
  // the same log will feed reconnect (M5). Dumped to a file on game-over.
  std::uint32_t seed = 0;
  std::string usedHero[2];
  std::vector<std::string> usedDeck[2];
  std::vector<std::pair<int, std::string>> actionLog;  // (seat, action JSON)
  bool dumped = false;
  // Single-player: seat 1 is a bot (no socket, fd[1] == -1) driven by pumpBot.
  bool vsBot = false;
};

std::unordered_map<int, Client> g_clients;
std::unordered_map<std::string, Room> g_rooms;
// token -> (room code, seat): a dropped player reclaims its seat with this.
// Same-process only; a server restart clears them (survives-restart = later).
std::unordered_map<std::string, std::pair<std::string, int>> g_sessions;
constexpr int kReconnectGraceSec = 120;  // hold a seat this long after a drop

// A human seat sits empty (dropped, awaiting reconnect)? Seat 0 is always
// human; seat 1 is human unless it is the bot.
bool roomHasDetachedHuman(const Room& r) {
  if (r.fd[0] < 0) return true;
  return !r.vsBot && r.fd[1] < 0;
}

void sendJson(int fd, const json& j) {
  if (fd < 0) return;  // a bot seat has no socket
  sendAll(fd, ws::textFrame(j.dump()));
}

void sendType(int fd, const std::string& type) {
  sendJson(fd, json{{"type", type}});
}

// A cryptographically-secure random source, kept separate from the gameplay
// mt19937. Reconnect tokens and the match seed are SECRETS: they must not come
// from the same stream whose outputs (room codes) are handed to clients,
// because mt19937 state is linearly recoverable from a few observed outputs --
// which would let an attacker predict future tokens (seat hijack + private-hand
// leak) and the shuffle seed (the opponent's deck order). On Linux libstdc++,
// std::random_device is backed by getrandom()/urandom (a CSPRNG).
std::uint32_t secureRand() {
  static std::random_device rd;
  return rd();
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

// A long random bearer token for reconnect (16 chars from the same alphabet),
// unique among live sessions. Drawn from the CSPRNG, not the gameplay RNG: this
// is the credential that authorises reclaiming a seat, so it must be
// unpredictable. (32 divides 2^32 exactly, so % 32 is unbiased.)
std::string makeToken() {
  static const char* kAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  std::string t;
  do {
    t.clear();
    for (int i = 0; i < 16; ++i) t += kAlphabet[secureRand() % 32];
  } while (g_sessions.count(t) != 0);
  return t;
}

// `eventJson` (default "") annotates this state with the public action that
// produced it, so the clients can play the move out step by step; both seats
// see the same event.
void broadcastRoom(const Room& r, const std::string& eventJson = "") {
  if (r.fd[0] >= 0)
    sendAll(r.fd[0], ws::textFrame(viewJson(*r.game, 0, eventJson)));
  if (r.fd[1] >= 0)
    sendAll(r.fd[1], ws::textFrame(viewJson(*r.game, 1, eventJson)));
}

// Write this room's match as a deterministic replay (engine format) once, when
// the game ends. The same recorded log will also drive reconnect (M5).
// Best-effort: a write failure is logged but never disrupts the match.
void dumpReplay(const std::string& code, Room& r) {
  if (r.dumped) return;
  r.dumped = true;
  std::error_code ec;
  std::filesystem::create_directories("replays", ec);
  std::string rep = makeReplay(r.seed, r.usedDeck[0], r.usedDeck[1],
                               r.usedHero[0], r.usedHero[1], r.actionLog);
  std::time_t t = std::time(nullptr);
  char ts[32];
  std::strftime(ts, sizeof(ts), "%Y%m%d-%H%M%S", std::localtime(&t));
  std::string path = "replays/" + code + "-" + ts + ".json";
  std::ofstream f(path);
  if (f) {
    f << rep;
    std::printf("Replay saved: %s (%zu actions)\n", path.c_str(),
                r.actionLog.size());
  } else {
    std::printf("Replay save FAILED: %s\n", path.c_str());
  }
}

// Two players are in: pick heroes, seed, build and start the engine game, tell
// both the match begins, then send the first views.
void startMatch(Room& r, const CardLibrary& lib, std::mt19937& rng) {
  std::uint32_t seed = secureRand();  // secret: hides the shuffle / deck order
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
  std::vector<std::string> d0 = deckFor(0);
  std::vector<std::string> d1 = deckFor(1);
  r.game = std::make_unique<Game>(lib, d0, d1, seed, h0, h1);
  r.game->start();
  r.playing = true;
  // Remember the resolved setup so a replay of this match can be reconstructed.
  r.seed = seed;
  r.usedHero[0] = h0;
  r.usedHero[1] = h1;
  r.usedDeck[0] = d0;
  r.usedDeck[1] = d1;
  r.actionLog.clear();
  r.dumped = false;
  // Issue reconnect tokens for the human seats and hand each seat its own.
  r.token[0] = makeToken();
  g_sessions[r.token[0]] = {r.code, 0};
  if (!r.vsBot) {
    r.token[1] = makeToken();
    g_sessions[r.token[1]] = {r.code, 1};
  }
  r.disconnectAt = 0;
  sendJson(r.fd[0], json{{"type", "matchStart"}, {"token", r.token[0]}});
  if (r.fd[1] >= 0)
    sendJson(r.fd[1], json{{"type", "matchStart"}, {"token", r.token[1]}});
  broadcastRoom(r);
  std::printf("Match started (heroes %s / %s, seed %u)\n", h0.c_str(),
              h1.c_str(), seed);
  std::fflush(stdout);
}

// Drive the bot (seat 1) for as long as it has a move: its mulligan, then its
// whole turn once play passes to it. Mutates the game + action log; the caller
// broadcasts the resulting view. The guard caps a runaway loop (never
// expected).
void pumpBot(Room& r, std::mt19937& rng) {
  if (!r.vsBot || !r.game) return;
  for (int guard = 0; guard < 2000 && !r.game->isOver(); ++guard) {
    std::string js = botNextAction(*r.game, 1, rng);
    if (js.empty()) break;
    std::string ev = publicEventJson(*r.game, 1, js);  // before it is applied
    if (!applyAction(*r.game, 1, js)) break;  // safety: never spin on a reject
    r.actionLog.emplace_back(1, js);
    broadcastRoom(r,
                  ev);  // one broadcast per bot action -> step-by-step replay
  }
}

// Detach a socket from its room without closing it: cancel a waiting room, or
// end a live match and notify the opponent. The socket returns to the lobby.
void leaveRoom(int fd) {
  Client& c = g_clients[fd];
  if (c.room.empty()) return;
  auto it = g_rooms.find(c.room);
  if (it != g_rooms.end()) {
    Room& r = it->second;
    // An intentional leave forfeits the seat: drop its reconnect tokens so the
    // room (and its sessions) cannot be resumed.
    if (!r.token[0].empty()) g_sessions.erase(r.token[0]);
    if (!r.token[1].empty()) g_sessions.erase(r.token[1]);
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

// A non-empty deck must be legal before a match can use it -- the server is the
// authority, so a broken or hostile client cannot start a match with an illegal
// deck. An empty deck is the dev-sandbox path (startMatch falls back to
// demoDeck). Returns true if legal; otherwise sends joinError and the caller
// rolls back any room/seat it set up.
bool deckOk(int fd, const CardLibrary& lib,
            const std::vector<std::string>& deck) {
  if (deck.empty()) return true;
  DeckCheck dc = validateDeck(lib, deck);
  if (dc.ok) return true;
  sendJson(fd, json{{"type", "joinError"},
                    {"reason", "bad_deck"},
                    {"detail", dc.reason + ":" + dc.detail}});
  return false;
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
    r.code = code;
    r.password = pw;
    r.fd[0] = fd;
    readLoadout(j, r, 0);  // host's chosen hero + deck
    if (!deckOk(fd, lib, r.deck[0])) {
      g_rooms.erase(code);
      return;
    }
    c.phase = Phase::Waiting;
    c.room = code;
    c.seat = 0;
    sendJson(fd, json{{"type", "roomCreated"}, {"code", code}});
    std::printf("Room %s created\n", code.c_str());
    std::fflush(stdout);
  } else if (action == "createBotRoom") {
    // Single-player: no waiting room -- seat 1 is a bot, the match starts now.
    if (c.phase != Phase::Lobby) return;
    std::string code = makeCode(rng);
    Room& r = g_rooms[code];
    r.code = code;
    r.fd[0] = fd;
    r.fd[1] = -1;  // bot seat (no socket)
    r.vsBot = true;
    readLoadout(j, r, 0);  // the human's hero + deck
    std::vector<const CardDef*> nonHero;
    for (const auto& d : lib.all())
      if (d.type != CardType::Hero) nonHero.push_back(&d);
    if (j.value("mirror", false)) {
      // Mirror training: BOTH seats get the SAME freshly-generated random deck
      // and hero (the player's own pick is ignored here); only the shuffle
      // differs (the engine shuffles each seat in turn). A pure play-skill test
      // on a random deck neither side built, different every match.
      std::vector<std::string> deck =
          draftDeck(nonHero, kDeckSize, kMaxCopies, rng);
      std::vector<std::string> heroes = heroPool(lib);
      std::string hero =
          heroes.empty() ? std::string{} : heroes[rng() % heroes.size()];
      r.deck[0] = r.deck[1] = deck;
      r.hero[0] = r.hero[1] = hero;
    } else {
      // Otherwise the bot drafts its own deck like a human deckbuilder picks
      // (colour count mono 30% / 2 35% / 3 20% / 4 5% / 5 10%) rather than the
      // full pool: the demoDeck fallback is a 160-card rainbow pile it cannot
      // curve out or even cast (5 colours + uncastable pentas).
      r.deck[1] = draftDeck(nonHero, kDeckSize, kMaxCopies, rng);
    }
    if (!deckOk(fd, lib, r.deck[0])) {
      g_rooms.erase(code);
      return;
    }
    c.phase = Phase::Playing;
    c.room = code;
    c.seat = 0;
    startMatch(r, lib, rng);  // sends matchStart + first views to the human
    pumpBot(r, rng);          // the bot takes its mulligan
    broadcastRoom(r);         // reflect the post-mulligan state
    std::printf("Bot room %s started\n", code.c_str());
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
    if (!deckOk(fd, lib, r.deck[1])) {
      r.fd[1] = -1;
      return;
    }
    c.phase = Phase::Playing;
    c.room = code;
    c.seat = 1;
    g_clients[r.fd[0]].phase = Phase::Playing;
    startMatch(r, lib, rng);
  } else if (action == "leaveRoom") {
    leaveRoom(fd);
  }
}

// Reclaim a seat in a live match after a drop: look up the token, reattach this
// socket to its room+seat, and replay the current view. The client re-enters
// the match screen (matchStart) and continues from the true engine state.
void handleResume(int fd, const json& j) {
  Client& c = g_clients[fd];
  if (c.phase != Phase::Lobby) return;  // only from a fresh lobby socket
  const std::string token = j.value("token", std::string{});
  auto sit = g_sessions.find(token);
  Room* r = nullptr;
  int seat = -1;
  std::string code;
  if (sit != g_sessions.end()) {
    code = sit->second.first;
    seat = sit->second.second;
    auto rit = g_rooms.find(code);
    if (rit != g_rooms.end() && rit->second.game)
      r = &rit->second;
    else
      g_sessions.erase(sit);  // stale token -> forget it
  }
  if (r == nullptr) {
    sendJson(fd, json{{"type", "resumeError"}, {"reason", "no_session"}});
    return;
  }
  if (r->fd[seat] >= 0) {  // seat still occupied -- do not hijack a live player
    sendJson(fd, json{{"type", "resumeError"}, {"reason", "seat_active"}});
    return;
  }
  r->fd[seat] = fd;
  c.phase = Phase::Playing;
  c.room = code;
  c.seat = seat;
  if (!roomHasDetachedHuman(*r)) r->disconnectAt = 0;
  sendJson(fd, json{{"type", "matchStart"}, {"token", token}});
  sendAll(fd, ws::textFrame(viewJson(*r->game, seat)));
  int other = r->fd[1 - seat];
  if (other >= 0) sendType(other, "opponentResumed");
  std::printf("Resume: seat %d back in room %s\n", seat, code.c_str());
  std::fflush(stdout);
}

// Non-destructive resume check: is `token` a seat this client can reclaim right
// NOW -- room still live AND its seat currently detached? Lets the client show
// "resume" only when it would actually work. Requiring a DETACHED seat also
// means a stale/foreign token for a seat still held by its player reports false
// (so a shared-storage token mix-up shows no button and cannot hijack).
void handleCanResume(int fd, const json& j) {
  const std::string token = j.value("token", std::string{});
  bool ok = false;
  auto sit = g_sessions.find(token);
  if (sit != g_sessions.end()) {
    auto rit = g_rooms.find(sit->second.first);
    const int seat = sit->second.second;
    if (rit != g_rooms.end() && rit->second.game && rit->second.fd[seat] < 0)
      ok = true;
  }
  sendJson(fd, json{{"type", "canResume"}, {"ok", ok}});
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
  if (action == "resume") {
    handleResume(fd, j);
    return;
  }
  if (action == "canResume") {
    handleCanResume(fd, j);
    return;
  }
  if (action == "createRoom" || action == "createBotRoom" ||
      action == "joinRoom" || action == "leaveRoom") {
    handleLobby(fd, j, lib, rng);
    return;
  }
  Client& c = g_clients[fd];
  if (c.phase != Phase::Playing || c.room.empty()) return;
  auto it = g_rooms.find(c.room);
  if (it == g_rooms.end() || !it->second.game) return;
  // Annotate the move BEFORE applying (a play/awaken resolves its card id while
  // the card is still in hand / the mana row), then record it for the replay.
  std::string ev = publicEventJson(*it->second.game, c.seat, payload);
  bool applied = applyAction(*it->second.game, c.seat, payload);
  if (applied) {
    it->second.actionLog.emplace_back(c.seat, payload);
    broadcastRoom(it->second, ev);  // show the actor's move, then...
    // Single-player: the bot plays out its turn, one broadcast per action, so
    // the human watches it step by step (pumpBot broadcasts internally).
    if (it->second.vsBot) pumpBot(it->second, rng);
  } else {
    broadcastRoom(it->second);  // rejected: plain resync, no event
  }
  if (applied && it->second.game->isOver()) dumpReplay(c.room, it->second);
}

// A socket dropped (close/EOF/error). During a LIVE match the seat only
// detaches -- the room, game and tokens survive so the player can reconnect
// within the grace window; the opponent is told to wait. A lobby/waiting socket
// (nothing to resume) just cancels its room as before.
void dropClient(int fd) {
  auto cit = g_clients.find(fd);
  if (cit != g_clients.end() && !cit->second.room.empty()) {
    const int seat = cit->second.seat;
    auto rit = g_rooms.find(cit->second.room);
    if (rit != g_rooms.end() && rit->second.playing && rit->second.game) {
      Room& r = rit->second;
      if (seat == 0 || seat == 1) r.fd[seat] = -1;
      r.disconnectAt = std::time(nullptr);
      const int other = (seat == 0) ? r.fd[1] : r.fd[0];
      if (other >= 0) sendType(other, "opponentDisconnected");
      std::printf("Seat %d dropped from room %s (grace %ds)\n", seat,
                  r.code.c_str(), kReconnectGraceSec);
    } else {
      leaveRoom(fd);  // lobby/waiting: cancel, nothing to resume
    }
  }
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

    // 1s timeout so the loop wakes to sweep expired reconnect grace windows
    // even when no socket is active.
    if (poll(fds.data(), static_cast<nfds_t>(fds.size()), 1000) < 0) break;

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

    // Reconnect grace GC: a room whose human seat stayed empty past the window
    // is closed (this also bounds room memory -- the hardening item).
    const std::time_t now = std::time(nullptr);
    std::vector<std::string> expired;
    for (const auto& [code, r] : g_rooms)
      if (r.playing && r.disconnectAt != 0 && roomHasDetachedHuman(r) &&
          now - r.disconnectAt >= kReconnectGraceSec)
        expired.push_back(code);
    for (const std::string& code : expired) {
      Room& r = g_rooms[code];
      if (!r.token[0].empty()) g_sessions.erase(r.token[0]);
      if (!r.token[1].empty()) g_sessions.erase(r.token[1]);
      const int alive = (r.fd[0] >= 0) ? r.fd[0] : r.fd[1];
      if (alive >= 0) {
        sendType(alive, "opponentLeft");
        Client& oc = g_clients[alive];
        oc.phase = Phase::Lobby;
        oc.room.clear();
        oc.seat = -1;
      }
      g_rooms.erase(code);
      std::printf("Room %s closed (reconnect grace expired)\n", code.c_str());
    }
  }

  close(srv);
  return 0;
}
