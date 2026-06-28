class_name GenDialog
extends Control

# Modal color picker for auto-deck generation. Shows the five colors as the
# board's faceted mana crystals; click to pick (bright) or unpick (dim). Emits
# `generate(colors)` with the chosen color ids -- empty is allowed (a colorless
# deck). Mirrors ConfirmDialog's dim-backdrop + centered-glass-panel shape.

signal generate(colors: Array)

var _picked := {}  # color id -> bool
var _crystals := {}  # color id -> CrystalNode


func setup() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	position = Vector2.ZERO
	size = get_viewport_rect().size
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_as_relative = false
	z_index = 4096

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.02, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			queue_free())
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(Ui.SIDE_ME, 0.72))
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.custom_minimum_size = Vector2(380, 0)
	panel.add_child(col)

	col.add_child(Ui.label("Догенерировать колоду", 22, Color(0.94, 0.96, 1.0), true, true))
	var hint := Ui.label(
		"Уже набранные карты сохранятся — добор до 40. Цвета: пусто — бесцветная, один — моно, все пять — с пятицветками.",
		15, Ui.INK_DIM, true)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(380, 0)
	col.add_child(hint)

	var crow := HBoxContainer.new()
	crow.alignment = BoxContainer.ALIGNMENT_CENTER
	crow.add_theme_constant_override("separation", 16)
	col.add_child(crow)
	for c in CardData.COLORS:
		crow.add_child(_pip(String(c)))

	var brow := HBoxContainer.new()
	brow.alignment = BoxContainer.ALIGNMENT_CENTER
	brow.add_theme_constant_override("separation", 10)
	var go := Ui.mbtn("Догенерировать", "primary", Ui.SIDE_ME, 210)
	go.pressed.connect(func() -> void:
		var picked: Array = []
		for c in CardData.COLORS:
			if bool(_picked.get(c, false)):
				picked.append(c)
		generate.emit(picked)
		queue_free())
	var cancel := Ui.mbtn("Отмена", "ghost", Ui.SIDE_ME, 140)
	cancel.pressed.connect(func() -> void: queue_free())
	brow.add_child(go)
	brow.add_child(cancel)
	col.add_child(brow)


func _pip(color: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	var cr := CrystalNode.new()
	cr.crystal_color = Palette.color_for(color)
	cr.spent = true  # starts unpicked = dim; clicking lights it
	cr.custom_minimum_size = Vector2(44, 60)
	cr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER  # fixed width, never stretch
	cr.mouse_filter = Control.MOUSE_FILTER_STOP
	cr.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_toggle(color))
	_crystals[color] = cr
	box.add_child(cr)
	var nm := Ui.label(Palette.ru(color).capitalize(), 13, Ui.INK_DIM, true, true)
	box.add_child(nm)
	return box


func _toggle(color: String) -> void:
	var on := not bool(_picked.get(color, false))
	_picked[color] = on
	var cr: CrystalNode = _crystals[color]
	cr.spent = not on
	cr.selected = on
	cr.queue_redraw()
