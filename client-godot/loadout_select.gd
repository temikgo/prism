class_name LoadoutSelect
extends Control

# Pre-match loadout: pick a hero (left) and a deck (right) before entering a
# room. Local choice (no opponent sync) -- it travels with createRoom/joinRoom.
# "Далее" is enabled only once both a hero and a deck are chosen; with no decks
# (the player's collection is empty) a match cannot start. Reports the choice up
# to the Router, which persists it and carries it into the room flow.

signal confirmed(hero_id: String, deck_id: String)
signal back_pressed

const HERO_HP := 30

var _hero_id := ""
var _deck_id := ""
var _hero_cards := {}   # hero id -> its selectable panel (for highlight)
var _deck_cards := {}   # deck id -> its selectable panel
var _next_btn: Button = null


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
	add_child(Backdrop.new())
	_apply_defaults()  # first run (no saved choice): preselect a sensible loadout

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 14)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	margin.add_child(root)
	add_child(margin)

	var title := Ui.label("Выбор героя и колоды", 30, Color(0.9, 0.93, 1.0), true)
	title.add_theme_font_override("font", Fonts.BLACK)
	root.add_child(title)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 28)
	root.add_child(cols)
	cols.add_child(_hero_column())
	cols.add_child(_deck_column())

	# Bottom bar: back + next.
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 14)
	root.add_child(bar)
	var back := Ui.neon_button("Назад", Color(0.6, 0.62, 0.7))
	back.custom_minimum_size = Vector2(160, 46)
	back.pressed.connect(func() -> void: back_pressed.emit())
	bar.add_child(back)
	_next_btn = Ui.neon_button("Далее", Color(0.4, 0.85, 1.0))
	_next_btn.custom_minimum_size = Vector2(200, 46)
	_next_btn.pressed.connect(_on_next)
	bar.add_child(_next_btn)

	_refresh()


# A framed half-screen panel with a header, holding `content` which expands to
# fill it. The two columns are equal-width and full height, so the screen is
# filled regardless of how many heroes/decks there are.
func _column_panel(title: String, content: Control) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.06, 0.08, 0.14, 0.5), 16, 1, Color(0.26, 0.3, 0.42), 18))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	panel.add_child(v)
	var head := Ui.label(title, 20, Color(0.74, 0.78, 0.9), true, true)
	v.add_child(head)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(content)
	return panel


# --- hero column -------------------------------------------------------------

func _hero_column() -> Control:
	var heroes := CardData.heroes()
	var grid := GridContainer.new()
	# Adaptive columns: a single row for few, otherwise ~2 rows, so the tiles
	# stay large and spread across the panel for any count.
	grid.columns = clampi(int(ceil(sqrt(float(max(heroes.size(), 1))))), 1, 4)
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 18)
	for hid in heroes:
		var tile := _hero_tile(hid)
		_hero_cards[hid] = tile
		grid.add_child(tile)
	return _column_panel("Герой", grid)


func _hero_tile(hero_id: String) -> Control:
	var d := CardData.def(hero_id)
	var passive := []
	for kw in d.get("keywords", []):
		passive.append({"id": String(kw.get("id", ""))})
	var hero := {"card": hero_id, "name": CardData.name_of(hero_id),
		"hp": HERO_HP, "armor": 0, "passive": passive}

	var panel := PanelContainer.new()
	# Each tile grows to share the grid space evenly -> the heroes fill the panel.
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
	# Centered both ways inside the (stretched) tile so the portrait sits in the
	# middle regardless of the tile's size.
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 8)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(HeroView.portrait_with_hp(hero, 150))
	var nm := Ui.label(String(hero["name"]), 20, Color(0.92, 0.94, 1.0), true, true)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nm)
	var badge := HeroView.passive_badge(hero)
	if badge != null:
		var brow := HBoxContainer.new()
		brow.alignment = BoxContainer.ALIGNMENT_CENTER
		brow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		brow.add_child(badge)
		v.add_child(brow)
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
		return _column_panel("Колода", empty)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 14)
	for d in decks:
		var tile := _deck_tile(d)
		_deck_cards[d["id"]] = tile
		list.add_child(tile)
	return _column_panel("Колода", list)


func _deck_tile(deck: Dictionary) -> Control:
	var panel := PanelContainer.new()
	# Fill the panel width and share its height, so one deck fills the column and
	# several decks split it evenly.
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var center := CenterContainer.new()
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 10)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := Ui.label(String(deck["name"]), 26, Color(0.94, 0.96, 1.0), true)
	nm.add_theme_font_override("font", Fonts.BLACK)
	v.add_child(nm)
	v.add_child(_deck_color_bar(deck))
	v.add_child(Ui.label("%d карт" % deck.get("cards", []).size(), 15,
		Color(0.64, 0.68, 0.8), true))
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
		panel.create_tween().tween_property(panel, "scale", Vector2(1.04, 1.04), 0.08))
	panel.mouse_exited.connect(func() -> void:
		panel.set_meta("hovered", false)
		_restyle(panel, selected_fn.call())
		panel.z_index = 0
		panel.create_tween().tween_property(panel, "scale", Vector2.ONE, 0.08))


func _restyle(panel: Control, selected: bool) -> void:
	panel.add_theme_stylebox_override("panel",
		_tile_style(selected, bool(panel.get_meta("hovered", false))))


func _tile_style(selected: bool, hovered: bool) -> StyleBoxFlat:
	if selected:
		return Ui.glass(Color(0.4, 0.85, 1.0), 0.55)
	if hovered:
		return Ui.glass(Color(0.55, 0.78, 1.0), 0.32)
	return Ui.bordered(Color(0.09, 0.11, 0.16, 0.85), 10, 1, Color(0.3, 0.34, 0.44), 10)


func _on_next() -> void:
	if _hero_id == "" or _deck_id == "":
		return
	confirmed.emit(_hero_id, _deck_id)
