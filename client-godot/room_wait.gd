class_name RoomWait
extends Control

# After creating a room: an orbiting loader, the room code in large mono type to
# read out, the server address to share (we are not hosted yet), and a gentle
# "waiting" line. Cancel sends leaveRoom. Styled from the lobby handoff; the
# mockup's prism core is dropped (no logo) -- WaitOrbit shows a plain glowing core.

signal cancel_pressed

var _code := ""
var _url := ""
var _status: Label = null
var _copy: Button = null


# Called by the Router before the screen enters the tree.
func setup(code: String, server_url: String) -> void:
	_code = code
	_url = server_url


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 8)
	center.add_child(col)

	var orbit := WaitOrbit.new()
	orbit.custom_minimum_size = Vector2(220, 220)
	orbit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(orbit)
	col.add_child(Ui.gap(14))

	col.add_child(Ui.caption("КОД КОМНАТЫ", Ui.INK_DIM, 6))
	col.add_child(_code_label())

	_copy = Ui.mbtn("скопировать  ·  продиктуйте другу", "ghost", Ui.COLORLESS, 340)
	_copy.add_theme_font_size_override("font_size", 15)
	_copy.custom_minimum_size = Vector2(340, 42)
	_copy.pressed.connect(_on_copy)
	col.add_child(_copy)

	col.add_child(Ui.gap(12))
	col.add_child(Ui.caption("АДРЕС СЕРВЕРА ДЛЯ ДРУГА", Ui.INK_FAINT, 4))
	var url := Ui.label(_url, 16, Color(0.78, 0.82, 0.92), true)
	url.add_theme_font_override("font", Fonts.NUM)
	col.add_child(url)

	col.add_child(Ui.gap(10))
	var wait := Ui.label("·  ждём соперника…", 15, Color(0.7, 0.74, 0.85), true)
	col.add_child(wait)
	# A slow breath on the waiting line, echoing the mockup's pulsing pip.
	var tw := create_tween().set_loops()
	tw.tween_property(wait, "modulate:a", 0.45, 1.2).set_trans(Tween.TRANS_SINE)
	tw.tween_property(wait, "modulate:a", 1.0, 1.2).set_trans(Tween.TRANS_SINE)

	_status = Ui.label("", 13, Color(0.95, 0.5, 0.5), true)
	col.add_child(_status)
	col.add_child(Ui.gap(14))

	var cancel := Ui.mbtn("Отмена", "ghost", Ui.COLORLESS, 300)
	cancel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cancel.pressed.connect(func() -> void: cancel_pressed.emit())
	col.add_child(cancel)


func _on_copy() -> void:
	DisplayServer.clipboard_set(_code)
	_copy.text = "скопировано"
	var t := get_tree().create_timer(1.6)
	t.timeout.connect(func() -> void:
		if is_instance_valid(_copy):
			_copy.text = "скопировать  ·  продиктуйте другу")


# A connection-level message from the Router (e.g. lost link while waiting).
func notify(text: String) -> void:
	if _status != null:
		_status.text = text


# The code in large mono display type (Chakra Petch -- Latin codes only), with
# wide tracking and a cool glow so it reads as the screen's hero element.
func _code_label() -> Label:
	var lbl := Ui.label(_code, 72, Color(0.95, 0.97, 1.0), true)
	lbl.add_theme_font_override("font", Fonts.spaced(Fonts.NUM_BLACK, 12))
	lbl.add_theme_color_override("font_shadow_color", Color(0.34, 0.5, 0.98, 0.4))
	lbl.add_theme_constant_override("shadow_outline_size", 16)
	lbl.add_theme_constant_override("shadow_offset_x", 0)
	lbl.add_theme_constant_override("shadow_offset_y", 0)
	return lbl
