#!/usr/bin/env python3
"""Render roadmap.json + git history into the interactive Pages landing.

The metaphor is the game's own: white light split into a spectrum, one hue per
work track (hues live in roadmap.json, NOT bound to the five game colours, so a
sixth track is just another ray). The landing (docs/index.html) is a zoomable
TIME-AXIS map: every git commit is a dot on its track's lane (assigned by files
touched), and the curated phases from roadmap.json sit on top as milestones.
History on the left, the "now" frontier and planned phases to the right.

Data is curated (roadmap.json) + git log; the HTML is generated -- never hand-edit.
Run: python3 tools/build_roadmap.py   ->   docs/index.html
"""

import colorsys
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "roadmap.json")
OUT_HTML = os.path.join(ROOT, "docs", "index.html")

BG = "#0c0d13"

STATUS_RU = {
    "done": "сделано",
    "active": "в работе",
    "planned": "план",
    "abandoned": "пробовали → откат",
}


def hex_of(hue, sat, light):
    r, g, b = colorsys.hls_to_rgb((hue % 360) / 360.0, light, sat)
    return f"#{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}"


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def attr(s):
    return esc(s).replace('"', "&quot;")


# ---------------------------------------------------------------------------
# Interactive landing (GitHub Pages): a zoomable TIME-AXIS map. Two layers over
# one horizontal time axis per track: every real git commit as a dot (zoom to
# separate dense clusters, hover for hash+subject) and the curated phases from
# roadmap.json as labelled milestones. History on the left, "now" frontier and
# planned phases to the right. This view exists because Pages is interactive
# (zoom/pan/hover) -- the whole point of a landing over a static README image.
# ---------------------------------------------------------------------------

LANDING_W = 1320
LAB_X = 40             # left label column
PLOT_X0 = 250          # timeline start (after the label column)
PLOT_X1 = LANDING_W - 48
FUTURE_W = 168         # width of the "план" zone, right of the now-line
NOW_X = PLOT_X1 - FUTURE_W
LTOP = 150
LDY = 118              # lane spacing on the landing


def track_of_path(p):
    if p.endswith("bot.cpp") or p.endswith("bot.hpp"):
        return "bot"
    if "balance" in p or "selfplay" in p:
        return "bot"  # self-play / balance harness is bot-vs-bot machinery
    if p.startswith("server/") or "protocol" in p or p.startswith("replays/"):
        return "server"
    if p.endswith("cards.json") or p.startswith("cards/") or p in (
            "EFFECTS.md", "ART.md"):
        return "cards"
    if p.startswith("client-godot/"):
        return "client"
    if p.startswith("engine/"):
        return "engine"
    return "infra"


def is_meta(p):
    # Docs / journal / generated meta touched by many commits (BACKLOG.md is
    # often the biggest diff) -- must NOT decide a commit's track, or e.g. a bot
    # change with a long journal entry lands in Инфра instead of Бот.
    return (p.endswith(".md") or p.startswith("docs/")
            or p.startswith("roadmap.") or p == ".gitignore" or p == "LICENSE")


def track_from_subject(s):
    # Fallback for commits that change only docs/journals (no code to score):
    # route them to the track their MESSAGE is about, so a bot-analysis journal
    # lands on Бот instead of the Инфра catch-all. Order = specific first; the
    # keywords are deliberately narrow so plain doc/chore notes stay infra.
    s = s.lower()

    def has(*ws):
        return any(w in s for w in ws)

    if has("self-play", "selfplay", "winrate", "noise floor", "crn", "gih",
           "per-card balance", "balance precision", "balance probe",
           "balance pass", "bot", "mcts", "greedy", "жадн", "determiniz",
           "детерминиз", "rollout", "puct", "lookahead", "тренировк"):
        return "bot"
    if has("websocket", "matchmak", "room manager", "replay", "реплей"):
        return "server"
    if has("app shell", "main menu", "vfx", "drag", "layout", "wordmark",
           "анимац", "screen", "экран"):
        return "client"
    if has("card-rework", "keyword set", "keyword catalog", "card pack",
           "archetype", "архетип", "re-cost", "nerf"):
        return "cards"
    if has("serialize", "сериализ", "clone", "combat", "движок"):
        return "engine"
    return None


