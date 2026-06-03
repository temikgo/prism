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
const FRAME := 5.0      # colored-gradient frame thickness around the art
const GEM := 34.0       # diameter of the cost / atk / hp corner gems
const BOARD_LIMIT := 8  # max creatures per side (mirrors the engine)

var socket := WebSocketPeer.new()
var was_open := false
var view := {}
var cards := {}            # card id -> definition (from cards.json)

# Click-fallback selection state (drag-and-drop ignores these).
var attacker_id := -1      # your selected creature, waiting for an attack target
var casting_index := -1    # hand index of a targeted spell waiting for a target
var awaken_index := -1     # mana-row index of a targeted awaken card
var pending_side := ""     # side a pending targeted spell can hit: enemy/friendly/any
var _picker: Control = null   # open mana-color chooser, if any
var _overlay: Control = null  # full-screen overlay layer (game-over screen)
var _fx: Control = null        # transient effects layer (damage numbers, ghosts)
var _prev_hp := {}             # creature id -> hp last seen (damage/death diff)
var _card_nodes := {}          # creature id -> its card node this rebuild
var _dmg := {}                 # creature id -> damage taken since the last view
var _summoned := {}            # creature id -> true if newly on the board
var _my_creatures_row: Control = null  # the HBox holding your board creatures
var _my_board_zone: Control = null     # your board drop zone (for hover test)
var _board_gap: Control = null         # slot opened while dragging a creature in
var _mull_sel := {}                    # mulligan: hand indices marked for replacing
var _scry_sel := {}                    # scry: peeked indices marked for the bottom

var url_edit: LineEdit
var status_label: Label
var root_box: VBoxContainer


# Color identity, rules glossary, and generic widget/style builders live in their
# own files: palette.gd (Palette), glossary.gd (Glossary), ui.gd (Ui).


# UiCard (the draggable/droppable card-or-zone widget) and FxLayer (the aiming
# arrow overlay) live in their own files: ui_card.gd and fx_layer.gd.


# --- lifecycle ---------------------------------------------------------------

func _ready() -> void:
	_load_cards()
	_build_shell()
	# Remove the default dark tooltip wrapper window-wide so our custom card
	# tooltip shows without a panel behind it. The auto-created tooltip popup
	# resolves its style from the window theme, not from the tooltip control.
	var th := Theme.new()
	th.set_stylebox("panel", "TooltipPanel", StyleBoxEmpty.new())
	get_window().theme = th


func _load_cards() -> void:
	# Deck cards (mirror of the server's pool) plus client-only token display
	# data (sprouts and other generated tokens that never sit in a deck).
	_load_card_file("res://cards.json")
	_load_card_file("res://tokens.json")


func _load_card_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
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
	var connect_btn := Ui.neon_button("Connect", Color(0.4, 0.8, 1.0))
	connect_btn.pressed.connect(_on_connect)
	bar.add_child(connect_btn)
	status_label = Ui.label("disconnected", 0, Color(0.7, 0.75, 0.85))
	bar.add_child(status_label)
	root_box.add_child(bar)

	# Full-screen overlay (game-over screen), populated on rebuild.
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)

	# Effects overlay on top of everything (attack arrow, damage numbers, ghosts).
	_fx = FxLayer.new()
	_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.z_index = 100  # above hovered cards (which raise their own z_index)
	add_child(_fx)


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
				_ingest_view(data)
	elif st == WebSocketPeer.STATE_CLOSED and was_open:
		was_open = false
		status_label.text = "closed"
	_update_board_gap()


# While dragging a creature over your board, open an empty slot at the spot it
# would land, so the board reflows before you drop.
func _update_board_gap() -> void:
	var d = UiCard.active_drag
	var ok: bool = d != null and typeof(d) == TYPE_DICTIONARY \
		and d.get("kind", "") == "hand" and bool(d.get("is_creature", false)) \
		and not bool(d.get("needs_target", false)) and bool(d.get("playable", true)) \
		and _my_creatures_row != null and is_instance_valid(_my_creatures_row) \
		and _my_board_zone != null and is_instance_valid(_my_board_zone) \
		and _my_board_zone.get_global_rect().has_point(get_global_mouse_position())
	if not ok:
		_remove_board_gap()
		return
	if _board_gap == null or not is_instance_valid(_board_gap):
		_board_gap = Panel.new()
		_board_gap.custom_minimum_size = CARD_SIZE
		_board_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.4, 0.9, 1.0, 0.08)
		sb.set_border_width_all(2)
		sb.border_color = Color(0.4, 0.9, 1.0, 0.5)
		sb.set_corner_radius_all(10)
		_board_gap.add_theme_stylebox_override("panel", sb)
		_my_creatures_row.add_child(_board_gap)
	elif _board_gap.get_parent() != _my_creatures_row:
		_board_gap.get_parent().remove_child(_board_gap)
		_my_creatures_row.add_child(_board_gap)
	_my_creatures_row.move_child(_board_gap, _drop_insert_index())


func _remove_board_gap() -> void:
	if _board_gap != null and is_instance_valid(_board_gap):
		_board_gap.queue_free()
	_board_gap = null


func _send(obj: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(obj))


# Apply a fresh view: diff creature HP against the last one to drive damage,
# death and summon animations, then rebuild.
func _ingest_view(new_view: Dictionary) -> void:
	# A new view means the board changed: a pending click-selection or open mana
	# picker would point at now-stale indices, so drop them.
	_clear_selection()
	_close_picker()
	_dmg = {}
	_summoned = {}
	var new_hp := {}
	for s in 2:
		for cr in new_view["players"][s].get("board", []):
			new_hp[int(cr["id"])] = int(cr["hp"])
	for id in new_hp:
		if _prev_hp.has(id):
			if new_hp[id] < _prev_hp[id]:
				_dmg[id] = _prev_hp[id] - new_hp[id]
		else:
			_summoned[id] = true
	# A creature we had is gone: rescue its node from the doomed tree and fade it.
	for id in _prev_hp:
		if not new_hp.has(id) and _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			_fade_out_dead(_card_nodes[id])

	view = new_view
	_card_nodes = {}
	_rebuild()  # refills _card_nodes
	_prev_hp = new_hp
	_animate_changes(_dmg.duplicate(), _summoned.duplicate())
	_dmg = {}
	_summoned = {}


