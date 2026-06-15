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
	if decks.is_empty():
		var empty := CenterContainer.new()
		var el := Ui.label("У вас нет колод —\nсобрать бой невозможно.", 16,
			Color(0.9, 0.55, 0.55), true)
		empty.add_child(el)
		return _column_panel("Колоды", "0 пресетов", empty)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 12)
	for d in decks:
		var tile := _deck_tile(d)
		_deck_cards[d["id"]] = tile
		list.add_child(tile)
	return _column_panel("Колоды", "%d %s" % [decks.size(), _decks_word(decks.size())], list)


# Russian plural for "пресет" (1 пресет / 2 пресета / 5 пресетов).
func _decks_word(n: int) -> String:
	var n10 := n % 10
	var n100 := n % 100
	if n10 == 1 and n100 != 11:
		return "пресет"
	if n10 >= 2 and n10 <= 4 and (n100 < 10 or n100 >= 20):
		return "пресета"
	return "пресетов"


func _deck_tile(deck: Dictionary) -> Control:
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
			_deck_id = did
			_refresh())
	_hook_hover(panel, func() -> bool: return did == _deck_id)
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
	if _deck_summary != null:
		var dn := ""
		if _deck_id != "":
			dn = String(Decks.by_id(_deck_id).get("name", ""))
		_deck_summary.text = dn if dn != "" else "не выбрана"
		_deck_summary.add_theme_color_override("font_color",
			Ui.INK if _deck_id != "" else Ui.INK_FAINT)
	if _next_btn != null:
		_next_btn.disabled = _hero_id == "" or _deck_id == ""


# Wire hover feedback on a selectable tile: a pointing cursor, a brighter border
# glow, and a small lift (Control.scale is a visual transform -- it overlaps
# neighbours without reflowing the grid). The selected style always wins.
func _hook_hover(panel: Control, selected_fn: Callable) -> void:
	panel.set_meta("hovered", false)
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.mouse_entered.connect(func() -> void:
		panel.set_meta("hovered", true)
		_restyle(panel, selected_fn.call())
		panel.pivot_offset = panel.size / 2.0
		panel.z_index = 10
		panel.create_tween().tween_property(panel, "scale", Vector2(1.03, 1.03), 0.08))
	panel.mouse_exited.connect(func() -> void:
		panel.set_meta("hovered", false)
		_restyle(panel, selected_fn.call())
		panel.z_index = 0
		panel.create_tween().tween_property(panel, "scale", Vector2.ONE, 0.08))


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
		sb.bg_color = Color(0.086, 0.118, 0.2, 0.92)
		sb.border_color = Ui.SIDE_ME
		sb.shadow_size = 24
		sb.shadow_color = Color(Ui.SIDE_ME.r, Ui.SIDE_ME.g, Ui.SIDE_ME.b, 0.5)
	elif hovered:
		sb.bg_color = Color(0.063, 0.082, 0.149, 0.85)
		sb.border_color = Ui.PANEL_STROKE.lerp(Ui.SIDE_ME, 0.55)
		sb.shadow_size = 16
		sb.shadow_color = Color(Ui.SIDE_ME.r, Ui.SIDE_ME.g, Ui.SIDE_ME.b, 0.3)
	else:
		sb.bg_color = Color(0.043, 0.051, 0.094, 0.7)
		sb.border_color = Ui.PANEL_STROKE
		sb.shadow_size = 8
		sb.shadow_color = Color(0, 0, 0, 0.4)
	return sb


func _on_next() -> void:
	if _hero_id == "" or _deck_id == "":
		return
	confirmed.emit(_hero_id, _deck_id)