def plural_commits(n):
    n10, n100 = n % 10, n % 100
    if n10 == 1 and n100 != 11:
        return "коммит"
    if 2 <= n10 <= 4 and not 12 <= n100 <= 14:
        return "коммита"
    return "коммитов"


def get_commits():
    """All commits (oldest first), each assigned to the track whose files it
    touched most. Returns {track_id: [{h,at,s}...]}, t_first, t_now."""
    import subprocess
    raw = subprocess.check_output(
        ["git", "log", "--no-merges", "--reverse",
         "--pretty=format:@@@%h|%at|%s", "--numstat"],
        cwd=ROOT, text=True)
    commits = []
    cur = None
    for line in raw.splitlines():
        if line.startswith("@@@"):
            h, at, s = line[3:].split("|", 2)
            cur = {"h": h, "at": int(at), "s": s, "w": {}}
            commits.append(cur)
        elif line.strip() and cur is not None:
            parts = line.split("\t")
            if len(parts) == 3:
                a, d, path = parts
                if is_meta(path):
                    continue  # journals/docs don't decide the track
                ch = (int(a) if a.isdigit() else 0) + \
                     (int(d) if d.isdigit() else 0) + 1
                t = track_of_path(path)
                cur["w"][t] = cur["w"].get(t, 0) + ch
    by_track = {}
    for c in commits:
        if c["w"]:
            t = max(c["w"], key=c["w"].get)  # code decides the track
        else:
            t = track_from_subject(c["s"]) or "infra"  # no code -> by message
        by_track.setdefault(t, []).append(c)
    at_of = {c["h"]: c["at"] for c in commits}  # phase anchor -> commit date
    t_first = min(c["at"] for c in commits)
    t_now = max(c["at"] for c in commits)
    return by_track, at_of, t_first, t_now


