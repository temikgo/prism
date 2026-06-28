import json
import os
import re
import sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT = os.path.join(ROOT, "cards", "sample.json")

CATALOG = {
    "red": ["pierce", "bypass", "regen", "self_lifesteal", "incandescence", "cauterize", "sear", "spark"],
    "yellow": ["floodlight", "blind", "provoke", "shield", "ward", "firststrike", "strobe", "flare"],
    "green": ["photosynthesis", "germinate", "growth", "compost", "spores", "undergrowth", "resonance", "mulch"],
    "blue": ["freeze", "chill", "delay", "scry", "scatter", "haze", "birefringence", "pinpoint"],
    "violet": ["awaken", "decoy", "stealth", "refract", "split", "mirage", "haunt", "glimmer"],
}
KW_COLOR = {kw: col for col, kws in CATALOG.items() for kw in kws}

# Catalog properties realised as inline actions (effects[].action) rather than a
# keyword chip. The rest are realised as keywords[].id.
ACTION_KW = {"blind", "freeze", "scry", "scatter", "mirage"}

HERO_KW = {"spectral_shift", "lighteater", "palette", "facet", "clairvoyance", "dawnlight", "halo"}

# Bespoke penta (5-colour) keywords: legal vocabulary, but outside the catalog so
# they do NOT count toward the 4x density (card_kw_instances only sums KW_COLOR).
PENTA_KW = {"echo", "mirror", "vanguard"}

ALLOWED_ACTIONS = {"freeze", "blind", "damage", "destroy", "draw", "dispel", "scry", "scatter", "mirage"}
ALLOWED_SELECTORS = {"enemy_hero", "chosen_enemy_minion", "chosen_friendly_minion",
                     "chosen_any_minion", "all_enemies", "all_creatures",
                     "chosen_enemy_aura"}
COLORLESS_ACTIONS = {"damage", "destroy", "draw", "dispel"}  # never colour a card

TARGET = 4
COLOR_ORDER = ["red", "yellow", "green", "blue", "violet"]


