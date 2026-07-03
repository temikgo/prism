class_name LoadoutSelect
extends Control

# Pre-match loadout: pick a hero (left) and a deck (right) before entering a
# room. Local choice (no opponent sync) -- it travels with createRoom/joinRoom.
# "Далее" is enabled only once both a hero and a deck are chosen; with no decks
# (the player's collection is empty) a match cannot start. Reports the choice up
# to the Router, which persists it and carries it into the room flow. Styled from
# the Claude Design handoff: glowing title, two glass panels with count headers,
# hero tiles with portrait + passive, a deck list, and a summary + pill bar.

signal confirmed(hero_id: String, deck_id: String)
signal back_pressed
signal create_deck  # jump straight to building a new deck
signal edit_deck(deck_id: String)  # open the deck builder on an existing deck

const HERO_HP := 30

var _hero_id := ""
var _deck_id := ""
var _hero_cards := {}   # hero id -> its selectable panel (for highlight)
var _deck_cards := {}   # deck id -> its selectable panel
var _next_btn: Button = null
var _hero_summary: Label = null
var _deck_summary: Label = null


# Called by the Router before the screen enters the tree, to restore the choice.
func setup(hero_id: String, deck_id: String) -> void:
	_hero_id = hero_id
	_deck_id = deck_id


# First run (nothing saved, or a saved id that no longer exists): preselect the
# first hero and the first deck so "Далее" is active immediately. With no decks
# at all, the deck stays unset (a match cannot start -- handled by the gate).
func _apply_defaults() -> void:
	var heroes := CardData.heroes()
	if (_hero_id == "" or not heroes.has(_hero_id)) and not heroes.is_empty():
		_hero_id = String(heroes[0])
	var decks := Decks.all()
	if (_deck_id == "" or Decks.by_id(_deck_id).is_empty()) and not decks.is_empty():
		_deck_id = String(decks[0]["id"])


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_apply_defaults()  # first run (no saved choice): preselect a sensible loadout
	_build()


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 52)
	margin.add_theme_constant_override("margin_right", 52)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 24)
	margin.add_child(root)
	add_child(margin)

	root.add_child(Ui.title("Выбор героя и колоды", 32))

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 28)
	root.add_child(cols)
	cols.add_child(_hero_column())
	cols.add_child(_deck_column())

	root.add_child(_foot())
	_refresh()


# Tear down and rebuild (after deleting a deck, so the list reflows).
func _rebuild() -> void:
	_deck_cards.clear()
	for c in get_children():
		c.queue_free()
	_build()


# --- bottom bar: back + summary + next --------------------------------------

func _foot() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 18)
	bar.alignment = BoxContainer.ALIGNMENT_CENTER

	var back := Ui.mbtn("Назад", "ghost", Ui.COLORLESS, 160)
	back.pressed.connect(func() -> void: back_pressed.emit())
	bar.add_child(back)

	# Centred summary chip (hero / deck), grows to push the buttons to the edges.
	var summary := PanelContainer.new()
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.add_theme_stylebox_override("panel", Ui.panel_glass())
	var srow := HBoxContainer.new()
	srow.alignment = BoxContainer.ALIGNMENT_CENTER
	srow.add_theme_constant_override("separation", 26)
	summary.add_child(srow)
	_hero_summary = _summary_pick(srow, "ГЕРОЙ")
	var sep := VSeparator.new()
	srow.add_child(sep)
	_deck_summary = _summary_pick(srow, "КОЛОДА")
	bar.add_child(summary)

	_next_btn = Ui.mbtn("Далее", "primary", Ui.SIDE_ME, 200)
	_next_btn.pressed.connect(_on_next)
	bar.add_child(_next_btn)
	return bar


# One "label: value" pick in the summary chip. Returns the value Label to update.
func _summary_pick(into: HBoxContainer, label: String) -> Label:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	into.add_child(v)
	v.add_child(Ui.caption(label, Ui.INK_FAINT, 3))
	var val := Ui.label("—", 17, Ui.INK, false, true)
	v.add_child(val)
	return val


# --- column shell ------------------------------------------------------------

