class_name PlayMenu
extends Control

# The play hub: create a private room, join one by code, or (later) public search.
# Reports the choice up to the Router; the Router owns the socket and lobby flow.

signal create_pressed
signal join_pressed
signal train_pressed
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

	col.add_child(Ui.title("Играть", 40))
	col.add_child(Ui.gap(20))

	var create := Ui.mbtn("Создать комнату", "primary", Ui.SIDE_ME)
	create.pressed.connect(func() -> void: create_pressed.emit())
	col.add_child(create)
	var join := Ui.mbtn("Войти по коду", "ghost", Ui.SIDE_ME)
	join.pressed.connect(func() -> void: join_pressed.emit())
	col.add_child(join)
	col.add_child(Ui.mbtn("Поиск", "muted", Ui.ACC_VIOLET))

	# Single-player: one button starts a match against the bot immediately.
	var train := Ui.mbtn("Тренировка", "ghost", Ui.ACC_VIOLET)
	train.pressed.connect(func() -> void: train_pressed.emit())
	col.add_child(train)

	var back := Ui.mbtn("Назад", "ghost", Ui.COLORLESS)
	back.pressed.connect(func() -> void: back_pressed.emit())
	col.add_child(back)

	col.add_child(Ui.gap(6))
	_status = Ui.label("", 13, Color(0.95, 0.5, 0.5), true)
	col.add_child(_status)


# A connection-level message from the Router (e.g. server unreachable).
func notify(text: String) -> void:
	if _status != null:
		_status.text = text
