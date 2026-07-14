import hashlib
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
#      TOOLS A FIGURE HOLDS MUST BE SIMPLE AND MADE OF LIGHT (a crook, a
#      hand-plough of pure light, a banner of shadow). NEVER realistic
#      machinery -- tractors, combines, engines, gears, vehicles: machines and
#      the light-world are incompatible ("wooden plough" rendered farm
#      machinery). Light-tech only.
#   3. MULTICOLOR = EACH COLOUR EARNS ITS PLACE BY ITS MEANING, NOT AT RANDOM.
#      The failure isn't "the body is two colours" -- a body CAN be two-toned
#      (ice crusting a mushroom-body, embers glowing through a stone hide). The
#      failure is a colour that's there for no reason, or one colour silently
#      taken over by the subject noun (a "frost X" going all-blue, a "bloom X"
#      all-green) so the second colour never appears. Fix: give EACH of the
#      card's colours a concrete carrier that MAKES SENSE for that colour, and
#      make sure BOTH are actually visible in the frame. The colour vocabulary:
#        - red    = fire / heat / embers / molten / cinders / a burning glow
#        - yellow = light / sun / dawn-gold / lightning / rays / radiance
#        - green  = living growth -- moss, leaves, vines, reeds, sprouts, bark
#        - blue   = water / ice / frost / rime / snow / cold
#        - violet = shadow / dusk / gloom / crystal / the void
#      Read the creature's nature to decide HOW each colour attaches: a frost
#      creature is naturally ice-bodied, so green comes as moss/reeds it wears or
#      trails; a treant is naturally wood-bodied, so blue comes as frost rimacross
#      its bark. Either colour may sit on the body or around it -- what matters is
#      the pairing is logical and neither colour goes missing. A subject noun that
#      screams one colour (frost/rime/ember/bloom) needs the OTHER colour given an
#      explicit, sensible home or MJ drops it. (Floodlord: ice-blue whale body,
#      green reeds as its mane -- both present, both logical.)
#      ANALOGOUS PAIRS (yellow+green, red+yellow) BLUR TO ONE HUE IF INTERMIXED.
#      Neighbouring colours on the wheel (gold light shining THROUGH green leaves)
#      average into lime/chartreuse and the boundary vanishes -- so the card reads
#      as one colour, unlike a contrasting pair (red+blue). Best mitigation in the
#      SUBJECT text: keep each colour on its own distinct part (a green canopy up
#      top, a gold trunk below), NOT one colour glowing/veined/haloed/threaded/
#      woven through the other -- those words are the trap. verify_intermix() warns
#      on them. (NB a palette-side "two solid zones" wrapper fix was tried and
#      reverted: it did not measurably improve renders and bloated the prompt.)
#      verify_both_colours() below warns when a two-colour art shows no carrier
#      word for one of its colours (that colour will render missing).
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
#  12. A CREATURE SUBJECT MUST HAVE A BODY MJ CAN DRAW. Two killers, seen live
#      (Floodlord rendered as a wave):
#        a. VAGUE CREATURE NOUNS (leviathan / colossus / titan / behemoth /
#           giant / spirit / wisp / being) carry no anatomy -- always pair them
#           with a body plan ("whale-bodied leviathan", "bull-shaped giant",
#           "its horned head and massive arms clearly drawn").
#        b. A BODY MADE OF A FLOWING ELEMENT ("of surging floodwater", "woven
#           from whitewater", "spirit of tidewater") dissolves into that
#           element. The creature stands IN the element; the element may be its
#           mane/breath/trail, never its whole body.
#      Plus: ONE scene event max -- a second event (a shore freezing over
#      behind the beast) competes for the frame and wins.
#      verify_subjects() below enforces 6/7/8/11/12 at generation time.
#  13. AVOID STANDING FULL-BODY QUADRUPEDS ON VISIBLE GROUND. The leg-to-ground
#      contact is an MJ weak spot: hooves/paws end strangely, the ground under
#      them renders as mush (killed several stag rerolls). Prefer, in order:
#      chest-up portrait (no legs in frame); legs sunk in pooled mist/shadow/
#      light ("deep shadow pooling around its paws" -- the panther trick);
#      airborne/mid-leap pose. A standing pose with visible hooves on open
#      ground needs a strong reason.
#  15. SAME-FAMILY SPECIES NEED THEIR HALLMARK FEATURE SPELLED OUT. The species
#      TOKEN alone renders the same generic bug/bird/fish ("scarab" and
#      "beetle" both drew one beetle; bare "flea"/"fly" drew blobs/ribbons).
#      Write the field mark: weevil = long down-curved snout; scarab = wide
#      fan-edged head plate; dung-beetle = flattened digging forelegs;
#      bombardier = venting shell; flea = hunched shell + oversized springing
#      hind legs; firefly = tail-lantern; fly = big compound eyes. The name's
#      species and the drawn species must be the same recognisable animal.
#  14. COPY/SWARM CARDS: STATE THE COUNT IN THE OPENING WORDS. "a figure ...
#      its double rises from its back" buries the twin mid-sentence and MJ
#      drops it (Haunting Double rendered with no double). Open with the
#      multiplicity -- "two overlapping figures, the front one solid, the
#      other its ghostly double..." (Twin Shade worked exactly because of
#      this). The wrapper auto-detects copy words and swaps "one single
#      creature" for a group clause, but the SUBJECT must still lead with
#      the count.
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
#   (2) PER-COLOUR STYLE ANCHORS -- the proven lock (restored after the numeric
#       style-code detour failed). Field results: red 9/9 accepted in one batch,
#       violet re-anchored and accepted, dual blends accepted. Numeric codes
#       were a lottery AND can carry a colour core (the one good code tinted
#       everything green at any weight); recolour hacks tint hue. Same-colour
#       image anchors have no palette problem BY DESIGN: the palette pull
#       reinforces the card's own colour. Duals reference both parents' anchors
#       and MJ blends them evenly. The 4-grid variance that remains is inherent
#       to MJ -- "first try" means the first grid contains a keeper.
#       The one failure mode: an anchor whose MANNER is off (the wavy stag)
#       leaks its manner into its colour. Fix at the source -- reroll that
#       anchor with the bare prompt until its manner matches the other four,
#       then paste its URL here. NEVER recolour an anchor and never borrow a
#       cross-colour sref: an image reference always carries its palette.
ANCHORS = {
    "red": "https://cdn.midjourney.com/711297ce-fa4e-41e0-bb6d-2f5ad22834f3/0_0.png",
    "yellow": "https://cdn.midjourney.com/83447cee-7915-40c9-ba5b-b9a6a31efde8/0_3.png",
    "green": "https://cdn.midjourney.com/72a0fa5e-72e4-49fc-ad9a-ebe820c8ed4a/0_0.png",
    "blue": "https://cdn.midjourney.com/0ae56907-7024-42fd-b4fd-4195d1da1a97/0_2.png",
    "violet": "https://cdn.midjourney.com/7baedbd9-f934-4d8c-9abd-5c184b6ce932/0_1.png",
}
ANCHOR_SW = 100


