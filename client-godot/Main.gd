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
const CARD_SIZE := Vector2(150, 210)
const FRAME := 5.0     # colored-gradient frame thickness around the art
const GEM := 34.0      # diameter of the cost / atk / hp corner gems

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


func _icon(icon_name: String, px: float, color: Color) -> TextureRect:
	var tex := TextureRect.new()
	tex.texture = load("res://icons/%s.svg" % icon_name)
	tex.custom_minimum_size = Vector2(px, px)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.modulate = color
	return tex


# --- a draggable / droppable card or zone -------------------------------------

class UiCard extends PanelContainer:
	signal clicked(payload: Dictionary)
	# Shared across all cards: the payload of the drag currently in flight, so
	# any card can decide whether to light up as a legal drop target.
	static var active_drag = null
	var payload: Dictionary = {}        # non-empty + draggable=true => can drag
	var drag_label: String = ""
	var preview_builder: Callable = Callable()   # returns the drag-preview Control
	var tooltip_builder: Callable = Callable()   # returns the hover-tooltip Control
	var can_drop_fn: Callable = Callable()
	var drop_fn: Callable = Callable()
	var hoverable := false                        # lift + scale on mouse-over
	var _is_drag_source := false

	func _ready() -> void:
		mouse_entered.connect(_on_hover_in)
		mouse_exited.connect(_on_hover_out)

	func _on_hover_in() -> void:
		if not hoverable:
			return
		pivot_offset = size / 2.0
		z_index = 20
		create_tween().tween_property(self, "scale", Vector2(1.08, 1.08), 0.08)

	func _on_hover_out() -> void:
		if not hoverable:
			return
		z_index = 0
		create_tween().tween_property(self, "scale", Vector2.ONE, 0.08)

	func _make_custom_tooltip(_for_text: String) -> Object:
		if tooltip_builder.is_valid():
			return tooltip_builder.call()
		return null

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
		active_drag = payload
		_is_drag_source = true
		if preview_builder.is_valid():
			set_drag_preview(preview_builder.call())
		else:
			var ghost := Label.new()
			ghost.text = drag_label
			ghost.add_theme_color_override("font_color", Color.WHITE)
			set_drag_preview(ghost)
		return payload

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		if can_drop_fn.is_valid():
			return bool(can_drop_fn.call(data))
		return false

	func _drop_data(_at: Vector2, data: Variant) -> void:
		if drop_fn.is_valid():
			drop_fn.call(data)

	func _notification(what: int) -> void:
		# While a drag is in flight: dim the source card, glow legal targets.
		if what == NOTIFICATION_DRAG_BEGIN:
			if _is_drag_source:
				modulate = Color(1, 1, 1, 0.35)
			elif active_drag != null and can_drop_fn.is_valid() \
					and bool(can_drop_fn.call(active_drag)):
				modulate = Color(1.45, 1.45, 1.1)
		elif what == NOTIFICATION_DRAG_END:
			active_drag = null
			_is_drag_source = false
			modulate = Color.WHITE


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
	var bg := TextureRect.new()
	bg.texture = _bg_texture()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	root_box = VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 8)
	margin.add_child(root_box)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	url_edit = LineEdit.new()
	url_edit.text = DEFAULT_URL
	url_edit.custom_minimum_size = Vector2(280, 0)
	bar.add_child(url_edit)
	var connect_btn := _neon_button("Connect", Color(0.4, 0.8, 1.0))
	connect_btn.pressed.connect(_on_connect)
	bar.add_child(connect_btn)
	status_label = Label.new()
	status_label.text = "disconnected"
	status_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	bar.add_child(status_label)
	root_box.add_child(bar)


func _bg_texture() -> Texture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray([
		Color(0.07, 0.08, 0.15), Color(0.10, 0.06, 0.16), Color(0.02, 0.02, 0.05)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.42)
	tex.fill_to = Vector2(1.05, 1.1)
	return tex


# Translucent dark "glass" with a neon accent border and a soft accent glow.
func _glass(accent: Color, bg_alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.15, bg_alpha)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.6)
	sb.shadow_size = 10
	sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.28)
	sb.set_content_margin_all(8)
	return sb


