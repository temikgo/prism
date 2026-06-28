class_name DeckBuilder
extends Control

# Deck construction screen (M4). Left: filterable pool of every non-hero card as
# compact tiles (LMB +1, RMB -1, max 2). Right: the deck under construction with
# a live N/40 counter, a mana curve, the grouped card list, and Save (locked
# until DeckRules.is_legal). Built from the Claude Design handoff, reusing the
# shell language (glass panels, glowing title, mana pips, mbtn). The server
# re-validates on join; this screen only stops the player saving/queuing an
# illegal deck. A saved deck is { id, name, cards: [card_id, ...] }.

signal saved(deck: Dictionary)
signal back_pressed

const COLORS := CardData.ALL_COLORS  # red..violet + colorless
const TYPES := [["creature", "Существо"], ["spell", "Заклинание"], ["aura", "Аура"]]
const COSTS := ["0", "1", "2", "3", "4", "5", "6+"]
const POOL_COLUMNS := 6
const TILE_SCALE := 0.78  # in-game card face (176x246) scaled down for the pool
const POOL_WHEEL_PX := 80.0
const POOL_PAN_PX := 14.0
const POOL_SMOOTH := 22.0

const OK_COLOR := Color(0.26, 0.82, 0.44)
const BAD_COLOR := Color(0.92, 0.36, 0.42)

var _deck := {}           # card_id -> count
var _deck_id := ""        # existing id when editing, else "" (new)
var _name := "Новая колода"

var _f_colors: Array = []
var _f_types: Array = []
var _f_costs: Array = []
var _f_kw := ""
var _q := ""

var _all_ids: Array = []
var _scale := TILE_SCALE  # current card scale (recomputed by _relayout to fill width)
var _tiles := {}          # card_id -> { root, holder, badge, name, face }
var _empty_note: Label = null
var _pool_scroll: ScrollContainer = null
var _pool_scroll_target := -1.0
var _grid: GridContainer = null
var _name_edit: LineEdit = null
var _counter: HBoxContainer = null
var _curve_box: HBoxContainer = null
var _list_box: VBoxContainer = null
var _save_btn: Button = null


# Restore an existing deck for editing (or leave defaults for a fresh build).
func setup(deck: Dictionary) -> void:
	if deck.is_empty():
		return
	_deck_id = String(deck.get("id", ""))
	_name = String(deck.get("name", _name))
	_deck = {}
	for cid in deck.get("cards", []):
		_deck[cid] = int(_deck.get(cid, 0)) + 1


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_all_ids = CardData.deck_cards()

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 46)
	margin.add_theme_constant_override("margin_right", 46)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 22)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)

	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	head.add_child(Ui.title("Конструктор колоды", 30))
	head.add_child(Ui.label("соберите ровно %d карт · до %d копий каждой"
			% [DeckRules.DECK_SIZE, DeckRules.MAX_COPIES], 13, Ui.INK_DIM))
	root.add_child(head)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 22)
	root.add_child(cols)
	cols.add_child(_left())
	cols.add_child(_right())

	_refresh_all_badges()  # reflect a preloaded deck (editing) on the tiles
	_refresh_pool()
	_refresh_deck()
	call_deferred("_relayout")  # once real sizes exist, scale cards to fill the width
	_start_preload()  # decode art off-thread, then build faces a few per frame


# --- left: filters + scrollable pool ---------------------------------------

func _left() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 2.0
	col.add_theme_constant_override("separation", 12)
	col.add_child(_filters())

	_pool_scroll = ScrollContainer.new()
	_pool_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pool_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_pool_scroll.resized.connect(_relayout)  # size cards to fill the width
	_grid = GridContainer.new()
	_grid.columns = POOL_COLUMNS
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 14)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id in _all_ids:
		var tile := _tile(String(id))
		_grid.add_child(tile)
	_pool_scroll.add_child(_grid)
	col.add_child(_pool_scroll)

	_empty_note = Ui.label("Ничего не найдено — измените фильтры.", 14, Ui.INK_FAINT, true)
	_empty_note.visible = false
	col.add_child(_empty_note)
	return col


