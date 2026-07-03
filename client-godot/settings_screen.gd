class_name SettingsScreen
extends Control

# Settings: the server address (where the match server lives -- not an identity).
# No name/account fields by design. Reports the chosen address up to the Router
# on close; the Router owns persistence. Styled from the Claude Design handoff:
# a glowing title, one glass panel with a mono address field, ghost pill buttons.

signal closed(url: String)

const DEFAULT_URL := "ws://127.0.0.1:8080"

var _url := DEFAULT_URL
var _url_edit: LineEdit = null
var _saved: Label = null


# Called by the Router before the screen enters the tree.
func setup(url: String) -> void:
	_url = url


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)

	col.add_child(Ui.title("Настройки", 32))
	col.add_child(Ui.gap(10))

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.panel_glass())
	col.add_child(panel)
	var pcol := VBoxContainer.new()
	pcol.add_theme_constant_override("separation", 8)
	pcol.custom_minimum_size = Vector2(460, 0)
	panel.add_child(pcol)

	pcol.add_child(Ui.caption("АДРЕС СЕРВЕРА"))
	_url_edit = Ui.style_input(LineEdit.new(), true)  # mono: a debug address
	_url_edit.text = _url
	_url_edit.placeholder_text = DEFAULT_URL
	_url_edit.add_theme_font_size_override("font_size", 16)
	pcol.add_child(_url_edit)
	pcol.add_child(Ui.label("Где запущен сервер матча.", 14, Ui.INK_FAINT))

	pcol.add_child(Ui.gap(8))
	pcol.add_child(Ui.caption("ГРОМКОСТЬ"))
	pcol.add_child(_volume_row("Музыка", Audio.music_vol(), Audio.set_music))
	pcol.add_child(_volume_row("Звук", Audio.sfx_vol(), Audio.set_sfx))

	col.add_child(Ui.gap(6))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)

	var reset := Ui.mbtn("Сбросить", "ghost", Ui.COLORLESS, 180)
	reset.pressed.connect(_on_reset)
	row.add_child(reset)
	var back := Ui.mbtn("Назад", "primary", Ui.SIDE_ME, 180)
	back.pressed.connect(_close)
	row.add_child(back)

	_saved = Ui.label("", 13, Color(0.55, 0.82, 0.7), true)
	col.add_child(_saved)


# One labelled volume slider (0..1). `apply` is Audio.set_music / Audio.set_sfx, which
# updates the bus live and persists it; it also plays a click so you hear the level.
func _volume_row(label: String, value: float, apply: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var lbl := Ui.label(label, 14, Ui.INK_FAINT)
	lbl.custom_minimum_size = Vector2(80, 0)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = value
	slider.custom_minimum_size = Vector2(340, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(v: float) -> void:
		apply.call(v)
		Audio.play("ui_toggle"))  # a soft tick per notch, not a click per drag step
	row.add_child(slider)
	return row


func _on_reset() -> void:
	_url_edit.text = DEFAULT_URL
	_saved.text = "сброшено"
	var t := get_tree().create_timer(1.4)
	t.timeout.connect(func() -> void:
		if is_instance_valid(_saved):
			_saved.text = "")


func _close() -> void:
	var url := _url_edit.text.strip_edges()
	if url.is_empty():
		url = DEFAULT_URL
	closed.emit(url)
