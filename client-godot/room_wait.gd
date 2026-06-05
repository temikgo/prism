class_name RoomWait
extends Control

# After creating a room: show the code (and the server address to share, since
# we are not hosted yet) and wait for the opponent. Cancel sends leaveRoom.

signal cancel_pressed

var _code := ""
var _url := ""
var _status: Label = null


# Called by the Router before the screen enters the tree.
func setup(code: String, server_url: String) -> void:
	_code = code
	_url = server_url


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(Backdrop.new())

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(Color(0.5, 0.62, 0.9), 0.5))
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.custom_minimum_size = Vector2(440, 0)
	panel.add_child(col)

	col.add_child(Ui.label("Комната создана", 22, Color(0.86, 0.9, 1.0), true))
	col.add_child(Ui.label("Код комнаты", 13, Color(0.62, 0.66, 0.78), true))
	col.add_child(_code_plate())
	col.add_child(_gap(4))
	col.add_child(Ui.label("Передайте другу код, пароль и адрес сервера:", 13,
		Color(0.6, 0.64, 0.74), true))
	col.add_child(Ui.label(_url, 14, Color(0.78, 0.82, 0.92), true, true))
	col.add_child(_gap(10))
	col.add_child(Ui.label("Ожидание соперника…", 15, Color(0.7, 0.74, 0.85), true))
	_status = Ui.label("", 13, Color(0.95, 0.5, 0.5), true)
	col.add_child(_status)
	col.add_child(_gap(8))

	var cancel := Ui.neon_button("Отмена", Color(0.6, 0.62, 0.7))
	cancel.custom_minimum_size = Vector2(160, 42)
	cancel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cancel.pressed.connect(func() -> void: cancel_pressed.emit())
	col.add_child(cancel)


# A connection-level message from the Router (e.g. lost link while waiting).
func notify(text: String) -> void:
	if _status != null:
		_status.text = text


# The code in large display type on its own plate.
func _code_plate() -> Control:
	var holder := CenterContainer.new()
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.1, 0.13, 0.2, 0.9), 10, 2, Color(0.45, 0.7, 1.0), 14))
	var lbl := Ui.label(_code, 52, Color(0.95, 0.97, 1.0), true)
	lbl.add_theme_font_override("font", Fonts.DISPLAY)
	plate.add_child(lbl)
	holder.add_child(plate)
	return holder


func _gap(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s
