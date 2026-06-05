class_name Fonts

# Project typography. Lato (humanist sans, full Cyrillic) carries the whole UI;
# Dela Gothic One (heavy display) is reserved for the wordmark and big titles.
# `default_theme()` is set on the app root so every Control inherits Lato without
# per-call-site changes; the heavier weights are applied directly where a label
# wants emphasis (titles, banners, stat gems).

const REGULAR := preload("res://fonts/Lato-Regular.ttf")
const SEMIBOLD := preload("res://fonts/Lato-Semibold.ttf")
const BOLD := preload("res://fonts/Lato-Bold.ttf")
const BLACK := preload("res://fonts/Lato-Black.ttf")
const DISPLAY := preload("res://fonts/DelaGothicOne-Regular.ttf")


# A theme whose default font is Lato. Setting it on a root Control makes every
# descendant inherit it; bold variants are opted into per widget.
static func default_theme() -> Theme:
	var th := Theme.new()
	th.default_font = REGULAR
	th.default_font_size = 15
	return th
