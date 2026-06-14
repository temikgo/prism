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

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)

	col.add_child(Ui.title("Создать комнату", 32))
	col.add_child(Ui.gap(10))

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.panel_glass())
	col.add_child(panel)
	var pcol := VBoxContainer.new()
	pcol.add_theme_constant_override("separation", 10)
	pcol.custom_minimum_size = Vector2(440, 0)
	panel.add_child(pcol)

	pcol.add_child(Ui.caption("ПАРОЛЬ КОМНАТЫ"))
	_pw = Ui.style_input(LineEdit.new())
	_pw.placeholder_text = "придумайте пароль"
	_pw.add_theme_font_size_override("font_size", 16)
	_pw.text_changed.connect(func(_t: String) -> void: _refresh())
	_pw.text_submitted.connect(func(_t: String) -> void: _try_submit())
	pcol.add_child(_pw)
	pcol.add_child(Ui.label("Передайте другу код комнаты и этот пароль.", 14,
		Ui.INK_FAINT))
	_status = Ui.label("", 14, Color(0.95, 0.5, 0.5))
	pcol.add_child(_status)

	col.add_child(Ui.gap(6))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)

	var back := Ui.mbtn("Назад", "ghost", Ui.COLORLESS, 160)
	back.pressed.connect(func() -> void: back_pressed.emit())
	row.add_child(back)
	_create_btn = Ui.mbtn("Создать", "primary", Ui.SIDE_ME, 200)
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
