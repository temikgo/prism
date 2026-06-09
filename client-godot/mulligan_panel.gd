class_name MulliganPanel
extends Control

# Opening-hand mulligan overlay: tap cards to mark them for replacement, then
# confirm. The selection lives in the coordinator (it must survive a view refresh
# when the opponent confirms mid-pick), so this panel is a stateless view: it is
# rebuilt from (hand, sel) and emits `toggle(index)` / `submit` for the host.

signal toggle(index: int)
signal submit


func setup(hand: Array, sel: Dictionary, done: bool) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # block the board underneath
	var accent := Color(0.45, 0.85, 1.0)

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

	var title := Ui.label("", 30, accent.lightened(0.3), true)
	vb.add_child(title)

	# Once you have confirmed, just wait for the opponent.
	if done:
		title.text = "Ждём соперника…"
		vb.add_child(Ui.label("Ваш мулиган принят.", 0, Color(0.75, 0.78, 0.86), true))
		return

	title.text = "Мулиган"
	vb.add_child(Ui.label("Нажмите на карты, которые хотите заменить, затем подтвердите.",
		14, Color(0.75, 0.78, 0.86), true))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for i in hand.size():
		var cid: String = hand[i]
		var marked: bool = sel.has(i)
		var wrap := Control.new()
		wrap.custom_minimum_size = Tokens.CARD_SIZE
		var card := CardView.widget(cid, null)
		if marked:
			# Dim and red-tint cards staged for replacement.
			card.modulate = Color(1.0, 0.5, 0.5, 0.6)
			card.rest_modulate = card.modulate
		var idx := i
		card.clicked.connect(func(_p: Dictionary) -> void: toggle.emit(idx))
		wrap.add_child(card)
		if marked:
			var badge := Ui.label("ЗАМЕНА", 16, Color(1.0, 0.7, 0.7), true)
			badge.position = Vector2(0, Tokens.CARD_SIZE.y / 2.0 - 12)
			badge.size = Vector2(Tokens.CARD_SIZE.x, 24)
			badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			wrap.add_child(badge)
		row.add_child(wrap)
	vb.add_child(row)

	var n := sel.size()
	var btn := Ui.neon_button("Заменить %d" % n if n > 0 else "Оставить руку", accent)
	btn.custom_minimum_size = Vector2(0, 40)
	btn.pressed.connect(func() -> void: submit.emit())
	vb.add_child(btn)
