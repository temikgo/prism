# Deploy Prism (web client + game server)

Goal: anyone opens `https://your-domain` and plays in the browser. Caddy serves
the exported Godot web client over HTTPS and proxies WebSocket traffic to the C++
game server. The web build is single-threaded, so no cross-origin-isolation
(COOP/COEP) headers are needed.

Two paths, same Caddyfile:
- **Docker Compose (recommended)** — one `docker compose up`, server builds in a
  container. Portable to any VM or Docker host. ← start here.
- **Bare VM (systemd)** — build natively, run as a systemd service. Lighter on a
  tiny box; more manual.

## What you need (your part)
- A VM: any Ubuntu 22.04+ box (1 vCPU / 1 GB is plenty). Note its public IP.
- A hostname with an **A record** pointing at that IP (Caddy gets TLS for it).

### Free option (recommended for "let everyone try it")
No monthly cost:
- **VM: Oracle Cloud Always Free** — a genuinely always-free Ubuntu VM (AMD
  E2.1.Micro, or ARM Ampere). Crucially **10 TB/mo egress** — the web build is
  ~180 MB per first load, so generous egress matters. (Google Cloud's free
  e2-micro only has ~1 GB/mo egress → exhausted in a handful of loads; avoid for a
  shared build.) Oracle signup needs a card for verification but never charges for
  always-free; ARM capacity can be flaky, AMD is usually available.
- **Hostname: DuckDNS** (free `name.duckdns.org`) pointed at the VM's public IP.
  (Or a cheap real domain.)
- **Serving the 180 MB client:** Caddy on the same VM serves it directly — no
  separate static host, so no per-file size limits (GitHub/Cloudflare Pages reject
  the 152 MB `.pck`). One free VM does everything: TLS + client + wss proxy + server.

Open the VM's ports **80 + 443** in Oracle's security list (and `sudo ufw allow
80,443/tcp` on the box).

---

## 1. Export the web client (local machine)
The export preset `Web` is committed (`client-godot/export_presets.cfg`). With the
4.3 export templates installed:
```
cd client-godot
.godot-bin/Godot_v4.3-stable_linux.x86_64 --headless --path . --export-release "Web" .web-export/index.html
```
Output lands in `client-godot/.web-export/` (index.html + .wasm + .pck + loader).
This folder is gitignored (152 MB), so it travels to the VM out of band — see the
upload step below.

## 2A. Docker Compose path (recommended)
On the VM:
```
sudo apt update && sudo apt install -y docker.io docker-compose-v2 git rsync
sudo usermod -aG docker $USER && newgrp docker      # run docker without sudo
git clone <repo> ~/prism && cd ~/prism
cp deploy/.env.example deploy/.env
# edit deploy/.env -> PRISM_DOMAIN=your.duckdns.org
```
Get the exported client onto the VM at `client-godot/.web-export/` (from your
**local** machine, where you ran the export):
```
rsync -avz client-godot/.web-export/ USER@VM_IP:~/prism/client-godot/.web-export/
```
Then bring it up:
```
cd ~/prism
docker compose -f deploy/docker-compose.yml up -d --build
```
Caddy fetches the TLS cert on the first request. Open `https://your-domain` — the
client auto-connects to `wss://your-domain/ws` (no manual address needed).

Updating:
- **Client:** re-export locally, `rsync` again, `docker compose ... restart caddy`
  (or nothing — Caddy serves the mounted files live).
- **Server:** `git pull && docker compose -f deploy/docker-compose.yml up -d --build prism`.

Logs / status: `docker compose -f deploy/docker-compose.yml logs -f`.
Replays land in the `prism-replays` named volume.

## 2B. Bare VM path (systemd, alternative)
Build + install the server:
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
systemd service:
```
sudo cp deploy/prism-server.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now prism-server
sudo systemctl status prism-server      # active (running)
```
Caddy (the same Caddyfile; defaults target 127.0.0.1:8080 + /var/www/prism). Set
the domain via an env file for the caddy unit, or just export it before reload:
```
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile
sudo sed -i 's/prism.example.com/your.duckdns.org/' /etc/caddy/Caddyfile
sudo systemctl reload caddy
```
Upload the exported client to `/var/www/prism/` (rsync from local, as above).
Update server: rebuild, `sudo cp build/server/prism_server /opt/prism/ && sudo systemctl restart prism-server`.

---

## Local production-mirror (test without a VM)
`deploy/local_serve.py` serves the export + proxies `/ws` to a local server on one
port — exactly what the deploy does, so you can click the URL and play locally.
```
./build/server/prism_server 8080 cards/sample.json      # terminal 1
python3 deploy/local_serve.py                            # terminal 2
# open http://127.0.0.1:8231/
```

## Notes
- The server is one process for many private rooms; a restart drops live matches.
- Firewall: open 80 + 443 (Caddy). The server port is never exposed — only Caddy
  reaches it (the `prism` service has no published port in compose; 8080 stays
  localhost-only in the systemd path).
- Single-threaded web build → no special headers; works behind any CDN/proxy.