func _filters() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.05, 0.055, 0.1, 0.5), 14, 1, Ui.PANEL_STROKE, 12))
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 9)
	panel.add_child(rows)

	# colors
	var r1 := _filter_row("Цвет")
	for c in COLORS:
		r1.add_child(_chip(Palette.ru(c).capitalize(), Palette.color_for(c),
			func(on: bool) -> void: _toggle(_f_colors, c, on)))
	rows.add_child(r1)

	# types + costs
	var r2 := _filter_row("Тип")
	for t in TYPES:
		r2.add_child(_chip(String(t[1]), Ui.SIDE_ME,
			func(on: bool) -> void: _toggle(_f_types, String(t[0]), on)))
	r2.add_child(_filter_label("Стоимость"))
	for cost in COSTS:
		r2.add_child(_chip(String(cost), Ui.SIDE_ME,
			func(on: bool) -> void: _toggle(_f_costs, String(cost), on)))
	rows.add_child(r2)

	# keyword + search
	var r3 := _filter_row("Ключевик")
	var kw := OptionButton.new()
	kw.add_item("любой", 0)
	var ids := _pool_keywords()
	for i in ids.size():
		kw.add_item(_kw_short(String(ids[i])), i + 1)
	kw.item_selected.connect(func(idx: int) -> void:
		_f_kw = "" if idx == 0 else String(ids[idx - 1])
		_refresh_pool())
	r3.add_child(kw)
	var search := LineEdit.new()
	search.placeholder_text = "поиск по имени…"
	search.custom_minimum_size = Vector2(190, 0)
	Ui.style_input(search)
	search.text_changed.connect(func(t: String) -> void:
		_q = t
		_refresh_pool())
	r3.add_child(search)
	rows.add_child(r3)
	return panel


func _filter_row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	row.add_child(_filter_label(label_text))
	return row


func _filter_label(text: String) -> Label:
	var l := Ui.caption(text, Ui.INK_FAINT, 2)
	l.custom_minimum_size = Vector2(86, 0)
	return l


func _chip(text: String, accent: Color, on_toggle: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", Fonts.SEMIBOLD)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", Ui.INK_DIM)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Ui.INK)
	var off := Ui.bordered(Color(1, 1, 1, 0.03), 999, 1, Ui.PANEL_STROKE, 0)
	off.content_margin_left = 13
	off.content_margin_right = 13
	off.content_margin_top = 6
	off.content_margin_bottom = 6
	var on := off.duplicate()
	on.bg_color = Color(accent.r, accent.g, accent.b, 0.22)
	on.border_color = Color(accent.r, accent.g, accent.b, 0.8)
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", off)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# Godot draws the toggled-on state with the `pressed` box only while held; for a
	# sticky chip we restyle on toggle so `normal` carries the on/off look.
	b.toggled.connect(func(pressed: bool) -> void:
		b.add_theme_stylebox_override("normal", on if pressed else off)
		b.add_theme_stylebox_override("hover", on if pressed else off)
		on_toggle.call(pressed))
	return b


# --- pool tile --------------------------------------------------------------

