class_name SettingsScreen
extends Control

# Settings: the server address (where the match server lives -- not an identity).
# No name/account fields by design. Reports the chosen address up to the Router
# on close; the Router owns persistence.

signal closed(url: String)

const DEFAULT_URL := "ws://127.0.0.1:8080"

var _url := DEFAULT_URL
var _url_edit: LineEdit = null


# Called by the Router before the screen enters the tree.
func setup(url: String) -> void:
	_url = url


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(Color(0.5, 0.62, 0.9), 0.5))
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.custom_minimum_size = Vector2(420, 0)
	panel.add_child(col)

	var title := Ui.label("Настройки", 28, Color(0.86, 0.9, 1.0), true)
	title.add_theme_font_override("font", Fonts.BLACK)
	col.add_child(title)
	col.add_child(_gap(6))

	col.add_child(Ui.label("Адрес сервера", 14, Color(0.66, 0.7, 0.82)))
	_url_edit = LineEdit.new()
	_url_edit.text = _url
	_url_edit.placeholder_text = DEFAULT_URL
	_url_edit.add_theme_font_size_override("font_size", 15)
	col.add_child(_url_edit)
	col.add_child(Ui.label("Где запущен сервер матча. Код и пароль комнаты появятся позже.",
		12, Color(0.55, 0.58, 0.68)))
	col.add_child(_gap(10))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)

	var reset := Ui.neon_button("Сбросить", Color(0.6, 0.62, 0.7))
	reset.custom_minimum_size = Vector2(150, 42)
	reset.pressed.connect(func() -> void: _url_edit.text = DEFAULT_URL)
	row.add_child(reset)

	var back := Ui.neon_button("Назад", Color(0.45, 0.85, 1.0))
	back.custom_minimum_size = Vector2(150, 42)
	back.pressed.connect(_close)
	row.add_child(back)


func _close() -> void:
	var url := _url_edit.text.strip_edges()
	if url.is_empty():
		url = DEFAULT_URL
	closed.emit(url)


func _gap(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s
