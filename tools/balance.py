import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARDS = os.path.join(ROOT, "cards", "sample.json")

LAMBDA_MULTI = 0.5
MULTI_CAP = 1.5
FLAG = 0.75

# Tier-1 stat model: atk valued above hp. Calibrated so a vanilla 3/2 @cost2 and
# 4/5 @cost4 land at R~=0 (the old neutral vanilla anchors -- the cards are gone,
# the calibration stays baked here as the reference vanilla curve).
# atk premium ~1.28x (a point of attack is worth more than a point of toughness
# in a tempo duel). The negative offset is implicit mana-convexity: big vanillas
# come out slightly weak, cheap ones fair. An explicit per-mana convexity knob is
# deferred to a Tier-2 self-play fit (two linear anchors can't pin it down).
W_ATK = 0.6
W_HP = 0.467
STAT_B = -0.734

KW = {
    "pierce": lambda a, h, n: 0.4,
    "bypass": lambda a, h, n: 0.8 * (a / 3.0),
    "lingering": lambda a, h, n: 0.2,
    "regen": lambda a, h, n: 0.45 * n,
    "self_lifesteal": lambda a, h, n: 0.6 * a,
    "provoke": lambda a, h, n: 0.4 + 0.1 * h,
    "shield": lambda a, h, n: 1.15 + 0.07 * (a + h),
    "ward": lambda a, h, n: 0.6,
    "floodlight": lambda a, h, n: 0.8,
    # Green de-snowball via STEEPER per-n slopes (these keywords' value is linear in
    # n, so the slope is what was under-priced -- a higher-n card must be nerfed
    # proportionally more, not by a flat constant). Magnitudes by self-play beta:
    # photosynthesis(ramp) and undergrowth read fair -> untouched; compost (top, +4.0)
    # steepest, then spores, then germinate/growth. N itself is never reduced.
    "photosynthesis": lambda a, h, n: 0.8 * n,
    "germinate": lambda a, h, n: 1.1 * n,
    "growth": lambda a, h, n: 2.0 * n,
    "compost": lambda a, h, n: 1.5 * n,
    "spores": lambda a, h, n: 1.25 * n,
    "undergrowth": lambda a, h, n: 0.95 * n,
    "chill": lambda a, h, n: 3.0 * n,
    # delay is priced AFTER the effects in power(): a delayed effect must be
    # (1+N)x an immediate one to be fair, so it is worth E/(1+N). The flat -0.3*n
    # here badly under-priced a brutal downside. Captured below, not in this loop.
    "delay": lambda a, h, n: 0.0,
    "stealth": lambda a, h, n: 0.2,
    "split": lambda a, h, n: min(2.4, 0.55 * a + 0.6) * n,
    "awaken": lambda a, h, n: 0.3,
    "decoy": lambda a, h, n: 0.2 * n,
    "refract": lambda a, h, n: 0.6,
    "haunt": lambda a, h, n: min(1.5, 0.45 * a + 0.2),
    # Set-v2 keywords (Tier-1 anchors; self-play beta is the real arbiter).
    "incandescence": lambda a, h, n: 2.2 * n,   # aura: +n atk to your whole board
    "cauterize": lambda a, h, n: 0.5 * a,       # combat dmg heals your hero
    "sear": lambda a, h, n: 0.5 * n,            # on death: n to enemy hero
    "spark": lambda a, h, n: 0.9 * n,           # active reach, repeatable
    "firststrike": lambda a, h, n: 0.4 + 0.12 * a,
    "strobe": lambda a, h, n: 0.6 * a,          # attacks twice
    "flare": lambda a, h, n: 0.4 * n,           # on death: blind n random
    "mulch": lambda a, h, n: 0.6,               # aura: heal a wounded ally each turn
    "haze": lambda a, h, n: 0.7 * n,            # aura: enemy spells cost +n
    # Blue control keywords valued below worth (under-extracted in greedy play),
    # see the EFF note: the discount is paid back to the card as stats.
    "birefringence": lambda a, h, n: 0.3,       # your targeted spells fork
    "pinpoint": lambda a, h, n: 0.3,            # spell dmg ignores shield/ward
    "brittle": lambda a, h, n: 0.4,             # frozen enemy shatters on any damage
    "lens": lambda a, h, n: 0.3,                # first spell each turn +1
    "glimmer": lambda a, h, n: 0.5,             # aura: first summon each turn stealthed
    "spectral_shift": lambda a, h, n: 0.0,
    "palette": lambda a, h, n: 0.0,
    "facet": lambda a, h, n: 0.0,
    "lighteater": lambda a, h, n: 0.0,
}