func _tile(id: String) -> Control:
	# The real in-game card face (high-quality mipmapped art + cost/stats/rim),
	# scaled down for the pool, with a deck-count badge over it and the name below.
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)

	var holder := CardHover.new()  # shows the in-game card tooltip on hover
	holder.card_id = id
	holder.custom_minimum_size = Tokens.CARD_SIZE * _scale
	holder.mouse_filter = Control.MOUSE_FILTER_STOP
	holder.tooltip_text = CardData.name_of(id)
	# The heavy card face is built later by _start_preload, once its art has been
	# decoded on a background thread, so opening never blocks on 85 texture loads.

	# count badge, top-right over the art
	var chip := Panel.new()
	chip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	chip.offset_left = -32
	chip.offset_top = 5
	chip.offset_right = -5
	chip.offset_bottom = 28
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.02, 0.02, 0.06, 0.92), 7, 1, Ui.PANEL_STROKE))
	var badge := Ui.label("0", 13, Ui.INK_FAINT, true, true)
	badge.add_theme_font_override("font", Fonts.NUM_BOLD)
	badge.set_anchors_preset(Control.PRESET_FULL_RECT)
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(badge)
	holder.add_child(chip)

	holder.gui_input.connect(func(e: InputEvent) -> void: _on_tile_input(e, id))
	var cc := CenterContainer.new()  # centre the fixed-size card in its (expanding) cell
	cc.add_child(holder)
	col.add_child(cc)

	var nm := Ui.label(CardData.name_of(id), 12, Ui.INK, true)
	nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	nm.custom_minimum_size = Vector2(Tokens.CARD_SIZE.x * _scale, 0)
	col.add_child(nm)

	_tiles[id] = {"root": col, "holder": holder, "badge": badge, "face": null, "name": nm}
	return col


func _on_tile_input(e: InputEvent, id: String) -> void:
	if e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_LEFT:
			_add(id)
		elif e.button_index == MOUSE_BUTTON_RIGHT:
			_remove(id)


func _input(e: InputEvent) -> void:
	if _pool_scroll == null or not is_visible_in_tree():
		return
	if not _pool_scroll.get_global_rect().has_point(_pool_scroll.get_global_mouse_position()):
		return
	var dy := 0.0
	if e is InputEventPanGesture:
		dy = e.delta.y * POOL_PAN_PX
	elif e is InputEventMouseButton and e.pressed:
		var f: float = e.factor if e.factor > 0.0 else 1.0
		if e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dy = POOL_WHEEL_PX * f
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
			dy = -POOL_WHEEL_PX * f
	if dy == 0.0:
		return
	var bar := _pool_scroll.get_v_scroll_bar()
	var max_y: float = maxf(0.0, bar.max_value - bar.page)
	var base: float = _pool_scroll_target if _pool_scroll_target >= 0.0 else float(_pool_scroll.scroll_vertical)
	_pool_scroll_target = clampf(base + dy, 0.0, max_y)
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _pool_scroll == null or _pool_scroll_target < 0.0:
		return
	var cur := float(_pool_scroll.scroll_vertical)
	var diff := _pool_scroll_target - cur
	if absf(diff) < 0.5:
		_pool_scroll.scroll_vertical = int(round(_pool_scroll_target))
		_pool_scroll_target = -1.0
		return
	var t: float = clampf(POOL_SMOOTH * delta, 0.0, 1.0)
	_pool_scroll.scroll_vertical = int(round(cur + diff * t))


# --- right: the deck under construction ------------------------------------

func _right() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(400, 0)
	panel.add_theme_stylebox_override("panel", Ui.panel_glass())
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)

	col.add_child(Ui.caption("Название колоды", Ui.INK_FAINT, 2))
	_name_edit = LineEdit.new()
	_name_edit.text = _name
	_name_edit.max_length = 28
	Ui.style_input(_name_edit)
	_name_edit.text_changed.connect(func(t: String) -> void: _name = t)
	col.add_child(_name_edit)

	_counter = HBoxContainer.new()
	_counter.alignment = BoxContainer.ALIGNMENT_CENTER
	_counter.add_theme_constant_override("separation", 8)
	col.add_child(_counter)

	col.add_child(Ui.caption("Кривая маны", Ui.INK_FAINT, 2))
	_curve_box = HBoxContainer.new()
	_curve_box.custom_minimum_size = Vector2(0, 92)
	_curve_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_curve_box.add_theme_constant_override("separation", 8)
	col.add_child(_curve_box)

	var list_scroll := ScrollContainer.new()
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 3)
	list_scroll.add_child(_list_box)
	col.add_child(list_scroll)

	_save_btn = Ui.mbtn("Сохранить", "primary", Ui.SIDE_ME, 348)
	_save_btn.pressed.connect(_on_save)
	col.add_child(_save_btn)
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 10)
	var clear := Ui.mbtn("Очистить", "ghost", Ui.SIDE_ME, 168)
	clear.pressed.connect(func() -> void:
		_deck = {}
		_refresh_all_badges()
		_refresh_deck())
	var back := Ui.mbtn("Назад", "ghost", Ui.SIDE_ME, 168)
	back.pressed.connect(func() -> void: back_pressed.emit())
	brow.add_child(clear)
	brow.add_child(back)
	col.add_child(brow)
	return panel