# A full-height glass column with a header row: a title (left) and a small count
# caption (right). `content` expands to fill the body.
func _column_panel(title: String, count: String, content: Control) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", Ui.panel_glass())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	panel.add_child(v)

	var headrow := HBoxContainer.new()
	v.add_child(headrow)
	var ht := Ui.label(title, 20, Ui.INK, false, true)
	headrow.add_child(ht)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	headrow.add_child(spacer)
	var cnt := Ui.caption(count, Ui.INK_DIM, 2)
	cnt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	headrow.add_child(cnt)

	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(content)
	return panel


# --- hero column -------------------------------------------------------------

func _hero_column() -> Control:
	var heroes := CardData.heroes()
	var grid := GridContainer.new()
	grid.columns = clampi(int(ceil(sqrt(float(max(heroes.size(), 1))))), 1, 4)
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	for hid in heroes:
		var tile := _hero_tile(hid)
		_hero_cards[hid] = tile
		grid.add_child(tile)
	return _column_panel("Герои", "%d доступно" % heroes.size(), grid)


func _hero_tile(hero_id: String) -> Control:
	var d := CardData.def(hero_id)
	var passive := []
	for kw in d.get("keywords", []):
		passive.append({"id": String(kw.get("id", ""))})
	var hero := {"card": hero_id, "name": CardData.name_of(hero_id),
		"hp": HERO_HP, "armor": 0, "passive": passive}

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(_hero_inner(hero))
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			Audio.play("ui_tap")
			_hero_id = hero_id
			_refresh())
	_hook_hover(panel, func() -> bool: return hero_id == _hero_id)
	return panel


func _hero_inner(hero: Dictionary) -> Control:
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(HeroView.portrait_with_hp(hero, 132))
	var nm := Ui.label(String(hero["name"]), 19, Color(0.94, 0.96, 1.0), true, true)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nm)

	# Passive name + a short plain-language description (the mockup's pname/ptext).
	var passive: Array = hero.get("passive", [])
	if not passive.is_empty():
		var kw: Dictionary = passive[0]
		var pname := Ui.label(Glossary.keyword_name(kw), 14, Ui.SIDE_ME.lightened(0.25), true, true)
		pname.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(pname)
		var full := Glossary.keyword(kw)
		var ci := full.find(":")
		var ptext := full.substr(ci + 1).strip_edges() if ci > 0 else full
		var pt := Ui.label(ptext, 12, Ui.INK_DIM, true)
		pt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		pt.custom_minimum_size = Vector2(190, 0)
		pt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(pt)
	center.add_child(v)
	return center


# --- deck column -------------------------------------------------------------

func _deck_column() -> Control:
	var decks := Decks.all()
	var content := VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	if decks.is_empty():
		var center := CenterContainer.new()
		center.size_flags_vertical = Control.SIZE_EXPAND_FILL
		center.add_child(Ui.label("У вас пока нет колод.\nСоздайте колоду, чтобы играть.",
			16, Ui.INK_DIM, true))
		content.add_child(center)
	else:
		var list := VBoxContainer.new()
		list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 12)
		for d in decks:
			list.add_child(_deck_tile(d))  # registers the panel in _deck_cards itself
		content.add_child(list)
	var create := Ui.mbtn("Создать колоду", "ghost", Ui.ACC_VIOLET, 300)
	create.pressed.connect(func() -> void: create_deck.emit())
	content.add_child(create)
	return _column_panel("Колоды", "%d %s" % [decks.size(), _decks_word(decks.size())], content)


# Russian plural for "колода" (1 колода / 2 колоды / 5 колод).
func _decks_word(n: int) -> String:
	var n10 := n % 10
	var n100 := n % 100
	if n10 == 1 and n100 != 11:
		return "колода"
	if n10 >= 2 and n10 <= 4 and (n100 < 10 or n100 >= 20):
		return "колоды"
	return "колод"


func _is_user_deck(did: String) -> bool:
	for d in Decks.user_decks():
		if String(d["id"]) == did:
			return true
	return false


