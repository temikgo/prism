class_name ConfirmDialog
extends Control

# A small full-screen modal confirm: a title, some message lines, and yes/no
# buttons. Emits `confirmed` on yes; cancel (button or backdrop) just frees it.
# Used e.g. to warn that playing a targeted card with no target loses its effect.

signal confirmed


func setup(title: String, lines: Array, yes_text := "Разыграть", no_text := "Отмена",
		accent := Color(0.95, 0.78, 0.36)) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	position = Vector2.ZERO
	size = get_viewport_rect().size
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_as_relative = false
	z_index = 4096

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.02, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			queue_free())
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(accent, 0.72))
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.custom_minimum_size = Vector2(320, 0)
	panel.add_child(col)

	col.add_child(Ui.label(title, 19, Color(0.96, 0.9, 0.7), true, true))
	for line in lines:
		var l := Ui.label(String(line), 13, Color(0.78, 0.8, 0.86), true)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(320, 0)
		col.add_child(l)
	col.add_child(Ui.gap(4))

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)
	var no := Ui.neon_button(no_text, Color(0.6, 0.62, 0.7))
	no.custom_minimum_size = Vector2(150, 40)
	no.pressed.connect(func() -> void: queue_free())
	row.add_child(no)
	var yes := Ui.neon_button(yes_text, accent)
	yes.custom_minimum_size = Vector2(150, 40)
	yes.pressed.connect(func() -> void:
		confirmed.emit()
		queue_free())
	row.add_child(yes)
