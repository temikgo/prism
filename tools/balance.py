import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARDS = os.path.join(ROOT, "cards", "sample.json")

LAMBDA_MULTI = 0.5
MULTI_CAP = 1.5
STAT_HP_WEIGHT = 1.0
FLAG = 0.75

KW = {
    "pierce": lambda a, h, n: 0.4,
    "bypass": lambda a, h, n: 0.8 * (a / 3.0),
    "lingering": lambda a, h, n: 0.2,
    "regen": lambda a, h, n: 0.2 * n,
    "self_lifesteal": lambda a, h, n: 0.6 * a,
    "provoke": lambda a, h, n: 0.4 + 0.1 * h,
    "shield": lambda a, h, n: 1.2,
    "ward": lambda a, h, n: 0.6,
    "floodlight": lambda a, h, n: 0.8,
    "photosynthesis": lambda a, h, n: 0.8 * n,
    "germinate": lambda a, h, n: 0.6 * n,
    "growth": lambda a, h, n: 1.5 * n,
    "compost": lambda a, h, n: 0.7 * n,
    "spores": lambda a, h, n: 0.9 * n,
    "undergrowth": lambda a, h, n: 0.6 * n,
    "chill": lambda a, h, n: 3.5 * n,
    "delay": lambda a, h, n: -0.3 * n,
    "stealth": lambda a, h, n: 0.2,
    "split": lambda a, h, n: min(1.8, 0.4 * a + 0.5) * n,
    "awaken": lambda a, h, n: 0.3,
    "decoy": lambda a, h, n: 0.2 * n,
    "ambush": lambda a, h, n: 0.5,
    "refract": lambda a, h, n: 0.6,
    "haunt": lambda a, h, n: min(1.5, 0.45 * a + 0.2),
    "spectral_shift": lambda a, h, n: 0.0,
    "umbra": lambda a, h, n: 0.0,
    "clairvoyance": lambda a, h, n: 0.0,
    "palette": lambda a, h, n: 0.0,
    "facet": lambda a, h, n: 0.0,
    "lighteater": lambda a, h, n: 0.0,
}

EFF = {
    "damage": lambda v: 0.7 * v,
    "damage_all": lambda v: 2.0 * v,
    "freeze": lambda v: 1.0 * v,
    "blind": lambda v: 1.2 * v,
    "flash": lambda v: 2.8 * v,
    "draw": lambda v: 1.5 * v,
    "destroy": lambda v: 4.0,
    "dispel": lambda v: 0.8,
    "scry": lambda v: 0.4 * v,
    "scatter": lambda v: 1.8,
    "mirage": lambda v: 1.8,
    "add_crystal": lambda v: 1.5 * v,
}


def cost(card):
    c = card.get("cost", {})
    generic = c.get("generic", 0)
    pips = sum(v for k, v in c.items() if k != "generic")
    mana = generic + pips
    ncolors = len(card.get("color", []))
    multi = min(MULTI_CAP, LAMBDA_MULTI * max(0, ncolors - 1))
    return mana + multi, mana, ncolors


def power(card):
    atk = card.get("stats", {}).get("atk", 0)
    hp = card.get("stats", {}).get("hp", 0)
    parts = {}
    if card["type"] == "creature":
        parts["stats"] = (atk + STAT_HP_WEIGHT * hp - 1) / 2.0
    for kw in card.get("keywords", []):
        kid = kw["id"]
        n = kw.get("n", 1)
        if kid == "resonance":
            # Resonance snapshots +n/+n per crystal at summon. On curve you hold
            # ~mana crystals when you play it, so it adds ~n*mana of stats -- which
            # is why a high-cost resonance body is a bomb. Cannot be a flat coeff.
            c = card.get("cost", {})
            mana = c.get("generic", 0) + sum(v for k, v in c.items() if k != "generic")
            parts["kw:resonance"] = float(n * mana)
            continue
        fn = KW.get(kid)
        if fn is None:
            parts["?" + kid] = 0.0
        else:
            parts["kw:" + kid] = fn(atk, hp, n)
    for eff in card.get("effects", []):
        a = eff["action"]
        v = eff.get("value", 0)
        fn = EFF.get(a)
        key = "eff:" + a
        val = fn(v) if fn else 0.0
        parts[key] = parts.get(key, 0.0) + val
    return sum(parts.values()), parts


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else CARDS
    cards = json.load(open(path, encoding="utf-8"))
    rows = []
    for card in cards:
        if card["type"] == "hero":
            continue
        c, mana, ncolors = cost(card)
        p, parts = power(card)
        r = p - c
        rows.append((r, card, p, c, mana, ncolors, parts))
    rows.sort(key=lambda x: x[0], reverse=True)
    print(f"{'card':<26}{'type':<9}{'M':>3} {'C':>5} {'P':>6} {'R':>6}  parts")
    print("-" * 100)
    for r, card, p, c, mana, ncolors, parts in rows:
        flag = " <<<" if abs(r) > FLAG else ""
        ps = " ".join(f"{k}={v:+.1f}" for k, v in parts.items() if abs(v) > 0.01)
        print(f"{card['id']:<26}{card['type']:<9}{mana:>3} {c:>5.1f} {p:>6.1f} {r:>+6.1f}{flag:<4}  {ps}")
    vals = [r for r, *_ in rows]
    mean = sum(vals) / len(vals)
    var = sum((x - mean) ** 2 for x in vals) / len(vals)
    flagged = sum(1 for v in vals if abs(v) > FLAG)
    print("-" * 100)
    print(f"n={len(vals)}  meanR={mean:+.2f}  sd={var ** 0.5:.2f}  flagged(|R|>{FLAG})={flagged}")


if __name__ == "__main__":
    main()