# --- mutation + refresh -----------------------------------------------------

func _add(id: String) -> void:
	var n := int(_deck.get(id, 0))
	if n >= DeckRules.MAX_COPIES:
		return
	_deck[id] = n + 1
	_update_badge(id)
	_refresh_deck()


func _remove(id: String) -> void:
	var n := int(_deck.get(id, 0))
	if n <= 0:
		return
	if n - 1 <= 0:
		_deck.erase(id)
	else:
		_deck[id] = n - 1
	_update_badge(id)
	_refresh_deck()


func _update_badge(id: String) -> void:
	if not _tiles.has(id):
		return
	var n := int(_deck.get(id, 0))
	var badge: Label = _tiles[id]["badge"]
	badge.text = str(n)
	badge.add_theme_color_override("font_color", Ui.INK if n > 0 else Ui.INK_FAINT)
	var holder: Control = _tiles[id]["holder"]
	holder.modulate = Color(0.6, 0.6, 0.64) if n >= DeckRules.MAX_COPIES else Color.WHITE


func _refresh_all_badges() -> void:
	for id in _tiles:
		_update_badge(String(id))


func _refresh_pool() -> void:
	var any := false
	for id in _all_ids:
		var vis := _passes(String(id))
		_tiles[id]["root"].visible = vis
		any = any or vis
	if _empty_note:
		_empty_note.visible = not any


# Scale every card face so POOL_COLUMNS cards fill the pool width (no centering
# gaps), capped at 1.0 so the native art is never upscaled/blurred. Re-runs on
# resize.
func _relayout() -> void:
	if _grid == null or _pool_scroll == null:
		return
	var cols: int = _grid.columns
	var hsep: int = _grid.get_theme_constant("h_separation")
	var avail := _pool_scroll.size.x - 16.0  # leave room for the vertical scrollbar
	if avail <= 0.0:
		return
	var cell := (avail - float(cols - 1) * hsep) / float(cols)
	_scale = clampf(cell / Tokens.CARD_SIZE.x, 0.4, 1.0)
	for id in _tiles:
		var t: Dictionary = _tiles[id]
		if t["face"] != null:  # faces are built as their art finishes decoding
			t["face"].scale = Vector2(_scale, _scale)
		t["holder"].custom_minimum_size = Tokens.CARD_SIZE * _scale
		t["name"].custom_minimum_size = Vector2(Tokens.CARD_SIZE.x * _scale, 0)


# Decode every card's art on background threads, then build the (now cheap) card
# faces a few per frame. The screen opens instantly; the heavy PNG decode never
# runs on the main thread, so there is no load freeze and the scroll stays smooth.
func _start_preload() -> void:
	var pending: Array = []
	for id in _all_ids:
		var path := _art_path(String(id))
		if path != "" and ResourceLoader.exists(path):
			ResourceLoader.load_threaded_request(path)
			pending.append(id)
		else:
			_build_face(String(id))  # no art file -> cheap placeholder face now
	while not pending.is_empty():
		if not is_inside_tree():
			return  # screen left mid-load; pending decodes finish harmlessly
		var built := 0
		var still: Array = []
		for id in pending:
			var path := _art_path(String(id))
			var st := ResourceLoader.load_threaded_get_status(path)
			if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS or built >= 4:
				still.append(id)
			else:
				if st == ResourceLoader.THREAD_LOAD_LOADED:
					ResourceLoader.load_threaded_get(path)  # finalize into the cache
				_build_face(String(id))  # CardView.face's load() now hits the cache
				built += 1
		pending = still
		await get_tree().process_frame


