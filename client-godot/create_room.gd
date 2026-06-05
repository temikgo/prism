class_name CreateRoom
extends Control

# Create a private room: choose a password (mandatory). The Router sends the
# createRoom command and moves to the waiting screen on roomCreated.

signal submit(password: String)
signal back_pressed

var _pw: LineEdit = null
var _create_btn: Button = null
var _status: Label = null


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
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(420, 0)
	panel.add_child(col)

	var title := Ui.label("Создать комнату", 26, Color(0.86, 0.9, 1.0), true)
	title.add_theme_font_override("font", Fonts.BLACK)
	col.add_child(title)
	col.add_child(_gap(6))

	col.add_child(Ui.label("Пароль комнаты", 14, Color(0.66, 0.7, 0.82)))
	_pw = LineEdit.new()
	_pw.placeholder_text = "обязателен"
	_pw.add_theme_font_size_override("font_size", 15)
	_pw.text_changed.connect(func(_t: String) -> void: _refresh())
	_pw.text_submitted.connect(func(_t: String) -> void: _try_submit())
	col.add_child(_pw)
	col.add_child(Ui.label("Передайте другу код комнаты и этот пароль.", 12,
		Color(0.55, 0.58, 0.68)))
	_status = Ui.label("", 13, Color(0.95, 0.5, 0.5))
	col.add_child(_status)
	col.add_child(_gap(6))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)

	var back := Ui.neon_button("Назад", Color(0.6, 0.62, 0.7))
	back.custom_minimum_size = Vector2(150, 42)
	back.pressed.connect(func() -> void: back_pressed.emit())
	row.add_child(back)

	_create_btn = Ui.neon_button("Создать", Color(0.4, 0.85, 1.0))
	_create_btn.custom_minimum_size = Vector2(150, 42)
	_create_btn.pressed.connect(_try_submit)
	row.add_child(_create_btn)

	_refresh()
	_pw.grab_focus()


func _try_submit() -> void:
	var pw := _pw.text.strip_edges()
	if pw.is_empty():
		return
	_status.text = ""
	submit.emit(pw)


# A connection-level message from the Router (e.g. server unreachable).
func notify(text: String) -> void:
	if _status != null:
		_status.text = text


func _refresh() -> void:
	_create_btn.disabled = _pw.text.strip_edges().is_empty()


func _gap(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s
