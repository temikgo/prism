import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TONE = {
    "red": "red and crimson",
    "yellow": "gold and amber",
    "green": "emerald green",
    "blue": "deep blue and cyan",
    "violet": "violet and purple",
}

CREATURE_HEAD = (
    "a being woven from living light, translucent radiant energy given form, "
    "bold clean graphic 2D ink linework, glowing luminous light-lines tracing "
    "its shape, flat illustration, "
)
EFFECT_HEAD = (
    "an effect of pure light, an abstract phenomenon of energy and rays with no "
    "creature, bold clean graphic 2D ink linework, glowing luminous light-lines "
    "and energy, flat illustration, "
)
TAIL = (
    ", set against a deep moody atmospheric background of swirling luminous "
    "energy in the same palette, drifting light-motes and layered depth, richly "
    "detailed and alive, centered composition"
)
HERO_STYLE = (
    "a striking stylized character portrait, bold clean graphic 2D ink linework, "
    "glowing luminous light accents tracing the figure, faint prismatic "
    "refractions and spectrum glints, flat illustration, set against a deep moody "
    "atmospheric background of swirling luminous energy, drifting light-motes and "
    "layered depth, richly detailed and alive, centered portrait"
)
FLAGS = (
    "--ar 2:3 --v 7 --style raw --c 0"
    " --no border, frame, panel, text, building, architecture, photo, 3D render,"
    " plain background, flat background"
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
        return "a strict pure white and silver monochrome palette, no strong hue, no other colours"
    if len(colors) >= 5:
        return "the full spectrum in balanced rainbow, every colour of light, none dominant"
    tones = " and ".join(TONE[c] for c in colors)
    return "a strict colour palette of only " + tones + " tones, no other colours"


def style_for(card):
    if card["type"] in ("spell", "aura"):
        return EFFECT_HEAD + palette(card.get("color", [])) + TAIL, EFFECT_FLAGS
    return CREATURE_HEAD + palette(card.get("color", [])) + TAIL, FLAGS


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


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "cards", "new_set.json")
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


if __name__ == "__main__":
    main()
