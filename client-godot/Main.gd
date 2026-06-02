extends Control

# Prism client. Connects to the C++ WebSocket server, renders the redacted view
# it receives, and sends JSON actions. Static card data (names, costs, stats,
# text) is read from res://cards.json; per-instance runtime state comes from the
# server view. The UI is built in code, so no scene editing is needed.
#
# Interaction is drag-and-drop with a click fallback:
#   * hand card  -> drag onto your board to play, or onto the MANA zone to bank,
#                   or (targeted spell) onto an enemy creature to cast at it;
#   * your creature -> drag onto an enemy creature or the enemy hero to attack;
#   * revealed awaken card in your mana row -> drag like a hand card to awaken it.
# Clicking does the same via a two-step "select, then pick target" flow.

const DEFAULT_URL := "ws://127.0.0.1:8080"
const CARD_SIZE := Vector2(104, 146)

var socket := WebSocketPeer.new()
var was_open := false
var view := {}
var cards := {}            # card id -> definition (from cards.json)

# Click-fallback selection state (drag-and-drop ignores these).
var attacker_id := -1      # your selected creature, waiting for an attack target
var casting_index := -1    # hand index of a targeted spell waiting for a target
var awaken_index := -1     # mana-row index of a targeted awaken card

var url_edit: LineEdit
var status_label: Label
var root_box: VBoxContainer


# --- color palette -----------------------------------------------------------

const COLOR_MAP := {
	"red": Color(0.86, 0.24, 0.26),
	"yellow": Color(0.92, 0.78, 0.24),
	"green": Color(0.34, 0.74, 0.40),
	"blue": Color(0.32, 0.56, 0.92),
	"violet": Color(0.62, 0.38, 0.86),
	"colorless": Color(0.72, 0.72, 0.78),
}


func _color_for(name: String) -> Color:
	return COLOR_MAP.get(name, COLOR_MAP["colorless"])


func _primary_color(d: Dictionary) -> Color:
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		return _color_for("colorless")
	return _color_for(String(colors[0]))


# --- a draggable / droppable card or zone -------------------------------------

class UiCard extends PanelContainer:
	signal clicked(payload: Dictionary)
	var payload: Dictionary = {}        # non-empty + draggable=true => can drag
	var drag_label: String = ""
	var can_drop_fn: Callable = Callable()
	var drop_fn: Callable = Callable()

	func _gui_input(event: InputEvent) -> void:
		# Fire on release, not press: a press that turns into a drag is consumed
		# by the drag system, so a real click never collides with dragging.
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT \
				and not event.pressed:
			clicked.emit(payload)

	func _get_drag_data(_at: Vector2) -> Variant:
		if not bool(payload.get("draggable", false)):
			return null
		var ghost := Label.new()
		ghost.text = drag_label
		ghost.add_theme_color_override("font_color", Color.WHITE)
		var preview := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.1, 0.1, 0.12, 0.9)
		sb.set_border_width_all(2)
		sb.border_color = Color.WHITE
		sb.set_content_margin_all(6)
		preview.add_theme_stylebox_override("panel", sb)
		preview.add_child(ghost)
		set_drag_preview(preview)
		return payload

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		if can_drop_fn.is_valid():
			return bool(can_drop_fn.call(data))
		return false

	func _drop_data(_at: Vector2, data: Variant) -> void:
		if drop_fn.is_valid():
			drop_fn.call(data)


# --- lifecycle ---------------------------------------------------------------

func _ready() -> void:
	_load_cards()
	_build_shell()


