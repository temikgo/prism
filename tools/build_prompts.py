import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# === HOW TO WRITE A CARD'S `art` FIELD (so MJ nails it first try) ===
# The wrapper below adds style + palette + flags; the `art` field is the SUBJECT.
# These are the rules that caught us out -- follow them when authoring `art`:
#   1. CONCRETE SUBJECT FIRST. Open with the thing being drawn, not mood.
#   2a. CREATURE = A CONCRETE BEING, NEVER A PHENOMENON. A creature card must name
#      a thing-that-lives: beast / spirit / wisp / sprite / treant / elemental /
#      construct. A phenomenon or object subject ("a ripple", "a gleam", "a grove",
#      "a battering-ram", "a collapsing star") gives MJ no creature, so it invents
#      a random one (a ripple -> a jellyfish). Phenomena/objects are ONLY for
#      spells and auras. Order: design mechanics -> name from them -> art from name.
#   2b. NO BARE HUMANOID -> REALISM. A humanoid subject ("a sovereign", "a knight")
#      renders as a realistic painted person and breaks the flat light-line look.
#      Prefer non-humanoids; if a figure is unavoidable, anchor it: "drawn as flat
#      glowing light-lines, not a realistic painted person".
#   3. MULTICOLOR = WEAVE EVERY COLOUR INTO THE SUBJECT, BALANCED. One colour's
#      imagery silently dominates (frost/rime/mist=blue, fire/ember=red,
#      bloom=green) and the palette line does NOT fix it -- the SUBJECT words set
#      the colour ratio. Name each colour's element explicitly and say "in equal
#      measure, neither dominant".
#   4. NO ABSTRACT JARGON AS THE SUBJECT. "mycelium", "oblivion", "resonance"
#      don't render recognizably -- spell out the visual (threads + mushroom-caps
#      + spore-clouds; an unmaking ray erasing a form into motes).
#   5. ONE CORE IMAGE. Don't cram every keyword's flavour in; pick the defining
#      visual so name <-> art <-> mechanic read as one subject.

TONE = {
    "red": "red and crimson",
    "yellow": "gold and amber",
    "green": "lime green and grass green",
    "blue": "deep blue and cyan",
    "violet": "violet and purple",
}

# One source of truth for each colour's shades. A fixed single tone made every
# card of a colour look identical; instead a mono card may use ANY shade of its
# colour (varies freely, not tied to its theme; art style stays locked).
#   RANGE (positive) -- offered to the card so its hue varies within the colour.
#   NEG   (negative)  -- the SAME shades, fed to --no for the OTHER four colours
#                        so glow/"light" can't leak in (a glow renders cyan on a
#                        green card otherwise). Both come from SHADES, so they
#                        stay symmetric -- every shade we allow for X we also
#                        forbid for non-X.
SHADES = {
    "red": ["red", "scarlet", "crimson", "ember-orange", "vermilion", "blood-red"],
    "yellow": ["gold", "amber", "bronze", "honey", "dawn-gold", "white-gold"],
    "green": ["green", "lime", "emerald", "jade", "moss", "forest green"],
    "blue": ["blue", "cyan", "azure", "teal", "steel-blue", "navy"],
    "violet": ["violet", "purple", "lilac", "magenta", "amethyst", "ultraviolet"],
}
RANGE = {c: "any shade of " + s[0] + ", freely varied -- " + ", ".join(s[1:])
         for c, s in SHADES.items()}
# Base colour word for --no. The real colour lock is binding every "light /
# energy / glow" word to the card's colour (see GLOW below) -- without that, a
# long --no list does nothing, because MJ's positive "glowing luminous energy"
# renders blue and a soft --no can't override it. So --no stays short.
NEG = {c: s[0] for c, s in SHADES.items()}

# STYLE LOCK. MJ v7 drifts between flat-2D and 3D/realistic renders. The reliable
# cure for "some come out 3D, some 2D" is a STYLE REFERENCE: generate one card you
# love, copy its image URL, and set STYLE_REF below to ' --sref <url>' (keep the
# leading space). Every prompt then inherits that exact look. Until then the text
# below leans hard on flat-2D, but --sref is what truly locks it.
STYLE_REF = ""

