class_name MainMenu
extends Control

# The title screen: the prism sigil + "PRISM" wordmark over the shared backdrop,
# a lore line, the primary navigation, and a footer. Pure presentation -- it owns
# no game/network state and only reports the player's choice up to the Router via
# signals. The look is ported from the Claude Design handoff (Prism — Main Menu):
# the triangle prism sigil, the Chakra-Petch wordmark with a cool layered halo,
# wide-tracked lore, a faint spectral aura bloom, neon-glass nav buttons, and a
# soft rise-in on load.

signal play_pressed
signal settings_pressed
signal quit_pressed

# Spectrum / accent colours from the design tokens (board palette).
const ACC_VIOLET := Color(0.678, 0.322, 0.941)   # #AD52F0
const COLORLESS := Color(0.8, 0.8, 0.878)        # #CCCCE0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# A faint spectral aura bloom centred behind the wordmark (the mockup's
	# #menu::before): a broad additive blue->violet radial, low and soft.
	add_child(_aura())

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 0)
	center.add_child(col)

	var sigil := PrismSigil.new()
	sigil.custom_minimum_size = Vector2(208, 188)
	col.add_child(sigil)
	col.add_child(Ui.gap(14))

	col.add_child(_wordmark())
	col.add_child(Ui.gap(18))
	col.add_child(_lore())
	col.add_child(Ui.gap(52))

	var nav := VBoxContainer.new()
	nav.alignment = BoxContainer.ALIGNMENT_CENTER
	nav.add_theme_constant_override("separation", 14)
	col.add_child(nav)
	nav.add_child(_menu_button("Играть", Ui.SIDE_ME, "primary",
		func() -> void: play_pressed.emit()))
	nav.add_child(_menu_button("Колоды", ACC_VIOLET, "muted", Callable()))
	nav.add_child(_menu_button("Настройки", COLORLESS, "ghost",
		func() -> void: settings_pressed.emit()))
	nav.add_child(_menu_button("Выход", COLORLESS, "ghost",
		func() -> void: quit_pressed.emit()))

	# Rise-in: fade + a touch of scale (position is container-managed, so we drive
	# alpha and a pivot-centred scale instead of a y-offset).
	col.pivot_offset = col.size * 0.5
	col.modulate.a = 0.0
	col.scale = Vector2(0.985, 0.985)
	var tw := create_tween().set_parallel(true)
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(col, "modulate:a", 1.0, 0.7)
	tw.tween_property(col, "scale", Vector2.ONE, 0.7)


# The wordmark: "PRISM" in Chakra Petch with wide tracking. Clean light glyphs
# with only a soft dark drop shadow for legibility -- no coloured outline/halo,
# which muddied the letters against the cool scene. The glow now comes from the
# aura bloom behind, not a stroke on the type.
func _wordmark() -> Label:
	var l := Label.new()
	l.text = "PRISM"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", _spaced(Fonts.NUM_BLACK, 14))
	l.add_theme_font_size_override("font_size", 104)
	l.add_theme_color_override("font_color", Color(0.957, 0.969, 1.0))
	l.add_theme_color_override("font_shadow_color", Color(0.02, 0.03, 0.08, 0.55))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 3)
	return l


func _lore() -> Label:
	var l := Label.new()
	l.text = "·  СВЕТ МЕГА-ПРИЗМЫ РАСКОЛОТ НА ПЯТЬ ЦВЕТОВ  ·"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", _spaced(Fonts.SEMIBOLD, 4))
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Ui.INK_DIM)
	return l


# One nav button in the board's neon-glass language. `kind`: "primary" (large
# blue, the call to action), "muted" (dim, hover-violet, carries a "скоро" note
# and does nothing), "ghost" (compact, neutral accent).
func _menu_button(text: String, accent: Color, kind: String, cb: Callable) -> Button:
	var primary := kind == "primary"
	var muted := kind == "muted"
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(340, 66 if primary else (52 if kind == "ghost" else 58))
	b.add_theme_font_override("font", _spaced(Fonts.SEMIBOLD, 1))
	b.add_theme_font_size_override("font_size", 21 if primary else (16 if kind == "ghost" else 18))
	var ink := Color(0.918, 0.949, 1.0) if primary else (Ui.INK_DIM if muted else Ui.INK)
	b.add_theme_color_override("font_color", ink)
	b.add_theme_color_override("font_hover_color", Color(0.957, 0.969, 1.0))
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", _pill(accent, primary, false))
	b.add_theme_stylebox_override("hover", _pill(accent, primary, true))
	b.add_theme_stylebox_override("pressed", _pill(accent, primary, true))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.focus_mode = Control.FOCUS_NONE

	if muted:
		# A faint "скоро" chip on the right rail; the button is inert.
		var note := Ui.label("СКОРО", 11, Ui.INK_FAINT)
		note.add_theme_font_override("font", _spaced(Fonts.SEMIBOLD, 2))
		note.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
		note.offset_right = -20
		note.offset_left = -70
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		note.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(note)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


# The neon-glass pill: a dark glass fill (blended toward the accent for primary),
# a hairline stroke with a lit top rim, and an accent glow that brightens on
# hover. Godot has no gradient/backdrop-blur, so the look is the translucent fill
# + lit rim + coloured drop shadow (the same fakery as the board rails).
func _pill(accent: Color, primary: bool, hot: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var base := Color(0.086, 0.094, 0.165, 0.82)
	sb.bg_color = base.lerp(Color(accent.r, accent.g, accent.b, 0.9), 0.22 if primary else 0.0)
	if hot and not primary:
		sb.bg_color = base.lerp(Color(accent.r, accent.g, accent.b, 0.9), 0.08)
	sb.set_corner_radius_all(15)
	sb.set_border_width_all(1)
	sb.border_width_top = 2  # lit top rim -> glass, not a flat box
	var stroke := Ui.PANEL_STROKE
	sb.border_color = stroke.lerp(accent, 0.55 if primary else 0.0)
	if hot:
		sb.border_color = stroke.lerp(accent, 0.65)
	# Accent glow: present at rest only for primary; everything lights up on hover.
	if primary:
		sb.shadow_size = 40 if hot else 28
		sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.6 if hot else 0.42)
	elif hot:
		sb.shadow_size = 26
		sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.4)
	else:
		sb.shadow_size = 12
		sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	return sb


# A broad, soft additive aura behind the lockup (spectral bloom).
func _aura() -> Control:
	var tr := TextureRect.new()
	tr.texture = Tokens.soft_dot()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.custom_minimum_size = Vector2(1000, 1000)
	tr.set_anchors_preset(Control.PRESET_CENTER)
	tr.offset_left = -500
	tr.offset_right = 500
	tr.offset_top = -560   # biased upward, behind the sigil/wordmark
	tr.offset_bottom = 440
	tr.modulate = Color(0.42, 0.55, 1.0, 0.12)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	tr.material = mat
	return tr


# A glyph-tracked variant of a base font (Godot Labels have no letter-spacing, so
# tracking from the design's letter-spacing is applied via FontVariation).
func _spaced(base: Font, px: int) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.set_spacing(TextServer.SPACING_GLYPH, px)
	return fv