def render_landing_scene(data, by_track, at_of, t_first, t_now):
    import datetime
    tracks = data["tracks"]
    n = len(tracks)
    lane_y = [LTOP + i * LDY for i in range(n)]
    mid_y = sum(lane_y) / n
    lanes_bottom = lane_y[-1] + 34
    height = lanes_bottom + 108

    span = max(1, t_now - t_first)

    def xt(at):
        return PLOT_X0 + (at - t_first) / span * (NOW_X - PLOT_X0)

    def dmy(at):
        return datetime.datetime.fromtimestamp(at).strftime("%d.%m.%Y")

    s = []
    s.append('<defs>')
    s.append('<filter id="glow" x="-60%" y="-60%" width="220%" height="220%">'
             '<feGaussianBlur stdDeviation="3.2" result="b"/>'
             '<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/>'
             '</feMerge></filter>')
    s.append(f'<radialGradient id="bg" cx="14%" cy="{mid_y / height * 100:.0f}%" '
             f'r="95%"><stop offset="0%" stop-color="#16172170"/>'
             f'<stop offset="100%" stop-color="{BG}"/></radialGradient>')
    s.append('</defs>')
    s.append(f'<rect x="-2000" y="-2000" width="6000" height="6000" '
             f'fill="{BG}"/>')
    s.append(f'<rect width="{LANDING_W}" height="{height}" fill="url(#bg)"/>')

    # --- time grid: a few date ticks across the history span ---
    span_days = span / 86400.0
    step = max(1, round(span_days / 6))
    grid_top = LTOP - 40
    grid_bot = lanes_bottom
    day = 86400
    t = t_first
    while t <= t_now + 1:
        x = xt(t)
        s.append(f'<line x1="{x:.1f}" y1="{grid_top}" x2="{x:.1f}" '
                 f'y2="{grid_bot}" stroke="#ffffff" stroke-width="1" '
                 f'opacity="0.045"/>')
        s.append(f'<text x="{x:.1f}" y="{grid_top - 8}" fill="#5d6172" '
                 f'font-size="11" text-anchor="middle">'
                 f'{datetime.datetime.fromtimestamp(t).strftime("%d.%m")}</text>')
        t += step * day

    # --- now-line + future ("план") zone ---
    s.append(f'<rect x="{NOW_X}" y="{grid_top}" width="{PLOT_X1 - NOW_X}" '
             f'height="{grid_bot - grid_top}" fill="#ffffff" opacity="0.02"/>')
    s.append(f'<line x1="{NOW_X}" y1="{grid_top}" x2="{NOW_X}" y2="{grid_bot}" '
             f'stroke="#cfd3e2" stroke-width="1.4" stroke-dasharray="2 4" '
             f'opacity="0.6"/>')
    s.append(f'<text x="{NOW_X}" y="{grid_top - 8}" fill="#cfd3e2" '
             f'font-size="11.5" font-weight="600" text-anchor="middle">'
             f'сейчас</text>')
    s.append(f'<text x="{(NOW_X + PLOT_X1) / 2:.0f}" y="{grid_top - 8}" '
             f'fill="#70748a" font-size="11" text-anchor="middle" '
             f'font-style="italic">план →</text>')

    # --- per track: label, lane, commits, phase milestones ---
    for i, tr in enumerate(tracks):
        y = lane_y[i]
        hue = tr["hue"]
        bright = hex_of(hue, 0.85, 0.62)
        dim = hex_of(hue, 0.55, 0.45)
        cms = by_track.get(tr["id"], [])

        # left label column (right-aligned to the timeline start)
        s.append(f'<text x="{PLOT_X0 - 20}" y="{y - 1}" fill="{bright}" '
                 f'font-size="17" font-weight="700" text-anchor="end">'
                 f'{esc(tr["name"])}</text>')
        s.append(f'<text x="{PLOT_X0 - 20}" y="{y + 16}" fill="#7e8295" '
                 f'font-size="11.5" text-anchor="end">'
                 f'{len(cms)} {plural_commits(len(cms))}</text>')
        # a small colour cap where the lane begins, the spectrum lead-in
        s.append(f'<circle cx="{PLOT_X0}" cy="{y}" r="3" fill="{bright}" '
                 f'filter="url(#glow)"/>')
        # the lane itself
        s.append(f'<line x1="{PLOT_X0}" y1="{y}" x2="{PLOT_X1}" y2="{y}" '
                 f'stroke="{dim}" stroke-width="1.6" opacity="0.4"/>')

        # commit layer: every commit a small dot on the lane (hover for hash +
        # subject). Each done phase is anchored to a commit, so its milestone
        # marker sits right on that commit's dot.
        for c in cms:
            x = xt(c["at"])
            sub = attr(f'{c["h"]} · {dmy(c["at"])}')
            s.append(f'<g class="commit" data-label="{attr(c["s"])}" '
                     f'data-sub="{sub}">'
                     f'<circle cx="{x:.1f}" cy="{y}" r="2.1" fill="{bright}" '
                     f'opacity="0.5"/></g>')

        # phase layer: each done/abandoned milestone sits on the EXACT date of
        # the commit that delivered it ("at" hash in roadmap.json) -- so a phase
        # never floats away from its commit. Active phases sit on the now-line;
        # planned phases spread across the future zone. Label overlap is resolved
        # by vertically stacking, NOT by moving a marker off its commit's time.
        nodes = tr["nodes"]
        past = [nd for nd in nodes if nd.get("status") in
                ("done", "active", "abandoned")]
        plan = [nd for nd in nodes if nd.get("status") == "planned"]
        phases = []
        for nd in past:
            base = STATUS_RU.get(nd.get("status"), nd.get("status"))
            if nd.get("status") == "active":
                px = NOW_X
                nd["_sub"] = base
            elif nd.get("at") in at_of:
                px = xt(at_of[nd["at"]])  # on its commit's real date
                nd["_sub"] = f'{base} · {nd["at"]} · {dmy(at_of[nd["at"]])}'
            else:
                px = xt(t_now)  # done but unanchored -> at the frontier
                nd["_sub"] = base
            phases.append((nd, px))
        for j, nd in enumerate(plan):
            px = NOW_X + (j + 1) / (len(plan) + 1) * (PLOT_X1 - NOW_X)
            phases.append((nd, px))
        _draw_phases(s, phases, y, bright, dim)

    # --- legend ---
    _landing_legend(s, lanes_bottom + 52)
    return "\n".join(s), height


