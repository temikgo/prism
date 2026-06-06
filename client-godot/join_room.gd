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

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(Color(0.5, 0.62, 0.9), 0.5))
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(420, 0)
	panel.add_child(col)

	var title := Ui.label("Войти по коду", 26, Color(0.86, 0.9, 1.0), true)
	title.add_theme_font_override("font", Fonts.BLACK)
	col.add_child(title)
	col.add_child(_gap(6))

	col.add_child(Ui.label("Код комнаты", 14, Color(0.66, 0.7, 0.82)))
	_code = LineEdit.new()
	_code.placeholder_text = "напр. PEKY"
	_code.max_length = 4
	_code.add_theme_font_size_override("font_size", 18)
	_code.text_changed.connect(_on_code_changed)
	col.add_child(_code)

	col.add_child(Ui.label("Пароль", 14, Color(0.66, 0.7, 0.82)))
	_pw = LineEdit.new()
	_pw.add_theme_font_size_override("font_size", 15)
	_pw.text_changed.connect(func(_t: String) -> void: _refresh())
	_pw.text_submitted.connect(func(_t: String) -> void: _try_submit())
	col.add_child(_pw)

	_error = Ui.label("", 13, Color(0.95, 0.5, 0.5))
	col.add_child(_error)
	col.add_child(_gap(6))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)

	var back := Ui.neon_button("Назад", Color(0.6, 0.62, 0.7))
	back.custom_minimum_size = Vector2(150, 42)
	back.pressed.connect(func() -> void: back_pressed.emit())
	row.add_child(back)

	_join_btn = Ui.neon_button("Войти", Color(0.4, 0.85, 1.0))
	_join_btn.custom_minimum_size = Vector2(150, 42)
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


func _gap(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s
