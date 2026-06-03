class_name Palette

# Color identity for the five Prism colors plus neutral, and their Russian
# names. Pure data and lookups, shared across the whole UI.

const MAP := {
	"red": Color(0.86, 0.24, 0.26),
	"yellow": Color(0.92, 0.78, 0.24),
	"green": Color(0.34, 0.74, 0.40),
	"blue": Color(0.32, 0.56, 0.92),
	"violet": Color(0.62, 0.38, 0.86),
	"colorless": Color(0.72, 0.72, 0.78),
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