def _sref(cols):
    urls = [ANCHORS[c] for c in cols if ANCHORS.get(c, "")]
    if not urls or len(cols) >= 5:
        return ""
    # Analogous pairs (yellow+green, green+blue...) at full --sw 100 avg the two
    # neighbouring anchor palettes into one muddy chartreuse across the frame
    # (measured: an elm rendered 0% true green, all hue 48-75deg). Chosen fix
    # (tested on the elk, 3 ways): keep BOTH anchors but at --sw 30 -- the low
    # weight lets palette()'s two solid zones drive the colour (clean gold + clean
    # green) while the anchors still carry the flat manner. Dropping anchors
    # entirely (sw 0) also fixed colour but drifted the manner off the set; a
    # single anchor rendered near-mono. Contrasting duals keep the full sw 100.
    sw = 30 if _is_analogous(cols) else ANCHOR_SW
    return " --sref " + " ".join(urls) + " --sw " + str(sw)

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
    "tracing its shape, one single creature with a clean readable silhouette, "
)
# Copy/swarm cards (a double, three duplicates, phantom ranks) must NOT get the
# "one single creature" clause -- it fights the subject and MJ drops the copies.
GROUP_HEAD = (
    "a " + _FLAT + " of beings made of living {g}light, glowing {g}light-lines "
    "tracing their shapes, every figure in frame clearly drawn with a clean "
    "readable silhouette, "
)
_MULTI_RE = re.compile(
    r"\b(two|three|twin|double|duplicates?|copies|copy of itself|pair of|"
    r"swarm|flock|host|ranks)\b")