func _load_cards() -> void:
	var f := FileAccess.open("res://cards.json", FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_ARRAY:
		for c in data:
			cards[c["id"]] = c


func _build_shell() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.12)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", bg)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	root_box = VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 8)
	panel.add_child(root_box)

	var bar := HBoxContainer.new()
	url_edit = LineEdit.new()
	url_edit.text = DEFAULT_URL
	url_edit.custom_minimum_size = Vector2(280, 0)
	bar.add_child(url_edit)
	var connect_btn := Button.new()
	connect_btn.text = "Connect"
	connect_btn.pressed.connect(_on_connect)
	bar.add_child(connect_btn)
	status_label = Label.new()
	status_label.text = "disconnected"
	bar.add_child(status_label)
	root_box.add_child(bar)


func _on_connect() -> void:
	var err := socket.connect_to_url(url_edit.text)
	if err != OK:
		status_label.text = "connect error %d" % err
	else:
		status_label.text = "connecting..."


func _process(_dt: float) -> void:
	socket.poll()
	var st := socket.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not was_open:
			was_open = true
			status_label.text = "connected"
		while socket.get_available_packet_count() > 0:
			var txt := socket.get_packet().get_string_from_utf8()
			var data: Variant = JSON.parse_string(txt)
			if typeof(data) == TYPE_DICTIONARY:
				view = data
				_rebuild()
	elif st == WebSocketPeer.STATE_CLOSED and was_open:
		was_open = false
		status_label.text = "closed"


func _send(obj: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(obj))


func _clear_selection() -> void:
	attacker_id = -1
	casting_index = -1
	awaken_index = -1


# --- view queries ------------------------------------------------------------

func _name_of(card_id: String) -> String:
	if cards.has(card_id) and cards[card_id].has("name"):
		return cards[card_id]["name"].get("ru", card_id)
	return card_id


func _text_of(card_id: String) -> String:
	if cards.has(card_id) and cards[card_id].has("text"):
		return cards[card_id]["text"].get("ru", "")
	return ""


func _my_turn() -> bool:
	return int(view.get("current", -1)) == int(view.get("you", -2))


func _needs_target(card_id: String) -> bool:
	var d: Dictionary = cards.get(card_id, {})
	for e in d.get("effects", []):
		if String(e.get("selector", "")) == "chosen_enemy_minion":
			return true
	return false


func _is_creature(card_id: String) -> bool:
	return String(cards.get(card_id, {}).get("type", "")) == "creature"


# --- top-level rebuild -------------------------------------------------------

func _rebuild() -> void:
	# Tear down everything below the connection bar and redraw from the view.
	while root_box.get_child_count() > 1:
		var n := root_box.get_child(1)
		root_box.remove_child(n)
		n.queue_free()
	if view.is_empty():
		return

	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var opp: Dictionary = view["players"][1 - you]

	root_box.add_child(_banner(you))
	root_box.add_child(_enemy_strip(opp))
	root_box.add_child(_board_row(opp.get("board", []), false))
	root_box.add_child(_separator())
	root_box.add_child(_board_row(me.get("board", []), true))
	root_box.add_child(_me_strip(me))
	root_box.add_child(_hand_row(me.get("hand", [])))
	root_box.add_child(_controls())


func _separator() -> Control:
	var line := HSeparator.new()
	line.add_theme_constant_override("separation", 6)
	return line


func _banner(you: int) -> Control:
	var banner := Label.new()
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_theme_font_size_override("font_size", 18)
	if bool(view.get("over", false)):
		var w := int(view.get("winner", -1))
		banner.text = "GAME OVER - " + ("YOU WIN" if w == you else "YOU LOSE")
	else:
		var who := "YOUR TURN" if _my_turn() else "OPPONENT'S TURN"
		banner.text = "%s   -   turn %d" % [who, int(view.get("turn", 0))]
	return banner


# --- hero strips -------------------------------------------------------------

