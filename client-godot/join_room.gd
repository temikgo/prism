class_name JoinRoom
extends Control

# Join a private room by code + password. The Router sends joinRoom; on success
# the match begins, on failure it calls show_error() with the server's reason.

signal submit(code: String, password: String)
signal back_pressed

const REASONS := {
	"no_room": "Комната не найдена",
	"bad_password": "Неверный пароль",
	"room_full": "Комната уже занята",
}

var _code: LineEdit = null
var _pw: LineEdit = null
var _error: Label = null
var _join_btn: Button = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)

	col.add_child(Ui.title("Войти по коду", 32))
	col.add_child(Ui.gap(10))

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.panel_glass())
	col.add_child(panel)
	var pcol := VBoxContainer.new()
	pcol.add_theme_constant_override("separation", 8)
	pcol.custom_minimum_size = Vector2(440, 0)
	panel.add_child(pcol)

	pcol.add_child(Ui.caption("КОД КОМНАТЫ"))
	_code = Ui.style_input(LineEdit.new(), true, true)  # big mono code field
	_code.placeholder_text = "----"
	_code.max_length = 4
	_code.text_changed.connect(_on_code_changed)
	pcol.add_child(_code)

	pcol.add_child(Ui.gap(2))
	pcol.add_child(Ui.caption("ПАРОЛЬ"))
	_pw = Ui.style_input(LineEdit.new())
	_pw.placeholder_text = "пароль комнаты"
	_pw.add_theme_font_size_override("font_size", 16)
	_pw.text_changed.connect(func(_t: String) -> void: _refresh())
	_pw.text_submitted.connect(func(_t: String) -> void: _try_submit())
	pcol.add_child(_pw)
	_error = Ui.label("", 14, Color(0.95, 0.5, 0.5))
	pcol.add_child(_error)

	col.add_child(Ui.gap(6))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)

	var back := Ui.mbtn("Назад", "ghost", Ui.COLORLESS, 160)
	back.pressed.connect(func() -> void: back_pressed.emit())
	row.add_child(back)
	_join_btn = Ui.mbtn("Войти", "primary", Ui.SIDE_ME, 200)
	_join_btn.pressed.connect(_try_submit)
	row.add_child(_join_btn)

	_refresh()
	_code.grab_focus()


# Show a server-reported failure and re-enable the form.
func show_error(reason: String) -> void:
	_error.text = REASONS.get(reason, "Не удалось войти")
	_join_btn.disabled = false


# A connection-level message from the Router (e.g. lost link).
func notify(text: String) -> void:
	_error.text = text
	_join_btn.disabled = false


func _on_code_changed(t: String) -> void:
	# Codes are uppercase; keep the caret at the end after rewriting.
	var up := t.to_upper()
	if up != t:
		_code.text = up
		_code.caret_column = up.length()
	_error.text = ""
	_refresh()
	# Codes are exactly 4 chars: once full, jump to the password field.
	if up.length() >= 4:
		_pw.grab_focus()


func _try_submit() -> void:
	var code := _code.text.strip_edges().to_upper()
	var pw := _pw.text.strip_edges()
	if code.length() < 4 or pw.is_empty():
		return
	_error.text = ""
	_join_btn.disabled = true
	submit.emit(code, pw)


func _refresh() -> void:
	var ok := _code.text.strip_edges().length() >= 4 \
		and not _pw.text.strip_edges().is_empty()
	_join_btn.disabled = not ok