EFFECT_HEAD = (
    "a " + _FLAT + " of a pure {g}light phenomenon, the subject rendered in "
    "bold {g}light and {g}energy alone, "
)
# Some creature cards are named after a STRUCTURE or OBJECT (a wall, rampart,
# blade, pillar); their art headlines that object, so "one single creature"
# would fight it. This head keeps the light-line look without demanding a beast.
STRUCT_HEAD = (
    "a " + _FLAT + " of a structure of living {g}light, glowing {g}light-lines "
    "tracing its form, one single bold object with a clean readable silhouette, "
)
# Words that mark a creature card whose subject is really an object/structure.
# Matched only against the OPENING of the art (the headline noun), so an
# incidental "shield-wall" or "blade-arms" on a real beast doesn't trip it.
_STRUCT_WORDS = (
    "wall", "rampart", "barbican", "ravelin", "gatehouse", "vault", "pillar",
    "shutter", "sword", "waymark", "standing stone", "beacon",
)


def _is_struct(art):
    head = " ".join(art.lower().split()[:6])
    return any(w in head for w in _STRUCT_WORDS)
TAIL = (
    ", on a deep dark flat background of swirling {g}energy in the same palette "
    "with drifting {g}light-motes, clean and graphic, {f}"
)
# A shared --sref + one fixed "large and centered, filling the frame" tail dragged
# every card of a colour into the SAME composition (two yellow hounds came out
# near-identical). Fix: keep the subject prominent (anti-tiny, rule 11) but drop
# the centring diktat and hand each SINGLE creature a per-card camera angle, so
# the anchor styles the colour while the framing varies the shot. Deterministic
# by id (md5, stable across builds -- no churn); skipped when the art already
# names its own shot, and not applied to structures/groups/effects (a wall must
# not be told to leap; effects own EFFECT_TAIL's middle-distance framing).
# Camera-only directions (no body action like "leap"/"rears up"), so they read
# sensibly on a beast, a tree or a structure alike. Variety here breaks the
# every-card-centered sameness; the art's own words (prowling, coiled...) still
# lead when present.
FRAMINGS = [
    "framed in a tight close crop",
    "seen from a dramatic low angle looking up",
    "seen from a high angle looking down",
    "viewed side-on in profile",
    "seen at a three-quarter angle",
    "set off to one side with sweeping empty dark around it",
    "pushed up close and filling much of the frame",
]
_CAMERA_RE = re.compile(
    r"portrait|close-up|close up|chest-up|chest up|\bprofile\b|mid-leap|mid-air|"
    r"airborne|looming|from above|from below|low angle|high angle|overhead|"
    r"side-on|three-quarter|in flight|coiled|planted|crouched|perched|rearing|"
    r"prowling|looking down|looking up|seen from|clinging|square in the lane")


def _framing(card, single):
    base = "the subject large in frame"
    if not single or _CAMERA_RE.search(card.get("art", "").lower()):
        return base
    idx = int(hashlib.md5(card["id"].encode()).hexdigest(), 16) % len(FRAMINGS)
    return base + ", " + FRAMINGS[idx]
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
# Spells/auras normally ban invented creatures (a "pure light phenomenon" makes
# MJ conjure a random beast). But a few effect arts DELIBERATELY stage faint
# background wildlife (deer sheltered in dawn mist). For those, keep the humanoid
# ban but drop creature/animal so the intended beasts render. Humanoids stay
# banned always -- an effect should never draw a person.
EFFECT_HUMANOID_BAN = ", character, person, figure, monster, face"
EFFECT_CREATURE_BAN = ", creature, animal"
_WILDLIFE_RE = re.compile(
    r"\b(deer|stag|doe|elk|beast|beasts|birds?|hares?|foxes?|wolves|herd|"
    r"fish|flock|creatures of the)\b")
HERO_FLAGS = FLAGS.replace("--ar 2:3", "--ar 1:1")

TOKENS = [
    {
        "id": "token_sprout",
        "name": {"ru": "Росток"},
        "color": ["green"],
        "type": "creature",
        "art": "a fresh young sprout of green light in sharp close-up, two unfurling leaves rising, soft motes of pollen-light drifting upward",
    },
]


# Wheel-adjacent colour pairs -- their hues sit next to each other and average
# into one muddy in-between tone (yellow+green -> lime). Three wrapper levers,
# tuned together, keep the two colours apart (tested on the elk):
#   palette() -> two solid colour blocks with a hard edge (not "equal measure",
#                which averages neighbours);
#   _glow     -> neutral (not "yellow and green" on every light-line, which blends);
#   _sref     -> both anchors but at --sw 30 (full 100 renders 0% true green;
#                dropping anchors fixes colour but drifts the manner).
# Also used by verify_intermix() to warn on colour-mixing words in the subject.
_ANALOG_SET = {frozenset(p) for p in
               (("red", "yellow"), ("yellow", "green"), ("green", "blue"),
                ("blue", "violet"), ("violet", "red"))}


