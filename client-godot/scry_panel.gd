class_name ScryPanel
extends Control

# Blue scry overlay: the peeked top cards (top first), tap any to send it to the
# bottom, then confirm; the unmarked ones stay on top in order. Like MulliganPanel,
# the selection lives in the coordinator -- this is a stateless view rebuilt from
# (peek, sel) that emits `toggle(index)` / `submit`.

signal toggle(index: int)
signal submit


func setup(peek: Array, sel: Dictionary) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var accent := Color(0.45, 0.7, 1.0)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(accent, 0.92))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	center.add_child(panel)

	vb.add_child(Ui.label("Прозрение", 30, accent.lightened(0.3), true))
	vb.add_child(Ui.label("Верх колоды слева. Отметьте карты, которые уберёте ВНИЗ; остальные останутся сверху.",
		14, Color(0.75, 0.78, 0.86), true))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for i in peek.size():
		var cid: String = peek[i]
		var marked: bool = sel.has(i)
		var wrap := Control.new()
		wrap.custom_minimum_size = Tokens.CARD_SIZE
		var card := CardView.widget(cid, null)
		if marked:
			card.modulate = Color(0.6, 0.7, 1.0, 0.6)
			card.rest_modulate = card.modulate
		var idx := i
		card.clicked.connect(func(_p: Dictionary) -> void: toggle.emit(idx))
		wrap.add_child(card)
		var pos_l := Ui.label("ВНИЗ" if marked else "верх %d" % (i + 1), 14,
			Color(0.7, 0.8, 1.0) if marked else Color(0.7, 0.73, 0.82), true)
		pos_l.position = Vector2(0, Tokens.CARD_SIZE.y / 2.0 - 12)
		pos_l.size = Vector2(Tokens.CARD_SIZE.x, 24)
		pos_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wrap.add_child(pos_l)
		row.add_child(wrap)
	vb.add_child(row)

	var n := sel.size()
	var btn := Ui.neon_button("Убрать вниз: %d" % n if n > 0 else "Оставить всё сверху", accent)
	btn.custom_minimum_size = Vector2(0, 40)
	btn.pressed.connect(func() -> void: submit.emit())
	vb.add_child(btn)