func _enemy_strip(opp: Dictionary) -> Control:
	var zone := UiCard.new()
	zone.add_theme_stylebox_override("panel", _hero_style(Color(0.5, 0.2, 0.2)))
	zone.can_drop_fn = func(data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.get("kind", "") == "attacker"
	zone.drop_fn = func(data: Variant) -> void:
		_send({"action": "attackHero", "attacker": int(data["id"])})
		_clear_selection()
	zone.clicked.connect(func(_p: Dictionary) -> void: _on_enemy_hero())

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	var hero: Dictionary = opp["hero"]
	row.add_child(_info_label("ENEMY HERO   HP %d   ARM %d" % [
		int(hero["hp"]), int(hero.get("armor", 0))], 16))
	row.add_child(_info_label("hand %d   deck %d   grave %d" % [
		int(opp.get("handCount", 0)), int(opp.get("deckCount", 0)),
		int(opp.get("graveyardCount", 0))], 13))
	row.add_child(_manarow_view(opp.get("manaRow", []), false))
	zone.add_child(row)
	return zone


func _me_strip(me: Dictionary) -> Control:
	var zone := UiCard.new()
	zone.add_theme_stylebox_override("panel", _hero_style(Color(0.2, 0.35, 0.5)))

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	var hero: Dictionary = me["hero"]
	row.add_child(_info_label("YOU   HP %d   ARM %d" % [
		int(hero["hp"]), int(hero.get("armor", 0))], 16))
	row.add_child(_info_label("mana  %s" % _mana_str(me["mana"]), 14))
	row.add_child(_manarow_view(me.get("manaRow", []), true))
	var auras: Array = me.get("auras", [])
	if not auras.is_empty():
		var names := []
		for a in auras:
			names.append(_name_of(String(a.get("card", ""))))
		row.add_child(_info_label("auras: " + ", ".join(names), 12))
	zone.add_child(row)
	return zone


func _info_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	return l


func _mana_str(mana: Dictionary) -> String:
	var avail: Dictionary = mana.get("available", {})
	var total: Dictionary = mana.get("crystals", {})
	var parts := []
	for color in ["red", "yellow", "green", "blue", "violet", "colorless"]:
		var t := int(total.get(color, 0))
		if t > 0:
			parts.append("%s %d/%d" % [color, int(avail.get(color, 0)), t])
	return "  ".join(parts) if not parts.is_empty() else "-"


# --- mana row (face-down backs + peekable awaken cards) ----------------------

func _manarow_view(mana_row: Array, mine: bool) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 3)
	var tag := Label.new()
	tag.text = "mana row:"
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_font_size_override("font_size", 11)
	row.add_child(tag)
	for i in mana_row.size():
		var slot: Dictionary = mana_row[i]
		var color := String(slot.get("color", "colorless"))
		if mine and slot.has("card"):
			row.add_child(_awaken_chip(int(i), String(slot["card"]), color))
		else:
			row.add_child(_mana_back(color))
	return row


func _mana_back(color: String) -> Control:
	var chip := Panel.new()
	chip.custom_minimum_size = Vector2(20, 28)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_for(color).darkened(0.45)
	sb.set_border_width_all(1)
	sb.border_color = _color_for(color)
	sb.set_corner_radius_all(3)
	chip.add_theme_stylebox_override("panel", sb)
	return chip


func _awaken_chip(idx: int, card_id: String, color: String) -> Control:
	var chip := UiCard.new()
	chip.custom_minimum_size = Vector2(26, 28)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_for(color).darkened(0.2)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.95, 0.85, 0.3)   # gold = peekable awaken
	sb.set_corner_radius_all(3)
	chip.add_theme_stylebox_override("panel", sb)
	chip.tooltip_text = "%s - awaken" % _name_of(card_id)
	var draggable := _my_turn()
	chip.payload = {
		"kind": "awaken", "manaRowIndex": idx, "card_id": card_id,
		"needs_target": _needs_target(card_id), "draggable": draggable,
	}
	chip.drag_label = "awaken: " + _name_of(card_id)
	chip.clicked.connect(func(p: Dictionary) -> void: _on_awaken_clicked(p))
	var star := Label.new()
	star.text = "AW"
	star.mouse_filter = Control.MOUSE_FILTER_IGNORE
	star.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	star.add_theme_font_size_override("font_size", 11)
	chip.add_child(star)
	return chip


