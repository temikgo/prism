class_name MainMenu
extends Control

# The title screen: game wordmark over the shared backdrop, and the primary
# navigation buttons. Pure presentation -- it owns no game/network state and
# only reports the player's choice up to the Router via signals.

signal play_pressed
signal settings_pressed
signal quit_pressed

const COLORS := ["red", "yellow", "green", "blue", "violet"]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 16)
	center.add_child(col)

	col.add_child(_wordmark())
	col.add_child(Ui.label("Свет Мега-Призмы расколот на семь цветов", 15,
		Color(0.66, 0.7, 0.82), true))
	col.add_child(_gap(28))

	col.add_child(_menu_button("Играть", Color(0.4, 0.85, 1.0),
		func() -> void: play_pressed.emit(), true))
	col.add_child(_menu_button("Колоды", Color(0.45, 0.5, 0.6), Callable(), false, true))
	col.add_child(_menu_button("Настройки", Color(0.62, 0.7, 0.92),
		func() -> void: settings_pressed.emit()))
	col.add_child(_menu_button("Выход", Color(0.88, 0.52, 0.52),
		func() -> void: quit_pressed.emit()))


# The prism emblem/sigil image (generated in MJ; a unique crystalline silhouette,
# glowing light on black/transparent, no lettering). Composited additively so the
# black background drops out and only the prism + spectrum read as light.
const EMBLEM_PATH := "res://art/ui/logo_prism.png"


# The wordmark lockup: the prism emblem above "PRISM" in the display font with a
# soft cool halo. The emblem is the procedural faceted crystal (exact palette) by
# default; a generated logo_prism.png, if dropped in, overrides it.
func _wordmark() -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	box.add_child(_emblem())
	var title := Ui.label("PRISM", 78, Color(0.96, 0.97, 1.0), true)
	title.add_theme_font_override("font", Fonts.DISPLAY)
	# A soft cool halo so the wordmark reads as glowing light, not flat text.
	title.add_theme_constant_override("outline_size", 14)
	title.add_theme_color_override("font_outline_color", Color(0.36, 0.5, 1.0, 0.35))
	box.add_child(title)
	return box


func _emblem() -> Control:
	if ResourceLoader.exists(EMBLEM_PATH):
		var img := TextureRect.new()
		img.texture = load(EMBLEM_PATH)
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.custom_minimum_size = Vector2(240, 210)
		img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Additive blend: a black/transparent logo background contributes nothing,
		# so only the prism and its spectrum show over the backdrop.
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		img.material = mat
		return img
	var emblem := LogoEmblem.new()
	emblem.custom_minimum_size = Vector2(150, 150)
	emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return emblem


func _prism_bar() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := COLORS.size()
	for i in n:
		var seg := Panel.new()
		seg.custom_minimum_size = Vector2(54, 5)
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c := Palette.color_for(COLORS[i])
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sb.shadow_size = 8
		sb.shadow_color = Color(c.r, c.g, c.b, 0.6)
		sb.corner_radius_top_left = 3 if i == 0 else 0
		sb.corner_radius_bottom_left = 3 if i == 0 else 0
		sb.corner_radius_top_right = 3 if i == n - 1 else 0
		sb.corner_radius_bottom_right = 3 if i == n - 1 else 0
		seg.add_theme_stylebox_override("panel", sb)
		row.add_child(seg)
	return row


func _menu_button(text: String, accent: Color, cb: Callable,
		primary := false, disabled := false) -> Button:
	var b := Ui.neon_button(text if not disabled else text + "   ·   скоро", accent)
	b.custom_minimum_size = Vector2(280, 54 if primary else 46)
	b.add_theme_font_size_override("font_size", 21 if primary else 16)
	if disabled:
		b.disabled = true
	else:
		b.pressed.connect(cb)
	return b


func _gap(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s
