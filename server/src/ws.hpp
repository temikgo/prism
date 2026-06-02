#pragma once
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// A tiny, dependency-free WebSocket (RFC 6455) helper: the opening handshake
// plus text-frame encode/decode. Enough for a local game server talking to a
// Godot/browser client; no TLS, no fragmentation, no extensions. Server frames
// are sent unmasked; client frames arrive masked and are unmasked here.

namespace prism::ws {

inline void sha1(const unsigned char* data, size_t len, unsigned char out[20]) {
  uint32_t h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476,
           h4 = 0xC3D2E1F0;
  std::vector<unsigned char> msg(data, data + len);
  uint64_t ml = static_cast<uint64_t>(len) * 8;
  msg.push_back(0x80);
  while (msg.size() % 64 != 56) msg.push_back(0x00);
  for (int i = 7; i >= 0; --i) msg.push_back((ml >> (8 * i)) & 0xFF);
  for (size_t chunk = 0; chunk < msg.size(); chunk += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i)
      w[i] = (msg[chunk + 4 * i] << 24) | (msg[chunk + 4 * i + 1] << 16) |
             (msg[chunk + 4 * i + 2] << 8) | (msg[chunk + 4 * i + 3]);
    for (int i = 16; i < 80; ++i) {
      uint32_t v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = (v << 1) | (v >> 31);
    }
    uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
    for (int i = 0; i < 80; ++i) {
      uint32_t f, k;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      uint32_t t = ((a << 5) | (a >> 27)) + f + e + k + w[i];
      e = d;
      d = c;
      c = (b << 30) | (b >> 2);
      b = a;
      a = t;
    }
    h0 += a;
    h1 += b;
    h2 += c;
    h3 += d;
    h4 += e;
  }
  uint32_t hs[5] = {h0, h1, h2, h3, h4};
  for (int i = 0; i < 5; ++i) {
    out[4 * i] = (hs[i] >> 24) & 0xFF;
    out[4 * i + 1] = (hs[i] >> 16) & 0xFF;
    out[4 * i + 2] = (hs[i] >> 8) & 0xFF;
    out[4 * i + 3] = hs[i] & 0xFF;
  }
}

inline std::string base64(const unsigned char* data, size_t len) {
  static const char* tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  int val = 0, bits = -6;
  for (size_t i = 0; i < len; ++i) {
    val = (val << 8) | data[i];
    bits += 8;
    while (bits >= 0) {
      out.push_back(tbl[(val >> bits) & 0x3F]);
      bits -= 6;
    }
  }
  if (bits > -6) out.push_back(tbl[((val << 8) >> (bits + 8)) & 0x3F]);
  while (out.size() % 4) out.push_back('=');
  return out;
}

// The Sec-WebSocket-Accept value for a given client key (RFC 6455 §4.2.2).
inline std::string acceptKey(const std::string& clientKey) {
  std::string s = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  unsigned char digest[20];
  sha1(reinterpret_cast<const unsigned char*>(s.data()), s.size(), digest);
  return base64(digest, 20);
}

// Parse the HTTP upgrade request; on success fill `response` with the 101
// reply.
inline bool handshake(const std::string& request, std::string& response) {
  std::string lower = request;
  for (char& c : lower) c = static_cast<char>(::tolower(c));
  const std::string h = "sec-websocket-key:";
  size_t p = lower.find(h);
  if (p == std::string::npos) return false;
  p += h.size();
  while (p < request.size() && (request[p] == ' ' || request[p] == '\t')) ++p;
  size_t end = request.find("\r\n", p);
  if (end == std::string::npos) return false;
  std::string key = request.substr(p, end - p);
  response =
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: " +
      acceptKey(key) + "\r\n\r\n";
  return true;
}

enum class Op {
  Continuation = 0x0,
  Text = 0x1,
  Binary = 0x2,
  Close = 0x8,
  Ping = 0x9,
  Pong = 0xA,
  Incomplete = 0xFF
};

struct Frame {
  Op op = Op::Incomplete;
  std::string payload;
  size_t consumed = 0;  // bytes used from the buffer (0 if incomplete)
};

// Try to parse one frame from the front of `buf` (client frames are masked).
inline Frame parse(const std::string& buf) {
  Frame f;
  if (buf.size() < 2) return f;
  auto b = reinterpret_cast<const unsigned char*>(buf.data());
  uint8_t opcode = b[0] & 0x0F;
  bool masked = b[1] & 0x80;
  uint64_t len = b[1] & 0x7F;
  size_t pos = 2;
  if (len == 126) {
    if (buf.size() < pos + 2) return f;
    len = (b[pos] << 8) | b[pos + 1];
    pos += 2;
  } else if (len == 127) {
    if (buf.size() < pos + 8) return f;
    len = 0;
    for (int i = 0; i < 8; ++i) len = (len << 8) | b[pos + i];
    pos += 8;
  }
  unsigned char mask[4] = {0, 0, 0, 0};
  if (masked) {
    if (buf.size() < pos + 4) return f;
    for (int i = 0; i < 4; ++i) mask[i] = b[pos + i];
    pos += 4;
  }
  if (buf.size() < pos + len) return f;
  std::string payload(len, '\0');
  for (uint64_t i = 0; i < len; ++i)
    payload[i] = static_cast<char>(b[pos + i] ^ (masked ? mask[i % 4] : 0));
  f.op = static_cast<Op>(opcode);
  if (f.op == Op::Incomplete) f.op = Op::Continuation;
  f.payload = std::move(payload);
  f.consumed = pos + len;
  return f;
}

// Build a server frame (unmasked) of the given opcode.
inline std::string frame(Op op, const std::string& payload) {
  std::string f;
  f.push_back(static_cast<char>(0x80 | static_cast<uint8_t>(op)));
  size_t n = payload.size();
  if (n < 126) {
    f.push_back(static_cast<char>(n));
  } else if (n <= 0xFFFF) {
    f.push_back(126);
    f.push_back(static_cast<char>((n >> 8) & 0xFF));
    f.push_back(static_cast<char>(n & 0xFF));
  } else {
    f.push_back(127);
    for (int i = 7; i >= 0; --i)
      f.push_back(static_cast<char>((n >> (8 * i)) & 0xFF));
  }
  f += payload;
  return f;
}

inline std::string textFrame(const std::string& s) {
  return frame(Op::Text, s);
}

}  // namespace prism::ws
