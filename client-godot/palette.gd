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


static func color_for(name: String) -> Color:
	return MAP.get(name, MAP["colorless"])


# The card's frame/glow color: its first color, or neutral if it has none.
static func primary(d: Dictionary) -> Color:
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		return color_for("colorless")
	return color_for(String(colors[0]))


static func ru(color: String) -> String:
	return RU.get(color, color)
