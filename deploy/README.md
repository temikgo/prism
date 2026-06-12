# Deploy Prism (web client + game server)

Goal: anyone opens `https://your-domain` and plays in the browser. One small VPS
runs the C++ game server; Caddy serves the exported Godot web client over HTTPS and
proxies WebSocket traffic to the server. The web build is single-threaded, so no
cross-origin-isolation (COOP/COEP) headers are needed.

## What you need (your part)
- A VPS: any Ubuntu 22.04+ box (1 vCPU / 1 GB is plenty). Note its IP.
- A domain (or subdomain). Point an **A record** at the VPS IP and wait for it to
  propagate. Caddy will get the TLS cert automatically.

### Free option (recommended for "let everyone try it")
Everything below works on a free, always-on box -- no monthly cost:
- **VM: Oracle Cloud Always Free.** A genuinely always-free Ubuntu VM (AMD
  E2.1.Micro, or ARM Ampere). Crucially it gives **10 TB/mo egress** -- the web
  build is ~180 MB per first load, so a generous egress matters. (Google Cloud's
  free e2-micro only has ~1 GB/mo egress -> exhausted in ~5 downloads; avoid for a
  shared build.) Oracle signup needs a card for verification but never charges for
  always-free; capacity for ARM can be flaky, AMD is usually available.
- **Hostname: DuckDNS** (free `name.duckdns.org`). Point it at the VM's public IP;
  Caddy gets a free Let's Encrypt cert for it. (Or a cheap real domain if you want.)
- **Hosting the 180 MB client:** Caddy on the same VM serves it directly -- no
  separate static host, so no per-file size limits (GitHub/Cloudflare Pages reject
  the 152 MB .pck). One free VM does everything: TLS + client + wss proxy + server.

The steps below are identical for the free box -- just use the Oracle VM + the
DuckDNS hostname in the Caddyfile. Open the VM's ports 80 + 443 in Oracle's
security list (and `ufw allow 80,443` on the box).

## 1. Export the web client (local machine)
The export preset `Web` is committed (`client-godot/export_presets.cfg`). With the
4.3 export templates installed:
```
cd client-godot
.godot-bin/Godot_v4.3-stable_linux.x86_64 --headless --path . --export-release "Web" .web-export/index.html
```
Output lands in `client-godot/.web-export/` (index.html + .wasm + .pck + loader).
Upload that folder's contents to the VPS at `/var/www/prism/`.

## 2. Build + install the server (on the VPS)
```
sudo apt update && sudo apt install -y build-essential cmake caddy git
git clone <repo> /tmp/prism && cd /tmp/prism
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j

sudo useradd --system --home /opt/prism --shell /usr/sbin/nologin prism || true
sudo mkdir -p /opt/prism/cards /var/www/prism
sudo cp build/server/prism_server /opt/prism/
sudo cp cards/sample.json /opt/prism/cards/
sudo chown -R prism:prism /opt/prism
```

## 3. systemd service
```
sudo cp deploy/prism-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now prism-server
sudo systemctl status prism-server   # should be active (running)
```

## 4. Caddy (TLS + static + wss proxy)
Edit `deploy/Caddyfile`: replace `prism.example.com` with your domain. Then:
```
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```
Caddy fetches the cert on first request. Open `https://your-domain` — the client
auto-connects to `wss://your-domain/ws` (no manual address needed on web).

## Updating
- Client: re-export, re-upload `/var/www/prism/`.
- Server: rebuild, `sudo cp build/server/prism_server /opt/prism/ && sudo systemctl restart prism-server`.

## Notes
- Match action logs (replays) are written to `/opt/prism/replays/`.
- The server is one process for many private rooms; restart drops live matches.
- Firewall: open 80 + 443 (Caddy); the server's 8080 stays localhost-only.