func _neon_button(text: String, accent: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", accent.lightened(0.5))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.43, 0.5))
	b.add_theme_stylebox_override("normal", _glass(accent, 0.4))
	b.add_theme_stylebox_override("hover", _glass(accent, 0.62))
	b.add_theme_stylebox_override("pressed", _glass(accent, 0.8))
	var dis := _glass(Color(0.32, 0.34, 0.42), 0.22)
	dis.shadow_size = 0
	b.add_theme_stylebox_override("disabled", dis)
	return b


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
	banner.add_theme_font_size_override("font_size", 22)
	if bool(view.get("over", false)):
		var w := int(view.get("winner", -1))
		var win := w == you
		banner.text = "GAME OVER - " + ("YOU WIN" if win else "YOU LOSE")
		banner.add_theme_color_override("font_color",
			Color(0.5, 0.95, 0.6) if win else Color(0.95, 0.45, 0.45))
	else:
		var who := "YOUR TURN" if _my_turn() else "OPPONENT'S TURN"
		banner.text = "%s   -   turn %d" % [who, int(view.get("turn", 0))]
		banner.add_theme_color_override("font_color",
			Color(0.45, 0.85, 1.0) if _my_turn() else Color(0.6, 0.62, 0.72))
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
	if attacker_id >= 0:
		zone.modulate = Color(1.35, 1.35, 1.05)

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
		# Click-fallback: light up enemy creatures while a target is awaited.
		if attacker_id >= 0 or casting_index >= 0 or awaken_index >= 0:
			card.modulate = Color(1.45, 1.45, 1.1)
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
	zone.custom_minimum_size = Vector2(84, CARD_SIZE.y)
	zone.add_theme_stylebox_override("panel", _glass(Color(0.55, 0.55, 0.7), 0.32))
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
	# Minimal card face: art + cost/atk/hp gems + a color frame. Name, rules
	# text and keywords live in the hover tooltip, not on the face.
	var card := UiCard.new()
	card.custom_minimum_size = CARD_SIZE
	# Neon glow in the card's own color (drawn by the card panel, behind the
	# rounded face, so it is not clipped).
	var col := _primary_color(cards.get(def_id, {}))
	var glow := StyleBoxFlat.new()
	glow.bg_color = Color(0, 0, 0, 0)
	glow.set_corner_radius_all(12)
	glow.shadow_size = 7
	glow.shadow_color = Color(col.r, col.g, col.b, 0.5)
	card.add_theme_stylebox_override("panel", glow)
	card.add_child(_card_face(def_id, runtime))
	# Pretty hover tooltip (built lazily) instead of the plain text one. A
	# non-empty tooltip_text is still required for the tooltip to trigger.
	card.tooltip_text = _name_of(def_id)
	card.tooltip_builder = func() -> Control: return _build_tooltip(def_id)
	card.hoverable = true
	# The drag preview is the card itself, centered under the cursor.
	card.preview_builder = func() -> Control:
		var wrapper := Control.new()
		var f := _card_face(def_id, runtime)
		f.size = CARD_SIZE
		f.position = -CARD_SIZE / 2.0
		wrapper.add_child(f)
		return wrapper
	return card


func _build_tooltip(def_id: String) -> Control:
	var d: Dictionary = cards.get(def_id, {})
	var col := _primary_color(d)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.15, 0.98)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = col
	sb.set_content_margin_all(11)
	panel.add_theme_stylebox_override("panel", sb)
	# Kill Godot's default tooltip wrapper (the dim panel behind ours).
	var th := Theme.new()
	th.set_stylebox("panel", "TooltipPanel", StyleBoxEmpty.new())
	panel.theme = th

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.custom_minimum_size = Vector2(250, 0)
	panel.add_child(v)

	var header := HBoxContainer.new()
	var name_l := Label.new()
	name_l.text = _name_of(def_id)
	name_l.add_theme_font_size_override("font_size", 18)
	name_l.add_theme_color_override("font_color", col.lightened(0.4))
	header.add_child(name_l)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sp)
	var cost_l := Label.new()
	cost_l.text = "%d" % _total_cost(d.get("cost", {}))
	cost_l.add_theme_font_size_override("font_size", 18)
	cost_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.98))
	header.add_child(cost_l)
	v.add_child(header)

	var type_l := Label.new()
	type_l.text = _type_label(d)
	type_l.add_theme_font_size_override("font_size", 12)
	type_l.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	v.add_child(type_l)

	var txt := _text_of(def_id)
	if txt != "":
		v.add_child(HSeparator.new())
		var text_l := Label.new()
		text_l.text = txt
		text_l.add_theme_font_size_override("font_size", 14)
		text_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text_l.custom_minimum_size = Vector2(250, 0)
		v.add_child(text_l)
	return panel


