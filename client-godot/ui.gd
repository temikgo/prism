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


# One mana crystal in the hero bar: a colored bar, or a rotated diamond for
# neutral. `filled` = still available this turn (bright), else spent (dim).
static func mana_pip(color: String, filled: bool, temp := false) -> Control:
	var is_neutral := color == "colorless"
	var c := Color(0.9, 0.92, 1.0) if is_neutral else Palette.color_for(color)
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(2 if is_neutral else 3)
	sb.set_border_width_all(1)
	if filled:
		sb.bg_color = c
		sb.border_color = Color.WHITE if is_neutral else c.lightened(0.45)
		sb.shadow_size = 6
		sb.shadow_color = Color(c.r, c.g, c.b, 0.6)
	else:
		# Spent this turn: a clearly dark crystal (not a faint outline), so spent
		# vs available reads as dark vs bright. The faint colored border keeps its
		# color legible.
		sb.bg_color = Color(0.16, 0.17, 0.21, 0.95)
		sb.border_color = Color(c.r, c.g, c.b, 0.55)
	if temp:
		# Bonus mana for this turn only (e.g. green photosynthesis ramp): keep the
		# pip's own fill but ring it in a green glow so it reads as extra, not a
		# permanent crystal.
		var g := Color(0.42, 0.9, 0.5)
		sb.border_color = g.lightened(0.3)
		sb.set_border_width_all(2)
		sb.shadow_size = 8
		sb.shadow_color = Color(g.r, g.g, g.b, 0.75)

	if is_neutral:
		# A rotated square reads as "any color" -- a prism/diamond.
		var holder := Control.new()
		holder.custom_minimum_size = Vector2(28, 38)
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var dia := Panel.new()
		dia.size = Vector2(19, 19)
		dia.position = Vector2(4.5, 9.5)
		dia.pivot_offset = Vector2(9.5, 9.5)
		dia.rotation = deg_to_rad(45)
		dia.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dia.add_theme_stylebox_override("panel", sb)
		holder.add_child(dia)
		return holder

	var pip := Panel.new()
	pip.custom_minimum_size = Vector2(26, 36)
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pip.add_theme_stylebox_override("panel", sb)
	return pip


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