def _is_analogous(cols):
    return len(cols) == 2 and frozenset(cols) in _ANALOG_SET


def palette(colors):
    if not colors:
        return "a clean monochrome palette of pure bright neutral white and soft pale grey, crisp neutral white, no other hue"
    if len(colors) >= 5:
        return "the full spectrum in balanced rainbow, every colour of light, none dominant"
    if len(colors) == 1:
        return "a palette of " + RANGE[colors[0]] + ", and no other colour"
    # Analogous pair: two solid zones with a hard edge, never a blended gradient
    # (equal-measure would average neighbouring hues into one lime/amber tone).
    if _is_analogous(colors):
        return ("a palette of two solid colour blocks, one block solid " + TONE[colors[0]]
                + ", the other block solid " + TONE[colors[1]]
                + ", split by one hard clean edge, never blended or graded, no other colours")
    # Contrasting multicolor: enforce balance so a skewed subject can't render mono.
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
    # locks a balanced two-tone (a soft --no never could). EXCEPT analogous pairs:
    # binding both hues onto every light-line is exactly what averages them into
    # one tone, so those keep the two colours in the palette's separate zones and
    # get a neutral "glowing" glow here instead of "yellow and green" per line.
    if _is_analogous(cols):
        return ""
    return " and ".join(cols) + " "


def style_for(card):
    cols = card.get("color", [])
    g = _glow(cols)
    is_effect = card["type"] in ("spell", "aura")
    is_struct = (not is_effect) and _is_struct(card.get("art", ""))
    if is_effect:
        head, kind = EFFECT_HEAD.format(g=g), "effect"
    elif is_struct:
        head, kind = STRUCT_HEAD.format(g=g), "struct"
    elif _MULTI_RE.search(card.get("art", "").lower()):
        head, kind = GROUP_HEAD.format(g=g), "group"
    else:
        head, kind = CREATURE_HEAD.format(g=g), "creature"
    # A structure subject must not carry the creature/animal --no bans.
    if is_effect:
        flags = FLAGS + EFFECT_HUMANOID_BAN
        if not _WILDLIFE_RE.search(card.get("art", "").lower()):
            flags += EFFECT_CREATURE_BAN
    else:
        flags = FLAGS
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
    if is_effect:
        tail = EFFECT_TAIL.format(g=g)
    else:
        tail = TAIL.format(g=g, f=_framing(card, single=(kind == "creature")))
    body = head + palette(cols) + tail
    return body, flags


_TYPE_RU = {"creature": "существо", "spell": "заклинание", "aura": "аура", "hero": "герой"}


def entry(card, style, flags):
    art = card.get("art", "")
    if not art:
        return []
    name = card.get("name", {}).get("ru", card["id"])
    kind = _TYPE_RU.get(card.get("type", ""), card.get("type", ""))
    return [
        "## " + name + " — `" + card["id"] + "`  (" + kind + ")",
        "save: `client-godot/art/" + card["id"] + ".png`",
        "```",
        art + ", " + style + " " + flags,
        "```",
        "",
    ]


_BLUE_RE = re.compile(r"\b(blue|cyan|teal|azure|turquoise)\b")

# --- Subject lints: every art-authoring rule we have violated at least once,
# --- encoded so it can never silently recur (run on every generation).
_VAGUE_RE = re.compile(
    r"^(?:\S+\s+){0,7}?\S*(leviathan|colossus|titan|behemoth|giant|spirit|wisp|being|shape|shade|phantom|wraith)\b")
_ANATOMY_RE = re.compile(
    r"(-shaped|-bodied|-like\b|clearly drawn|head|jaws|arms?\b|legged|legs|paws|"
    r"face|hooded|sleeves|robe|cloak|"
    r"wings?\b|fins|antlers|horn|coils|shoulders|whiskers|tail\b|limbs|"
    r"whale|bull|bear|ox\b|tortoise|serpent|otter|raven|cuttlefish|toad|stag|"
    r"boar|wolf|panther|fox\b|moth|beetle|spider|crab|owl|heron|mantis|scarab|"
    r"lynx|drake|dragon|phoenix|basilisk|mammoth|elk|newt|kingfisher|hound|"
    r"mastiff|rhinoceros|pangolin|armadillo|jellyfish|anglerfish|eel|minnow|"
    r"archerfish|salamander|hornet|gnat|tick\b|flea|fly\b|firefly|dragonfly|"
    r"swift\b|nightjar|bat\b|marten|peacock|cicada|stick-insect|scorpion|slug|"
    r"snail|mole|hawk|lion|aurochs|crane|sunbird|glowfly|horse|figure)")
