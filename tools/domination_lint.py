import sys

import _common

COLOR_ORDER = ["red", "yellow", "green", "blue", "violet"]

# Keyword Ns where SMALLER is better: decoy N wakes free after N turns banked,
# delay N fires after N turns -- fewer turns is strictly stronger. A naive
# bigger-N-wins comparison would call "decoy 1" worse than "decoy 2".
INVERTED_N = {"decoy", "delay"}

# Effect actions that can be a COST the caster pays, not a payoff. Only the
# value-less form is a pure rider cost (Sheaf: sacrifice + draw 2); with a value
# the sacrifice IS the engine (Wake: N damage per body) and compares as a payoff.
COST_ACTIONS = {"sacrifice"}


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


def kw_at_least(nb, na, kid):
    return nb <= na if kid in INVERTED_N else nb >= na


def kw_strictly_more(nb, na, kid):
    return nb < na if kid in INVERTED_N else nb > na


def dominates(b, a):
    """True if card b is at least as good as a on every axis and strictly
    better on at least one -- so a is a dead duplicate nobody picks over b."""
    if b.get("type") != a.get("type"):
        return False
    # Cost domination is per-COLOUR, not just total mana + colour-set: b is only
    # "at least as easy to cast" if it demands no more of ANY single colour AND no
    # more mana overall. Otherwise a deeper-but-cheaper card (3 red vs 2 red + 2
    # generic) looks dominating on totals while actually being harder to splash.
    bcost, acost = b.get("cost", {}) or {}, a.get("cost", {}) or {}
    bp = {c: int(bcost.get(c, 0)) for c in COLOR_ORDER}
    ap = {c: int(acost.get(c, 0)) for c in COLOR_ORDER}
    if any(bp[c] > ap[c] for c in COLOR_ORDER):
        return False  # b needs more of some colour -> not easier to cast
    if mv(b) > mv(a):
        return False  # b costs more mana overall -> not dominating
    sb, sa = b.get("stats") or {}, a.get("stats") or {}
    if int(sb.get("atk", 0)) < int(sa.get("atk", 0)):
        return False
    if int(sb.get("hp", 0)) < int(sa.get("hp", 0)):
        return False
    kb, ka = kw_map(b), kw_map(a)
    for kid, n in ka.items():
        if kid not in kb or not kw_at_least(kb[kid], n, kid):
            return False  # b lacks a keyword a carries (or weaker N)
    eb, ea = eff_map(b), eff_map(a)
    for key, v in ea.items():
        if key[0] in COST_ACTIONS and v == 0:
            continue  # a's pure rider cost is a drawback; b not having it is fine
        if key not in eb or eb[key] < v:
            return False  # b lacks an effect a carries (or weaker value)
    for key, v in eb.items():
        if key[0] in COST_ACTIONS and v == 0 and key not in ea:
            return False  # b pays a cost a does not -> not at least as good

    strict = (
        mv(b) < mv(a)
        or any(bp[c] < ap[c] for c in COLOR_ORDER)
        or int(sb.get("atk", 0)) > int(sa.get("atk", 0))
        or int(sb.get("hp", 0)) > int(sa.get("hp", 0))
        or set(kb) > set(ka)
        or any(kw_strictly_more(kb[k], ka.get(k, 0), k) for k in kb if k in ka)
        or set(eb) > set(ea)
        or any(eb[k] > ea.get(k, 0) for k in eb if k[0] not in COST_ACTIONS)
    )
    return strict


def main():
    cards = _common.load_cards()
    pool = [c for c in _common.nonhero(cards) if len(c.get("color", [])) < 5]

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