EFF = {
    "damage": lambda v: 0.7 * v,
    # Blue control effects are valued BELOW their theoretical worth: greedy play
    # (and the bot) under-extract tempo control, so the model credits them less
    # and the saved cost is handed back as stats -- a deliberate control premium
    # that lands blue near the rest of the field in self-play.
    "freeze": lambda v: 0.6 * v,
    "blind": lambda v: 1.2 * v,
    "draw": lambda v: 1.5 * v,
    "destroy": lambda v: 4.0,
    "dispel": lambda v: 1.5 if v == 0 else 0.8 * v,
    "scry": lambda v: 0.25 * v,
    "scatter": lambda v: 1.1,
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
    delay_n = 0
    if card["type"] == "creature":
        parts["stats"] = W_ATK * atk + W_HP * hp + STAT_B
    for kw in card.get("keywords", []):
        kid = kw["id"]
        n = kw.get("n", 1)
        if kid == "delay":
            delay_n = n  # priced after the effects (discounts the gated effect)
            continue
        if kid == "resonance":
            # Resonance snapshots +n/+n per crystal at summon. A pure n*mana slope
            # (assuming ~mana crystals on curve) overstated dear bodies and badly
            # understated cheap ones -- yet self-play shows resonance(1) winning
            # ~the same (66-71%) at 3/4/6 mana: a cheap body lives longer and keeps
            # growing as you ramp, offsetting its smaller start. So the curve is
            # shallow, not proportional. The old base (n*(0.7*mana+1.8)) read every
            # resonance(1) body at +1.5 R -- but 66-71% is a payoff, not "broken";
            # a flatter n*(0.5*mana+0.6) lands resonance(1) near fair while a cheap
            # body still scores a touch above a dear one.
            c = card.get("cost", {})
            mana = c.get("generic", 0) + sum(v for k, v in c.items() if k != "generic")
            # De-snowball resonance (top green overperformer: amber_grub +4.8,
            # geode_toad +2.5 pp, also audit-flagged). Its value scales with the
            # card's OWN mana, so steepening the mana slope makes raising the cost
            # raise the value -> uncostable runaway. So bump the per-n CONSTANT
            # (0.6 -> 1.0) and let the re-cost shrink the body (stats), keeping the
            # gentle 0.5 mana slope so the card stays costable.
            parts["kw:resonance"] = float(n * (0.5 * mana + 1.0))
            continue
        fn = KW.get(kid)
        if fn is None:
            parts["?" + kid] = 0.0
        else:
            parts["kw:" + kid] = fn(atk, hp, n)
    eff_total = 0.0
    for eff in card.get("effects", []):
        a = eff["action"]
        v = eff.get("value", 0)
        sel = eff.get("selector", "")
        fn = EFF.get(a)
        key = "eff:" + a
        val = fn(v) if fn else 0.0
        # AoE multiplier: the EFF table prices single-target; a board-wide
        # selector hits ~2-3 bodies, so it is worth much more (a 4-to-all wipe is
        # not a 4-to-one bolt). Without this the formula badly under-rates wipes.
        if sel in ("all_creatures", "all_enemies"):
            val *= 2.4
        parts[key] = parts.get(key, 0.0) + val
        eff_total += val
    # Blue delay: the effect fires N turns late -- a brutal downside. A delayed
    # effect must be (1+N)x an immediate one to be fair, so it is worth E/(1+N);
    # the shortfall E*N/(1+N) is the delay penalty, shown as its own term.
    if delay_n > 0 and eff_total != 0.0:
        parts["kw:delay"] = -eff_total * delay_n / (1 + delay_n)
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