_FLOWING_BODY_RE = re.compile(
    r"\b(woven from|made of|built of|formed of|body of|creature of|spirit of|beast of)\s+"
    r"(surging |rushing |drifting |ebbing )?"
    r"(the )?(flood(water)?|whitewater|tidewater|meltwater)\b")
_SIZE_OPEN_RE = re.compile(r"^a (tiny|small|little) ")
# A creature art that OPENS with a contentless container noun (beast/creature/
# animal...) hands MJ no silhouette, so it locks onto the generic word and draws
# a random animal, DROPPING any hallmark stated later mid-sentence (Argus's
# hundred eyes, the colossus's shell). The distinctive feature must lead the
# string. Warning-only (some openers are legitimately fine once a hallmark sits
# right after) -- eyeballed, not build-failing.
_GENERIC_OPENER_RE = re.compile(
    r"^(?:a|an|the)\s+(?:\w+\s+){0,2}?(beast|creature|animal|monster|thing|entity)\b")
_LIMB_COUNT_RE = re.compile(
    r"\b(one|two|three|four|five|six|seven|eight) (leg|wing|arm|eye|head|tail)s?\b")
_NEGATION_RE = re.compile(r"\bno \w+|\bnever\b|\bwithout\b")
# Rule 7: a spell/aura must not draw the effect's target/victim -- MJ renders the
# little burning/sacrificed beings instead of the phenomenon (Wake drew a row of
# guttering wisps being consumed). "wisp/prey/victim" join the figure words.
_TARGET_RE = re.compile(
    r"\b(enemy|enemies|foe|foes|ally|allies|caster|hero|soldier|defender|"
    r"person|figure|wisps?|prey|victims?)\b")
_META_RE = re.compile(
    r"\b(cards?|deck|mana|player|turns?)\b|you hoard|\byour\b")
# Diffusion models can't bind an object to a specific part of another object
# ("a lantern in its chest" -> the lantern is dropped or floats alongside; a
# structural limit, not a wording one). Force such details out as a separate
# large form instead (head/held object), which MJ renders reliably.
_NESTED_RE = re.compile(
    r"\b(inside|within|in|deep in|set in|buried in|embedded in) (its|their|the) "
    r"(chest|breast|belly|core|heart|ribs|forehead|body|torso|gut|maw)\b")
_ANCHOR_PHRASE = "not a realistic painted person"


_STOP = set("""a an the of in on at to and or with its it their his her one two three
from into out over under across behind before after against as like that this
each every very more most other another same own back up down off drawn flat
glowing light lines not realistic painted person sharp close-up close up light-lines
clearly drawn frame""".split())


def _sig(art):
    words = re.findall(r"[a-z]+(?:-[a-z]+)?", art.lower())
    return {w for w in words if len(w) > 3 and w not in _STOP}


# Visual-formula classes: words that render the SAME on canvas. Two same-type
# cards sharing a species-class AND an action-class are twins no matter how the
# words differ (Sootfly the fly and Spark Flea the flea both drew "tiny red
# insect + bright burst").
_SPECIES_CLASS = {
    "tiny-insect": ["fly", "flea", "gnat", "midge", "firefly", "tick"],
    "moth": ["moth"], "hornet": ["hornet", "wasp"], "beetle": ["beetle", "weevil", "scarab"],
    "mantis": ["mantis"], "dragonfly": ["dragonfly"], "spider": ["spider"],
    "serpent": ["serpent", "snake", "cobra", "eel"], "drake": ["drake", "dragon", "wyrm"],
    "bird": ["hawk", "owl", "crane", "heron", "kingfisher", "swift ", "shrike",
             "raven", "nightjar", "sunbird", "phoenix", "bird"],
    "canine": ["wolf", "hound", "mastiff", "fox"], "feline": ["lynx", "panther", "lion"],
    "bovine": ["ox", "aurochs", "bull", "buffalo", "bison"],
    "deer": ["stag", "elk", "fawn", "deer"], "boar": ["boar"], "ram": ["ram"],
    "toad": ["toad", "frog"], "fish": ["fish", "minnow", "mudskipper"],
    "ray": ["manta", "ray"], "whale": ["whale", "leviathan"],
    "tortoise": ["tortoise", "turtle"], "crab": ["crab"], "scorpion": ["scorpion"],
    "jellyfish": ["jellyfish"], "cuttlefish": ["cuttlefish", "octopus", "squid"],
    "figure": ["figure", "figures", "sentry", "sower", "mourner", "bannerman", "marshal"],
    "tree": ["oak", "elm", "treant", "tree"], "fungus": ["mushroom", "puffball",
             "fungus", "toadstool"], "wall": ["wall", "rampart", "gatehouse", "hedge",
             "bastion", "vault", "shutter"],
}
_ACTION_CLASS = {
    "burst": ["burst", "flash", "flaring", "flare", "explod", "snuffed",
              "spark-pops", "detonat"],
    "pierce-shield": ["through a shield", "through a raised shield", "clean through"],
    "copy": ["double", "duplicate", "copies", "mirror-copy", "after-image",
             "echo of itself", "twin"],
    "lurk-crystals": ["among banked crystals", "among glowing violet crystals"],
    "freeze-near": ["rime", "hoarfrost", "frozen breath", "flash-freez"],
    "heal-back": ["streaming back", "flowing back", "warmth streaming"],
    "grow-turn": ["thickening", "swelling", "broadening", "each turn", "every turn"],
    "draw-crystal": ["drawing a", "crystal out of", "crystal up", "crystals welling"],
}