# Apply damage / death / summon effects once the new board has laid out.
func _animate_changes(dmg: Dictionary, summoned: Dictionary) -> void:
	await get_tree().process_frame
	for id in summoned:
		if _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			_pop_in(_card_nodes[id])
	for id in dmg:
		if _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			var nd: Control = _card_nodes[id]
			_flash_card(nd)
			_spawn_float_number(
				nd.global_position + Vector2(nd.size.x * 0.5, nd.size.y * 0.18), int(dmg[id]))


func _flash_card(card: Control) -> void:
	card.pivot_offset = card.size * 0.5
	var rest: Color = card.rest_modulate
	var t := create_tween()
	t.tween_property(card, "modulate", Color(2.2, 0.5, 0.5), 0.06)
	t.parallel().tween_property(card, "scale", Vector2(1.14, 1.14), 0.06)
	t.tween_property(card, "modulate", rest, 0.3)
	t.parallel().tween_property(card, "scale", Vector2.ONE, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _pop_in(card: Control) -> void:
	card.pivot_offset = card.size * 0.5
	var rest: Color = card.rest_modulate
	card.scale = Vector2(0.45, 0.45)
	card.modulate = Color(1.6, 1.6, 1.6, 0.0)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(card, "scale", Vector2.ONE, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(card, "modulate", rest, 0.26)


func _fade_out_dead(node: Control) -> void:
	var gp := node.global_position
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)
	_fx.add_child(node)
	node.global_position = gp
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.pivot_offset = node.size * 0.5
	var t := create_tween()
	t.tween_property(node, "modulate", Color(2.2, 0.4, 0.4), 0.08)  # death flash
	t.tween_property(node, "modulate", Color(1.4, 0.3, 0.3, 0.0), 0.4)
	t.parallel().tween_property(node, "scale", Vector2(0.55, 0.55), 0.4)
	t.parallel().tween_property(node, "rotation", deg_to_rad(18.0), 0.4)
	t.parallel().tween_property(node, "position", node.position + Vector2(0, 36), 0.4)
	t.chain().tween_callback(node.queue_free)


func _spawn_float_number(pos: Vector2, amount: int) -> void:
	var lbl := Ui.label("-%d" % amount, 32, Color(1.0, 0.4, 0.4))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("outline_size", 6)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.pivot_offset = Vector2(14, 18)
	lbl.position = pos
	lbl.scale = Vector2(0.6, 0.6)
	_fx.add_child(lbl)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(lbl, "position", pos + Vector2(0, -58), 0.7)
	t.tween_property(lbl, "scale", Vector2(1.15, 1.15), 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(lbl, "modulate", Color(1, 1, 1, 0), 0.7)
	t.chain().tween_callback(lbl.queue_free)


func _clear_selection() -> void:
	attacker_id = -1
	casting_index = -1
	awaken_index = -1
	pending_side = ""


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
	if bool(view.get("over", false)):
		return false  # the game is decided -- no actions
	return int(view.get("current", -1)) == int(view.get("you", -2))


func _needs_target(card_id: String) -> bool:
	return _target_side(card_id) != ""


# Which side a targeted spell can hit: "enemy", "friendly", "any", or "" (none).
func _target_side(card_id: String) -> String:
	var d: Dictionary = cards.get(card_id, {})
	for e in d.get("effects", []):
		match String(e.get("selector", "")):
			"chosen_enemy_minion":
				return "enemy"
			"chosen_friendly_minion":
				return "friendly"
			"chosen_any_minion":
				return "any"
	return ""


func _is_creature(card_id: String) -> bool:
	return String(cards.get(card_id, {}).get("type", "")) == "creature"


# Can the current available mana pay this cost? Colored pips come from their own
# color; the generic part comes from whatever is left (matches the engine).
func _can_afford(cost: Dictionary, avail: Dictionary) -> bool:
	var pool := {}
	for c in ["red", "yellow", "green", "blue", "violet", "colorless"]:
		pool[c] = int(avail.get(c, 0))
	for c in ["red", "yellow", "green", "blue", "violet"]:
		var need := int(cost.get(c, 0))
		if pool[c] < need:
			return false
		pool[c] -= need
	var left := 0
	for c in pool:
		left += int(pool[c])
	return left >= int(cost.get("generic", 0))


# Playable right now: my turn, affordable, and (for creatures) the board has room.
func _is_playable(card_id: String) -> bool:
	if not _my_turn():
		return false
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	if not _can_afford(cards.get(card_id, {}).get("cost", {}), me["mana"].get("available", {})):
		return false
	if _is_creature(card_id) and int(me.get("board", []).size()) >= BOARD_LIMIT:
		return false
	# Cannot play an aura you already control (matches the engine rule).
	if String(cards.get(card_id, {}).get("type", "")) == "aura":
		for a in me.get("auras", []):
			if String(a.get("card", "")) == card_id:
				return false
	# A targeted spell with no legal target on the board cannot be cast.
	if _needs_target(card_id) and not _has_legal_target(card_id):
		return false
	return true


# Is there at least one legal target for this card's targeted effect?
func _has_legal_target(card_id: String) -> bool:
	var side := _target_side(card_id)
	if side == "":
		return true
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var opp: Dictionary = view["players"][1 - you]
	if side == "enemy" or side == "any":
		for c in opp.get("board", []):
			if not bool(c.get("stealth", false)):
				return true
	if side == "friendly" or side == "any":
		if not me.get("board", []).is_empty():
			return true
	return false


func _has_keyword(card_id: String, kw: String) -> bool:
	for k in cards.get(card_id, {}).get("keywords", []):
		if String(k.get("id", "")) == kw:
			return true
	return false


func _keyword_n(card_id: String, kw: String) -> int:
	for k in cards.get(card_id, {}).get("keywords", []):
		if String(k.get("id", "")) == kw:
			return int(k.get("n", 0))
	return 0


# Does the enemy control a (visible) provoker, forcing attacks onto it?
func _enemy_has_provoke() -> bool:
	var you := int(view["you"])
	var opp: Dictionary = view["players"][1 - you]
	for c in opp.get("board", []):
		if bool(c.get("stealth", false)):
			continue
		if _has_keyword(String(c["card"]), "provoke"):
			return true
	return false


# A legal attack target: not hidden, and if a provoker exists you may only hit
# a provoker.
func _valid_attack_target(cr: Dictionary) -> bool:
	if bool(cr.get("stealth", false)):
		return false
	if _enemy_has_provoke() and not _has_keyword(String(cr["card"]), "provoke"):
		return false
	return true


# Does the currently selected attacker (click-fallback) have Bypass?
func _attacker_has_bypass() -> bool:
	if attacker_id < 0:
		return false
	var you := int(view["you"])
	for c in view["players"][you].get("board", []):
		if int(c["id"]) == attacker_id:
			return _has_keyword(String(c["card"]), "bypass")
	return false


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
	UiCard.targeting = attacker_id >= 0 or casting_index >= 0 or awaken_index >= 0

	root_box.add_child(_banner(you))
	root_box.add_child(_enemy_strip(opp))
	root_box.add_child(_board_row(opp.get("board", []), opp.get("auras", []), false))
	root_box.add_child(_separator())
	root_box.add_child(_board_row(me.get("board", []), me.get("auras", []), true))
	root_box.add_child(_me_strip(me))
	root_box.add_child(_hand_row(me.get("hand", [])))
	root_box.add_child(_controls())

	for c in _overlay.get_children():
		c.queue_free()
	if bool(view.get("over", false)):
		_overlay.add_child(_game_over_panel(you))
	elif bool(view.get("mulligan", false)):
		_overlay.add_child(_mulligan_panel(me))
	elif view.has("scry"):
		_overlay.add_child(_scry_panel(view["scry"]))


func _separator() -> Control:
	var line := HSeparator.new()
	line.add_theme_constant_override("separation", 6)
	return line


func _game_over_panel(you: int) -> Control:
	var win := int(view.get("winner", -1)) == you
	var accent := Color(0.5, 0.95, 0.6) if win else Color(0.95, 0.45, 0.45)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks underneath

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(accent, 0.9))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.add_child(Ui.label("ПОБЕДА" if win else "ПОРАЖЕНИЕ", 48, accent.lightened(0.3), true))
	vb.add_child(Ui.label("Перезапустите сервер для новой партии", 14,
		Color(0.75, 0.78, 0.86), true))
	panel.add_child(vb)
	center.add_child(panel)
	return dim


# Opening-hand mulligan: tap cards to mark them for replacement, then confirm.
# Both players choose at once; the first turn begins when both have confirmed.
func _mulligan_panel(me: Dictionary) -> Control:
	var accent := Color(0.45, 0.85, 1.0)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # block the board underneath

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(accent, 0.92))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	center.add_child(panel)

	var title := Ui.label("", 30, accent.lightened(0.3), true)
	vb.add_child(title)

	# Once you have confirmed, just wait for the opponent.
	if bool(me.get("mulliganDone", false)):
		title.text = "Ждём соперника…"
		vb.add_child(Ui.label("Ваш мулиган принят.", 0, Color(0.75, 0.78, 0.86), true))
		return dim

	title.text = "Мулиган"
	vb.add_child(Ui.label("Нажмите на карты, которые хотите заменить, затем подтвердите.",
		14, Color(0.75, 0.78, 0.86), true))

	var hand: Array = me.get("hand", [])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for i in hand.size():
		var cid: String = hand[i]
		var marked: bool = _mull_sel.has(i)
		var wrap := Control.new()
		wrap.custom_minimum_size = CARD_SIZE
		var card := _make_card(cid, null)
		if marked:
			# Dim and red-tint cards staged for replacement.
			card.modulate = Color(1.0, 0.5, 0.5, 0.6)
			card.rest_modulate = card.modulate
		var idx := i
		card.clicked.connect(func(_p: Dictionary) -> void: _toggle_mulligan(idx))
		wrap.add_child(card)
		if marked:
			var badge := Ui.label("ЗАМЕНА", 16, Color(1.0, 0.7, 0.7), true)
			badge.position = Vector2(0, CARD_SIZE.y / 2.0 - 12)
			badge.size = Vector2(CARD_SIZE.x, 24)
			badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			wrap.add_child(badge)
		row.add_child(wrap)
	vb.add_child(row)

	var n := _mull_sel.size()
	var btn := Ui.neon_button("Заменить %d" % n if n > 0 else "Оставить руку", accent)
	btn.custom_minimum_size = Vector2(0, 40)
	btn.pressed.connect(_send_mulligan)
	vb.add_child(btn)
	return dim