func _type_label(d: Dictionary) -> String:
	var ru_type := {"creature": "Существо", "spell": "Заклинание", "aura": "Аура"}
	var line: String = ru_type.get(String(d.get("type", "")), String(d.get("type", "")))
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		return line + " - нейтральная"
	var ru_color := {
		"red": "красный", "yellow": "жёлтый", "green": "зелёный",
		"blue": "синий", "violet": "фиолетовый",
	}
	var names := []
	for c in colors:
		names.append(ru_color.get(String(c), String(c)))
	return line + " - " + ", ".join(names)


# Full card visual as a fixed-size Control with everything anchored to corners,
# so the size is constant regardless of contents (used for the card and the
# drag preview alike).
func _card_face(def_id: String, runtime) -> Control:
	var d: Dictionary = cards.get(def_id, {})
	var face := Panel.new()
	face.custom_minimum_size = CARD_SIZE
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Rounded body; clip_children rounds the gradient frame and art to it. The
	# corner gems are circles and sit clear of the rounded corners, so they read
	# fully. clip_children draws the panel normally, so the shadow still shows.
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.07, 0.07, 0.10)
	body.set_corner_radius_all(12)
	face.add_theme_stylebox_override("panel", body)
	face.clip_children = CanvasItem.CLIP_CHILDREN_ONLY

	# Color frame: gradient built from the card's colors (neutral = white).
	var frame := TextureRect.new()
	frame.texture = _frame_texture(d)
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(frame)

	# Art inset by FRAME px so the gradient shows as a ring around it.
	var art := _art_full(def_id)
	_anchor_inset(art, FRAME)
	face.add_child(art)

	# Status overlays that cover the art so they read at a glance.
	if typeof(runtime) == TYPE_DICTIONARY and int(runtime.get("frozen", 0)) > 0:
		var ice := ColorRect.new()
		ice.color = Color(0.45, 0.72, 1.0, 0.32)
		ice.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_anchor_inset(ice, FRAME)
		face.add_child(ice)
	if typeof(runtime) == TYPE_DICTIONARY and bool(runtime.get("sick", false)):
		var sleep := ColorRect.new()
		sleep.color = Color(0.08, 0.10, 0.24, 0.42)
		sleep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_anchor_inset(sleep, FRAME)
		face.add_child(sleep)

	# Cost gem (top-left), ring tinted by the card's primary color.
	var cost_gem := _gem(str(_total_cost(d.get("cost", {}))), _primary_color(d).lightened(0.2))
	_anchor_corner(cost_gem, 0, 0, FRAME, FRAME)
	face.add_child(cost_gem)

	# Stat gems (bottom corners) for creatures.
	var has_stats: bool = d.has("stats") or (typeof(runtime) == TYPE_DICTIONARY and runtime.has("atk"))
	if has_stats:
		var atk := 0
		var hp := 0
		var max_hp := 0
		if typeof(runtime) == TYPE_DICTIONARY:
			atk = int(runtime.get("atk", 0))
			hp = int(runtime.get("hp", 0))
			max_hp = int(runtime.get("maxHp", hp))
		else:
			atk = int(d["stats"].get("atk", 0))
			hp = int(d["stats"].get("hp", 0))
			max_hp = hp
		var atk_gem := _gem(str(atk), Color(0.95, 0.8, 0.35))
		_anchor_corner(atk_gem, 0, 1, FRAME, -GEM - FRAME)
		face.add_child(atk_gem)
		var hp_color := Color(0.55, 0.95, 0.5) if hp >= max_hp else Color(0.97, 0.4, 0.4)
		var hp_gem := _gem(str(hp), hp_color)
		_anchor_corner(hp_gem, 1, 1, -GEM - FRAME, -GEM - FRAME)
		face.add_child(hp_gem)

	# Status icons (top-right), right-aligned and growing left/down.
	if typeof(runtime) == TYPE_DICTIONARY:
		var status_row = _status_icons(runtime)
		if status_row != null:
			status_row.anchor_left = 1
			status_row.anchor_right = 1
			status_row.offset_left = -FRAME
			status_row.offset_right = -FRAME
			status_row.offset_top = FRAME
			status_row.offset_bottom = FRAME
			status_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			status_row.grow_vertical = Control.GROW_DIRECTION_END
			face.add_child(status_row)
	return face


