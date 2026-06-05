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
	add_child(Backdrop.new())

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


# "PRISM" in bright light over a thin five-colour prism bar.
func _wordmark() -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	var title := Ui.label("PRISM", 76, Color(0.94, 0.96, 1.0), true)
	title.add_theme_constant_override("outline_size", 0)
	box.add_child(title)
	box.add_child(_prism_bar())
	return box


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