func _toggle_mulligan(index: int) -> void:
	if _mull_sel.has(index):
		_mull_sel.erase(index)
	else:
		_mull_sel[index] = true
	_rebuild()  # redraw the panel with the new selection


func _send_mulligan() -> void:
	var indices: Array = _mull_sel.keys()
	indices.sort()
	_send({"action": "mulligan", "indices": indices})
	_mull_sel.clear()


# Blue scry: the peeked top cards (top first), tap any to send it to the bottom,
# then confirm. The unmarked ones stay on top in order.
func _scry_panel(peek: Array) -> Control:
	var accent := Color(0.45, 0.7, 1.0)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)

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
		var marked: bool = _scry_sel.has(i)
		var wrap := Control.new()
		wrap.custom_minimum_size = CARD_SIZE
		var card := _make_card(cid, null)
		if marked:
			card.modulate = Color(0.6, 0.7, 1.0, 0.6)
			card.rest_modulate = card.modulate
		var idx := i
		card.clicked.connect(func(_p: Dictionary) -> void: _toggle_scry(idx))
		wrap.add_child(card)
		var pos_l := Ui.label("ВНИЗ" if marked else "верх %d" % (i + 1), 14,
			Color(0.7, 0.8, 1.0) if marked else Color(0.7, 0.73, 0.82), true)
		pos_l.position = Vector2(0, CARD_SIZE.y / 2.0 - 12)
		pos_l.size = Vector2(CARD_SIZE.x, 24)
		pos_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wrap.add_child(pos_l)
		row.add_child(wrap)
	vb.add_child(row)

	var n := _scry_sel.size()
	var btn := Ui.neon_button("Убрать вниз: %d" % n if n > 0 else "Оставить всё сверху", accent)
	btn.custom_minimum_size = Vector2(0, 40)
	btn.pressed.connect(_send_scry)
	vb.add_child(btn)
	return dim


func _toggle_scry(index: int) -> void:
	if _scry_sel.has(index):
		_scry_sel.erase(index)
	else:
		_scry_sel[index] = true
	_rebuild()


func _send_scry() -> void:
	var bottom: Array = _scry_sel.keys()
	bottom.sort()
	_send({"action": "scryResolve", "bottom": bottom})
	_scry_sel.clear()


