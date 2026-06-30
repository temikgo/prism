import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT = os.path.join(ROOT, "cards", "sample.json")

COLOR_ORDER = ["red", "yellow", "green", "blue", "violet"]


def mv(card):
    cost = card.get("cost", {}) or {}
    return sum(int(v) for v in cost.values())


def kw_map(card):
    out = {}
    for k in card.get("keywords", []):
        out[k.get("id")] = int(k.get("n", 0))
    return out


def eff_map(card):
    out = {}
    for e in card.get("effects", []):
        key = (e.get("action"), e.get("selector"))
        out[key] = max(out.get(key, 0), int(e.get("value", 0)))
    return out


def dominates(b, a):
    """True if card b is at least as good as a on every axis and strictly
    better on at least one -- so a is a dead duplicate nobody picks over b."""
    if b.get("type") != a.get("type"):
        return False
    cb, ca = set(b.get("color", [])), set(a.get("color", []))
    if not cb <= ca:
        return False  # b needs a colour a does not -> not easier to cast
    if mv(b) > mv(a):
        return False  # b costs more -> not dominating
    sb, sa = b.get("stats") or {}, a.get("stats") or {}
    if int(sb.get("atk", 0)) < int(sa.get("atk", 0)):
        return False
    if int(sb.get("hp", 0)) < int(sa.get("hp", 0)):
        return False
    kb, ka = kw_map(b), kw_map(a)
    for kid, n in ka.items():
        if kid not in kb or kb[kid] < n:
            return False  # b lacks a keyword a carries (or weaker N)
    eb, ea = eff_map(b), eff_map(a)
    for key, v in ea.items():
        if key not in eb or eb[key] < v:
            return False  # b lacks an effect a carries (or weaker value)

    strict = (
        mv(b) < mv(a)
        or cb < ca
        or int(sb.get("atk", 0)) > int(sa.get("atk", 0))
        or int(sb.get("hp", 0)) > int(sa.get("hp", 0))
        or set(kb) > set(ka)
        or any(kb[k] > ka.get(k, 0) for k in kb)
        or set(eb) > set(ea)
        or any(eb[k] > ea.get(k, 0) for k in eb)
    )
    return strict


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    cards = json.load(open(path, encoding="utf-8"))
    pool = [c for c in cards if c.get("type") != "hero" and len(c.get("color", [])) < 5]

    dead = []
    for a in pool:
        for b in pool:
            if a is b:
                continue
            if dominates(b, a):
                dead.append((a["id"], b["id"]))
                break

    print("domination lint: %d cards (non-hero, non-penta)" % len(pool))
    if dead:
        print("STRICTLY DOMINATED (%d) -- the left card is never picked over the right:" % len(dead))
        for a, b in dead:
            print("  %-34s dominated by  %s" % (a, b))
        sys.exit(1)
    print("OK -- no strictly dominated cards")


if __name__ == "__main__":
    main()