func _build_face(id: String) -> void:
	var t: Dictionary = _tiles[id]
	if t["face"] != null:
		return
	var face := CardView.face(id, null, true)  # small mipmapped art_thumb
	face.scale = Vector2(_scale, _scale)
	t["holder"].add_child(face)
	t["holder"].move_child(face, 0)  # behind the count badge
	t["face"] = face


func _art_path(id: String) -> String:
	var did := CardData.display_id(id)
	var t := "res://art_thumb/%s.png" % did  # preload the same small copy the face uses
	return t if ResourceLoader.exists(t) else "res://art/%s.png" % did


func _passes(id: String) -> bool:
	var d := CardData.def(id)
	if not _f_colors.is_empty():
		# AND: the card must carry every selected colour (e.g. red+blue -> only
		# cards that are both), not merely one of them.
		var cols := _card_colors(d)
		for fc in _f_colors:
			if not cols.has(fc):
				return false
	if not _f_types.is_empty() and not _f_types.has(String(d.get("type", ""))):
		return false
	if not _f_costs.is_empty():
		var mv := CardData.total_cost(d.get("cost", {}))
		var bucket := "6+" if mv >= 6 else str(mv)
		if not _f_costs.has(bucket):
			return false
	if _f_kw != "" and not CardData.has_keyword(id, _f_kw):
		return false
	if _q.strip_edges() != "" and not CardData.name_of(id).to_lower().contains(_q.strip_edges().to_lower()):
		return false
	return true


func _refresh_deck() -> void:
	_rebuild_counter()
	_rebuild_curve()
	_rebuild_list()
	var legal := DeckRules.is_legal(_deck)
	_save_btn.disabled = not legal


func _rebuild_counter() -> void:
	for c in _counter.get_children():
		c.queue_free()
	var total := DeckRules.total(_deck)
	var legal := DeckRules.is_legal(_deck)
	var tone := OK_COLOR if legal else BAD_COLOR
	var num := Ui.label(str(total), 30, tone, false, true)
	num.add_theme_font_override("font", Fonts.NUM_BLACK)
	_counter.add_child(num)
	_counter.add_child(Ui.label("/ %d" % DeckRules.DECK_SIZE, 18, Ui.INK_DIM, false, true))
	var reason := Ui.label(DeckRules.status_text(_deck), 12, tone)
	reason.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_counter.add_child(reason)


func _rebuild_curve() -> void:
	for c in _curve_box.get_children():
		c.queue_free()
	var bins := [0, 0, 0, 0, 0, 0, 0]
	for id in _deck:
		var mv := CardData.total_cost(CardData.def(id).get("cost", {}))
		bins[mini(mv, 6)] += int(_deck[id])
	var peak := 1
	for n in bins:
		peak = maxi(peak, n)
	for i in bins.size():
		_curve_box.add_child(_curve_bar(bins[i], peak, "6+" if i == 6 else str(i)))


func _curve_bar(n: int, peak: int, xlabel: String) -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_END
	col.add_theme_constant_override("separation", 3)
	if n > 0:
		col.add_child(Ui.label(str(n), 10, Ui.INK_DIM, true))
	var bar := Panel.new()
	var h := 3 if n == 0 else int(round(float(n) / peak * 64.0))
	bar.custom_minimum_size = Vector2(0, maxi(3, h))
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fill := Ui.SIDE_ME if n > 0 else Ui.PANEL_STROKE
	bar.add_theme_stylebox_override("panel", Ui.bordered(
		Color(fill.r, fill.g, fill.b, 0.55 if n > 0 else 0.18), 4, 0, fill))
	col.add_child(bar)
	col.add_child(Ui.label(xlabel, 10, Ui.INK_FAINT, true))
	return col