func _banner(you: int) -> Control:
	var banner := Ui.label("", 22, null, true)
	if bool(view.get("over", false)):
		var w := int(view.get("winner", -1))
		var win := w == you
		banner.text = "GAME OVER - " + ("YOU WIN" if win else "YOU LOSE")
		banner.add_theme_color_override("font_color",
			Color(0.5, 0.95, 0.6) if win else Color(0.95, 0.45, 0.45))
	elif bool(view.get("mulligan", false)):
		banner.text = "МУЛИГАН"
		banner.add_theme_color_override("font_color", Color(0.45, 0.85, 1.0))
	else:
		var who := "YOUR TURN" if _my_turn() else "OPPONENT'S TURN"
		banner.text = "%s   -   turn %d" % [who, int(view.get("turn", 0))]
		banner.add_theme_color_override("font_color",
			Color(0.45, 0.85, 1.0) if _my_turn() else Color(0.6, 0.62, 0.72))
	return banner


# --- hero strips -------------------------------------------------------------

func _enemy_strip(opp: Dictionary) -> Control:
	var zone := UiCard.new()
	zone.custom_minimum_size = Vector2(0, 72)  # a fat, easy drop target for face hits
	zone.add_theme_stylebox_override("panel", _hero_style(Color(0.9, 0.32, 0.38)))
	# Attack the face: blocked by a provoker unless the attacker has Bypass.
	zone.can_drop_fn = func(data: Variant) -> bool:
		if typeof(data) != TYPE_DICTIONARY or data.get("kind", "") != "attacker":
			return false
		return not _enemy_has_provoke() or bool(data.get("bypass", false))
	zone.drop_fn = func(data: Variant) -> void:
		_send({"action": "attackHero", "attacker": int(data["id"])})
		_clear_selection()
	zone.clicked.connect(func(_p: Dictionary) -> void: _on_enemy_hero())
	if attacker_id >= 0 and (not _enemy_has_provoke() or _attacker_has_bypass()):
		zone.modulate = Color(1.5, 1.4, 1.1)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 14)
	row.add_child(_hero_block(opp["hero"], "ENEMY"))
	row.add_child(_counts_label(opp))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	row.add_child(_mana_crystals(opp.get("mana", {})))
	row.add_child(_manarow_view(opp.get("manaRow", []), false))
	zone.add_child(row)
	return zone


func _me_strip(me: Dictionary) -> Control:
	var zone := UiCard.new()
	zone.add_theme_stylebox_override("panel", _hero_style(Color(0.32, 0.6, 0.98)))

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 14)
	row.add_child(_hero_block(me["hero"], "YOU"))
	var power := Ui.neon_button("Сила героя", Color(0.72, 0.45, 0.95))
	power.disabled = true
	power.tooltip_text = "Сила героя - появится позже"
	row.add_child(power)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	row.add_child(_mana_crystals(me.get("mana", {})))
	row.add_child(_manarow_view(me.get("manaRow", []), true))
	row.add_child(_counts_label(me))
	zone.add_child(row)
	return zone


func _aura_shelf(auras: Array, mine: bool) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var tag := Ui.label("ВАШИ АУРЫ" if mine else "АУРЫ ВРАГА", 10, Color(0.6, 0.64, 0.74))
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(tag)
	for a in auras:
		box.add_child(_aura_tile(String(a.get("card", ""))))
	return box


func _aura_tile(card_id: String) -> Control:
	var col := Palette.primary(cards.get(card_id, {}))
	var tile := UiCard.new()
	tile.custom_minimum_size = Vector2(140, 58)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.15, 0.92)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2)
	sb.border_color = col
	sb.shadow_size = 8
	sb.shadow_color = Color(col.r, col.g, col.b, 0.5)
	sb.set_content_margin_all(5)
	tile.add_theme_stylebox_override("panel", sb)
	tile.tooltip_text = _name_of(card_id)
	tile.tooltip_builder = func() -> Control: return _build_tooltip(card_id, null)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	row.add_child(_art_thumb(card_id, col, 46))
	var name_l := Ui.label(_name_of(card_id), 12)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_l.custom_minimum_size = Vector2(66, 0)
	row.add_child(name_l)
	tile.add_child(row)
	return tile


# A square art thumbnail for a card, or a tinted placeholder if the art is
# missing. Shared by the aura shelf and the awaken chips.
func _art_thumb(card_id: String, fallback: Color, px: float) -> Control:
	var path := "res://art/%s.png" % card_id
	if ResourceLoader.exists(path):
		var tex := TextureRect.new()
		tex.texture = load(path)
		tex.custom_minimum_size = Vector2(px, px)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return tex
	var ph := ColorRect.new()
	ph.color = fallback.darkened(0.4)
	ph.custom_minimum_size = Vector2(px, px)
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return ph


func _hero_block(hero: Dictionary, title: String) -> Control:
	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 5)
	var t := Ui.label(title, 15)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(t)
	box.add_child(Ui.icon("heart", 22, Color(0.95, 0.42, 0.46)))
	box.add_child(_gem(str(int(hero["hp"])), Color(0.95, 0.42, 0.46)))
	if int(hero.get("armor", 0)) > 0:
		box.add_child(Ui.icon("shield", 20, Color(0.72, 0.82, 0.98)))
		var arm := Ui.label(str(int(hero["armor"])), 16, Color(0.72, 0.82, 0.98))
		arm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(arm)
	return box


func _counts_label(p: Dictionary) -> Control:
	var txt := "рука %d   колода %d   сброс %d" % [
		int(p.get("handCount", 0)), int(p.get("deckCount", 0)),
		int(p.get("graveyardCount", 0))]
	# Blue delay: how many effects are queued to resolve on this player's turns.
	var pending := int(p.get("pendingCount", 0))
	if pending > 0:
		txt += "   отложено %d" % pending
	var l := Ui.label(txt, 12, Color(0.6, 0.64, 0.74))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _mana_crystals(mana: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	var avail: Dictionary = mana.get("available", {})
	var total: Dictionary = mana.get("crystals", {})
	var any := false
	for color in ["red", "yellow", "green", "blue", "violet", "colorless"]:
		var t := int(total.get(color, 0))
		if t <= 0:
			continue
		any = true
		var av := int(avail.get(color, 0))
		var group := HBoxContainer.new()
		group.mouse_filter = Control.MOUSE_FILTER_IGNORE
		group.add_theme_constant_override("separation", 2)
		for i in t:
			group.add_child(Ui.mana_pip(color, i < av))
		row.add_child(group)
	if not any:
		var l := Ui.label("нет маны", 12, Color(0.5, 0.53, 0.62))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(l)
	return row


# A single mana crystal: bright and glowing when available, dim when spent.
# --- mana row (face-down backs + peekable awaken cards) ----------------------

# The banked cards themselves are just hidden mana -- their count already shows
# as crystals -- so we only surface your own awaken-able cards here.
func _manarow_view(mana_row: Array, mine: bool) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 3)
	var tagged := false
	for i in mana_row.size():
		var slot: Dictionary = mana_row[i]
		if not slot.has("card"):  # face-down: only awaken/floodlight reveal a card
			continue
		if not tagged:
			# Yours = awaken-able cards; the enemy's only show under your floodlight.
			var label := "разбудить:" if mine else "прожектор:"
			var tag := Ui.label(label, 11, Color(0.95, 0.85, 0.4))
			tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(tag)
			tagged = true
		if mine:
			row.add_child(_awaken_chip(int(i), slot))
		else:
			row.add_child(_revealed_chip(slot))
	return row


