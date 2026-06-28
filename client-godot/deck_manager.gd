class_name DeckManager
extends Control

# The deck collection, reached from the main menu's "Колоды". Lists the player's
# saved decks (name, colours, count, legality) with edit/delete, plus a button to
# build a new one. The deck builder is opened from here; the pre-match loadout
# only *selects* an already-built deck. Reuses the shell language (glass panels,
# glowing title, mbtn).

signal edit_deck(deck_id: String)  # "" = build a new deck; else edit that one
signal back_pressed

var _list: VBoxContainer = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 60)
	margin.add_theme_constant_override("margin_right", 60)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 26)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	margin.add_child(root)

	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	head.add_child(Ui.title("Колоды", 32))
	head.add_child(Ui.label("соберите свои колоды по 40 карт — потом выбирайте их перед матчем",
		13, Ui.INK_DIM))
	root.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 12)
	scroll.add_child(_list)
	root.add_child(scroll)
	_rebuild()

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 12)
	var back := Ui.mbtn("Назад", "ghost", Ui.COLORLESS, 200)
	back.pressed.connect(func() -> void: back_pressed.emit())
	foot.add_child(back)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp)
	var imp := Ui.mbtn("Импорт по коду", "ghost", Ui.ACC_VIOLET, 240)
	imp.pressed.connect(_open_import)
	foot.add_child(imp)
	var create := Ui.mbtn("＋ Создать колоду", "primary", Ui.SIDE_ME, 320)
	create.pressed.connect(func() -> void: edit_deck.emit(""))
	foot.add_child(create)
	root.add_child(foot)


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()
	var decks := Decks.all()
	if decks.is_empty():
		var center := CenterContainer.new()
		center.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var note := Ui.label("У вас пока нет колод.\nНажмите «Создать колоду», чтобы собрать первую.",
			16, Ui.INK_DIM, true)
		note.add_theme_constant_override("line_spacing", 7)
		center.add_child(note)
		_list.add_child(center)
		return
	for d in decks:
		_list.add_child(_deck_row(d))


func _deck_row(deck: Dictionary) -> Control:
	var panel := PanelContainer.new()
	# A plain dark slab, NOT panel_glass -- the latter's blue-tinted border + blue
	# shadow read as a stray translucent frame behind each deck.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.055, 0.063, 0.11, 0.7)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(1)
	sb.border_color = Ui.PANEL_STROKE
	sb.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 6)
	var nm := Ui.label(String(deck["name"]), 22, Color(0.94, 0.96, 1.0), false, true)
	nm.add_theme_font_override("font", Fonts.BLACK)
	info.add_child(nm)
	info.add_child(_color_bar(deck))
	var n: int = deck.get("cards", []).size()
	var legal := DeckRules.is_legal(_counts(deck))
	var meta := "%d карт" % n
	var tone := Ui.INK_DIM
	if not legal:
		meta += "  ·  нелегальна"
		tone = Color(0.92, 0.5, 0.5)
	info.add_child(Ui.label(meta, 14, tone))
	row.add_child(info)

	var did := String(deck["id"])
	var share := Ui.mbtn("Поделиться", "ghost", Ui.ACC_VIOLET, 150)
	share.pressed.connect(func() -> void: _open_share(deck))
	row.add_child(share)
	var edit := Ui.mbtn("Изменить", "ghost", Ui.SIDE_ME, 150)
	edit.pressed.connect(func() -> void: edit_deck.emit(did))
	row.add_child(edit)
	var del := Ui.mbtn("Удалить", "ghost", Ui.SIDE_FOE, 130)
	del.pressed.connect(func() -> void: _confirm_delete(deck))
	row.add_child(del)
	return panel


func _confirm_delete(deck: Dictionary) -> void:
	var did := String(deck["id"])
	var dlg := ConfirmDialog.new()
	dlg.confirmed.connect(func() -> void:
		Decks.delete_deck(did)
		_rebuild())
	add_child(dlg)
	dlg.setup("Удалить колоду?", ["«%s» будет удалена безвозвратно." % String(deck["name"])],
		"Удалить", "Отмена", Color(0.92, 0.30, 0.34))


# A dim-backdrop centered modal; returns { overlay, col } to fill with content.
func _modal(title: String) -> Dictionary:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.z_index = 4096
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.02, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			overlay.queue_free())
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(Ui.ACC_VIOLET, 0.72))
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(500, 0)
	panel.add_child(col)
	col.add_child(Ui.label(title, 20, Color(0.94, 0.96, 1.0), true, true))
	add_child(overlay)
	return {"overlay": overlay, "col": col}


func _open_share(deck: Dictionary) -> void:
	var dlg := ShareDialog.new()
	add_child(dlg)
	dlg.setup(deck)


func _open_import() -> void:
	var m := _modal("Импорт колоды по коду")
	var col: VBoxContainer = m["col"]
	col.add_child(Ui.label("Вставьте код колоды, полученный от друга.", 13, Ui.INK_DIM, true))
	var box := TextEdit.new()
	box.placeholder_text = "вставьте код сюда…"
	box.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.custom_minimum_size = Vector2(500, 120)
	col.add_child(box)
	var err := Ui.label("", 13, Color(0.95, 0.4, 0.45), true)
	err.visible = false
	col.add_child(err)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var imp := Ui.mbtn("Импортировать", "primary", Ui.ACC_VIOLET, 220)
	imp.pressed.connect(func() -> void:
		var d := Decks.import_code(box.text)
		if d.is_empty():
			err.text = "Неверный код или карты из другого набора."
			err.visible = true
		else:
			m["overlay"].queue_free()
			_rebuild())
	var cancel := Ui.mbtn("Отмена", "ghost", Ui.COLORLESS, 160)
	cancel.pressed.connect(func() -> void: m["overlay"].queue_free())
	row.add_child(imp)
	row.add_child(cancel)
	col.add_child(row)


# A small spectrum bar of the colours present in the deck (its identity).
func _color_bar(deck: Dictionary) -> Control:
	var present := {}
	for cid in deck.get("cards", []):
		for c in CardData.def(String(cid)).get("color", []):
			present[String(c)] = true
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for col_name in CardData.COLORS:
		if not present.has(col_name):
			continue
		var bar := Panel.new()
		bar.custom_minimum_size = Vector2(30, 7)
		var c := Palette.color_for(col_name)
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sb.set_corner_radius_all(4)
		sb.shadow_size = 5
		sb.shadow_color = Color(c.r, c.g, c.b, 0.5)
		bar.add_theme_stylebox_override("panel", sb)
		row.add_child(bar)
	return row


func _counts(deck: Dictionary) -> Dictionary:
	var c := {}
	for cid in deck.get("cards", []):
		c[cid] = int(c.get(cid, 0)) + 1
	return c
