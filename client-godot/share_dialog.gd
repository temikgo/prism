class_name ShareDialog
extends Control

# Modal that shows a deck's shareable code (base64, from Decks.export_code) with a
# copy-to-clipboard button. Dim backdrop + centered glass panel, like ConfirmDialog.

func setup(deck: Dictionary) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
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
	panel.add_theme_stylebox_override("panel", Ui.glass(Ui.ACC_VIOLET, 0.72))
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(500, 0)
	panel.add_child(col)

	col.add_child(Ui.label("Код колоды «%s»" % String(deck.get("name", "")), 20,
		Color(0.94, 0.96, 1.0), true, true))
	var hint := Ui.label("Скопируйте код и отправьте другу — он вставит его через «Импорт по коду».",
		13, Ui.INK_DIM, true)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(500, 0)
	col.add_child(hint)

	var code := Decks.export_code(deck)
	var box := TextEdit.new()
	box.text = code
	box.editable = false
	box.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.custom_minimum_size = Vector2(500, 120)
	col.add_child(box)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var copy := Ui.mbtn("Скопировать", "primary", Ui.ACC_VIOLET, 220)
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(code)
		copy.text = "Скопировано")
	var close := Ui.mbtn("Закрыть", "ghost", Ui.COLORLESS, 160)
	close.pressed.connect(func() -> void: queue_free())
	row.add_child(copy)
	row.add_child(close)
	col.add_child(row)