# A peekable awaken card sitting in your mana row: a mini-card (art + name + a
# tag) with a gold frame. It brightens and glows once you can pay for it this
# turn; otherwise it is dimmed like an unaffordable hand card. A decoy that has
# aged enough awakens for free and is tagged accordingly.
func _awaken_chip(idx: int, slot: Dictionary) -> Control:
	var card_id := String(slot["card"])
	var color := String(slot.get("color", "colorless"))
	var age := int(slot.get("age", 0))
	var free := _has_keyword(card_id, "decoy") and age >= _keyword_n(card_id, "decoy")
	var gold := Color(0.95, 0.85, 0.3)
	var affordable := _can_awaken(card_id, color, age)
	var chip := UiCard.new()
	chip.custom_minimum_size = Vector2(150, 54)
	var sb := Ui.bordered(Color(0.09, 0.10, 0.15, 0.94), 8, 2,
		gold if affordable else gold.darkened(0.4), 5)
	if affordable:
		sb.shadow_size = 10
		sb.shadow_color = Color(gold.r, gold.g, gold.b, 0.6)
	chip.add_theme_stylebox_override("panel", sb)
	chip.tooltip_text = _name_of(card_id)
	chip.tooltip_builder = func() -> Control: return _build_tooltip(card_id, null)
	chip.hoverable = true
	if not affordable:
		chip.modulate = Color(0.62, 0.62, 0.68, 0.92)
		chip.rest_modulate = chip.modulate
	chip.payload = {
		"kind": "awaken", "manaRowIndex": idx, "card_id": card_id,
		"needs_target": _needs_target(card_id), "draggable": _my_turn(),
		"target_side": _target_side(card_id),
	}
	chip.drag_label = "awaken: " + _name_of(card_id)
	chip.clicked.connect(func(p: Dictionary) -> void: _on_awaken_clicked(p))

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	row.add_child(_art_thumb(card_id, Palette.color_for(color), 42))
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_l := Ui.label(_name_of(card_id), 12)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_l.custom_minimum_size = Vector2(80, 0)
	col.add_child(name_l)
	var tag_txt := "бесплатно!" if free else "разбудить"
	var tag := Ui.label(tag_txt, 9, gold if affordable else gold.darkened(0.25))
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(tag)
	row.add_child(col)
	chip.add_child(row)
	return chip


# A read-only peek at an enemy's banked card, revealed by your floodlight aura.
func _revealed_chip(slot: Dictionary) -> Control:
	var card_id := String(slot["card"])
	var color := String(slot.get("color", "colorless"))
	var chip := UiCard.new()
	chip.custom_minimum_size = Vector2(124, 46)
	chip.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.09, 0.10, 0.15, 0.9), 7, 1, Color(0.7, 0.62, 0.32)))
	chip.tooltip_text = _name_of(card_id)
	chip.tooltip_builder = func() -> Control: return _build_tooltip(card_id, null)
	chip.hoverable = true
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 5)
	row.add_child(_art_thumb(card_id, Palette.color_for(color), 36))
	var name_l := Ui.label(_name_of(card_id), 11)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_l.custom_minimum_size = Vector2(72, 0)
	row.add_child(name_l)
	chip.add_child(row)
	return chip


# Can you awaken this banked card right now? Mirrors Game::awaken: its own
# crystal must be unspent and pays 1 of the cost in its color (else 1 generic);
# the remainder must be affordable. A decoy aged >= N awakens for free.
func _can_awaken(card_id: String, color: String, age: int) -> bool:
	if not _my_turn():
		return false
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var avail: Dictionary = me["mana"].get("available", {})
	if int(avail.get(color, 0)) < 1:
		return false  # the banked crystal itself must still be available
	if _is_creature(card_id) and int(me.get("board", []).size()) >= BOARD_LIMIT:
		return false
	if _has_keyword(card_id, "decoy") and age >= _keyword_n(card_id, "decoy"):
		return true  # aged decoy: only the banked crystal is spent
	var cost: Dictionary = (cards.get(card_id, {}).get("cost", {})).duplicate(true)
	if int(cost.get(color, 0)) > 0:
		cost[color] = int(cost[color]) - 1
	elif int(cost.get("generic", 0)) > 0:
		cost["generic"] = int(cost["generic"]) - 1
	var pool: Dictionary = avail.duplicate(true)
	pool[color] = int(pool.get(color, 0)) - 1  # the banked crystal is consumed
	return _can_afford(cost, pool)


# --- board rows --------------------------------------------------------------

func _board_row(board: Array, auras: Array, mine: bool) -> Control:
	# The whole row is a drop zone: dropping a playable hand/awaken card here
	# plays it (creatures land on your own side). Auras sit on a side shelf so
	# they take horizontal, not vertical, space.
	var zone := UiCard.new()
	zone.custom_minimum_size = Vector2(0, CARD_SIZE.y + 12)
	zone.add_theme_stylebox_override("panel", _zone_style(mine))
	if mine:
		zone.glow_self = true  # glow the zone border, not the creatures/auras in it
		zone.can_drop_fn = func(data: Variant) -> bool: return _can_play_here(data)
		zone.drop_fn = func(data: Variant) -> void: _play_at_drop(data)

	var outer := HBoxContainer.new()
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_theme_constant_override("separation", 10)
	if not auras.is_empty():
		outer.add_child(_aura_shelf(auras, mine))

	var row := HBoxContainer.new()
	# IGNORE so drops in the gaps fall through to the zone; the creature cards
	# (mouse_filter STOP) still receive their own input regardless.
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for cr in board:
		row.add_child(_creature_card(cr, mine))
	outer.add_child(row)
	zone.add_child(outer)
	if mine:
		# Remember the row/zone so a drag can open a slot for the incoming creature.
		_my_creatures_row = row
		_my_board_zone = zone
		_board_gap = null  # the old gap (if any) was freed with the old row
	return zone