def _phase_shapes(nd, x, y, bright, dim):
    """Marker drawn on the lane + the label's style. The label y is chosen by the
    caller (anti-overlap stacking), so this only returns the styling."""
    st = nd.get("status", "planned")
    major = nd.get("weight", "minor") == "major"
    label = esc(nd["label"])
    if st == "active":
        parts = [f'<circle cx="{x:.1f}" cy="{y}" r="13" fill="none" '
                 f'stroke="{bright}" stroke-width="2.2" opacity="0.7" '
                 f'class="pulse"/>',
                 f'<circle cx="{x:.1f}" cy="{y}" r="7.5" fill="{bright}" '
                 f'filter="url(#glow)"/>']
        return parts, label, 13.5, "#ffffff", 700, False
    if st == "abandoned":
        r = 6.5
        parts = [f'<path d="M{x - r:.1f},{y - r} L{x + r:.1f},{y + r} '
                 f'M{x + r:.1f},{y - r} L{x - r:.1f},{y + r}" stroke="{bright}" '
                 f'stroke-width="2.2" opacity="0.7" stroke-linecap="round"/>']
        return parts, label, 12, "#a59aa0", 400, True
    if st == "done":
        r = 7 if major else 5
        parts = [f'<circle cx="{x:.1f}" cy="{y}" r="{r}" fill="{bright}" '
                 f'filter="url(#glow)"/>']
        return (parts, label, 13 if major else 11.5,
                "#e6e8f0" if major else "#aeb2c2", 700 if major else 500, False)
    r = 7 if major else 4.5  # planned
    parts = [f'<circle cx="{x:.1f}" cy="{y}" r="{r}" fill="{BG}" '
             f'stroke="{dim}" stroke-width="2" opacity="0.85"/>']
    return parts, label, 12, "#8a8ea0", 600, False


def _draw_phases(s, phases, y, bright, dim):
    """Draw a track's phase markers on the lane and stack their labels into rows
    so nearby labels never overlap. viewBox zoom scales text and gaps together,
    so overlap must be removed in the base layout -- zooming can't separate it."""
    rows = []  # right edge x of the last label placed in each stacked row
    for nd, x in sorted(phases, key=lambda t: t[1]):
        parts, label, fs, fill, weight, italic = _phase_shapes(nd, x, y, bright,
                                                               dim)
        half = len(label) * 0.3 * fs + 5  # estimated half label width + pad
        r = 0
        while r < len(rows) and x - half <= rows[r] + 8:
            r += 1
        if r == len(rows):
            rows.append(0.0)
        rows[r] = x + half
        ly = y - (18 + r * 16)
        st = nd.get("status", "planned")
        note = nd.get("note")
        sub = nd.get("_sub", STATUS_RU.get(st, st))
        out = [f'<g class="node" tabindex="0" data-label="{attr(nd["label"])}" '
               f'data-sub="{attr(sub)}"'
               + (f' data-note="{attr(note)}"' if note else '') + '>'] + parts
        if r > 0:  # leader line from the marker up to the stacked label
            out.append(f'<line x1="{x:.1f}" y1="{y - 9}" x2="{x:.1f}" '
                       f'y2="{ly + 4:.1f}" stroke="{bright}" stroke-width="1" '
                       f'opacity="0.25"/>')
        ital = ' font-style="italic"' if italic else ''
        out.append(f'<text x="{x:.1f}" y="{ly:.1f}" text-anchor="middle" '
                   f'fill="{fill}" font-size="{fs}" font-weight="{weight}"{ital}>'
                   f'{label}</text>')
        out.append('</g>')
        s += out