# Flat-2D vocabulary, repeated so it wins over v7's default realism. NO "energy
# given form" / "depth" (those invite volumetric 3D).
_FLAT = (
    "flat 2D illustration, bold clean thick ink outlines, cel-shaded with flat "
    "colour fills, graphic poster art, no shading gradients, no 3D"
)
# {g} is the card's GLOW colour ("green ", "rainbow ", ...) bound onto every
# light/energy word, so the luminous look can't default to blue on a non-blue
# card. This binding -- not --no -- is what actually locks the colour.
CREATURE_HEAD = (
    "a " + _FLAT + " of a being made of living {g}light, glowing {g}light-lines "
    "tracing its shape, "
)
EFFECT_HEAD = (
    "a " + _FLAT + " of glowing {g}light, the subject rendered in bold {g}light "
    "and {g}energy, no creature or person, "
)
TAIL = (
    ", on a deep moody flat background of swirling {g}energy in the same palette "
    "with drifting {g}light-motes, clean and graphic, the subject large and "
    "centered, filling the frame"
)
HERO_STYLE = (
    "a " + _FLAT + " character portrait, glowing light accents tracing the "
    "figure, faint spectrum glints, on a deep moody flat background of swirling "
    "luminous energy, centered portrait"
)
FLAGS = (
    "--ar 2:3 --v 7 --style raw --c 0" + STYLE_REF
    + " --no border, frame, panel, text, building, architecture, photo,"
    " photorealistic, 3D, 3d render, CGI, octane render, realistic shading,"
    " volumetric lighting, depth of field, plain background"
)
EFFECT_FLAGS = FLAGS + ", creature, character, person, figure, monster, animal, face"
HERO_FLAGS = FLAGS.replace("--ar 2:3", "--ar 1:1")

TOKENS = [
    {
        "id": "token_sprout",
        "name": {"ru": "Росток"},
        "color": ["green"],
        "type": "creature",
        "art": "a tiny fresh sprout of green light, two small unfurling leaves rising, soft motes of pollen-light drifting upward",
    },
]


def palette(colors):
    if not colors:
        return "a clean monochrome palette of pure bright neutral white and soft pale grey, crisp neutral white, no other hue"
    if len(colors) >= 5:
        return "the full spectrum in balanced rainbow, every colour of light, none dominant"
    if len(colors) == 1:
        return "a palette of " + RANGE[colors[0]] + ", and no other colour"
    # Multicolor: enforce balance so a colour-skewed subject can't render mono.
    tones = " and ".join(TONE[c] for c in colors)
    return ("a strict colour palette of only " + tones
            + " tones in equal measure with no colour dominant, no other colours")


def _glow(cols):
    if len(cols) == 1:
        return cols[0] + " "      # "green "
    if len(cols) >= 5:
        return "rainbow "
    if not cols:
        return "neutral white "
    # two-colour: bind BOTH colours onto every "light/energy/motes" mention.
    # An empty glow let MJ default the positive light to blue and let whichever
    # colour the subject implied dominate; naming both, evenly, is what actually
    # locks a balanced two-tone (a soft --no never could).
    return " and ".join(cols) + " "


def style_for(card):
    cols = card.get("color", [])
    g = _glow(cols)
    is_effect = card["type"] in ("spell", "aura")
    head = (EFFECT_HEAD if is_effect else CREATURE_HEAD).format(g=g)
    flags = EFFECT_FLAGS if is_effect else FLAGS
    # Colour lock for 1- and 2-colour cards: exclude every colour NOT in the
    # card's identity, plus the grey/steel tones the moody background drifts into
    # (e.g. red+yellow leaking a blue-grey). Colourless (white/silver) and penta
    # (rainbow) keep their own palettes, so they get no colour --no list.
    if len(cols) < 5:
        # Bar every hue NOT in the card's identity. Colourless (white/silver) bars
        # all five; coloured cards also bar the grey drift. Penta keeps its rainbow.
        excl = [NEG[c] for c in NEG if c not in cols]
        if cols:
            excl.append("grey")
        # Green sits next to cyan; without blue in the identity MJ drifts green
        # into teal (worst with yellow). Bar the cyan family -- but only when blue
        # is absent, so green-blue and mono-blue keep their teal.
        if "green" in cols and "blue" not in cols:
            excl += ["cyan", "teal"]
        flags = flags + ", " + ", ".join(excl)
    # NOTE: deliberately NO positive "no blue" clause. MJ does not honour negation
    # in the prompt body -- the literal token "blue" there biases TOWARD blue, so
    # earlier "never a blue background" wording actively summoned it. Blue is
    # banned only where negation works: the --no list above.
    # A card whose SUBJECT is a built structure (wall/rampart/barricade) must not
    # also --no "building, architecture" -- that fights its own subject. Drop those
    # two terms for such cards.
    if any(w in card.get("art", "").lower() for w in ("wall", "rampart", "barricade", "lighthouse", "tower")):
        flags = flags.replace("building, architecture, ", "")
    body = head + palette(cols) + TAIL.format(g=g)
    return body, flags