func _anchor_inset(node: Control, inset: float) -> void:
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.offset_left = inset
	node.offset_top = inset
	node.offset_right = -inset
	node.offset_bottom = -inset


func _anchor_corner(node: Control, ax: float, ay: float, ox: float, oy: float) -> void:
	# Pin a GEM-sized node to corner (ax,ay in {0,1}) with offset (ox,oy).
	node.anchor_left = ax
	node.anchor_right = ax
	node.anchor_top = ay
	node.anchor_bottom = ay
	node.offset_left = ox
	node.offset_right = ox + GEM
	node.offset_top = oy
	node.offset_bottom = oy + GEM


func _gem(text: String, ring: Color) -> Control:
	var g := Panel.new()
	g.custom_minimum_size = Vector2(GEM, GEM)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.94)
	sb.set_corner_radius_all(int(GEM / 2.0))
	sb.set_border_width_all(2)
	sb.border_color = ring
	g.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", ring.lightened(0.4))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_child(l)
	return g


func _art_full(def_id: String) -> Control:
	var path := "res://art/%s.png" % def_id
	if ResourceLoader.exists(path):
		var tex := TextureRect.new()
		tex.texture = load(path)
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		return tex
	var ph := ColorRect.new()
	ph.color = _primary_color(cards.get(def_id, {})).darkened(0.4)
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return ph


func _frame_texture(d: Dictionary) -> Texture2D:
	var cols := PackedColorArray()
	var card_colors: Array = d.get("color", [])
	if card_colors.is_empty():
		# Colorless: a clean white frame. The prismatic rainbow is reserved for
		# a card that genuinely carries all five colors.
		cols.append(Color(0.93, 0.93, 0.97))
		cols.append(Color(0.78, 0.80, 0.88))
	else:
		for c in card_colors:
			cols.append(_color_for(String(c)))
		if cols.size() == 1:
			cols.append(cols[0])

	var grad := Gradient.new()
	var offs := PackedFloat32Array()
	for i in cols.size():
		offs.append(float(i) / float(cols.size() - 1))
	grad.offsets = offs
	grad.colors = cols

	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_LINEAR
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(1, 1)
	return tex


func _total_cost(cost: Dictionary) -> int:
	var t := int(cost.get("generic", 0))
	for c in ["red", "yellow", "green", "blue", "violet"]:
		t += int(cost.get(c, 0))
	return t


func _status_icons(cr: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 3)
	var any := false
	if int(cr.get("frozen", 0)) > 0:
		row.add_child(_icon("snowflake", 20, Color(0.6, 0.85, 1.0)))
		any = true
	if bool(cr.get("shield", false)):
		row.add_child(_icon("shield", 20, Color(0.97, 0.88, 0.4)))
		any = true
	if bool(cr.get("stealth", false)):
		row.add_child(_icon("eye", 20, Color(0.75, 0.55, 0.97)))
		any = true
	if int(cr.get("blind", 0)) > 0:
		row.add_child(_icon("eye", 20, Color(0.97, 0.5, 0.5)))
		any = true
	if bool(cr.get("sick", false)):
		row.add_child(_icon("moon", 20, Color(0.72, 0.77, 0.87)))
		any = true
	if not any:
		return null
	# Dark chip behind the icons so they read over any art.
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.05, 0.7)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(3)
	chip.add_theme_stylebox_override("panel", sb)
	chip.add_child(row)
	return chip


# --- styles ------------------------------------------------------------------

func _hero_style(tint: Color) -> StyleBoxFlat:
	return _glass(tint, 0.4)


func _zone_style(mine: bool) -> StyleBoxFlat:
	var accent := Color(0.3, 0.75, 0.6) if mine else Color(0.75, 0.35, 0.4)
	var sb := _glass(accent, 0.22)
	sb.shadow_size = 0   # board zones stay calm; only cards/heroes glow
	return sb


# --- controls + hints --------------------------------------------------------

func _controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var end_btn := _neon_button("End Turn", Color(1.0, 0.62, 0.3))
	end_btn.disabled = not _my_turn()
	end_btn.pressed.connect(func() -> void:
		_clear_selection()
		_send({"action": "endTurn"}))
	row.add_child(end_btn)

	var hint := Label.new()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.78))
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