def card_kw_instances(card):
    """Set of catalog keywords this card carries (as a colour property)."""
    out = set()
    for kw in card.get("keywords", []):
        kid = kw.get("id")
        if kid in KW_COLOR:
            out.add(kid)
    for eff in card.get("effects", []):
        a = eff.get("action")
        if a in ACTION_KW and a in KW_COLOR:
            out.add(a)
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    cards = json.load(open(path, encoding="utf-8"))
    errors = []
    counts = Counter()          # keyword -> total instances
    per_tier = defaultdict(Counter)
    ids = set()

    for c in cards:
        cid = c.get("id", "<no id>")
        if cid in ids:
            errors.append(f"duplicate id: {cid}")
        ids.add(cid)
        typ = c.get("type")
        if typ == "hero":
            continue
        colors = c.get("color", [])
        ncol = len(colors)
        tier = {0: "colorless", 1: "mono", 2: "bicolor", 5: "penta"}.get(ncol, f"{ncol}-color")
        kws = card_kw_instances(c)

        # R13: legal vocabulary
        for kw in c.get("keywords", []):
            kid = kw.get("id")
            if kid not in KW_COLOR and kid not in HERO_KW and kid not in PENTA_KW:
                errors.append(f"{cid}: unknown keyword '{kid}'")
        for eff in c.get("effects", []):
            a = eff.get("action")
            if a not in ALLOWED_ACTIONS:
                errors.append(f"{cid}: illegal action '{a}'")
            sel = eff.get("selector")
            if sel is not None and sel not in ALLOWED_SELECTORS:
                errors.append(f"{cid}: illegal selector '{sel}'")
            if eff.get("trigger") not in (None, "on_play"):
                errors.append(f"{cid}: non-on_play trigger '{eff.get('trigger')}'")

        # id prefix
        if ncol == 1 and not cid.startswith(colors[0] + "_"):
            errors.append(f"{cid}: mono id must start with '{colors[0]}_'")
        if ncol == 2:
            pref = "_".join(sorted(colors, key=COLOR_ORDER.index)) + "_"
            if not cid.startswith(pref):
                errors.append(f"{cid}: bicolor id must start with '{pref}'")
        if ncol == 5 and not cid.startswith("prismatic_"):
            errors.append(f"{cid}: penta id must start with 'prismatic_'")

        # colour identity (R3)
        if ncol == 0:
            if kws:
                errors.append(f"{cid}: colorless card carries colour keyword(s) {kws}")
            for eff in c.get("effects", []):
                a = eff.get("action")
                if a in COLORLESS_ACTIONS or a is None:
                    continue
                errors.append(f"{cid}: colorless card carries coloured action '{a}'")
        elif ncol in (1, 2):
            kw_colors = {KW_COLOR[k] for k in kws}
            for col in colors:
                if col not in kw_colors:
                    errors.append(f"{cid}: {tier} missing a {col} keyword (carries {sorted(kws)})")

        for k in kws:
            counts[k] += 1
            per_tier[tier][k] += 1

    # clones (R5): identical full package. Pentas are bespoke stubs whose
    # uniqueness lives in their engine effect, not the JSON, so two empty
    # 5-colour stubs that happen to share a cost are not real clones -- exempt
    # them here exactly as the near-dup check below does.
    seen = {}
    for c in cards:
        if c.get("type") == "hero" or len(c.get("color", [])) >= 5:
            continue
        sig = json.dumps({
            "type": c.get("type"), "color": sorted(c.get("color", [])),
            "cost": c.get("cost"), "stats": c.get("stats"),
            "keywords": sorted(json.dumps(k, sort_keys=True) for k in c.get("keywords", [])),
            "effects": sorted(json.dumps(e, sort_keys=True) for e in c.get("effects", [])),
        }, sort_keys=True)
        if sig in seen:
            errors.append(f"clone: {c['id']} == {seen[sig]}")
        seen[sig] = c["id"]

    # near-duplicates (uniqueness rule): two cards that share type, colour,
    # keywords (incl. N), effects and stats, differing ONLY by cost -- one
    # strictly dominates the other. A boring duplicate even though not a full
    # clone. Stats differentiate creatures, so this mostly catches auras/spells.
    nseen = {}
    for c in cards:
        # pentas are bespoke stubs (uniqueness lives in their engine effect, not
        # the JSON), so empty 5-colour stubs are exempt from the near-dup rule.
        if c.get("type") == "hero" or len(c.get("color", [])) >= 5:
            continue
        sig = json.dumps({
            "type": c.get("type"), "color": sorted(c.get("color", [])),
            "stats": c.get("stats"),
            "keywords": sorted(json.dumps(k, sort_keys=True) for k in c.get("keywords", [])),
            "effects": sorted(json.dumps(e, sort_keys=True) for e in c.get("effects", [])),
        }, sort_keys=True)
        if sig in nseen:
            errors.append(f"near-duplicate (differ only by cost): {c['id']} ~ {nseen[sig]}")
        nseen[sig] = c["id"]

    # name reflection: every significant word of a card's EN name must be echoed
    # in its art subject, so the picture actually depicts the name (no "Vampire
    # Moth" drawn as a plain moth, no "Thick Fog" without fog). Applies to
    # creatures, spells and auras. Pentas are bespoke stubs (no art subject yet),
    # heroes exempt.
    NAME_STOP = {"of", "the", "a", "an", "and", "to", "in", "on", "with", "at", "its", "it"}

    def nwords(s):
        return [w for w in re.findall(r"[a-z']+", s.lower()) if w not in NAME_STOP]

    def nstem(w):
        return w.rstrip("s") if len(w) > 4 else w

    for c in cards:
        if c.get("type") not in ("creature", "spell", "aura") or len(c.get("color", [])) >= 5:
            continue
        en = (c.get("name") or {}).get("en", "")
        art = c.get("art", "").lower()
        artw = {nstem(w) for w in nwords(art)}
        for w in nwords(en):
            s = nstem(w)
            if s not in artw and not any(s in a or a in s for a in artw):
                errors.append(f"{c['id']}: name word '{w}' not reflected in art")

    # report
    n = len([c for c in cards if c.get("type") != "hero"])
    print(f"cards (non-hero): {n}")
    tiers = Counter()
    for c in cards:
        if c.get("type") == "hero":
            continue
        tiers[len(c.get("color", []))] += 1
    print("tiers:", {("colorless" if k == 0 else f"{k}c"): v for k, v in sorted(tiers.items())})
    print()
    off = []
    for col in COLOR_ORDER:
        print(f"  {col}")
        for kw in CATALOG[col]:
            t = counts[kw]
            mark = "" if t == TARGET else f"   <-- {t} (want {TARGET})"
            print(f"    {kw:16} {t}{mark}")
            if t != TARGET:
                off.append((kw, t))
    print()
    if errors:
        print(f"STRUCTURE ERRORS ({len(errors)}):")
        for e in errors:
            print("  -", e)
    else:
        print("structure: OK")
    if off:
        print(f"\nDENSITY off-target: {len(off)} keyword(s) != {TARGET}")
    else:
        print("density: every keyword == 4  OK")
    sys.exit(1 if errors or off else 0)


if __name__ == "__main__":
    main()