func _creature_card(cr: Dictionary, mine: bool) -> UiCard:
	var card := _make_card(String(cr["card"]), cr)
	var cid := int(cr["id"])
	if mine:
		# Your creature: drag to attack; also a drop target for playing a creature
		# here or casting a friendly/any-target spell on it.
		# Mirror Creature::canAttack: not sick/attacked/frozen/blinded and atk > 0.
		var can_attack := _my_turn() and int(cr.get("atk", 0)) > 0 \
			and int(cr.get("frozen", 0)) == 0 and int(cr.get("blind", 0)) == 0 \
			and not bool(cr.get("sick", false)) and not bool(cr.get("attacked", false))
		card.payload = {
			"kind": "attacker", "id": cid, "draggable": can_attack,
			"bypass": _has_keyword(String(cr["card"]), "bypass"),
		}
		card.drag_label = _name_of(String(cr["card"]))
		# Accept a creature/aura play-drop OR a friendly/any spell, but only glow
		# for the spell case (playing a creature is not played "onto" this one).
		card.can_drop_fn = func(data: Variant) -> bool:
			return _can_play_here(data) or _can_cast_on(data, "friendly")
		card.highlight_check = func(data: Variant) -> bool:
			return _can_cast_on(data, "friendly")
		card.drop_fn = func(data: Variant) -> void:
			if _can_cast_on(data, "friendly"):
				_play_payload(data, cid)
			else:
				_play_at_drop(data)
		card.clicked.connect(func(_p: Dictionary) -> void: _on_my_creature(cid))
		# On your turn, dim creatures that cannot attack so the ready ones glow.
		if _my_turn() and not can_attack:
			card.modulate = Color(0.6, 0.62, 0.7, 0.92)
			card.rest_modulate = Color(0.6, 0.62, 0.7, 0.92)
		# A friendly/any spell awaiting a target lights up your creatures.
		if (casting_index >= 0 or awaken_index >= 0) and pending_side in ["friendly", "any"]:
			card.modulate = Color(1.45, 1.45, 1.1)
			card.rest_modulate = Color(1.45, 1.45, 1.1)
	else:
		# Enemy creature: accept an attacker (subject to provoke/stealth), or an
		# enemy/any-target spell (not on a hidden creature).
		card.can_drop_fn = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY:
				return false
			if data.get("kind", "") == "attacker":
				return _valid_attack_target(cr)
			return _can_cast_on(data, "enemy") and not bool(cr.get("stealth", false))
		card.drop_fn = func(data: Variant) -> void:
			if data.get("kind", "") == "attacker":
				_send({"action": "attackCreature", "attacker": int(data["id"]), "target": cid})
				_clear_selection()
			else:
				_play_payload(data, cid)
		card.clicked.connect(func(_p: Dictionary) -> void: _on_enemy_creature(cid))
		# Light up only valid targets: attackable ones (respecting provoke/stealth)
		# while attacking, castable ones while a spell awaits a target.
		var await_attack := attacker_id >= 0 and _valid_attack_target(cr)
		var await_spell := (casting_index >= 0 or awaken_index >= 0) \
			and pending_side in ["enemy", "any"] and not bool(cr.get("stealth", false))
		if await_attack or await_spell:
			card.modulate = Color(1.45, 1.45, 1.1)

	# Green germinate: an "activate" button on your own creature.
	if mine and _has_keyword(String(cr["card"]), "germinate"):
		card.add_child(_germinate_button(cr, cid))

	_card_nodes[cid] = card
	return card


# True if you can use this creature's germinate right now.
func _can_germinate(cr: Dictionary) -> bool:
	if not _my_turn() or bool(cr.get("usedActive", false)):
		return false
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	if int(me.get("board", []).size()) >= BOARD_LIMIT:
		return false
	var avail: Dictionary = me["mana"].get("available", {})
	var total := 0
	for c in ["red", "yellow", "green", "blue", "violet", "colorless"]:
		total += int(avail.get(c, 0))
	return total >= 1


func _germinate_button(cr: Dictionary, cid: int) -> Button:
	var acc := Color(0.4, 0.8, 0.46)
	var ok := _can_germinate(cr)
	var n := int(_keyword_n(String(cr["card"]), "germinate"))
	var b := Button.new()
	b.text = "росток %d/%d" % [n, n]
	b.add_theme_font_size_override("font_size", 11)
	b.disabled = not ok
	b.tooltip_text = "Проращивание: 1 кристалл → росток %d/%d (раз в ход)" % [n, n]
	b.add_theme_color_override("font_color", acc.lightened(0.5))
	b.add_theme_color_override("font_disabled_color", Color(0.45, 0.48, 0.55))
	b.add_theme_stylebox_override("normal", Ui.glass(acc, 0.55))
	b.add_theme_stylebox_override("hover", Ui.glass(acc, 0.75))
	var dis := Ui.glass(Color(0.3, 0.32, 0.4), 0.3)
	dis.shadow_size = 0
	b.add_theme_stylebox_override("disabled", dis)
	b.position = Vector2(FRAME + 2, FRAME + 2)
	b.size = Vector2(CARD_SIZE.x - 2 * (FRAME + 2), 22)
	b.pressed.connect(func() -> void:
		_send({"action": "activate", "id": cid})
		_clear_selection())
	return b


# --- hand --------------------------------------------------------------------

func _hand_row(hand: Array) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(_mana_zone())

	# Cards overlap (fan) when there are too many to lay out side by side.
	var cards_box := HBoxContainer.new()
	var n := hand.size()
	var sep := 8
	if n > 1:
		var avail := size.x - 40 - 84 - 48  # window margins, mana zone, padding
		var needed := n * CARD_SIZE.x + (n - 1) * 8
		if float(needed) > avail:
			sep = int((avail - n * CARD_SIZE.x) / float(n - 1))
			sep = maxi(sep, -int(CARD_SIZE.x * 0.5))
	cards_box.add_theme_constant_override("separation", sep)

	for i in n:
		var cid: String = hand[i]
		var card := _make_card(cid, null)
		var playable := _is_playable(cid)
		card.payload = {
			"kind": "hand", "index": int(i), "card_id": cid,
			"needs_target": _needs_target(cid), "is_creature": _is_creature(cid),
			"draggable": _my_turn(), "playable": playable,
			"target_side": _target_side(cid),
		}
		card.drag_label = _name_of(cid)
		# Dim cards you cannot play this turn so the playable ones stand out.
		if not playable:
			card.modulate = Color(0.62, 0.62, 0.68, 0.92)
			card.rest_modulate = Color(0.62, 0.62, 0.68, 0.92)
		var idx := i
		card.clicked.connect(func(_p: Dictionary) -> void: _on_hand_card(idx, cid))
		cards_box.add_child(card)
	box.add_child(cards_box)
	return box