# --- board rows --------------------------------------------------------------

func _board_row(board: Array, mine: bool) -> Control:
	# The whole row is a drop zone: dropping a playable hand/awaken card here
	# plays it (creatures land on your own side).
	var zone := UiCard.new()
	zone.custom_minimum_size = Vector2(0, CARD_SIZE.y + 12)
	zone.add_theme_stylebox_override("panel", _zone_style(mine))
	if mine:
		zone.can_drop_fn = func(data: Variant) -> bool: return _can_play_here(data)
		zone.drop_fn = func(data: Variant) -> void: _play_payload(data, 0)

	var row := HBoxContainer.new()
	# IGNORE so drops in the gaps fall through to the zone; the creature cards
	# (mouse_filter STOP) still receive their own input regardless.
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for cr in board:
		row.add_child(_creature_card(cr, mine))
	zone.add_child(row)
	return zone


func _creature_card(cr: Dictionary, mine: bool) -> UiCard:
	var card := _make_card(String(cr["card"]), cr)
	var cid := int(cr["id"])
	if mine:
		# Your creature: drag to attack, and also accept play-drops landing on it.
		var can_attack := _my_turn() and int(cr.get("frozen", 0)) == 0 \
			and not bool(cr.get("sick", false)) and not bool(cr.get("attacked", false))
		card.payload = {"kind": "attacker", "id": cid, "draggable": can_attack}
		card.drag_label = _name_of(String(cr["card"]))
		card.can_drop_fn = func(data: Variant) -> bool: return _can_play_here(data)
		card.drop_fn = func(data: Variant) -> void: _play_payload(data, 0)
		card.clicked.connect(func(_p: Dictionary) -> void: _on_my_creature(cid))
	else:
		# Enemy creature: accept an attacker, or a targeted spell/awaken.
		card.can_drop_fn = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY:
				return false
			if data.get("kind", "") == "attacker":
				return true
			return data.get("kind", "") in ["hand", "awaken"] and bool(data.get("needs_target", false))
		card.drop_fn = func(data: Variant) -> void:
			if data.get("kind", "") == "attacker":
				_send({"action": "attackCreature", "attacker": int(data["id"]), "target": cid})
				_clear_selection()
			else:
				_play_payload(data, cid)
		card.clicked.connect(func(_p: Dictionary) -> void: _on_enemy_creature(cid))
	return card


# --- hand --------------------------------------------------------------------

func _hand_row(hand: Array) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	var mana_zone := _mana_zone()
	box.add_child(mana_zone)

	for i in hand.size():
		var cid: String = hand[i]
		var card := _make_card(cid, null)
		card.payload = {
			"kind": "hand", "index": int(i), "card_id": cid,
			"needs_target": _needs_target(cid), "is_creature": _is_creature(cid),
			"draggable": _my_turn(),
		}
		card.drag_label = _name_of(cid)
		var idx := i
		card.clicked.connect(func(_p: Dictionary) -> void: _on_hand_card(idx, cid))
		box.add_child(card)
	return box


