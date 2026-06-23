#!/usr/bin/env python3
"""Render roadmap.json into a Prism-styled development tree (roadmap.svg).

The metaphor is the game's own: a white beam enters a prism and fans into a
spectrum of rays -- one ray per work track. Tracks are NOT bound to the five game
colours; each carries its own hue along the spectrum (stored in roadmap.json), so
adding a sixth or tenth track is just another ray on the rainbow, not a broken
concept. Hue encodes the track; node STYLE encodes status:

  done       solid glowing dot
  active      bright ringed dot (the live frontier)
  planned    hollow faded dot
  abandoned  a branch that forks off the lane and dies in a dashed x
             (a tried-and-reverted dead end, e.g. the MCTS bot)

Data is curated (roadmap.json), the SVG is generated -- do not hand-edit the SVG.
Run: python3 tools/build_roadmap.py   ->   roadmap.svg
"""

import colorsys
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "roadmap.json")
OUT = os.path.join(ROOT, "roadmap.svg")

W = 1320
MARGIN_L = 60
PRISM_X = 96
LANE_X0 = 256          # where lanes (and the first node) begin
LANE_X1 = W - 96       # where lanes end
TOP_Y = 134
DY = 110               # vertical gap between track lanes
BG = "#0c0d13"


def hex_of(hue, sat, light):
    r, g, b = colorsys.hls_to_rgb((hue % 360) / 360.0, light, sat)
    return f"#{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}"


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


MAX_NODES = 9  # per-track visible cap; beyond it the oldest minor steps collapse


def visible(nodes):
    """Keep the picture bounded as work piles up: always show milestones (major,
    active, abandoned) and the most recent minor steps; fold the older minor
    steps into one "+N steps" marker at the lane start. A no-op while a track has
    <= MAX_NODES nodes (today), so it scales without changing the current look."""
    if len(nodes) <= MAX_NODES:
        return nodes
    keep = {i for i, n in enumerate(nodes)
            if n.get("weight") == "major" or n.get("status") in
            ("active", "abandoned")}
    minors = [i for i, n in enumerate(nodes) if i not in keep]
    budget = max(0, MAX_NODES - 1 - len(keep))
    recent = set(minors[-budget:]) if budget else set()
    dropped = [i for i in minors if i not in recent]
    out = []
    if dropped:
        out.append({"label": f"+{len(dropped)} шагов", "status": "collapsed",
                    "weight": "minor"})
    out += [n for i, n in enumerate(nodes) if i in keep or i in recent]
    return out


