class_name PlayMenu
extends Control

# The play hub: create a private room, join one by code, or (later) public search.
# Reports the choice up to the Router; the Router owns the socket and lobby flow.

signal create_pressed
signal join_pressed
signal back_pressed

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

	var title := Ui.label("Играть", 40, Color(0.92, 0.95, 1.0), true)
	title.add_theme_font_override("font", Fonts.BLACK)
	col.add_child(title)
	col.add_child(Ui.gap(18))

	col.add_child(_button("Создать комнату", Color(0.4, 0.85, 1.0),
		func() -> void: create_pressed.emit(), true))
	col.add_child(_button("Войти по коду", Color(0.55, 0.78, 0.95),
		func() -> void: join_pressed.emit()))
	col.add_child(_button("Поиск", Color(0.45, 0.5, 0.6), Callable(), false, true))
	col.add_child(Ui.gap(8))
	col.add_child(_button("Назад", Color(0.6, 0.64, 0.74),
		func() -> void: back_pressed.emit()))
	_status = Ui.label("", 13, Color(0.95, 0.5, 0.5), true)
	col.add_child(_status)


# A connection-level message from the Router (e.g. server unreachable).
func notify(text: String) -> void:
	if _status != null:
		_status.text = text


func _button(text: String, accent: Color, cb: Callable,
		primary := false, disabled := false) -> Button:
	var b := Ui.neon_button(text if not disabled else text + "   ·   скоро", accent)
	b.custom_minimum_size = Vector2(300, 54 if primary else 46)
	b.add_theme_font_size_override("font_size", 19 if primary else 16)
	if disabled:
		b.disabled = true
	else:
		b.pressed.connect(cb)
	return b
