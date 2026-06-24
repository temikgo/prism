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
signal decks_pressed
signal settings_pressed
signal quit_pressed


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
	var play := Ui.mbtn("Играть", "primary", Ui.SIDE_ME)
	play.pressed.connect(func() -> void: play_pressed.emit())
	nav.add_child(play)
	var decks_btn := Ui.mbtn("Колоды", "ghost", Ui.ACC_VIOLET)
	decks_btn.pressed.connect(func() -> void: decks_pressed.emit())
	nav.add_child(decks_btn)
	var settings := Ui.mbtn("Настройки", "ghost", Ui.COLORLESS)
	settings.pressed.connect(func() -> void: settings_pressed.emit())
	nav.add_child(settings)
	var quit := Ui.mbtn("Выход", "ghost", Ui.COLORLESS)
	quit.pressed.connect(func() -> void: quit_pressed.emit())
	nav.add_child(quit)

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
	l.add_theme_font_override("font", Fonts.spaced(Fonts.NUM_BLACK, 14))
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
	l.add_theme_font_override("font", Fonts.spaced(Fonts.SEMIBOLD, 4))
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Ui.INK_DIM)
	return l


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
