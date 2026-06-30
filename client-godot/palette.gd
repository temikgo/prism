class_name Palette

# Color identity for the five Prism colors plus neutral, and their Russian
# names. Pure data and lookups, shared across the whole UI.

# Saturated jewel tones tuned to match the painterly card art (crimson, gold,
# emerald, azure, amethyst) rather than the earlier pastel set.
const MAP := {
	"red": Color(0.92, 0.20, 0.30),
	"yellow": Color(0.98, 0.76, 0.20),
	"green": Color(0.26, 0.82, 0.44),
	"blue": Color(0.24, 0.58, 0.98),
	"violet": Color(0.68, 0.32, 0.94),
	"colorless": Color(0.80, 0.80, 0.88),
}

const RU := {
	"red": "красный", "yellow": "жёлтый", "green": "зелёный",
	"blue": "синий", "violet": "фиолетовый", "colorless": "бесцветный",
}

# Which colour owns each catalog keyword (mirrors tools/check_density.py CATALOG).
# Lets a multicolour card paint each keyword name in its own colour rather than
# one shared hue.
const KW_COLOR := {
	"pierce": "red", "bypass": "red", "regen": "red", "self_lifesteal": "red",
	"incandescence": "red", "cauterize": "red", "sear": "red", "spark": "red",
	"floodlight": "yellow", "blind": "yellow", "provoke": "yellow", "shield": "yellow",
	"ward": "yellow", "firststrike": "yellow", "strobe": "yellow", "flare": "yellow",
	"photosynthesis": "green", "germinate": "green", "growth": "green", "compost": "green",
	"spores": "green", "undergrowth": "green", "resonance": "green", "mulch": "green",
	"freeze": "blue", "chill": "blue", "delay": "blue", "scry": "blue",
	"scatter": "blue", "haze": "blue", "birefringence": "blue", "pinpoint": "blue",
	"awaken": "violet", "decoy": "violet", "stealth": "violet", "refract": "violet",
	"split": "violet", "mirage": "violet", "haunt": "violet", "glimmer": "violet",
}


static func color_for(name: String) -> Color:
	return MAP.get(name, MAP["colorless"])


# A drawn mana crystal's fill: colourless wears the neutral prism tint, every
# colour wears its own.
static func crystal_color(color: String) -> Color:
	return Color(0.85, 0.87, 0.96) if color == "colorless" else color_for(color)


# The colour of a keyword (its catalog colour), or `fallback` when it is not a
# catalog keyword (penta/hero keywords, inline effects).
static func keyword_color(kid: String, fallback: Color) -> Color:
	return color_for(KW_COLOR[kid]) if KW_COLOR.has(kid) else fallback


# The card's frame/glow color: its first color, or neutral if it has none.
static func primary(d: Dictionary) -> Color:
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		return color_for("colorless")
	return color_for(String(colors[0]))


static func ru(color: String) -> String:
	return RU.get(color, color)