func _mana_zone() -> Control:
	var zone := UiCard.new()
	zone.custom_minimum_size = Vector2(70, CARD_SIZE.y)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.14, 0.16, 0.2)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.5, 0.5, 0.6)
	sb.set_corner_radius_all(6)
	zone.add_theme_stylebox_override("panel", sb)
	zone.can_drop_fn = func(data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.get("kind", "") == "hand"
	zone.drop_fn = func(data: Variant) -> void:
		_place_mana(int(data["index"]), String(data["card_id"]))
	var l := Label.new()
	l.text = "TO\nMANA"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	zone.add_child(l)
	return zone


# --- card visual -------------------------------------------------------------

func _make_card(def_id: String, runtime) -> UiCard:
	var d: Dictionary = cards.get(def_id, {})
	var col := _primary_color(d)
	var card := UiCard.new()
	card.custom_minimum_size = CARD_SIZE

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.17)
	sb.set_border_width_all(3)
	sb.border_color = col
	sb.set_corner_radius_all(7)
	sb.set_content_margin_all(5)
	card.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 2)
	card.add_child(v)

	# Header: cost badge (left) + status badges (right).
	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_cost_node(d.get("cost", {})))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	if typeof(runtime) == TYPE_DICTIONARY:
		var st := _status_text(runtime)
		if st != "":
			header.add_child(_info_label(st, 11))
	v.add_child(header)

	# Name.
	var name_label := Label.new()
	name_label.text = _name_of(def_id)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(name_label)

	# Art area: res://art/<id>.png if present, else a colored placeholder.
	var art := _art_node(def_id, col)
	v.add_child(art)

	# Rules text.
	var txt := _text_of(def_id)
	if txt != "":
		var text_label := Label.new()
		text_label.text = txt
		text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_label.add_theme_font_size_override("font_size", 10)
		text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		v.add_child(text_label)

	# Stats footer for creatures: runtime atk/hp if on board, else printed.
	var stat_row = _stats_node(def_id, runtime)
	if stat_row != null:
		v.add_child(stat_row)
	return card


func _art_node(def_id: String, col: Color) -> Control:
	var path := "res://art/%s.png" % def_id
	if ResourceLoader.exists(path):
		var tex := TextureRect.new()
		tex.texture = load(path)
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tex.custom_minimum_size = Vector2(0, 64)
		tex.size_flags_vertical = Control.SIZE_EXPAND_FILL
		return tex
	var ph := Panel.new()
	ph.custom_minimum_size = Vector2(0, 64)
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.35)
	sb.set_corner_radius_all(4)
	ph.add_theme_stylebox_override("panel", sb)
	return ph


func _cost_node(cost: Dictionary) -> Control:
	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	var gen := int(cost.get("generic", 0))
	var badge := Label.new()
	badge.text = str(gen)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_font_size_override("font_size", 14)
	badge.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	box.add_child(badge)
	for color in ["red", "yellow", "green", "blue", "violet"]:
		for _i in int(cost.get(color, 0)):
			var pip := Panel.new()
			pip.custom_minimum_size = Vector2(9, 9)
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var psb := StyleBoxFlat.new()
			psb.bg_color = _color_for(color)
			psb.set_corner_radius_all(5)
			pip.add_theme_stylebox_override("panel", psb)
			box.add_child(pip)
	return box


func _stats_node(def_id: String, runtime) -> Control:
	var d: Dictionary = cards.get(def_id, {})
	var atk := 0
	var hp := 0
	if typeof(runtime) == TYPE_DICTIONARY:
		atk = int(runtime.get("atk", 0))
		hp = int(runtime.get("hp", 0))
	elif d.has("stats"):
		atk = int(d["stats"].get("atk", 0))
		hp = int(d["stats"].get("hp", 0))
	else:
		return null   # auras / spells have no stats

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var a := Label.new()
	a.text = "%d ATK" % atk
	a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	a.add_theme_font_size_override("font_size", 15)
	a.add_theme_color_override("font_color", Color(0.95, 0.85, 0.4))
	row.add_child(a)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	var h := Label.new()
	h.text = "%d HP" % hp
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_font_size_override("font_size", 15)
	# Tint HP red when damaged below printed max.
	if typeof(runtime) == TYPE_DICTIONARY and hp < int(runtime.get("maxHp", hp)):
		h.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
	else:
		h.add_theme_color_override("font_color", Color(0.5, 0.95, 0.5))
	row.add_child(h)
	return row