def entry(card, style, flags):
    art = card.get("art", "")
    if not art:
        return []
    name = card.get("name", {}).get("ru", card["id"])
    return [
        "## " + name + " — `" + card["id"] + "`",
        "save: `client-godot/art/" + card["id"] + ".png`",
        "```",
        art + ", " + style + " " + flags,
        "```",
        "",
    ]


_BLUE_RE = re.compile(r"\b(blue|cyan|teal|azure|turquoise)\b")


def verify_blue(cards):
    """Self-certify the prompt-side blue defence for every non-blue, non-penta
    card: (1) NO blue/cyan/teal word anywhere in the subject+body (negation lives
    only in --no, since the token in the body biases toward blue), (2) --no bars
    blue, (3) a green card without blue also bars cyan/teal. Returns violations so
    a regression fails loudly at generation time."""
    bad = []
    for c in cards:
        cols = c.get("color", [])
        if c.get("type") == "hero" or len(cols) >= 5 or "blue" in cols:
            continue
        body, flags = style_for(c)
        subj = (c.get("art", "") + ", " + body).lower()
        neg = flags.split("--no", 1)[1] if "--no" in flags else ""
        if _BLUE_RE.search(subj):
            bad.append((c["id"], "blue word in subject/body"))
        if "blue" not in neg:
            bad.append((c["id"], "--no missing blue"))
        if "green" in cols and ("cyan" not in neg or "teal" not in neg):
            bad.append((c["id"], "green w/o cyan+teal exclusion"))
    return bad


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "cards", "sample.json")
    pool = json.load(open(path, encoding="utf-8"))
    heroes = [c for c in json.load(open(os.path.join(ROOT, "cards", "sample.json"), encoding="utf-8")) if c["type"] == "hero"]

    out = [
        "# Prism — промпты артов (Midjourney v7)",
        "",
        "Единый стиль текстовым суффиксом + `--c 0`. Палитра у каждой карты строго своя.",
        "Существа = «being of light», заклинания/ауры = «effect of light, no creature».",
        "Вставь промпт → выбери лучший из 4 → **Download** → сохрани в путь.",
        "",
    ]
    n = 0
    out += ["## — СУЩЕСТВА —", ""]
    for c in pool:
        if c["type"] == "creature":
            s, f = style_for(c)
            out += entry(c, s, f)
            n += 1
    out += ["## — ЗАКЛИНАНИЯ И АУРЫ —", ""]
    for c in pool:
        if c["type"] in ("spell", "aura"):
            s, f = style_for(c)
            out += entry(c, s, f)
            n += 1
    out += ["## — ТОКЕНЫ —", ""]
    for c in TOKENS:
        s, f = style_for(c)
        out += entry(c, s, f)
        n += 1
    out += ["## — ГЕРОИ —", ""]
    for c in heroes:
        out += entry(c, HERO_STYLE, HERO_FLAGS)
        n += 1

    dest = os.path.join(ROOT, "ART_PROMPTS.md")
    open(dest, "w", encoding="utf-8").write("\n".join(out))
    print("wrote " + dest + " with " + str(n) + " prompts")

    issues = verify_blue(pool + TOKENS)
    if issues:
        print("blue-defence: " + str(len(issues)) + " issue(s)")
        for cid, why in issues:
            print("  - " + cid + ": " + why)
    else:
        print("blue-defence: OK (every non-blue card locked against blue)")


if __name__ == "__main__":
    main()