def build():
    data = json.load(open(DATA, encoding="utf-8"))
    tracks = data["tracks"]
    n = len(tracks)
    lane_y = [TOP_Y + i * DY for i in range(n)]
    mid_y = sum(lane_y) / n
    height = TOP_Y + (n - 1) * DY + 150

    s = []
    s.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" '
        f'viewBox="0 0 {W} {height}" font-family="Segoe UI, Helvetica, Arial, '
        f'sans-serif">')

    # --- defs: soft glow + the background's own faint prism bloom ---
    s.append('<defs>')
    s.append('<filter id="glow" x="-60%" y="-60%" width="220%" height="220%">'
             '<feGaussianBlur stdDeviation="3.2" result="b"/>'
             '<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/>'
             '</feMerge></filter>')
    s.append('<filter id="softglow" x="-80%" y="-80%" width="260%" '
             'height="260%"><feGaussianBlur stdDeviation="7"/></filter>')
    s.append(f'<radialGradient id="bg" cx="12%" cy="{mid_y / height * 100:.0f}%" '
             f'r="95%"><stop offset="0%" stop-color="#16172170"/>'
             f'<stop offset="100%" stop-color="{BG}"/></radialGradient>')
    s.append('</defs>')

    s.append(f'<rect width="{W}" height="{height}" fill="{BG}"/>')
    s.append(f'<rect width="{W}" height="{height}" fill="url(#bg)"/>')

    # --- header ---
    s.append(f'<text x="{MARGIN_L}" y="56" fill="#f2f3f8" font-size="30" '
             f'font-weight="700" letter-spacing="3">{esc(data["title"]).upper()}'
             f'</text>')
    s.append(f'<text x="{MARGIN_L}" y="82" fill="#8a8ea0" font-size="13.5">'
             f'{esc(data["subtitle"])}</text>')

    # --- incoming white beam + prism ---
    apex = (PRISM_X, mid_y)
    s.append(f'<line x1="{MARGIN_L - 28}" y1="{mid_y}" x2="{PRISM_X}" '
             f'y2="{mid_y}" stroke="#ffffff" stroke-width="3" opacity="0.85" '
             f'filter="url(#glow)"/>')
    # a slim glass triangle
    tri = f'{PRISM_X - 6},{mid_y - 34} {PRISM_X + 30},{mid_y} ' \
          f'{PRISM_X - 6},{mid_y + 34}'
    s.append(f'<polygon points="{tri}" fill="#ffffff" opacity="0.06"/>')
    s.append(f'<polygon points="{tri}" fill="none" stroke="#ffffff" '
             f'stroke-width="1.4" opacity="0.5"/>')
    apex = (PRISM_X + 30, mid_y)

    # --- per-track ray + lane + nodes ---
    for i, tr in enumerate(tracks):
        y = lane_y[i]
        hue = tr["hue"]
        bright = hex_of(hue, 0.85, 0.62)
        dim = hex_of(hue, 0.55, 0.42)

        # fan ray from the prism apex to the lane start
        cx = (apex[0] + LANE_X0) / 2
        s.append(f'<path d="M{apex[0]},{apex[1]} C{cx},{apex[1]} {cx},{y} '
                 f'{LANE_X0},{y}" fill="none" stroke="{bright}" '
                 f'stroke-width="2.6" opacity="0.9" filter="url(#glow)"/>')
        # the lane itself
        s.append(f'<line x1="{LANE_X0}" y1="{y}" x2="{LANE_X1}" y2="{y}" '
                 f'stroke="{dim}" stroke-width="2" opacity="0.5"/>')
        # track name
        s.append(f'<text x="{LANE_X0}" y="{y - 16}" fill="{bright}" '
                 f'font-size="15.5" font-weight="700">{esc(tr["name"])}</text>')

        nodes = visible(tr["nodes"])
        k = len(nodes)
        x0, x1 = LANE_X0 + 40, LANE_X1 - 14
        for j, nd in enumerate(nodes):
            x = x0 + (x1 - x0) * (j / max(1, k - 1))
            st = nd.get("status", "planned")
            major = nd.get("weight", "minor") == "major"
            label = esc(nd["label"])
            if st == "collapsed":  # folded older minor steps: a faint "⋯ +N"
                for d in (-5, 0, 5):
                    s.append(f'<circle cx="{x + d}" cy="{y}" r="1.7" '
                             f'fill="{dim}" opacity="0.7"/>')
                s.append(f'<text x="{x}" y="{y + 22}" fill="#70748a" '
                         f'font-size="9.5" text-anchor="middle" '
                         f'opacity="0.7">{label}</text>')
                continue
            if st == "abandoned":
                # a pruned branch: forks down off the lane, dies in a dashed x
                by = y + 30
                s.append(f'<path d="M{x},{y} C{x},{y + 18} {x - 4},{by - 6} '
                         f'{x},{by}" fill="none" stroke="{bright}" '
                         f'stroke-width="1.6" stroke-dasharray="3 3" '
                         f'opacity="0.45"/>')
                r = 6
                s.append(f'<circle cx="{x}" cy="{by}" r="{r}" fill="none" '
                         f'stroke="{bright}" stroke-width="1.6" opacity="0.5"/>')
                s.append(f'<path d="M{x - 3.5},{by - 3.5} L{x + 3.5},{by + 3.5} '
                         f'M{x + 3.5},{by - 3.5} L{x - 3.5},{by + 3.5}" '
                         f'stroke="{bright}" stroke-width="1.5" opacity="0.6"/>')
                s.append(f'<text x="{x}" y="{by + 22}" fill="#9a8f96" '
                         f'font-size="11" text-anchor="middle" '
                         f'font-style="italic">{label}</text>')
                note = nd.get("note")
                if note:
                    s.append(f'<text x="{x}" y="{by + 36}" fill="#6f6a72" '
                             f'font-size="10" text-anchor="middle" '
                             f'font-style="italic">{esc(note)}</text>')
                continue

            # on-lane node, styled by STATUS x WEIGHT. Major = a labelled
            # milestone (big glow); minor = a small step (tiny dot, faint small
            # label). So a card nerf never looks as weighty as the game loop.
            if st == "active":  # the live frontier -- always prominent + ringed
                s.append(f'<circle cx="{x}" cy="{y}" r="14" fill="none" '
                         f'stroke="{bright}" stroke-width="2" opacity="0.7"/>')
                s.append(f'<circle cx="{x}" cy="{y}" r="8.5" fill="{bright}" '
                         f'filter="url(#glow)"/>')
                lab_fill, lab_size, lab_op, lab_w = "#ffffff", 12.5, "1", "600"
            elif st == "done":
                if major:
                    s.append(f'<circle cx="{x}" cy="{y}" r="8" fill="{bright}" '
                             f'filter="url(#glow)"/>')
                    lab_fill, lab_size, lab_op, lab_w = "#dadce5", 12.5, "1", "600"
                else:
                    s.append(f'<circle cx="{x}" cy="{y}" r="3.6" '
                             f'fill="{dim}"/>')
                    lab_fill, lab_size, lab_op, lab_w = "#9094a3", 9.5, "0.7", "400"
            else:  # planned
                r = 7 if major else 3.2
                s.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{BG}" '
                         f'stroke="{dim}" stroke-width="2" '
                         f'opacity="{0.9 if major else 0.6}"/>')
                if major:
                    lab_fill, lab_size, lab_op, lab_w = "#8a8ea0", 12, "0.95", "600"
                else:
                    lab_fill, lab_size, lab_op, lab_w = "#70748a", 9.5, "0.6", "400"
            ty = y + (26 if major or st == "active" else 22)
            s.append(f'<text x="{x}" y="{ty}" fill="{lab_fill}" '
                     f'font-size="{lab_size}" font-weight="{lab_w}" '
                     f'text-anchor="middle" opacity="{lab_op}">{label}</text>')

    # --- legend ---
    ly = TOP_Y + (n - 1) * DY + 78
    lx = MARGIN_L
    leg = [("done", "сделано"), ("active", "в работе"), ("planned", "план"),
           ("abandoned", "пробовали → откат")]
    s.append(f'<text x="{lx}" y="{ly - 16}" fill="#6f6a72" font-size="11" '
             f'letter-spacing="2">СТАТУС</text>')
    gx = lx
    gh = "#aeb2c2"
    for st, name in leg:
        if st == "done":
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="6" fill="{gh}"/>')
        elif st == "active":
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="11" fill="none" '
                     f'stroke="{gh}" stroke-width="1.6" opacity="0.7"/>')
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="6" fill="{gh}"/>')
        elif st == "planned":
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="6" fill="{BG}" '
                     f'stroke="{gh}" stroke-width="2"/>')
        else:
            s.append(f'<circle cx="{gx + 7}" cy="{ly}" r="6" fill="none" '
                     f'stroke="{gh}" stroke-width="1.6" stroke-dasharray="3 3" '
                     f'opacity="0.6"/>')
            s.append(f'<path d="M{gx + 3.5},{ly - 3.5} L{gx + 10.5},{ly + 3.5} '
                     f'M{gx + 10.5},{ly - 3.5} L{gx + 3.5},{ly + 3.5}" '
                     f'stroke="{gh}" stroke-width="1.4" opacity="0.6"/>')
        s.append(f'<text x="{gx + 22}" y="{ly + 4}" fill="#9a9ead" '
                 f'font-size="12">{esc(name)}</text>')
        gx += 60 + len(name) * 7.2

    s.append('</svg>')
    out = "\n".join(s) + "\n"
    open(OUT, "w", encoding="utf-8").write(out)
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({len(tracks)} tracks, "
          f"{height}px tall)")


if __name__ == "__main__":
    build()
