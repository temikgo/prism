# Deploy Prism (web client + game server)

Goal: anyone opens `https://your-domain` and plays in the browser. One small VPS
runs the C++ game server; Caddy serves the exported Godot web client over HTTPS and
proxies WebSocket traffic to the server. The web build is single-threaded, so no
cross-origin-isolation (COOP/COEP) headers are needed.

## What you need (your part)
- A VPS: any Ubuntu 22.04+ box, ~$4–6/mo (1 vCPU / 1 GB is plenty). Note its IP.
- A domain (or subdomain). Point an **A record** at the VPS IP and wait for it to
  propagate. Caddy will get the TLS cert automatically.

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
