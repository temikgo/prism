class_name ManaPicker
extends Control

# Full-screen mana-color chooser overlay: a dim backdrop (click to cancel) with a
# radial wheel near the cursor, one sector per color. Emits `picked(color_id)`;
# cancelling (backdrop or the wheel's center hole) just frees itself. Built in
# setup(); the caller adds it as a child and connects `picked`.

signal picked(color_id: String)

var _panel: PanelContainer = null


func setup(colors: Array, mouse_pos: Vector2, view_size: Vector2) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Force it above everything (hovered cards lift to z_index 20).
	z_as_relative = false
	z_index = 4096

	var backdrop := Button.new()
	backdrop.flat = true
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.pressed.connect(_dismiss)
	add_child(backdrop)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", Ui.glass(Color(0.6, 0.62, 0.8), 0.97))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(Ui.label("Каким кристаллом?", 13, null, true))
	var wheel := RadialPicker.new()
	var ids := PackedStringArray()
	for c in colors:
		ids.append(String(c))
	wheel.colors = ids
	wheel.picked.connect(func(cid: String) -> void:
		picked.emit(cid)
		_dismiss())
	wheel.cancelled.connect(_dismiss)
	vb.add_child(wheel)
	_panel.add_child(vb)
	add_child(_panel)

	var pos := mouse_pos - Vector2(110, 110)
	pos.x = clampf(pos.x, 8.0, view_size.x - 210.0)
	pos.y = clampf(pos.y, 8.0, view_size.y - 230.0)
	_panel.position = pos


func _dismiss() -> void:
	queue_free()