func _mana_zone() -> Control:
	var zone := UiCard.new()
	zone.custom_minimum_size = Vector2(84, CARD_SIZE.y)
	zone.add_theme_stylebox_override("panel", Ui.glass(Color(0.55, 0.55, 0.7), 0.32))
	zone.can_drop_fn = func(data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.get("kind", "") == "hand"
	zone.drop_fn = func(data: Variant) -> void:
		_place_mana(int(data["index"]), String(data["card_id"]))
	var l := Ui.label("TO\nMANA", 0, null, true)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	var col := Palette.primary(cards.get(def_id, {}))
	var glow := StyleBoxFlat.new()
	glow.bg_color = Color(0, 0, 0, 0)
	glow.set_corner_radius_all(12)
	glow.shadow_size = 10
	glow.shadow_color = Color(col.r, col.g, col.b, 0.6)
	card.add_theme_stylebox_override("panel", glow)
	card.add_child(_card_face(def_id, runtime))
	# Pretty hover tooltip (built lazily) instead of the plain text one. A
	# non-empty tooltip_text is still required for the tooltip to trigger.
	card.tooltip_text = _name_of(def_id)
	card.tooltip_builder = func() -> Control: return _build_tooltip(def_id, runtime)
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


func _build_tooltip(def_id: String, runtime = null) -> Control:
	var d: Dictionary = cards.get(def_id, {})
	var col := Palette.primary(d)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.10, 0.11, 0.15, 0.98), 10, 2, col, 11))

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.custom_minimum_size = Vector2(250, 0)
	panel.add_child(v)

	var header := HBoxContainer.new()
	header.add_child(Ui.label(_name_of(def_id), 18, col.lightened(0.4)))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sp)
	header.add_child(Ui.label("%d" % _total_cost(d.get("cost", {})), 18, Color(0.85, 0.88, 0.98)))
	v.add_child(header)

	v.add_child(Ui.label(Glossary.type_label(d), 12, Color(0.6, 0.65, 0.75)))

	# Rules are generated from the card's data (single source of truth): a full
	# explanation per keyword, then a plain imperative sentence per effect. Cards
	# carry no hand-written rules text.
	var lines := []
	for kw in d.get("keywords", []):
		var kl := Glossary.keyword(kw)
		if kl != "":
			lines.append(kl)
	for e in d.get("effects", []):
		var el := Glossary.effect_text(e)
		if el != "":
			lines.append(el)
	if not lines.is_empty():
		v.add_child(HSeparator.new())
		for line in lines:
			v.add_child(_explain_label(line))

	# Optional flavor (lore) line, shown dim under the rules when present.
	var flavor := _text_of(def_id)
	if flavor != "":
		v.add_child(HSeparator.new())
		var fl := Ui.label(flavor, 12, Color(0.62, 0.6, 0.72))
		fl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fl.custom_minimum_size = Vector2(250, 0)
		v.add_child(fl)

	# Active statuses on a creature in play, with how long they last.
	var status := Glossary.status_lines(runtime)
	if not status.is_empty():
		v.add_child(HSeparator.new())
		for s in status:
			var sl := Ui.label(s, 12, Color(0.55, 0.82, 1.0))
			sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			sl.custom_minimum_size = Vector2(250, 0)
			v.add_child(sl)
	return panel


func _explain_label(text: String) -> Label:
	var l := Ui.label(text, 12, Color(0.74, 0.8, 0.64))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(250, 0)
	return l


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

	# Cost badge (top-left): generic number plus one colored pip per colored
	# requirement, so the color cost is visible at a glance.
	var cost_badge := _cost_badge(d.get("cost", {}))
	cost_badge.anchor_left = 0
	cost_badge.anchor_top = 0
	cost_badge.anchor_right = 0
	cost_badge.anchor_bottom = 0
	cost_badge.offset_left = FRAME
	cost_badge.offset_top = FRAME
	cost_badge.offset_right = FRAME
	cost_badge.offset_bottom = FRAME
	cost_badge.grow_horizontal = Control.GROW_DIRECTION_END
	cost_badge.grow_vertical = Control.GROW_DIRECTION_END
	face.add_child(cost_badge)

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
	var l := Ui.label(text, 17, ring.lightened(0.4), true)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
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
	ph.color = Palette.primary(cards.get(def_id, {})).darkened(0.4)
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
			cols.append(Palette.color_for(String(c)))
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


func _cost_badge(cost: Dictionary) -> Control:
	var pill := PanelContainer.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.09, 0.9)
	sb.set_corner_radius_all(9)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.55, 0.6, 0.75, 0.7)
	sb.set_content_margin_all(3)
	pill.add_theme_stylebox_override("panel", sb)

	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	var gen := int(cost.get("generic", 0))
	var has_color := false
	for c in ["red", "yellow", "green", "blue", "violet"]:
		if int(cost.get(c, 0)) > 0:
			has_color = true
	# Show the generic number when there is one, or when the card is free of any
	# colored pips (so a "0" still appears instead of an empty badge).
	if gen > 0 or not has_color:
		var n := Ui.label(str(gen), 18, Color(0.95, 0.96, 1.0))
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(n)
	for c in ["red", "yellow", "green", "blue", "violet"]:
		for _i in int(cost.get(c, 0)):
			box.add_child(Ui.cost_pip(c))
	pill.add_child(box)
	return pill


func _status_icons(cr: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 3)
	var any := false
	if int(cr.get("frozen", 0)) > 0:
		row.add_child(Ui.icon("snowflake", 20, Color(0.6, 0.85, 1.0)))
		any = true
	if bool(cr.get("shield", false)):
		row.add_child(Ui.icon("shield", 20, Color(0.97, 0.88, 0.4)))
		any = true
	if bool(cr.get("ward", false)):
		row.add_child(Ui.icon("halo", 20, Color(0.72, 0.95, 1.0)))
		any = true
	if bool(cr.get("stealth", false)):
		row.add_child(Ui.icon("eye", 20, Color(0.75, 0.55, 0.97)))
		any = true
	if int(cr.get("blind", 0)) > 0:
		row.add_child(Ui.icon("eye", 20, Color(0.97, 0.5, 0.5)))
		any = true
	if bool(cr.get("sick", false)):
		row.add_child(Ui.icon("moon", 20, Color(0.72, 0.77, 0.87)))
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
	return Ui.glass(tint, 0.4)