func _confirm_delete(deck: Dictionary) -> void:
	var did := String(deck["id"])
	var dlg := ConfirmDialog.new()
	dlg.confirmed.connect(func() -> void:
		Decks.delete_deck(did)
		if _deck_id == did:
			_deck_id = ""
			_apply_defaults()
		_rebuild())
	add_child(dlg)
	dlg.setup("Удалить колоду?", ["«%s» будет удалена безвозвратно." % String(deck["name"])],
		"Удалить", "Отмена", Color(0.92, 0.30, 0.34))


func _deck_tile(deck: Dictionary) -> Control:
	var did0 := String(deck["id"])
	if not _is_user_deck(did0):
		var p := _deck_panel(deck)
		_deck_cards[did0] = p  # the panel is what _restyle re-styles on (re)select
		return p
	# User decks get edit + delete buttons overlaid top-right; wrap the panel in a
	# plain Control so the buttons float over it without the container reflowing it.
	var wrap := Control.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel := _deck_panel(deck, wrap)  # hover scales the wrap so the buttons ride along
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.add_child(panel)
	_deck_cards[did0] = panel  # _refresh re-styles THIS, so selection stays exclusive
	var share := _corner_button("res://icons/share.svg",
		Color(0.55, 0.7, 0.7), Color(0.5, 0.92, 0.92), -106)
	share.pressed.connect(func() -> void:
		var dlg := ShareDialog.new()
		add_child(dlg)
		dlg.setup(deck))
	wrap.add_child(share)
	var edit := _corner_button("res://icons/pencil.svg",
		Color(0.6, 0.7, 0.85), Ui.SIDE_ME, -72)
	edit.pressed.connect(func() -> void: edit_deck.emit(did0))
	wrap.add_child(edit)
	var del := _corner_button("res://icons/trash.svg",
		Color(0.7, 0.5, 0.55), Color(0.95, 0.4, 0.45), -38)
	del.pressed.connect(func() -> void: _confirm_delete(deck))
	wrap.add_child(del)
	return wrap


# A small flat icon button pinned to the tile's top-right; `left` is the left
# offset from the right edge (so the buttons sit side by side). No tooltip.
func _corner_button(icon_path: String, normal: Color, hover: Color, left: int) -> Button:
	var b := Button.new()
	b.icon = load(icon_path)
	b.expand_icon = true
	b.custom_minimum_size = Vector2(30, 30)
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.add_theme_color_override("icon_normal_color", normal)
	b.add_theme_color_override("icon_hover_color", hover)
	b.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	b.offset_left = left
	b.offset_top = 8
	b.offset_right = left + 30
	b.offset_bottom = 38
	b.pressed.connect(func() -> void: Audio.play("ui_click"))
	return b


func _deck_panel(deck: Dictionary, scale_target: Control = null) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var center := CenterContainer.new()
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 10)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := Ui.label(String(deck["name"]), 24, Color(0.94, 0.96, 1.0), true)
	nm.add_theme_font_override("font", Fonts.BLACK)
	v.add_child(nm)
	v.add_child(_deck_color_bar(deck))
	v.add_child(Ui.label("%d карт" % deck.get("cards", []).size(), 15, Ui.INK_DIM, true))
	center.add_child(v)
	panel.add_child(center)
	var did := String(deck["id"])
	panel.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			Audio.play("ui_tap")
			_deck_id = did
			_refresh())
	_hook_hover(panel, func() -> bool: return did == _deck_id, scale_target)
	return panel


# A row of colour bars for the colours present in the deck (its identity), like a
# small spectrum -- fills the tile and reads as "what this deck is".
func _deck_color_bar(deck: Dictionary) -> Control:
	var present := {}
	for cid in deck.get("cards", []):
		for c in CardData.def(String(cid)).get("color", []):
			present[String(c)] = true
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for col_name in CardData.COLORS:
		if not present.has(col_name):
			continue
		var bar := Panel.new()
		bar.custom_minimum_size = Vector2(34, 8)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c := Palette.color_for(col_name)
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sb.set_corner_radius_all(4)
		sb.shadow_size = 6
		sb.shadow_color = Color(c.r, c.g, c.b, 0.5)
		bar.add_theme_stylebox_override("panel", sb)
		row.add_child(bar)
	return row


