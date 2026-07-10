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
#   2b. HUMANOIDS ARE ALLOWED, SPARINGLY, AND ALWAYS ANCHORED. A human figure is
#      fine when it is the CLEAREST read of the name (a "Sower" sowing beats any
#      beast), but a BARE humanoid renders as a realistic painted person and
#      breaks the flat light-line look -- so always anchor it: "drawn as flat
#      glowing <colour> light-lines, not a realistic painted person". Keep them
#      the minority of the set (most cards read fine as beasts/spirits/plants);
#      never let recognizability lose to a no-humanoid reflex -- rule 10 wins.
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
#   6. NO LIMB COUNTS, SIMPLE POSES. Never number body parts ("one leg",
#      "six legs" -- MJ miscounts and draws extras). Prefer a side or
#      three-quarter view and one clear action, no tangle of thin overlapping
#      limbs; describe colour asymmetry as left/right, never "one wing ...
#      the other".
#   7. SPELL/AURA: NEVER NAME THE EFFECT'S TARGET. "at the enemy", "a lone
#      figure", "sealing the enemy line", "toward the caster's hand" -- MJ
#      draws that being (usually as a person) instead of the phenomenon.
#      Stage the phenomenon on neutral scenery (ground, stones, ice, reeds,
#      sky) with a visible SOURCE and DIRECTION, so the event reads without
#      a victim in frame. Creature-card bystanders follow the same idea:
#      shields and beasts, never defenders/soldiers/figures.
#   8. NO NEGATION IN THE PROMPT BODY. "no creature or person", "never blue"
#      -- MJ sees the token and draws it. Bans live ONLY in --no (the wrapper
#      owns them); the subject must simply not contain the word.
#   9. PHENOMENA ONLY IN PROVEN TEMPLATES -- no freeform compositions. Every
#      spell/aura subject must be one of:
#        T1 ground event: a crack/wave/sheet/front moving ACROSS dark ground,
#           source and direction visible (crimson rift).
#        T2 column: a bolt/column/beam from the sky DOWN to one impact point
#           on a plain (wrath of pyrrhus).
#        T3 prop protagonist: one concrete inanimate thing doing one thing
#           (well, window, curtain, sheaf, pillar, standing stone).
#      NEVER: sky-wide formless light ("the sky itself burning"), a bare
#      glowing disc overhead (reads as a UFO), light with nothing concrete
#      in frame. Also avoid the word "spell" in subjects (summons a caster);
#      call it a bolt/curse/beam.
#      The template must SERVE the name, never replace it (a sun card keeps
#      its sun). Name-concepts get their strong graphic archetype: a sun is
#      a SUNBURST (white-hot core + a full crown of rays in every direction,
#      never a bare disc); an eclipse is a BLACK SUN ringed by a thin corona.
#  11. NO SIZE WORDS ON THE MAIN SUBJECT. Opening with "a tiny/small X" makes
#      MJ render X small in the canvas -- few pixels, sketch-level detail
#      (fought the wrapper's "filling the frame" and lost). Convey smallness
#      by CONTRAST (a far larger fish looming behind) or context ("small
#      against the dark"), and put the subject itself "in sharp close-up".
#  10. BIJECTION TEST. Given all 198 arts and all 198 names, a player must be
#      able to match them 1:1. So every subject carries ONE unique visual key
#      = the name's noun, literally in frame ("Drums of War" shows a drum --
#      made of light if the material is banned); a species/archetype appears
#      at most once per colour; recurring motifs (a copy beside its owner,
#      lurking among crystals, a hedge, a puffball, receding water) must
#      differ by species AND pose. If the NAME itself cannot be staged
#      recognisably, RENAME the card (the name serves the art; mechanics are
#      untouchable). Mechanic adjectives stay banned in names.

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

# STYLE LOCK. MJ v7 drifts between flat-2D and 3D/realistic renders, and its
# aesthetic prior leaks blue into non-blue cards. Two defences layered here:
#   (1) --s 25 in FLAGS. Stylize defaults to 100 and is exactly where the blue
#       "MJ look" sneaks in; near-zero stylize follows the prompt literally and
#       keeps colours true. Also no mood-grading words in the wrapper (dropped
#       "moody" -- it graded backgrounds teal).
#   (2) PER-COLOUR STYLE ANCHORS -- the true lock. A single shared --sref was
#       rejected: a style reference transfers its own palette, so one anchor
#       poisons every other colour. Per-colour anchors turn that into the fix:
#       each card references an anchor of ITS OWN colour, so the palette pull
#       reinforces the card's colour instead of fighting it; duals reference
#       BOTH parents' anchors and MJ blends them evenly (= the two-colour mix
#       we want). Style stays uniform because all five anchors come from the
#       same series.
#       Bootstrap (once): for each colour, generate cards with the bare prompt
#       until ONE comes out perfect (red/blue can start from the best existing
#       art in client-godot/art/); in MJ copy that image's URL and paste it
#       into ANCHORS below; rerun this script. Cards of a colour whose anchor
#       is still "" just get no --sref until it is filled in.
#       Tuning: anchor colour overpowering the subject -> lower ANCHOR_SW to
#       50; style still drifting to 3D -> raise toward 300.
ANCHORS = {
    "red": "https://cdn.midjourney.com/711297ce-fa4e-41e0-bb6d-2f5ad22834f3/0_0.png",
    "yellow": "https://cdn.midjourney.com/429fedec-2bf5-4763-9dbc-bb408d8acb80/0_0.png",
    "green": "https://cdn.midjourney.com/72a0fa5e-72e4-49fc-ad9a-ebe820c8ed4a/0_0.png",
    "blue": "https://cdn.midjourney.com/0ae56907-7024-42fd-b4fd-4195d1da1a97/0_2.png",
    "violet": "https://cdn.midjourney.com/ea7d4479-235d-4b0b-a318-455d63f5ee1a/0_2.png",
}
ANCHOR_SW = 100