def _classes(art, table):
    low = art.lower()
    out = set()
    for name, keys in table.items():
        for k in keys:
            if " " in k or "-" in k:
                if k in low:
                    out.add(name); break
            elif re.search(r"\b" + k + r"\b", low):
                out.add(name); break
    return out


def verify_formulas(cards):
    pool = [(c["id"], c.get("type"), c.get("art", ""))
            for c in cards if c.get("type") == "creature" and c.get("art")]
    bad = []
    for i in range(len(pool)):
        for j in range(i + 1, len(pool)):
            a, b = pool[i], pool[j]
            sa, sb = _classes(a[2], _SPECIES_CLASS), _classes(b[2], _SPECIES_CLASS)
            if not (sa & sb):
                continue
            aa, ab = _classes(a[2], _ACTION_CLASS), _classes(b[2], _ACTION_CLASS)
            if aa & ab:
                bad.append((a[0], b[0], ",".join(sa & sb) + "+" + ",".join(aa & ab)))
    return bad


def verify_color_species(cards):
    """Rule 10: a species/archetype appears at most once per colour. Two creatures
    of the SAME colour identity sharing a species-class read as the same beast
    recoloured even when their action differs (two yellow hounds, night_watchman
    vs cage_keeper -- twin-lint missed them because it needs species AND action to
    match). Only classed species are checked; unclassed invented beasts are free."""
    from collections import defaultdict
    seen = defaultdict(list)  # (colour-key, species-class) -> [ids]
    for c in cards:
        if c.get("type") != "creature" or not c.get("art"):
            continue
        ck = ",".join(sorted(c.get("color", []))) or "none"
        for sp in _classes(c["art"], _SPECIES_CLASS):
            seen[(ck, sp)].append(c["id"])
    return [(ck, sp, ids) for (ck, sp), ids in sorted(seen.items()) if len(ids) > 1]


# Carrier words that give a colour a visible home in a subject (rule 3). Used to
# warn when a two-colour art names no carrier for one of its colours -- that
# colour then renders missing (a "frost X" going all-blue with no green in sight).
_CARRIER = {
    # red carries fire AND the electric discharge of the red+blue storm cards
    # (sparks/charge/volt read red on canvas; blue there is the frost/rain).
    "red": r"red|scarlet|crimson|vermilion|ember|cinder|flame|fire|molten|coal|"
           r"lava|burning|blazing|magma|smould|spark|charge|volt|arc\b|electric|"
           r"storm|thunder|jolt",
    "yellow": r"yellow|gold|amber|bronze|honey|sun|solar|dawn|radian|lightning|"
              r"beam|ray-|rays|glare|blazing|searchlight",
    "green": r"green|moss|lichen|leaf|leaves|vine|ivy|reed|sprout|seed|root|"
             r"bark|bramble|thorn|frond|grass|bloom|bud|fern|petal|verdant|"
             r"duckweed|hedge|oak|elm|grove|wood",
    "blue": r"blue|cyan|azure|teal|frost|rime|ice|icy|snow|hoarfrost|meltwater|"
            r"glacier|chill|cold|water|flood|tide|wave|river|rapids|surge|swell",
    "violet": r"violet|purple|lilac|magenta|amethyst|shadow|dusk|gloom|umbral|"
              r"void|night|dark|crystal|shade",
}
_CARRIER_RE = {c: re.compile(r"\b(" + pat + r")", re.I) for c, pat in _CARRIER.items()}