# --- selection state ---------------------------------------------------------

func _refresh() -> void:
	for hid in _hero_cards:
		_restyle(_hero_cards[hid], hid == _hero_id)
	for did in _deck_cards:
		_restyle(_deck_cards[did], did == _deck_id)
	if _hero_summary != null:
		_hero_summary.text = CardData.name_of(_hero_id) if _hero_id != "" else "не выбран"
		_hero_summary.add_theme_color_override("font_color",
			Ui.INK if _hero_id != "" else Ui.INK_FAINT)
	var deck_legal := _deck_id != "" and _deck_legal()
	if _deck_summary != null:
		var dn := ""
		if _deck_id != "":
			dn = String(Decks.by_id(_deck_id).get("name", ""))
			if not deck_legal:
				dn += "  ·  неполна"
		_deck_summary.text = dn if dn != "" else "не выбрана"
		var col: Color = Ui.INK_FAINT
		if _deck_id != "":
			col = Color(0.92, 0.5, 0.5) if not deck_legal else Ui.INK
		_deck_summary.add_theme_color_override("font_color", col)
	if _next_btn != null:
		_next_btn.disabled = _hero_id == "" or not deck_legal


# Wire hover feedback on a selectable tile: a pointing cursor, a brighter border
# glow, and a small lift (Control.scale is a visual transform -- it overlaps
# neighbours without reflowing the grid). The selected style always wins.
# `scale_target` is the node that scales/lifts on hover (defaults to the panel
# itself; a wrapped user-deck tile passes its wrapper so the delete button scales
# and stays on top with the panel instead of falling behind it).
func _hook_hover(panel: Control, selected_fn: Callable, scale_target: Control = null) -> void:
	var st: Control = scale_target if scale_target != null else panel
	panel.set_meta("hovered", false)
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.mouse_entered.connect(func() -> void:
		Audio.play("ui_hover")
		panel.set_meta("hovered", true)
		_restyle(panel, selected_fn.call())
		st.pivot_offset = st.size / 2.0
		st.z_index = 10
		st.create_tween().tween_property(st, "scale", Vector2(1.03, 1.03), 0.08))
	panel.mouse_exited.connect(func() -> void:
		panel.set_meta("hovered", false)
		_restyle(panel, selected_fn.call())
		st.z_index = 0
		st.create_tween().tween_property(st, "scale", Vector2.ONE, 0.08))


func _restyle(panel: Control, selected: bool) -> void:
	panel.add_theme_stylebox_override("panel",
		_tile_style(selected, bool(panel.get_meta("hovered", false))))


# Selected -> a lit blue glass with an accent glow ring; hovered -> a softer lit
# glass; resting -> a calm dark slab with a lit top rim (matches the panels).
func _tile_style(selected: bool, hovered: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(13)
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.set_content_margin_all(12)
	if selected:
		# Selection reads from the bright background tint + blue border alone; no
		# blue glow halo behind the tile (it looked like a stray frame).
		sb.bg_color = Color(0.086, 0.118, 0.2, 0.92)
		sb.border_color = Ui.SIDE_ME
		sb.shadow_size = 0
	elif hovered:
		sb.bg_color = Color(0.063, 0.082, 0.149, 0.85)
		sb.border_color = Ui.PANEL_STROKE.lerp(Ui.SIDE_ME, 0.55)
		sb.shadow_size = 0
	else:
		sb.bg_color = Color(0.043, 0.051, 0.094, 0.7)
		sb.border_color = Ui.PANEL_STROKE
		sb.shadow_size = 8
		sb.shadow_color = Color(0, 0, 0, 0.4)
	return sb


func _deck_legal() -> bool:
	if _deck_id == "":
		return false
	return DeckRules.list_legal(Decks.by_id(_deck_id).get("cards", []))


func _on_next() -> void:
	if _hero_id == "" or not _deck_legal():
		return
	confirmed.emit(_hero_id, _deck_id)