def _landing_legend(s, ly):
    lx = LAB_X
    s.append(f'<text x="{lx}" y="{ly - 16}" fill="#878089" font-size="12.5" '
             f'letter-spacing="2">ЛЕГЕНДА</text>')
    gh = "#aeb2c2"
    gx = lx
    items = [("done", "этап сделан"), ("active", "в работе"),
             ("planned", "план"), ("abandoned", "пробовали → откат"),
             ("commit", "коммит")]
    for st, name in items:
        if st == "done":
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="6" fill="{gh}"/>')
        elif st == "active":
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="11" fill="none" '
                     f'stroke="{gh}" stroke-width="1.6" opacity="0.7"/>')
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="6" fill="{gh}"/>')
        elif st == "planned":
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="6" fill="{BG}" '
                     f'stroke="{gh}" stroke-width="2"/>')
        elif st == "commit":
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="2.4" fill="{gh}" '
                     f'opacity="0.7"/>')
        else:
            s.append(f'<path d="M{gx + 3},{ly - 4} L{gx + 11},{ly + 4} '
                     f'M{gx + 11},{ly - 4} L{gx + 3},{ly + 4}" stroke="{gh}" '
                     f'stroke-width="1.5" opacity="0.7" stroke-linecap="round"/>')
        s.append(f'<text x="{gx + 22}" y="{ly + 5}" fill="#aab0c0" '
                 f'font-size="13.5">{esc(name)}</text>')
        gx += 70 + len(name) * 8.2


def build_landing():
    data = json.load(open(DATA, encoding="utf-8"))
    by_track, at_of, t_first, t_now = get_commits()
    inner, height = render_landing_scene(data, by_track, at_of, t_first, t_now)
    svg = (f'<svg id="map" viewBox="0 0 {LANDING_W} {height}" '
           f'xmlns="http://www.w3.org/2000/svg" '
           f'font-family="Segoe UI, Helvetica, Arial, sans-serif" '
           f'role="img" aria-label="Дерево разработки Prism">\n{inner}\n</svg>')
    total = sum(len(v) for v in by_track.values())
    html = LANDING_TMPL.format(
        title=esc(data["title"]), subtitle=esc(data["subtitle"]),
        ncommits=total, svg=svg)
    os.makedirs(os.path.dirname(OUT_HTML), exist_ok=True)
    open(OUT_HTML, "w", encoding="utf-8").write(html)
    open(os.path.join(os.path.dirname(OUT_HTML), ".nojekyll"), "w").write("")
    print(f"wrote {os.path.relpath(OUT_HTML, ROOT)} "
          f"(+ .nojekyll, {total} commits)")