func _rebuild_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	if _deck.is_empty():
		_list_box.add_child(Ui.label("Колода пуста. Нажмите на карты слева, чтобы добавить.",
			12, Ui.INK_FAINT, true))
		return
	var by_cost := {}
	for id in _deck:
		var mv := CardData.total_cost(CardData.def(id).get("cost", {}))
		if not by_cost.has(mv):
			by_cost[mv] = []
		by_cost[mv].append(String(id))
	var costs := by_cost.keys()
	costs.sort()
	for cost in costs:
		_list_box.add_child(Ui.caption("стоимость %d" % cost, Ui.INK_FAINT, 1))
		var ids: Array = by_cost[cost]
		ids.sort_custom(func(a, b): return CardData.name_of(a) < CardData.name_of(b))
		for id in ids:
			_list_box.add_child(_list_row(String(id)))


func _list_row(id: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	var sw := Panel.new()
	sw.custom_minimum_size = Vector2(10, 18)
	var c := Palette.primary(CardData.def(id))
	sw.add_theme_stylebox_override("panel", Ui.bordered(c, 3, 0, c))
	row.add_child(sw)
	var nm := Ui.label(CardData.name_of(id), 13, Ui.INK)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.clip_text = true
	row.add_child(nm)
	var minus := _step_btn("−")
	minus.pressed.connect(func() -> void: _remove(id))
	row.add_child(minus)
	var ct := Ui.label(str(int(_deck.get(id, 0))), 13, Ui.INK, false, true)
	ct.add_theme_font_override("font", Fonts.NUM_BOLD)
	ct.custom_minimum_size = Vector2(16, 0)
	ct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(ct)
	var plus := _step_btn("＋")
	plus.disabled = int(_deck.get(id, 0)) >= DeckRules.MAX_COPIES
	plus.pressed.connect(func() -> void: _add(id))
	row.add_child(plus)
	return row


func _step_btn(glyph: String) -> Button:
	var b := Button.new()
	b.text = glyph
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(24, 24)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", Ui.INK_DIM)
	b.add_theme_color_override("font_hover_color", Ui.INK)
	b.add_theme_color_override("font_disabled_color", Color(0.32, 0.34, 0.42))
	var sb := Ui.bordered(Color(1, 1, 1, 0.04), 7, 1, Ui.PANEL_STROKE)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", Ui.bordered(Color(1, 1, 1, 0.09), 7, 1, Ui.PANEL_STROKE))
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_stylebox_override("disabled", Ui.bordered(Color(1, 1, 1, 0.02), 7, 1, Color(1, 1, 1, 0.04)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


func _on_save() -> void:
	if not DeckRules.is_legal(_deck):
		return
	var id := _deck_id if _deck_id != "" else _new_id()
	var nm := _name.strip_edges()
	if nm == "":
		nm = "Колода"
	saved.emit({"id": id, "name": nm, "cards": DeckRules.to_card_list(_deck)})


func _new_id() -> String:
	return "user_%d" % Time.get_unix_time_from_system()


# --- small helpers ----------------------------------------------------------

func _toggle(arr: Array, value: Variant, on: bool) -> void:
	if on:
		if not arr.has(value):
			arr.append(value)
	else:
		arr.erase(value)
	_refresh_pool()


func _card_colors(d: Dictionary) -> Array:
	var cs: Array = d.get("color", [])
	return cs if not cs.is_empty() else ["colorless"]


func _type_ru(t: String) -> String:
	for pair in TYPES:
		if pair[0] == t:
			return String(pair[1])
	return t


func _kw_short(kw: String) -> String:
	var full: String = Glossary.KW.get(kw, kw)
	var colon := full.find(":")
	return full.substr(0, colon) if colon > 0 else full


# Keyword ids actually present in the pool, sorted by their Russian short name.
func _pool_keywords() -> Array:
	var seen := {}
	for id in _all_ids:
		for k in CardData.def(id).get("keywords", []):
			seen[String(k.get("id", ""))] = true
	var ids := seen.keys()
	ids.sort_custom(func(a, b): return _kw_short(a) < _kw_short(b))
	return ids