def verify_both_colours(cards):
    """Rule 3: a two-colour art must give BOTH colours a carrier word, else the
    unnamed colour renders missing. Warning-only (semantics -- whether the pairing
    is LOGICAL -- still needs a human eye; this only catches an absent colour)."""
    bad = []
    for c in cards:
        cols = c.get("color", [])
        if c.get("type") == "hero" or len(cols) != 2 or not c.get("art"):
            continue
        art = c["art"]
        missing = [col for col in cols if not _CARRIER_RE[col].search(art)]
        if missing:
            bad.append((c["id"], "no carrier for " + "+".join(missing)))
    return bad


# Analogous pairs (neighbours on the wheel) average into one hue when intermixed
# instead of kept in separate spatial zones (rule 3). Uses _ANALOG_SET (defined
# by palette()). Contrasting pairs (red+blue, yellow+violet) don't blur, exempt.
_INTERMIX_RE = re.compile(
    r"veined with|veined all through|haloed with|lit through|lit and haloed|"
    r"blazing through|blaze with|shot through with|threaded through|threads of|"
    r"glowing through|shining through|woven half|woven from|washed through", re.I)


def verify_intermix(cards):
    """Rule 3: an analogous two-colour card that intermixes its colours (one
    glowing through the other) blurs to a single lime/amber hue. Warn so the
    colours get separate spatial zones instead. Warning-only (green+blue where
    the two sit in distinct parts is fine -- this only flags the mixing words)."""
    bad = []
    for c in cards:
        cols = c.get("color", [])
        if not _is_analogous(cols) or not c.get("art"):
            continue
        if _INTERMIX_RE.search(c["art"]):
            bad.append(c["id"])
    return bad


def verify_generic_openers(cards):
    """Warn on creature arts that lead with a contentless beast noun (see
    _GENERIC_OPENER_RE). The hallmark must come first or MJ draws a random
    animal. Warning-only."""
    return [c["id"] for c in cards
            if c.get("type") == "creature" and c.get("art")
            and _GENERIC_OPENER_RE.match(c["art"].strip().lower())]


def verify_pairs(cards, threshold=0.42):
    """Twin-prompt lint: two subjects this lexically close render identically
    (Sootfly vs Spark Flea: both 'small red insect bursting bright'). Compares
    every same-type pair; fails the build above the threshold so near-duplicate
    formulas can't slip back in."""
    pool = [(c["id"], c.get("type"), _sig(c.get("art", "")))
            for c in cards if c.get("type") != "hero" and c.get("art")]
    bad = []
    for i in range(len(pool)):
        for j in range(i + 1, len(pool)):
            a, b = pool[i], pool[j]
            if a[1] != b[1] or not a[2] or not b[2]:
                continue
            inter = len(a[2] & b[2])
            jac = inter / len(a[2] | b[2])
            if jac >= threshold:
                bad.append((a[0], b[0], round(jac, 2)))
    return bad


