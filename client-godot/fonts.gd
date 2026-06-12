class_name Fonts

# Project typography. Exo 2 (a sci-fi grotesque with full Cyrillic, chosen to rhyme
# with the techy numerals and the light/crystal theme) carries the whole UI as a
# single variable font -- the weights below are FontVariations of it on the wght axis
# (100-900), so there is one face to ship and hint. Chakra Petch (a techy mono-ish
# face, Latin/digits only -- NO Cyrillic) is reserved for NUMBERS only: stat gems,
# counters, costs. Dela Gothic One stays the heavy display face for the wordmark/
# titles. `default_theme()` sets the Exo 2 body weight on the app root so every
# Control inherits it; heavier weights and the numeric face are opted into per widget
# (titles, banners, stat gems, counters).

const _BODY := preload("res://fonts/Exo2.ttf")  # variable, wght 100..900
const DISPLAY := preload("res://fonts/DelaGothicOne-Regular.ttf")
# Numbers only (no Cyrillic): apply to digit-only labels via add_theme_font_override.
const NUM := preload("res://fonts/ChakraPetch-Medium.ttf")
const NUM_BOLD := preload("res://fonts/ChakraPetch-SemiBold.ttf")
const NUM_BLACK := preload("res://fonts/ChakraPetch-Bold.ttf")

# Inter weights as variations of the one variable face. Body sits at 500 (Medium)
# rather than 400 for solidity at small UI sizes (the thin default read too light).
static var REGULAR: Font = _weight(500)
static var SEMIBOLD: Font = _weight(620)
static var BOLD: Font = _weight(720)
static var BLACK: Font = _weight(820)


# A FontVariation of the body face pinned to a wght-axis value (the variable default
# is 400, so each weight is set explicitly to keep them consistent).
static func _weight(w: int) -> Font:
	var fv := FontVariation.new()
	fv.base_font = _BODY
	fv.set_variation_opentype({"wght": w})
	return fv


# A theme whose default font is the Inter body weight. Setting it on a root Control
# makes every descendant inherit it; bold variants are opted into per widget.
static func default_theme() -> Theme:
	var th := Theme.new()
	th.default_font = REGULAR
	th.default_font_size = 15
	return th