def _sref(cols):
    urls = [ANCHORS[c] for c in cols if ANCHORS.get(c, "")]
    if not urls or len(cols) >= 5:
        return ""
    return " --sref " + " ".join(urls) + " --sw " + str(ANCHOR_SW)

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
    "tracing its shape, one single creature with a clean readable silhouette "
    "in a simple uncluttered pose, "
)
EFFECT_HEAD = (
    "a " + _FLAT + " of a pure {g}light phenomenon, the subject rendered in "
    "bold {g}light and {g}energy alone, "
)
TAIL = (
    ", on a deep dark flat background of swirling {g}energy in the same palette "
    "with drifting {g}light-motes, clean and graphic, the subject large and "
    "centered, filling the frame"
)
EFFECT_TAIL = (
    ", on a deep dark flat background of swirling {g}energy in the same palette "
    "with drifting {g}light-motes, clean and graphic with crisp fine linework, "
    "one clear event with a visible source and direction, framed from a middle "
    "distance, the whole scene readable at a glance"
)
HERO_STYLE = (
    "a " + _FLAT + " character portrait, glowing light accents tracing the "
    "figure, faint spectrum glints, on a deep dark flat background of swirling "
    "luminous energy, centered portrait"
)
FLAGS = (
    "--ar 2:3 --v 7 --style raw --c 0 --s 25"
    + " --no border, frame, panel, text, building, architecture, photo,"
    " photorealistic, 3D, 3d render, CGI, octane render, realistic shading,"
    " volumetric lighting, depth of field, plain background, deformed,"
    " mutated, extra limbs, extra legs, fused limbs"
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
    # Colour-matched style anchors last, so the URL list terminates the --no list.
    flags = flags + _sref(cols)
    tail = EFFECT_TAIL if is_effect else TAIL
    body = head + palette(cols) + tail.format(g=g)
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
        "Единый стиль текстовым суффиксом + `--c 0 --s 25` (низкий stylize = буквальное следование",
        "промпту: меньше «синего дрейфа» и отсебятины). Палитра у каждой карты строго своя.",
        "Существа = «being of light», заклинания/ауры = «effect of light, no creature».",
        "",
        "**Калибровка (один раз, ДО массовой генерации): пер-цветовые якоря.** Общий sref на весь",
        "сет отвергнут — он тянет СВОЮ палитру во все карты. Вместо этого один эталон НА ЦВЕТ:",
        "1) для каждого из 5 цветов генери карты голым промптом, пока одна не выйдет идеальной",
        "   (красному/синему можно стартовать с лучшего готового арта из `client-godot/art/`);",
        "2) URL этих 5 картинок впиши в `ANCHORS` в `tools/build_prompts.py` и перегенери файл.",
        "Дальше каждая карта ссылается на якорь СВОЕГО цвета (перенос палитры работает за нас),",
        "двуцветки — на ОБА якоря сразу (MJ смешивает их поровну — ровно нужный микс цветов).",
        "Якорь пережимает сюжет → снижай `ANCHOR_SW` к 50; стиль уплывает в 3D → поднимай к 300.",
        "",
        "**Если конкретный арт не удался:** (1) перезапусти тот же промпт ещё раз; (2) кривые или",
        "лишние лапы — Editor → Vary Region по месту, остальное не трогая; (3) карта упорно синит",
        "или 3D — замени в её промпте `--v 7` на `--niji 7` (обвязка та же, ниджи сильнее",
        "в плоской 2D-графике и чистых линиях).",
        "",
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

    art_dir = os.path.join(ROOT, "client-godot", "art")
    have = {f[:-4] for f in os.listdir(art_dir) if f.endswith(".png")} if os.path.isdir(art_dir) else set()
    kept = []
    for b in re.split(r"(?=^## )", "\n".join(out), flags=re.M):
        if not b.startswith("## "):
            continue
        m = re.search(r"`([a-z_0-9]+)`", b.split("\n", 1)[0])
        if m and m.group(1) not in have:
            kept.append(b)
    todo = ("# ART TODO — карты без арта (" + str(len(kept)) + " шт.)\n\n"
            "Каждый блок: имя, id, путь сохранения, готовый MJ-промпт. "
            "Сохраняй PNG по строке `save:`.\n\n" + "".join(kept))
    todo_dest = os.path.join(ROOT, "ART_PROMPTS_TODO.md")
    open(todo_dest, "w", encoding="utf-8").write(todo)
    print("wrote " + todo_dest + " with " + str(len(kept)) + " prompts (no art yet)")

    issues = verify_blue(pool + TOKENS)
    if issues:
        print("blue-defence: " + str(len(issues)) + " issue(s)")
        for cid, why in issues:
            print("  - " + cid + ": " + why)
    else:
        print("blue-defence: OK (every non-blue card locked against blue)")


if __name__ == "__main__":
    main()
