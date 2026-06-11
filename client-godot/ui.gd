class_name Ui

# Generic, stateless widget/style builders shared across the client: labels,
# the neon "glass" and bordered panels, buttons, icons and the mana/cost pips.
# Nothing here reads game state -- callers pass in everything.

# One-liner Label builder. Only the arguments you pass are applied. Pass size <= 0
# / color = null to inherit the theme default; set `center` for centered text and
# `bold` for the semibold weight (otherwise the theme's Lato Regular is used).
static func label(text: String, size: int = 0, color: Variant = null,
		center: bool = false, bold: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	if color != null:
		l.add_theme_color_override("font_color", color)
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if bold:
		l.add_theme_font_override("font", Fonts.SEMIBOLD)
	return l


# Translucent dark "glass" with a neon accent border and a soft accent glow.
static func glass(accent: Color, bg_alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.14, bg_alpha)
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(2)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.9)
	# A lit top edge: a brighter, thicker upper border reads as light catching the
	# rim of the glass, so panels feel like inked vellum rather than flat boxes.
	sb.border_width_top = 3
	sb.shadow_size = 20
	sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.45)
	sb.set_content_margin_all(8)
	return sb


# A plain rounded panel with a solid border (no shadow). Covers the small
# bordered chips/tiles/pills; overlay panels use glass() instead.
static func bordered(bg: Color, radius: int, border_w: int, border_c: Color, margin: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_border_width_all(border_w)
	sb.border_color = border_c
	if margin > 0:
		sb.set_content_margin_all(margin)
	return sb


static func neon_button(text: String, accent: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", Fonts.SEMIBOLD)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", accent.lightened(0.5))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.43, 0.5))
	b.add_theme_stylebox_override("normal", glass(accent, 0.4))
	b.add_theme_stylebox_override("hover", glass(accent, 0.62))
	b.add_theme_stylebox_override("pressed", glass(accent, 0.8))
	var dis := glass(Color(0.32, 0.34, 0.42), 0.22)
	dis.shadow_size = 0
	b.add_theme_stylebox_override("disabled", dis)
	# No focus rectangle: the press/hover glass is the only state feedback. The
	# default theme draws a focus outline that reads as a flat rectangle on click.
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.focus_mode = Control.FOCUS_NONE
	return b


static func icon(icon_name: String, px: float, color: Color) -> TextureRect:
	var tex := TextureRect.new()
	tex.texture = load("res://icons/%s.svg" % icon_name)
	tex.custom_minimum_size = Vector2(px, px)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.modulate = color
	return tex


# One faceted mana crystal. `filled` = still available this turn (bright), else
# spent (drained + dim); `temp` rings it green for bonus ramp mana. Colourless uses
# the neutral prism tint, every colour shares the same kite cut.
static func mana_pip(color: String, filled: bool, temp := false) -> Control:
	var is_neutral := color == "colorless"
	var crystal := CrystalNode.new()
	crystal.crystal_color = Color(0.85, 0.87, 0.96) if is_neutral else Palette.color_for(color)
	crystal.spent = not filled
	crystal.temp = temp
	crystal.custom_minimum_size = Vector2(22, 30)
	crystal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return crystal


# A small colored pip used to spell out a card's colored cost.
static func cost_pip(color: String) -> Control:
	var c := Palette.color_for(color)
	var pip := Panel.new()
	pip.custom_minimum_size = Vector2(13, 16)
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pip.add_theme_stylebox_override("panel", bordered(c, 3, 1, c.lightened(0.45)))
	var holder := CenterContainer.new()   # vertical-center the pip beside the number
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(pip)
	return holder


# A fixed-height vertical spacer for stacking screen sections.
static func gap(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s