func _zone_style(mine: bool) -> StyleBoxFlat:
	var accent := Color(0.3, 0.75, 0.6) if mine else Color(0.75, 0.35, 0.4)
	var sb := Ui.glass(accent, 0.22)
	sb.shadow_size = 0   # board zones stay calm; only cards/heroes glow
	return sb


# --- controls + hints --------------------------------------------------------

func _controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var end_btn := Ui.neon_button("End Turn", Color(1.0, 0.62, 0.3))
	end_btn.disabled = not _my_turn()
	end_btn.pressed.connect(func() -> void:
		_clear_selection()
		_send({"action": "endTurn"}))
	row.add_child(end_btn)

	var hint := Ui.label("", 0, Color(0.62, 0.66, 0.78))
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
	# An unplayable hand card lights up no board zone (but can still go to mana).
	if data.get("kind", "") == "hand" and not bool(data.get("playable", true)):
		return false
	# A targeted spell must be dropped on a creature, not on the board.
	return not bool(data.get("needs_target", false))


# True if the dragged targeted spell/awaken may be cast on a creature of the
# given side ("friendly" or "enemy"). An "any" spell hits either side.
func _can_cast_on(data: Variant, want_side: String) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not (data.get("kind", "") in ["hand", "awaken"]):
		return false
	if not bool(data.get("needs_target", false)):
		return false
	var side := String(data.get("target_side", ""))
	if side != "any" and side != want_side:
		return false
	# Hand cards must be affordable; awaken legality is checked by the server.
	if data.get("kind", "") == "hand" and not bool(data.get("playable", true)):
		return false
	return true


func _play_payload(data: Variant, target: int) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	if data.get("kind", "") == "awaken":
		_send({"action": "awaken", "manaRowIndex": int(data["manaRowIndex"]), "target": target})
	else:
		_send({"action": "play", "handIndex": int(data["index"]), "target": target})
	_clear_selection()


# Play a creature onto your board at the slot the cursor dropped it.
func _play_at_drop(data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var pos := _drop_insert_index()
	if data.get("kind", "") == "awaken":
		_send({"action": "awaken", "manaRowIndex": int(data["manaRowIndex"]), "target": 0, "pos": pos})
	else:
		_send({"action": "play", "handIndex": int(data["index"]), "target": 0, "pos": pos})
	_clear_selection()


# How many of your creatures sit left of the drop point -> the insertion slot.
func _drop_insert_index() -> int:
	var you := int(view["you"])
	var mx := get_global_mouse_position().x
	var n := 0
	for cr in view["players"][you].get("board", []):
		var id := int(cr["id"])
		if _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			var nd: Control = _card_nodes[id]
			if nd.global_position.x + nd.size.x * 0.5 < mx:
				n += 1
	return n


func _place_mana(idx: int, card_id: String) -> void:
	var d: Dictionary = cards.get(card_id, {})
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		_send({"action": "placeMana", "handIndex": idx, "color": "colorless"})
		_clear_selection()
	elif colors.size() == 1:
		_send({"action": "placeMana", "handIndex": idx, "color": String(colors[0])})
		_clear_selection()
	else:
		# Multicolor card: let the player choose which crystal it becomes.
		_show_color_picker(idx, colors)


func _show_color_picker(idx: int, colors: Array) -> void:
	# In-scene chooser: a dim full-screen backdrop (click to cancel) with a small
	# panel of color buttons near the cursor. Avoids the flaky popup window.
	_close_picker()
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var backdrop := Button.new()
	backdrop.flat = true
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.pressed.connect(_close_picker)
	layer.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(Color(0.6, 0.62, 0.8), 0.97))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.add_child(Ui.label("Каким кристаллом положить?", 14))
	for c in colors:
		var cc := String(c)
		var b := Ui.neon_button(Palette.ru(cc), Palette.color_for(cc))
		b.pressed.connect(func() -> void:
			_send({"action": "placeMana", "handIndex": idx, "color": cc})
			_clear_selection()
			_close_picker())
		vb.add_child(b)
	panel.add_child(vb)
	layer.add_child(panel)
	add_child(layer)

	var pos := get_global_mouse_position() - Vector2(20, 20)
	pos.x = clampf(pos.x, 8.0, size.x - 200.0)
	pos.y = clampf(pos.y, 8.0, size.y - 180.0)
	panel.position = pos
	_picker = layer


func _close_picker() -> void:
	if _picker != null:
		_picker.queue_free()
		_picker = null


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
		pending_side = _target_side(card_id)
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
		pending_side = _target_side(String(p.get("card_id", "")))
		_rebuild()
	else:
		_clear_selection()
		_send({"action": "awaken", "manaRowIndex": idx, "target": 0})


func _on_my_creature(cid: int) -> void:
	if not _my_turn():
		return
	# Cast a pending friendly/any spell on this creature, else select it to attack.
	if casting_index >= 0 and pending_side in ["friendly", "any"]:
		_send({"action": "play", "handIndex": casting_index, "target": cid})
		_clear_selection()
		return
	if awaken_index >= 0 and pending_side in ["friendly", "any"]:
		_send({"action": "awaken", "manaRowIndex": awaken_index, "target": cid})
		_clear_selection()
		return
	_clear_selection()
	attacker_id = cid
	_rebuild()


func _on_enemy_creature(cid: int) -> void:
	if not _my_turn():
		return
	if casting_index >= 0 and pending_side in ["enemy", "any"]:
		_send({"action": "play", "handIndex": casting_index, "target": cid})
		_clear_selection()
	elif awaken_index >= 0 and pending_side in ["enemy", "any"]:
		_send({"action": "awaken", "manaRowIndex": awaken_index, "target": cid})
		_clear_selection()
	elif attacker_id >= 0:
		_send({"action": "attackCreature", "attacker": attacker_id, "target": cid})
		_clear_selection()


func _on_enemy_hero() -> void:
	if not _my_turn():
		return
	if attacker_id >= 0:
		_send({"action": "attackHero", "attacker": attacker_id})
		_clear_selection()