func _status_text(cr: Dictionary) -> String:
	var parts := []
	if int(cr.get("frozen", 0)) > 0:
		parts.append("ICE")
	if int(cr.get("blind", 0)) > 0:
		parts.append("BLIND")
	if bool(cr.get("shield", false)):
		parts.append("SHLD")
	if bool(cr.get("stealth", false)):
		parts.append("HID")
	if bool(cr.get("sick", false)):
		parts.append("ZZ")
	return " ".join(parts)


# --- styles ------------------------------------------------------------------

func _hero_style(tint: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = tint.darkened(0.55)
	sb.set_border_width_all(2)
	sb.border_color = tint
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	return sb


func _zone_style(mine: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.14, 0.12) if mine else Color(0.14, 0.10, 0.10)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.25, 0.4, 0.3) if mine else Color(0.4, 0.25, 0.25)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(6)
	return sb


# --- controls + hints --------------------------------------------------------

func _controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var end_btn := Button.new()
	end_btn.text = "End Turn"
	end_btn.disabled = not _my_turn()
	end_btn.pressed.connect(func() -> void:
		_clear_selection()
		_send({"action": "endTurn"}))
	row.add_child(end_btn)

	var hint := Label.new()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if casting_index >= 0 or awaken_index >= 0:
		hint.text = "pick an enemy creature as the target (click the card again to cancel)"
	elif attacker_id >= 0:
		hint.text = "pick an enemy creature or the enemy hero to attack"
	else:
		hint.text = "drag a card to your board or the MANA zone, or drag a creature onto a target to attack"
	row.add_child(hint)
	return row


# --- drag drop helpers (shared by play / awaken) -----------------------------

func _can_play_here(data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not (data.get("kind", "") in ["hand", "awaken"]):
		return false
	# A targeted spell must be dropped on an enemy creature, not on the board.
	return not bool(data.get("needs_target", false))


func _play_payload(data: Variant, target: int) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	if data.get("kind", "") == "awaken":
		_send({"action": "awaken", "manaRowIndex": int(data["manaRowIndex"]), "target": target})
	else:
		_send({"action": "play", "handIndex": int(data["index"]), "target": target})
	_clear_selection()


func _place_mana(idx: int, card_id: String) -> void:
	var d: Dictionary = cards.get(card_id, {})
	var colors: Array = d.get("color", [])
	var color := "colorless" if colors.is_empty() else String(colors[0])
	_send({"action": "placeMana", "handIndex": idx, "color": color})
	_clear_selection()


# --- click fallback ----------------------------------------------------------

func _on_hand_card(idx: int, card_id: String) -> void:
	if not _my_turn():
		return
	if casting_index == idx:
		casting_index = -1
		_rebuild()
		return
	if _needs_target(card_id):
		_clear_selection()
		casting_index = idx
		_rebuild()
	else:
		_clear_selection()
		_send({"action": "play", "handIndex": idx})


func _on_awaken_clicked(p: Dictionary) -> void:
	if not _my_turn():
		return
	var idx := int(p["manaRowIndex"])
	if awaken_index == idx:
		awaken_index = -1
		_rebuild()
		return
	if bool(p.get("needs_target", false)):
		_clear_selection()
		awaken_index = idx
		_rebuild()
	else:
		_clear_selection()
		_send({"action": "awaken", "manaRowIndex": idx, "target": 0})


func _on_my_creature(cid: int) -> void:
	_clear_selection()
	attacker_id = cid
	_rebuild()


func _on_enemy_creature(cid: int) -> void:
	if casting_index >= 0:
		_send({"action": "play", "handIndex": casting_index, "target": cid})
		_clear_selection()
	elif awaken_index >= 0:
		_send({"action": "awaken", "manaRowIndex": awaken_index, "target": cid})
		_clear_selection()
	elif attacker_id >= 0:
		_send({"action": "attackCreature", "attacker": attacker_id, "target": cid})
		_clear_selection()


func _on_enemy_hero() -> void:
	if attacker_id >= 0:
		_send({"action": "attackHero", "attacker": attacker_id})
		_clear_selection()