def verify_subjects(cards):
    """Enforce rules 6/7/8/11/12 on every art subject. Returns violations."""
    bad = []
    for c in cards:
        if c.get("type") == "hero":
            continue
        art = c.get("art", "")
        low = art.lower()
        body = low.replace(_ANCHOR_PHRASE, "")
        if _SIZE_OPEN_RE.match(low):
            bad.append((c["id"], "size word on the main subject (rule 11)"))
        if _LIMB_COUNT_RE.search(low):
            bad.append((c["id"], "counted body parts (rule 6)"))
        if _NEGATION_RE.search(body):
            bad.append((c["id"], "negation in the subject body (rule 8)"))
        if _META_RE.search(low):
            bad.append((c["id"], "game-meta vocabulary in the art (cards/deck/turn/mana/you)"))
        if _NESTED_RE.search(low):
            bad.append((c["id"], "object nested inside a body part (MJ can't bind it; make it a separate large form)"))
        if c.get("type") in ("spell", "aura"):
            if _TARGET_RE.search(low):
                bad.append((c["id"], "names the effect's target (rule 7)"))
        else:
            if _FLOWING_BODY_RE.search(low):
                bad.append((c["id"], "body made of a flowing element (rule 12b)"))
            if _VAGUE_RE.search(low) and not _ANATOMY_RE.search(low):
                bad.append((c["id"], "vague creature noun without anatomy (rule 12a)"))
    return bad


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
        "**Замок стиля = пер-цветовые якоря (проверено боем: красный 9/9 одной пачкой).** Каждая",
        "карта ссылается на эталон СВОЕГО цвета — перенос палитры усиливает цвет карты, а не",
        "борется с ним; двуцветки берут оба якоря (MJ мешает поровну). Числовые style-коды",
        "отвергнуты: лотерея + бывают с цветовым ядром (лучший код зеленил всё на любом весе).",
        "Якорь перекрашивать НЕЛЬЗЯ и чужой цвет одалживать НЕЛЬЗЯ — image-ref всегда несёт палитру.",
        "Если якорь выбился МАНЕРОЙ (волнистый олень) — перегенерить сам якорь голым промптом",
        "(без --sref), пока манера не совпадёт с остальными, и вписать URL в ANCHORS.",
        "Разброс внутри сетки 4 — свойство MJ: «с первого раза» = в первой сетке есть годный кадр.",
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
        out += entry(c, HERO_STYLE, HERO_FLAGS + _sref([]))
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
    # Only maintain the TODO file while art is still outstanding. Once every card
    # has a PNG (kept is empty) there's nothing to do, so remove any stale TODO
    # rather than leave an empty file behind.
    todo_dest = os.path.join(ROOT, "ART_PROMPTS_TODO.md")
    if kept:
        todo = ("# ART TODO — карты без арта (" + str(len(kept)) + " шт.)\n\n"
                "Каждый блок: имя, id, путь сохранения, готовый MJ-промпт. "
                "Сохраняй PNG по строке `save:`.\n\n" + "".join(kept))
        open(todo_dest, "w", encoding="utf-8").write(todo)
        print("wrote " + todo_dest + " with " + str(len(kept)) + " prompts (no art yet)")
    else:
        if os.path.exists(todo_dest):
            os.remove(todo_dest)
        print("all cards have art -- no TODO (removed stale ART_PROMPTS_TODO.md)")

    issues = verify_blue(pool + TOKENS)
    if issues:
        print("blue-defence: " + str(len(issues)) + " issue(s)")
        for cid, why in issues:
            print("  - " + cid + ": " + why)
    else:
        print("blue-defence: OK (every non-blue card locked against blue)")

    subj = verify_subjects(pool + TOKENS)
    if subj:
        print("subject-lint: " + str(len(subj)) + " issue(s)")
        for cid, why in subj:
            print("  - " + cid + ": " + why)
        sys.exit(1)
    print("subject-lint: OK (anatomy, no flowing bodies, no targets/negations/size/limb-counts)")

    pairs = verify_pairs(pool)
    formulas = verify_formulas(pool)
    if pairs or formulas:
        print("twin-lint: %d lexical + %d formula pair(s)" % (len(pairs), len(formulas)))
        for a, b, jac in pairs:
            print("  - %s ~ %s (jaccard %.2f)" % (a, b, jac))
        for a, b, why in formulas:
            print("  - %s ~ %s (formula %s)" % (a, b, why))
        sys.exit(1)
    print("twin-lint: OK (no two subjects share a visual formula)")

    # Same species-class more than once per colour. NOT build-failing: the set
    # uses deliberate, hallmark-differentiated families (red's insect swarm,
    # green's beetles, defensive structures). A warning to eyeball -- each group
    # below must read as visibly distinct beasts (rule 15), never one recoloured.
    dups = verify_color_species(pool)
    if dups:
        print("species-per-colour: %d family group(s) to keep visibly distinct:" % len(dups))
        for ck, sp, ids in dups:
            print("  - [%s] %s: %s" % (ck, sp, ", ".join(ids)))
    else:
        print("species-per-colour: OK (no repeated species within a colour)")

    # Creature arts leading with a contentless beast noun (hallmark buried later).
    openers = verify_generic_openers(pool)
    if openers:
        print("generic-opener: %d creature(s) lead with a bare beast noun (put the hallmark first):" % len(openers))
        for cid in openers:
            print("  - " + cid)
    else:
        print("generic-opener: OK (every creature leads with its distinctive form)")

    # Two-colour arts missing a carrier word for one colour (it renders absent).
    twotone = verify_both_colours(pool)
    if twotone:
        print("two-colour balance: %d card(s) where a colour has no carrier word:" % len(twotone))
        for cid, why in twotone:
            print("  - %s: %s" % (cid, why))
    else:
        print("two-colour balance: OK (both colours carried in every dual art)")

    # Analogous duals whose colours intermix into one hue (need spatial zones).
    intermix = verify_intermix(pool)
    if intermix:
        print("analogous-intermix: %d card(s) blending neighbour colours into one hue:" % len(intermix))
        for cid in intermix:
            print("  - " + cid)
    else:
        print("analogous-intermix: OK (neighbour colours kept in separate zones)")


if __name__ == "__main__":
    main()