LANDING_TMPL = """<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Prism — над чем идёт работа</title>
<meta name="description" content="Призма раскладывает свет в спектр — живое дерево разработки модульной онлайн-ККИ Prism.">
<style>
  :root {{ --bg:#0c0d13; --ink:#f2f3f8; --dim:#8a8ea0; }}
  * {{ box-sizing:border-box; }}
  html,body {{ margin:0; background:var(--bg); color:var(--ink);
    font-family:"Segoe UI",Helvetica,Arial,sans-serif;
    -webkit-font-smoothing:antialiased; }}
  a {{ color:inherit; }}
  @font-face {{ font-family:"Chakra Petch"; font-weight:700;
    src:url("fonts/ChakraPetch-Bold.ttf") format("truetype"); }}
  .wrap {{ max-width:1320px; margin:0 auto; padding:0 24px; }}

  header.hero {{ padding:96px 0 44px; position:relative; text-align:center; }}
  /* a soft spectral aura behind the lockup -- the game's own bloom, so the
     colour lives behind white glyphs instead of being smeared across them */
  .hero .bloom {{ position:absolute; left:50%; top:46%;
    width:min(900px,92vw); height:420px; transform:translate(-50%,-50%);
    pointer-events:none; z-index:0; opacity:.5;
    background:radial-gradient(ellipse at center,
      #ff5a6e22 0%, #ffd23f1c 26%, #46e07a1c 48%, #3aa0ff1f 70%,
      #b06bff14 86%, transparent 100%);
    filter:blur(26px); }}
  .hero .lock {{ position:relative; z-index:1; }}
  /* the in-game wordmark: Chakra Petch Bold, wide tracking, clean near-white */
  .hero h1 {{ margin:0; padding-top:.12em; font-family:"Chakra Petch",
    "Segoe UI",sans-serif; font-size:clamp(56px,12vw,150px); font-weight:700;
    letter-spacing:.10em; line-height:1.08; color:#f4f7ff;
    text-shadow:0 3px 14px #02030855, 0 0 40px #6f86ff22; }}
  .hero .lore {{ margin:14px 0 0; color:var(--dim);
    font-size:clamp(11px,1.5vw,14px); letter-spacing:.28em;
    font-weight:600; }}
  .hero .tag {{ margin:26px auto 0; max-width:680px; color:#c9ccda;
    font-size:clamp(16px,2.2vw,20px); line-height:1.55; }}

  section.map {{ padding:18px 0 40px; }}
  section.map h2 {{ font-size:25px; font-weight:700; letter-spacing:2px;
    margin:0 0 6px; }}
  section.map p.lead {{ color:#9aa0b4; font-size:15.5px; margin:0 0 20px;
    max-width:820px; line-height:1.55; }}
  .mapbox {{ position:relative; border:1px solid #16171f; border-radius:14px;
    overflow:hidden; background:#0a0b10; }}
  svg#map {{ width:100%; height:auto; display:block; cursor:grab;
    touch-action:none; }}
  svg#map.grabbing {{ cursor:grabbing; }}
  .hint {{ color:#5d6172; font-size:12.5px; margin:10px 2px 0; }}

  .pulse {{ transform-box:fill-box; transform-origin:center;
    animation:breathe 2.6s ease-in-out infinite; }}
  @keyframes breathe {{ 0%,100% {{ opacity:.3; }} 50% {{ opacity:.8; }} }}
  @media (prefers-reduced-motion:reduce) {{ .pulse {{ animation:none; }} }}

  .node {{ cursor:pointer; outline:none; }}
  .node:hover, .node:focus-visible {{ filter:brightness(1.4); }}
  .commit {{ cursor:pointer; }}
  .commit:hover circle {{ r:4; opacity:1; filter:brightness(1.5); }}

  #tip {{ position:fixed; pointer-events:none; z-index:20; opacity:0;
    transform:translateY(4px); transition:opacity .12s, transform .12s;
    background:#15161f; border:1px solid #2a2c3a; border-radius:10px;
    padding:9px 12px; max-width:280px; box-shadow:0 10px 30px #0009; }}
  #tip.on {{ opacity:1; transform:translateY(0); }}
  #tip .t {{ font-size:13.5px; font-weight:600; }}
  #tip .s {{ font-size:11.5px; margin-top:3px; color:var(--dim);
    letter-spacing:.3px; }}
  #tip .n {{ font-size:12px; margin-top:6px; color:#c5c8d6;
    font-style:italic; }}

  footer {{ border-top:1px solid #1c1d28; margin-top:24px; padding:26px 0 48px;
    color:var(--dim); font-size:13px; display:flex; flex-wrap:wrap; gap:18px;
    justify-content:space-between; }}
  footer a {{ color:#aeb2c2; text-decoration:none; }}
  footer a:hover {{ color:var(--ink); }}
</style>
</head>
<body>
<div class="wrap">
  <header class="hero">
    <div class="bloom"></div>
    <div class="lock">
      <h1>PRISM</h1>
      <p class="lore">·&nbsp; СВЕТ МЕГА-ПРИЗМЫ РАСКОЛОТ НА ПЯТЬ ЦВЕТОВ &nbsp;·</p>
    </div>
    <p class="tag">Модульная онлайн-ККИ 1v1 — мир света и спектра, где призмант
      материализует лучи Мега-Призмы в существ. Белый луч входит в призму и
      раскладывается в спектр: каждый луч — отдельный трек разработки.</p>
  </header>

  <section class="map">
    <h2>{title}</h2>
    <div class="mapbox">
      {svg}
    </div>
    <p class="hint">Колесо — зум, перетаскивание — двигать, двойной клик —
      сброс. Наведение на точку или этап — детали.</p>
  </section>

  <footer>
    <span>Призма раскладывает свет — мы раскладываем работу по трекам.</span>
    <span><a href="https://github.com/temikgo/prism">temikgo/prism</a></span>
  </footer>
</div>

<div id="tip"><div class="t"></div><div class="s"></div><div class="n"></div></div>

<script>
  // --- tooltip (shared by phase milestones and commits) ---
  var tip = document.getElementById("tip");
  var tt = tip.querySelector(".t"), ts = tip.querySelector(".s"),
      tn = tip.querySelector(".n");
  function show(e) {{
    var g = e.currentTarget;
    tt.textContent = g.getAttribute("data-label") || "";
    ts.textContent = g.getAttribute("data-sub") || "";
    var note = g.getAttribute("data-note");
    tn.textContent = note || ""; tn.style.display = note ? "block" : "none";
    tip.classList.add("on"); move(e);
  }}
  function move(e) {{
    var x = e.clientX + 14, y = e.clientY + 14;
    var w = tip.offsetWidth, h = tip.offsetHeight;
    if (x + w > innerWidth - 8) x = innerWidth - w - 8;
    if (y + h > innerHeight - 8) y = e.clientY - h - 14;
    tip.style.left = x + "px"; tip.style.top = y + "px";
  }}
  function hide() {{ tip.classList.remove("on"); }}
  document.querySelectorAll(".node, .commit").forEach(function (g) {{
    g.addEventListener("mouseenter", show);
    g.addEventListener("mousemove", move);
    g.addEventListener("mouseleave", hide);
    g.addEventListener("focus", function () {{
      var r = g.getBoundingClientRect();
      show({{ currentTarget: g, clientX: r.left + r.width / 2,
        clientY: r.top + r.height / 2 }});
    }});
    g.addEventListener("blur", hide);
  }});

  // --- pan / zoom via the SVG viewBox ---
  var svg = document.getElementById("map");
  var vb0 = svg.getAttribute("viewBox").split(" ").map(Number);
  var W0 = vb0[2], H0 = vb0[3];
  var vb = {{ x: 0, y: 0, w: W0, h: H0 }};
  function apply() {{
    svg.setAttribute("viewBox", vb.x + " " + vb.y + " " + vb.w + " " + vb.h);
  }}
  function clamp() {{
    vb.x = Math.max(0, Math.min(W0 - vb.w, vb.x));
    vb.y = Math.max(0, Math.min(H0 - vb.h, vb.y));
  }}
  svg.addEventListener("wheel", function (e) {{
    e.preventDefault();
    var r = svg.getBoundingClientRect();
    var px = vb.x + (e.clientX - r.left) / r.width * vb.w;
    var py = vb.y + (e.clientY - r.top) / r.height * vb.h;
    var f = e.deltaY < 0 ? 0.85 : 1 / 0.85;
    var nw = Math.max(W0 * 0.16, Math.min(W0, vb.w * f));
    var nh = nw * H0 / W0;
    vb.x = px - (px - vb.x) * (nw / vb.w);
    vb.y = py - (py - vb.y) * (nh / vb.h);
    vb.w = nw; vb.h = nh; clamp(); apply();
  }}, {{ passive: false }});
  var drag = false, lx = 0, ly = 0;
  svg.addEventListener("pointerdown", function (e) {{
    drag = true; lx = e.clientX; ly = e.clientY;
    svg.setPointerCapture(e.pointerId); svg.classList.add("grabbing");
  }});
  svg.addEventListener("pointermove", function (e) {{
    if (!drag) return;
    var r = svg.getBoundingClientRect();
    vb.x -= (e.clientX - lx) / r.width * vb.w;
    vb.y -= (e.clientY - ly) / r.height * vb.h;
    lx = e.clientX; ly = e.clientY; clamp(); apply();
  }});
  function endDrag() {{ drag = false; svg.classList.remove("grabbing"); }}
  svg.addEventListener("pointerup", endDrag);
  svg.addEventListener("pointercancel", endDrag);
  svg.addEventListener("dblclick", function () {{
    vb = {{ x: 0, y: 0, w: W0, h: H0 }}; apply();
  }});
</script>
</body>
</html>
"""


def build():
    build_landing()


if __name__ == "__main__":
    build()
