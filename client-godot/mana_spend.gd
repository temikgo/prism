class_name ManaSpendPicker
extends Control

# Full-screen overlay to choose which crystals pay a card's generic cost, when
# that choice is ambiguous. Shows your available crystals in a single row: the
# ones reserved for the card's colored cost are dim/locked, the rest are
# tappable. Tap exactly `generic` of the free ones (each tap toggles one), then
# confirm. Emits `picked(generic_pay)` as a {color: count} map; cancel frees it.

signal picked(generic_pay: Dictionary)
signal cancelled

var _generic := 0
var _free := []   # [{node: Panel, color: String, sel: bool}] -- the tappable ones
var _count_label: Label = null
var _confirm: Button = null


func setup(generic: int, avail: Dictionary, pips: Dictionary) -> void:
	_generic = generic
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Pin to the whole viewport explicitly: added as a plain child (not in a
	# container), the anchor pass can otherwise leave us at content size.
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
			cancelled.emit()
			queue_free())
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(Color(0.55, 0.62, 0.9), 0.7))
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)

	col.add_child(Ui.label("Чем оплатить бесцветную ману", 19,
		Color(0.9, 0.93, 1.0), true, true))
	col.add_child(Ui.label("Тёмные кристаллы зарезервированы под цвет. Выбери %d." % _generic,
		12, Color(0.62, 0.66, 0.78), true))
	col.add_child(Ui.gap(2))

	# One compact row: all crystals, grouped by color, locked ones first.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 5)
	for color in CardData.ALL_COLORS:
		var have := int(avail.get(color, 0))
		var reserved := int(pips.get(color, 0))
		for i in have:
			if i < reserved:
				row.add_child(_pip(color, true, false))  # locked for the colored cost
			else:
				var cell := _pip(color, false, false)
				var entry := {"node": cell, "color": color, "sel": false}
				_free.append(entry)
				cell.gui_input.connect(func(e: InputEvent) -> void:
					if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
						_toggle(entry))
				row.add_child(cell)
	col.add_child(row)

	col.add_child(Ui.gap(2))
	_count_label = Ui.label("", 14, Color(0.85, 0.88, 1.0), true, true)
	col.add_child(_count_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	col.add_child(buttons)
	var cancel := Ui.neon_button("Отмена", Color(0.6, 0.62, 0.7))
	cancel.custom_minimum_size = Vector2(140, 40)
	cancel.pressed.connect(func() -> void:
		cancelled.emit()
		queue_free())
	buttons.add_child(cancel)
	_confirm = Ui.neon_button("Оплатить", Color(0.45, 0.85, 1.0))
	_confirm.custom_minimum_size = Vector2(140, 40)
	_confirm.pressed.connect(_on_confirm)
	buttons.add_child(_confirm)

	_refresh()


# A 18x24 crystal cell. `locked` => reserved (dim, not tappable); otherwise a free
# crystal whose look flips between chosen (bright) and unchosen (faint).
func _pip(color: String, locked: bool, chosen: bool) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(46, 58)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE if locked else Control.MOUSE_FILTER_STOP
	_style_pip(p, Palette.color_for(color), locked, chosen)
	return p


# Three clearly distinct tiers: locked = dark grey (reserved for the colored
# cost), free = full saturated colour (tappable), chosen = bright + glow (picked).
func _style_pip(p: Panel, c: Color, locked: bool, chosen: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(2)
	if locked:
		sb.bg_color = Color(0.16, 0.17, 0.21, 0.95)
		sb.border_color = Color(0.30, 0.32, 0.38)
	elif chosen:
		sb.bg_color = c.lightened(0.12)
		sb.set_border_width_all(3)
		sb.border_color = Color(1, 1, 1, 0.9)
		sb.shadow_size = 10
		sb.shadow_color = Color(c.r, c.g, c.b, 0.8)
	else:
		sb.bg_color = c
		sb.border_color = c.lightened(0.5)
	p.add_theme_stylebox_override("panel", sb)


func _total() -> int:
	var n := 0
	for e in _free:
		if e["sel"]:
			n += 1
	return n


# Toggle exactly the tapped crystal: deselect it if chosen, else select it (only
# while the total is still under the needed amount). No "fill up to here" jump.
func _toggle(entry: Dictionary) -> void:
	if entry["sel"]:
		entry["sel"] = false
	elif _total() < _generic:
		entry["sel"] = true
	_refresh()


func _refresh() -> void:
	for e in _free:
		_style_pip(e["node"], Palette.color_for(e["color"]), false, e["sel"])
	var total := _total()
	_count_label.text = "Выбрано %d / %d" % [total, _generic]
	_confirm.disabled = total != _generic


func _on_confirm() -> void:
	if _total() != _generic:
		return
	var pay := {}
	for e in _free:
		if e["sel"]:
			pay[e["color"]] = int(pay.get(e["color"], 0)) + 1
	picked.emit(pay)
	queue_free()
