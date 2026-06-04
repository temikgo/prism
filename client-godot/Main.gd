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
const CARD_SIZE := Vector2(176, 246)
const RIM := 2.0        # thin colored light-rim around the full-bleed art
const PAD := 6.0        # inset of cost / stats / status from the card edge
const GEM := 34.0       # diameter of the cost / atk / hp corner gems
const STATUS_MAX := 4   # status icons shown before collapsing to a +N chip
const BOARD_LIMIT := 8  # max creatures per side (mirrors the engine)

var socket := WebSocketPeer.new()
var was_open := false
var view := {}
var cards := {}            # card id -> definition (from cards.json)

# Click-fallback selection state (drag-and-drop ignores these).
var _picker: Control = null   # open mana-color chooser, if any
var _motes: GPUParticles2D = null  # ambient light particles (resized with window)
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
var _pending_lunge := {}               # {attacker, pos}: a just-sent attack to animate
var _enemy_hero_node = null            # enemy hero medallion node (lunge target)

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
	# The light of the Mega-Prism: a soft cool glow spilling from the top, and a
	# vignette darkening the edges so the lit battlefield draws the eye to center.
	add_child(_glow_layer(Vector2(0.5, -0.05), 1.0,
		Color(0.46, 0.56, 1.0, 0.26), Color(0.46, 0.56, 1.0, 0.0)))
	add_child(_glow_layer(Vector2(0.5, 1.02), 0.7,
		Color(0.55, 0.28, 0.7, 0.16), Color(0.55, 0.28, 0.7, 0.0)))
	add_child(_glow_layer(Vector2(0.5, 0.5), 0.95,
		Color(0.0, 0.0, 0.0, 0.0), Color(0.0, 0.0, 0.02, 0.62)))
	# Slow drifting light motes -- ambient "living light", behind the UI. They are
	# sized to the actual window and re-fitted whenever it resizes (e.g. maximize).
	_motes = _ambient_motes()
	add_child(_motes)
	get_tree().root.size_changed.connect(_on_window_resized)
	_fit_motes()

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
	var connect_btn := Ui.neon_button("Подключиться", Color(0.4, 0.8, 1.0))
	connect_btn.pressed.connect(_on_connect)
	bar.add_child(connect_btn)
	status_label = Ui.label("нет связи", 0, Color(0.7, 0.75, 0.85))
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


### --- ambient particles ---------------------------------------------------

# A soft round dot texture for the light motes (radial white -> transparent).
func _soft_dot() -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 1.0)
	t.width = 96
	t.height = 96
	return t


# Slow drifting motes of cool light across the whole board (ambient atmosphere).
# Window resized (e.g. maximize): refit the ambient motes and rebuild the board,
# since the hand fan and board-row overlap are sized from the window width and
# would otherwise stay stale (cards clumped or overflowing) until the next view.
func _on_window_resized() -> void:
	_fit_motes()
	# Don't rebuild mid-drag (it would free the dragged node) or before any view.
	if view.is_empty() or UiCard.active_drag != null:
		return
	_rebuild()


# Resize the mote cloud to the current window so it covers the whole board
# (including the right mana column) after a maximize/resize.
func _fit_motes() -> void:
	if _motes == null:
		return
	var vp := get_viewport_rect().size
	_motes.position = vp * 0.5
	var mat: ParticleProcessMaterial = _motes.process_material
	mat.emission_box_extents = Vector3(vp.x * 0.55, vp.y * 0.6, 0)
	_motes.restart()  # re-seed across the new area so it fills immediately


func _ambient_motes() -> GPUParticles2D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(820, 520, 0)
	mat.direction = Vector3(0, -1, 0)
	mat.spread = 45.0
	mat.gravity = Vector3(0, -4, 0)
	mat.initial_velocity_min = 3.0
	mat.initial_velocity_max = 12.0
	mat.scale_min = 0.08
	mat.scale_max = 0.32
	# Fade in then out over each mote's life, tinted cool light.
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	ramp.colors = PackedColorArray([
		Color(0.7, 0.82, 1.0, 0.0), Color(0.78, 0.86, 1.0, 0.85),
		Color(0.82, 0.9, 1.0, 0.8), Color(0.82, 0.9, 1.0, 0.0)])
	var rtex := GradientTexture1D.new()
	rtex.gradient = ramp
	mat.color_ramp = rtex

	var p := GPUParticles2D.new()
	p.process_material = mat
	p.texture = _soft_dot()
	p.amount = 90
	p.lifetime = 8.0
	p.preprocess = 8.0          # start with the screen already populated
	return p                    # position/extents set by _fit_motes()


# A full-screen radial glow/vignette layer. `center`/`radius` are in UV (0..1);
# the gradient runs `inner` (at the center) -> `outer` (at the radius).
func _glow_layer(center: Vector2, radius: float, inner: Color, outer: Color) -> TextureRect:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([inner, outer])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = center
	tex.fill_to = center + Vector2(0.0, radius)
	var tr := TextureRect.new()
	tr.texture = tex
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


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
			status_label.text = "на связи"
		while socket.get_available_packet_count() > 0:
			var txt := socket.get_packet().get_string_from_utf8()
			var data: Variant = JSON.parse_string(txt)
			if typeof(data) == TYPE_DICTIONARY:
				_ingest_view(data)
	elif st == WebSocketPeer.STATE_CLOSED and was_open:
		was_open = false
		status_label.text = "соединение закрыто"
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
	# A new view means the board changed: an open mana picker would point at a
	# now-stale index, so drop it.
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
# Attack helpers: record the target's on-screen position and the attacker, then
# send. _animate_changes plays the lunge on the (rebuilt) attacker node.
func _attack_creature(attacker_id: int, target_cid: int) -> void:
	_pending_lunge = {"attacker": attacker_id, "pos": _node_center(_card_nodes.get(target_cid))}
	_send({"action": "attackCreature", "attacker": attacker_id, "target": target_cid})


func _attack_hero(attacker_id: int) -> void:
	# Lunge straight up toward the enemy side (not sideways at the flank medallion).
	var ac := _node_center(_card_nodes.get(attacker_id))
	_pending_lunge = {"attacker": attacker_id, "pos": Vector2(ac.x, 40.0)}
	_send({"action": "attackHero", "attacker": attacker_id})


func _node_center(n) -> Vector2:
	if n != null and is_instance_valid(n):
		return n.global_position + n.size * 0.5
	return Vector2(get_viewport_rect().size.x * 0.5, 70.0)  # fallback: enemy side


# A quick lunge of `node` toward `target_pos` and back -- the attack hit.
func _lunge(node: Control, target_pos: Vector2) -> void:
	var start := node.position
	var dir := target_pos - (node.global_position + node.size * 0.5)
	if dir.length() < 1.0:
		return
	dir = dir.normalized()
	node.z_index = 15
	var t := create_tween()
	t.tween_property(node, "position", start + dir * 32.0, 0.09) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "position", start, 0.15) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_callback(_reset_z.bind(node))


func _reset_z(node: Control) -> void:
	if is_instance_valid(node):
		node.z_index = 0


# A soft, slowly pulsing gold ring under a ready-to-attack creature: a clear
# "this can act" signal. Drawn behind the card face so it reads as a halo.
func _attach_ready_pulse(card: Control) -> void:
	var ring := Panel.new()
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring.offset_left = -3
	ring.offset_top = -3
	ring.offset_right = 3
	ring.offset_bottom = 3
	ring.show_behind_parent = true
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	var gold := Color(0.98, 0.85, 0.4)
	sb.border_color = gold
	sb.shadow_size = 12
	sb.shadow_color = Color(gold.r, gold.g, gold.b, 0.55)
	ring.add_theme_stylebox_override("panel", sb)
	card.add_child(ring)
	var t := create_tween()
	t.set_loops()
	t.tween_property(ring, "modulate:a", 0.35, 0.8).set_trans(Tween.TRANS_SINE)
	t.tween_property(ring, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE)


func _animate_changes(dmg: Dictionary, summoned: Dictionary) -> void:
	await get_tree().process_frame
	if not _pending_lunge.is_empty():
		var aid := int(_pending_lunge["attacker"])
		if _card_nodes.has(aid) and is_instance_valid(_card_nodes[aid]):
			_lunge(_card_nodes[aid], _pending_lunge["pos"])
		_pending_lunge = {}
	for id in summoned:
		if _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			_pop_in(_card_nodes[id])
	var total := 0
	for id in dmg:
		if _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			var nd: Control = _card_nodes[id]
			_flash_card(nd)
			_spawn_float_number(
				nd.global_position + Vector2(nd.size.x * 0.5, nd.size.y * 0.18), int(dmg[id]))
		total += int(dmg[id])
	if total > 0:
		_shake(minf(4.0 + total * 1.7, 16.0))  # impact scales with the hit


# Brief positional screen shake (impact feedback). Decays over a few quick steps
# and always returns to rest.
func _shake(intensity: float) -> void:
	var steps := 5
	var t := create_tween()
	for i in steps:
		var amp := intensity * (1.0 - float(i) / steps)
		t.tween_property(self, "position",
			Vector2(randf_range(-amp, amp), randf_range(-amp, amp)), 0.035)
	t.tween_property(self, "position", Vector2.ZERO, 0.05)


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


# --- view queries ------------------------------------------------------------

# Generated tokens are numbered per size (e.g. germinate's "token_sprout2"); fall
# back to the base family ("token_sprout") so they share its name and art.
func _display_id(id: String) -> String:
	if cards.has(id):
		return id
	var base := id.rstrip("0123456789")
	if base != "" and base != id and cards.has(base):
		return base
	return id


func _def(id: String) -> Dictionary:
	return cards.get(_display_id(id), {})


func _name_of(card_id: String) -> String:
	var d := _def(card_id)
	if d.has("name"):
		return d["name"].get("ru", card_id)
	return card_id


func _text_of(card_id: String) -> String:
	if cards.has(card_id) and cards[card_id].has("text"):
		return cards[card_id]["text"].get("ru", "")
	return ""


func _my_turn() -> bool:
	if bool(view.get("over", false)):
		return false  # the game is decided -- no actions
	return int(view.get("current", -1)) == int(view.get("you", -2))


# You may bank exactly one card to mana per turn (engine: placedManaThisTurn).
func _can_place_mana() -> bool:
	if not _my_turn():
		return false
	var you := int(view.get("you", -1))
	if you < 0:
		return false
	return not bool(view["players"][you].get("placedMana", false))


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


# Affordable if one available crystal may be retuned to a spectrum-adjacent
# color (Prism spectral_shift). Mirrors the engine's shiftedPool check.
func _can_afford_with_shift(cost: Dictionary, avail: Dictionary) -> bool:
	var colors := ["red", "yellow", "green", "blue", "violet"]
	for xi in range(5):
		for yi in range(5):
			if absi(xi - yi) != 1:
				continue
			if int(avail.get(colors[yi], 0)) < 1:
				continue
			var swapped := avail.duplicate()
			swapped[colors[yi]] = int(swapped.get(colors[yi], 0)) - 1
			swapped[colors[xi]] = int(swapped.get(colors[xi], 0)) + 1
			if _can_afford(cost, swapped):
				return true
	return false


# Does this player's hero carry the given passive keyword?
func _hero_has(p: Dictionary, passive_id: String) -> bool:
	for kw in p.get("hero", {}).get("passive", []):
		if String(kw.get("id", "")) == passive_id:
			return true
	return false


# Playable right now: my turn, affordable, and (for creatures) the board has room.
func _is_playable(card_id: String) -> bool:
	if not _my_turn():
		return false
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var cost: Dictionary = cards.get(card_id, {}).get("cost", {})
	var avail: Dictionary = me["mana"].get("available", {})
	# Prism spectral_shift can pay a foreign pip with a spectrum-neighbour crystal,
	# once per turn -- so a card unaffordable normally may still be playable.
	var shift_ready: bool = _hero_has(me, "spectral_shift") and not bool(me.get("shiftUsed", false))
	if not _can_afford(cost, avail) and not (shift_ready and _can_afford_with_shift(cost, avail)):
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
	# Each half is a band: [hero medallion | board (center) | piles]. Heroes get
	# real presence on the flank; the deck/graveyard/mana live as the right column.
	root_box.add_child(_player_half(opp, false))
	root_box.add_child(_separator())
	root_box.add_child(_player_half(me, true))
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
	# Just a small gap between the two armies (no decorative line -- the lane
	# borders and the side accents already separate the sides).
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


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
	var txt := ""
	var col := Color(0.6, 0.62, 0.72)
	if bool(view.get("over", false)):
		var win := int(view.get("winner", -1)) == you
		txt = "ПОБЕДА" if win else "ПОРАЖЕНИЕ"
		col = Color(0.5, 0.95, 0.6) if win else Color(0.95, 0.45, 0.45)
	elif bool(view.get("mulligan", false)):
		txt = "МУЛИГАН"
		col = Color(0.45, 0.85, 1.0)
	else:
		var mine := _my_turn()
		txt = ("ВАШ ХОД" if mine else "ХОД СОПЕРНИКА") + "    ход %d" % int(view.get("turn", 0))
		col = ME_ACCENT.lightened(0.12) if mine else ENEMY_ACCENT.lightened(0.05)

	# A centered header pill that glows in the active side's colour, with a small
	# diamond on each side -- reads as a banner, not a bare line of text.
	var pill := PanelContainer.new()
	var sb := Ui.glass(col, 0.26)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	pill.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(_banner_diamond(col))
	row.add_child(Ui.label(txt, 17, col.lightened(0.45), true))
	row.add_child(_banner_diamond(col))
	pill.add_child(row)

	var center := HBoxContainer.new()
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(pill)
	return center


func _banner_diamond(col: Color) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(10, 16)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dia := Panel.new()
	var ds := StyleBoxFlat.new()
	ds.bg_color = col.lightened(0.3)
	ds.set_corner_radius_all(2)
	dia.add_theme_stylebox_override("panel", ds)
	dia.size = Vector2(8, 8)
	dia.position = Vector2(1, 4)
	dia.pivot_offset = Vector2(4, 4)
	dia.rotation = deg_to_rad(45)
	dia.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(dia)
	return holder


# --- hero strips -------------------------------------------------------------

const ENEMY_ACCENT := Color(0.92, 0.36, 0.42)
const ME_ACCENT := Color(0.34, 0.62, 0.98)


# One player's band: [hero medallion | board (center, expands) | piles column].
func _player_half(p: Dictionary, mine: bool) -> Control:
	var half := HBoxContainer.new()
	half.add_theme_constant_override("separation", 10)
	half.size_flags_vertical = Control.SIZE_EXPAND_FILL
	half.add_child(_hero_medallion(p.get("hero", {}), mine))
	var board := _board_row(p.get("board", []), p.get("auras", []), mine)
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	half.add_child(board)
	half.add_child(_piles_column(p, mine))
	return half


# The hero as a big framed portrait with HP/armor gems and the passive badge.
# The enemy medallion doubles as the face-attack drop target.
func _hero_medallion(hero: Dictionary, mine: bool) -> Control:
	var accent := ME_ACCENT if mine else ENEMY_ACCENT
	var card := UiCard.new()
	card.custom_minimum_size = Vector2(158, 0)
	card.size_flags_vertical = Control.SIZE_FILL
	card.add_theme_stylebox_override("panel", Ui.glass(accent, 0.4))
	if not mine:
		_enemy_hero_node = card  # lunge target for face attacks
		# Attack the face: blocked by a provoker unless the attacker has Bypass.
		card.can_drop_fn = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY or data.get("kind", "") != "attacker":
				return false
			return not _enemy_has_provoke() or bool(data.get("bypass", false))
		card.drop_fn = func(data: Variant) -> void:
			_attack_hero(int(data["id"]))

	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 5)
	var tag := Ui.label("ВЫ" if mine else "СОПЕРНИК", 11, accent.lightened(0.35), true)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(tag)
	v.add_child(_hero_portrait_with_hp(hero, 124))
	var nm := Ui.label(String(hero.get("name", "Герой")), 17, null, true)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nm)
	var badge := _hero_passive_badge(hero)
	if badge != null:
		var brow := HBoxContainer.new()
		brow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		brow.alignment = BoxContainer.ALIGNMENT_CENTER
		brow.add_child(badge)
		v.add_child(brow)
	card.add_child(v)
	return card


# Square portrait with the HP gem overhanging the bottom-right (armor bottom-left).
func _hero_portrait_with_hp(hero: Dictionary, px: float) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(px, px)
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var portrait := _hero_portrait(String(hero.get("card", "")), px)
	portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(portrait)
	var hp := _stat_gem(str(int(hero.get("hp", 0))), Color(0.95, 0.42, 0.46), 44)
	hp.position = Vector2(px - 40, px - 40)
	holder.add_child(hp)
	if int(hero.get("armor", 0)) > 0:
		var ar := _stat_gem(str(int(hero["armor"])), Color(0.72, 0.82, 0.98), 34)
		ar.position = Vector2(-6, px - 30)
		holder.add_child(ar)
	return holder


# A round stat gem (HP / armor) sized to `d`, drawn at an absolute position.
func _stat_gem(text: String, ring: Color, d: float) -> Control:
	var g := Panel.new()
	g.custom_minimum_size = Vector2(d, d)
	g.size = Vector2(d, d)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.96)
	sb.set_corner_radius_all(int(d / 2.0))
	sb.set_border_width_all(2)
	sb.border_color = ring
	sb.shadow_size = 6
	sb.shadow_color = Color(ring.r, ring.g, ring.b, 0.5)
	g.add_theme_stylebox_override("panel", sb)
	var l := Ui.label(text, int(d * 0.42), ring.lightened(0.45), true)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_child(l)
	return g


# Right flank: mana, the banked-card peek, deck/graveyard stacks, counts, top card.
func _piles_column(p: Dictionary, mine: bool) -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(142, 0)
	col.size_flags_vertical = Control.SIZE_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_mana_block(p.get("mana", {})))
	var mr := _manarow_view(p.get("manaRow", []), mine)
	if mr != null:
		col.add_child(mr)
	var piles := HBoxContainer.new()
	piles.alignment = BoxContainer.ALIGNMENT_CENTER
	piles.add_theme_constant_override("separation", 12)
	piles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	piles.add_child(_pile_stack(int(p.get("deckCount", 0)), "колода", Color(0.5, 0.7, 0.95)))
	piles.add_child(_pile_stack(int(p.get("graveyardCount", 0)), "сброс", Color(0.62, 0.6, 0.68)))
	col.add_child(piles)
	var il := Ui.label("рука %d" % int(p.get("handCount", 0)), 11, Color(0.6, 0.64, 0.74), true)
	il.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(il)
	# Lens clairvoyance: your revealed top card sits by your deck.
	if mine and p.has("topCard"):
		col.add_child(_topcard_chip(String(p["topCard"])))
	return col


func _mana_block(mana: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	var tag := Ui.label("МАНА", 10, Color(0.62, 0.66, 0.78), true)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(tag)
	box.add_child(_mana_pips(mana))
	return box


# Mana crystals, grouped by color, wrapping within the flank column width.
func _mana_pips(mana: Dictionary) -> Control:
	var flow := HFlowContainer.new()
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 3)
	flow.custom_minimum_size = Vector2(134, 0)
	var avail: Dictionary = mana.get("available", {})
	var total: Dictionary = mana.get("crystals", {})
	var any := false
	for color in ["red", "yellow", "green", "blue", "violet", "colorless"]:
		var t := int(total.get(color, 0))
		var av := int(avail.get(color, 0))
		# Show permanent crystals plus any temporary mana on top (available beyond
		# the permanent stock -- e.g. photosynthesis ramp), so bonus mana is visible.
		var count := maxi(t, av)
		if count <= 0:
			continue
		any = true
		var group := HBoxContainer.new()
		group.mouse_filter = Control.MOUSE_FILTER_IGNORE
		group.add_theme_constant_override("separation", 2)
		for i in count:
			group.add_child(Ui.mana_pip(color, i < av, i >= t))
		flow.add_child(group)
	if not any:
		var l := Ui.label("нет маны", 11, Color(0.5, 0.53, 0.62))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		flow.add_child(l)
	return flow


# A deck/graveyard pile: up to three offset card-backs with the count on top.
func _pile_stack(count: int, label: String, accent: Color) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	var stack := Control.new()
	stack.custom_minimum_size = Vector2(46, 56)
	stack.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var depth := maxi(clampi(count, 0, 3), 1)
	var w := 36.0
	var h := 48.0
	for i in range(depth):
		var back := Panel.new()
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		back.size = Vector2(w, h)
		back.position = Vector2(i * 3, (depth - 1 - i) * 3)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.11, 0.13, 0.18, 0.96) if count > 0 else Color(0.10, 0.11, 0.14, 0.65)
		sb.set_corner_radius_all(6)
		sb.set_border_width_all(2)
		sb.border_color = accent if i == depth - 1 else accent.darkened(0.35)
		back.add_theme_stylebox_override("panel", sb)
		stack.add_child(back)
	var cl := Ui.label(str(count), 18, accent.lightened(0.45), true)
	cl.size = Vector2(w, h)
	cl.position = Vector2((depth - 1) * 3, 0)
	cl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(cl)
	box.add_child(stack)
	var ll := Ui.label(label, 10, Color(0.6, 0.64, 0.74), true)
	ll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ll)
	return box


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
	# Art-only square tile (name + rules on hover) so it never wraps/overflows.
	var col := Palette.primary(_def(card_id))
	var tile := UiCard.new()
	tile.custom_minimum_size = Vector2(58, 58)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.15, 0.92)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2)
	sb.border_color = col
	sb.shadow_size = 8
	sb.shadow_color = Color(col.r, col.g, col.b, 0.5)
	sb.set_content_margin_all(3)
	tile.add_theme_stylebox_override("panel", sb)
	tile.tooltip_text = _name_of(card_id)
	tile.tooltip_builder = func() -> Control: return _build_tooltip(card_id, null)
	tile.hoverable = true
	tile.add_child(_art_thumb(card_id, col, 50))
	return tile


# A square art thumbnail for a card, or a tinted placeholder if the art is
# missing. Shared by the aura shelf and the awaken chips.
func _art_thumb(card_id: String, fallback: Color, px: float) -> Control:
	var path := "res://art/%s.png" % _display_id(card_id)
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


const HERO_ACCENT := Color(0.8, 0.72, 0.98)  # heroes are off-color (light violet)


# A large framed hero portrait (rounded, bordered, clipped). Falls back to a
# tinted placeholder until art/<heroId>.png exists (see ART_HEROES.md).
func _hero_portrait(card_id: String, px: float) -> Control:
	var holder := Panel.new()
	holder.custom_minimum_size = Vector2(px, px)
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.15)
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(2)
	sb.border_color = HERO_ACCENT
	sb.shadow_size = 8
	sb.shadow_color = Color(HERO_ACCENT.r, HERO_ACCENT.g, HERO_ACCENT.b, 0.45)
	holder.add_theme_stylebox_override("panel", sb)
	holder.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var art := _art_thumb(card_id, HERO_ACCENT, px)
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(art)
	holder.tooltip_text = _name_of(card_id)
	return holder


# Maps a hero's passive keyword to its tinted icon (icons/<name>.svg).
func _passive_icon(id: String) -> String:
	match id:
		"spectral_shift": return "prism"
		"umbra": return "eclipse"
		"clairvoyance": return "lens"
	return "eye"


# A round badge for the hero's passive: its icon, with a styled hover tooltip.
func _hero_passive_badge(hero: Dictionary) -> Control:
	var passive: Array = hero.get("passive", [])
	if passive.is_empty():
		return null
	var kw: Dictionary = passive[0]
	var badge := UiCard.new()
	badge.custom_minimum_size = Vector2(30, 30)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	badge.add_theme_stylebox_override("panel", _round_style(HERO_ACCENT, false))
	badge.add_child(Ui.icon(_passive_icon(String(kw.get("id", ""))), 18, HERO_ACCENT.lightened(0.4)))
	badge.tooltip_text = Glossary.keyword_name(kw)
	badge.tooltip_builder = func() -> Control: return _hero_passive_tooltip(hero)
	return badge


func _hero_passive_tooltip(hero: Dictionary) -> Control:
	var passive: Array = hero.get("passive", [])
	var kw: Dictionary = passive[0] if not passive.is_empty() else {}
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.10, 0.11, 0.15, 0.98), 10, 2, HERO_ACCENT, 11))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.custom_minimum_size = Vector2(240, 0)
	panel.add_child(v)
	v.add_child(Ui.label(String(hero.get("name", "Герой")), 16, HERO_ACCENT.lightened(0.4)))
	v.add_child(Ui.label("Сила героя · пассив", 11, Color(0.6, 0.64, 0.74)))
	v.add_child(HSeparator.new())
	# The passive: its icon and bold name, then the plain-language explanation.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(Ui.icon(_passive_icon(String(kw.get("id", ""))), 20, HERO_ACCENT.lightened(0.3)))
	head.add_child(Ui.label(Glossary.keyword_name(kw), 15, HERO_ACCENT.lightened(0.3)))
	v.add_child(head)
	var full := Glossary.keyword(kw)
	var ci := full.find(":")
	v.add_child(_rich(full.substr(ci + 1).strip_edges() if ci > 0 else full,
		13, Color(0.82, 0.86, 0.92)))
	# Flavor (the artist's words), if any.
	var flavor := _text_of(String(hero.get("card", "")))
	if flavor != "":
		v.add_child(HSeparator.new())
		var fl := Ui.label(flavor, 12, Color(0.62, 0.6, 0.72))
		fl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fl.custom_minimum_size = Vector2(240, 0)
		v.add_child(fl)
	return panel


# Lens clairvoyance: a small chip showing the revealed top card of your deck.
func _topcard_chip(card_id: String) -> Control:
	var col := Palette.primary(_def(card_id))
	var tile := UiCard.new()
	tile.custom_minimum_size = Vector2(0, 44)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.15, 0.92)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = HERO_ACCENT
	sb.set_content_margin_all(4)
	tile.add_theme_stylebox_override("panel", sb)
	tile.tooltip_text = _name_of(card_id)
	tile.tooltip_builder = func() -> Control: return _build_tooltip(card_id, null)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 5)
	row.add_child(Ui.icon("lens", 14, HERO_ACCENT))
	row.add_child(_art_thumb(card_id, col, 34))
	var nl := Ui.label(_name_of(card_id), 11)
	nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	nl.custom_minimum_size = Vector2(72, 0)
	row.add_child(nl)
	tile.add_child(row)
	return tile


# --- mana row (face-down backs + peekable awaken cards) ----------------------

# The banked cards themselves are just hidden mana -- their count already shows
# as crystals -- so we only surface your own awaken-able cards here.
func _manarow_view(mana_row: Array, mine: bool) -> Control:
	# Your awaken cards, or (under floodlight) every enemy banked card. Returns
	# null when there is nothing to show. The list is height-capped and scrolls,
	# so a full mana row never grows the column and pushes the other board away.
	var slots := []
	for i in mana_row.size():
		var slot: Dictionary = mana_row[i]
		if slot.has("card"):
			slots.append({"i": int(i), "slot": slot})
	if slots.is_empty():
		return null

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 3)
	var tag := Ui.label("разбудить:" if mine else "прожектор:", 11, Color(0.95, 0.85, 0.4), true)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(tag)

	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sc.mouse_filter = Control.MOUSE_FILTER_PASS
	var cap_h := 0.0
	if mine:
		# Your awaken cards stay full interactive chips (usually few); cap ~2 tall.
		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 3)
		for c in slots:
			inner.add_child(_awaken_chip(int(c["i"]), c["slot"]))
		sc.add_child(inner)
		cap_h = mini(slots.size(), 2) * 57.0
	else:
		# Floodlight can reveal many crystals -> compact art thumbnails that wrap.
		var flow := HFlowContainer.new()
		flow.custom_minimum_size = Vector2(136, 0)
		flow.add_theme_constant_override("h_separation", 3)
		flow.add_theme_constant_override("v_separation", 3)
		for c in slots:
			var s: Dictionary = c["slot"]
			flow.add_child(_revealed_thumb(String(s["card"]), String(s.get("color", "colorless"))))
		sc.add_child(flow)
		var rows := (slots.size() + 2) / 3  # 3 thumbnails per row
		cap_h = mini(rows, 2) * 39.0  # show up to 2 rows, scroll the rest
	sc.custom_minimum_size = Vector2(138, cap_h)
	box.add_child(sc)
	return box


# A compact peek thumbnail (floodlight): art only, with the full hover tooltip.
func _revealed_thumb(card_id: String, color: String) -> Control:
	var t := UiCard.new()
	t.custom_minimum_size = Vector2(36, 36)
	t.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.09, 0.10, 0.15, 0.92), 6, 1, Color(0.7, 0.62, 0.32), 2))
	t.tooltip_text = _name_of(card_id)
	t.tooltip_builder = func() -> Control: return _build_tooltip(card_id, null)
	t.hoverable = true
	t.add_child(_art_thumb(card_id, Palette.color_for(color), 30))
	return t


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
	chip.custom_minimum_size = Vector2(132, 54)
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

	# Art + a short status tag only (the name shows on hover) -- no wrapping text.
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(_art_thumb(card_id, Palette.color_for(color), 42))
	var tag_txt := "бесплатно!" if free else "разбудить"
	var tag := Ui.label(tag_txt, 11, gold if affordable else gold.darkened(0.25))
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tag)
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
	# Creatures overlap (like the hand fan) when too many to lay out side by side,
	# so a full board never runs off the right edge. Account for both flanks.
	var n := board.size()
	var sep := 6
	if n > 1:
		var avail := size.x - 158 - 142 - 60  # medallion + piles + separations/margins
		if not auras.is_empty():
			avail -= 150
		var needed := n * CARD_SIZE.x + (n - 1) * 6
		if float(needed) > avail:
			sep = int((avail - n * CARD_SIZE.x) / float(n - 1))
			sep = maxi(sep, -int(CARD_SIZE.x * 0.6))
	row.add_theme_constant_override("separation", sep)
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
		# On your turn, dim creatures that cannot attack so the ready ones glow.
		if _my_turn() and not can_attack:
			card.modulate = Color(0.6, 0.62, 0.7, 0.92)
			card.rest_modulate = Color(0.6, 0.62, 0.7, 0.92)
		elif can_attack:
			_attach_ready_pulse(card)
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
				_attack_creature(int(data["id"]), cid)
			else:
				_play_payload(data, cid)

	# Activated abilities (e.g. germinate): round icon buttons centered along the
	# bottom edge, in the same row as the ATK/HP gems -- a separate control from
	# the attack drag, so several abilities can sit side by side. Added to the
	# face (a Panel that respects anchors), not the card (a Container that would
	# stretch it over the whole art).
	if mine:
		var dock := _ability_dock(cr, cid)
		if dock != null:
			card.get_child(0).add_child(dock)

	_card_nodes[cid] = card
	return card


# An activated-ability keyword -> its dock icon and accent (empty = not one).
func _ability_meta(kid: String) -> Dictionary:
	match kid:
		"germinate":
			return {"icon": "leaf", "accent": Color(0.38, 0.82, 0.46)}
	return {}


func _ability_dock(cr: Dictionary, cid: int) -> Control:
	var dock := HBoxContainer.new()
	dock.add_theme_constant_override("separation", 4)
	dock.alignment = BoxContainer.ALIGNMENT_CENTER
	dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for kw in _def(String(cr["card"])).get("keywords", []):
		if not _ability_meta(String(kw.get("id", ""))).is_empty():
			dock.add_child(_ability_button(cr, cid, String(kw["id"])))
	if dock.get_child_count() == 0:
		return null
	# Full-width strip pinned to the bottom; centered so the buttons sit between
	# the corner stat gems.
	dock.anchor_left = 0
	dock.anchor_right = 1
	dock.anchor_top = 1
	dock.anchor_bottom = 1
	dock.offset_top = -GEM - PAD
	dock.offset_bottom = -PAD
	return dock


func _ability_button(cr: Dictionary, cid: int, kid: String) -> Button:
	var meta := _ability_meta(kid)
	var acc: Color = meta["accent"]
	var used := bool(cr.get("usedActive", false))
	var ready := _can_ability(cr, kid)
	var b := AbilityButton.new()
	b.custom_minimum_size = Vector2(30, 30)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # stay a 30px circle
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.focus_mode = Control.FOCUS_NONE
	b.icon = load("res://icons/%s.svg" % meta["icon"])
	b.expand_icon = true
	b.disabled = not ready
	# Frame: bright accent when ready, faded accent once spent, neutral grey when
	# simply unaffordable. Always a clean round frame -- never bare.
	var frame_col := acc if ready else (acc.darkened(0.4) if used else Color(0.42, 0.44, 0.52))
	var icon_col := acc.lightened(0.55) if ready else Color(0.55, 0.57, 0.64)
	b.add_theme_color_override("icon_normal_color", icon_col)
	b.add_theme_color_override("icon_hover_color", Color.WHITE)
	b.add_theme_color_override("icon_disabled_color", icon_col)
	b.add_theme_stylebox_override("normal", _round_style(frame_col, ready))
	b.add_theme_stylebox_override("hover", _round_style(frame_col.lightened(0.25), ready))
	b.add_theme_stylebox_override("pressed", _round_style(frame_col, true))
	b.add_theme_stylebox_override("disabled", _round_style(frame_col, false))
	# Styled hover panel (a non-empty tooltip_text is still required to trigger).
	b.tooltip_text = Glossary.keyword_name({"id": kid, "n": _keyword_n(String(cr["card"]), kid)})
	b.tooltip_builder = func() -> Control: return _ability_tooltip_panel(cr, kid, used)
	b.pressed.connect(func() -> void:
		_send({"action": "activate", "id": cid}))
	return b


func _round_style(border: Color, glow: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.11, 0.96)
	sb.set_corner_radius_all(15)  # half of 30 -> a circle
	sb.set_border_width_all(2)
	sb.border_color = border
	sb.set_content_margin_all(5)
	if glow:
		sb.shadow_size = 8
		sb.shadow_color = Color(border.r, border.g, border.b, 0.6)
	return sb


func _can_ability(cr: Dictionary, kid: String) -> bool:
	return _ability_reason(cr, kid) == ""


# Why this ability can't be used right now (specific), or "" if it can.
func _ability_reason(cr: Dictionary, kid: String) -> String:
	if not _my_turn():
		return "Не ваш ход."
	if bool(cr.get("usedActive", false)):
		return "Уже использовано в этом ходу."
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	match kid:
		"germinate":
			if int(me.get("board", []).size()) >= BOARD_LIMIT:
				return "Стол заполнен (%d существ)." % BOARD_LIMIT
			var avail: Dictionary = me["mana"].get("available", {})
			var total := 0
			for c in ["red", "yellow", "green", "blue", "violet", "colorless"]:
				total += int(avail.get(c, 0))
			if total < 1:
				return "Нет свободного кристалла (нужен 1)."
	return ""


func _ability_tooltip_panel(cr: Dictionary, kid: String, used: bool) -> Control:
	var meta := _ability_meta(kid)
	var acc: Color = meta["accent"]
	var kw := {"id": kid, "n": _keyword_n(String(cr["card"]), kid)}

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.10, 0.11, 0.15, 0.98), 10, 2, acc, 11))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.custom_minimum_size = Vector2(230, 0)
	panel.add_child(v)

	# Header: the ability icon + its name.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(Ui.icon(meta["icon"], 22, acc.lightened(0.4)))
	head.add_child(Ui.label(Glossary.keyword_name(kw), 16, acc.lightened(0.4)))
	v.add_child(head)

	# Description: the keyword's explanation (without the leading name).
	var full := Glossary.keyword(kw)
	var ci := full.find(":")
	v.add_child(_rich(full.substr(ci + 1).strip_edges() if ci > 0 else full,
		13, Color(0.82, 0.86, 0.92)))

	# State line: the specific reason it's unavailable, or a ready prompt.
	var reason := _ability_reason(cr, kid)
	if reason == "":
		v.add_child(Ui.label("Готово к использованию.", 12, acc.lightened(0.3)))
	else:
		var col := Color(0.95, 0.6, 0.5) if used else Color(0.78, 0.8, 0.88)
		v.add_child(Ui.label(reason, 12, col))
	return panel


# --- hand --------------------------------------------------------------------

func _hand_row(hand: Array) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	# Cards overlap (fan) when there are too many to lay out side by side.
	var cards_box := HBoxContainer.new()
	var n := hand.size()
	var sep := 8
	if n > 1:
		var avail := size.x - 40 - 48  # window margins + padding
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
		card.double_clicked.connect(func(_p: Dictionary) -> void: _on_hand_double(idx, cid))
		cards_box.add_child(card)
	box.add_child(cards_box)
	return box


# --- card visual -------------------------------------------------------------

func _make_card(def_id: String, runtime) -> UiCard:
	# Minimal card face: art + cost/atk/hp gems + a color frame. Name, rules
	# text and keywords live in the hover tooltip, not on the face.
	var card := UiCard.new()
	card.custom_minimum_size = CARD_SIZE
	# Neon glow in the card's own color (drawn by the card panel, behind the
	# rounded face, so it is not clipped).
	var col := Palette.primary(_def(def_id))
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
	var d: Dictionary = _def(def_id)
	var col := Palette.primary(d)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.10, 0.11, 0.15, 0.98), 10, 2, col, 11))

	# Compact text-only card info on hover (name, cost, type, generated rules,
	# flavor, live statuses). Godot anchors and clamps it to the viewport.
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

	# Rules are generated from the card's data (single source of truth). The bold
	# "headline" is the card's printed text: keyword names plus the on_play
	# effects, prefixed by a bold, precise "when" -- "При выходе:" for a creature,
	# or "Через N ход(ов):" when delay folds the timing in. Below it, each keyword
	# gets a full plain-language explanation.
	var is_creature := String(d.get("type", "")) == "creature"
	var delay_n := _keyword_n(def_id, "delay")
	var effs := []
	for e in d.get("effects", []):
		if String(e.get("trigger", "")) == "on_play":
			var s := Glossary.effect_text(e)
			if s != "":
				effs.append(s)
	# Delay is shown as the effect's timing, not as a separate keyword.
	var fold_delay := delay_n > 0 and not effs.is_empty()

	var head := ""
	for kw in d.get("keywords", []):
		if fold_delay and String(kw.get("id", "")) == "delay":
			continue
		var nm := Glossary.keyword_name(kw)
		if nm != "":
			head += "[b]%s[/b]. " % nm
	if not effs.is_empty():
		var joined: String = " ".join(effs)
		var when := ""
		if fold_delay:
			when = "[b]Через %d ход(ов):[/b] " % delay_n
		elif is_creature:
			when = "[b]При выходе:[/b] "
		head += when + joined
	head = head.strip_edges()
	if head != "":
		v.add_child(HSeparator.new())
		v.add_child(_rich(head, 14, Color(0.9, 0.92, 0.97)))

	# Detailed keyword explanations (the bold name, then its meaning).
	var details := []
	var shown := {}
	for kw in d.get("keywords", []):
		if fold_delay and String(kw.get("id", "")) == "delay":
			continue
		var full := Glossary.keyword(kw)
		if full == "":
			continue
		shown[String(kw.get("id", ""))] = true
		var ci := full.find(":")
		details.append("[b]%s[/b]%s" % [full.substr(0, ci), full.substr(ci)] if ci > 0 else full)
	# Effects that apply a named status (freeze/blind/flash) explain that status
	# too, even when the card carries no matching keyword -- e.g. a spell that
	# just freezes still tells you what "заморожен" means.
	for e in d.get("effects", []):
		if String(e.get("trigger", "")) != "on_play":
			continue
		var act := String(e.get("action", ""))
		if act == "" or shown.has(act) or not Glossary.KW.has(act):
			continue
		shown[act] = true
		var fx: String = Glossary.keyword({"id": act, "n": int(e.get("value", 0))})
		var cix := fx.find(":")
		details.append("[b]%s[/b]%s" % [fx.substr(0, cix), fx.substr(cix)] if cix > 0 else fx)
	if not details.is_empty():
		for dline in details:
			v.add_child(_rich(dline, 12, Color(0.74, 0.8, 0.64)))

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


# A wrapping label that honours [b]bold[/b] BBCode, for the rules text.
func _rich(bb: String, size: int, color: Color) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.custom_minimum_size = Vector2(250, 0)
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	r.add_theme_color_override("default_color", color)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.text = bb
	return r


# Full card visual as a fixed-size Control with everything anchored to corners,
# so the size is constant regardless of contents (used for the card and the
# drag preview alike).
func _card_face(def_id: String, runtime) -> Control:
	var d: Dictionary = _def(def_id)
	var has_stats: bool = d.has("stats") or (typeof(runtime) == TYPE_DICTIONARY and runtime.has("atk"))
	var face := Panel.new()
	face.custom_minimum_size = CARD_SIZE
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Rounded dark body; clip_children rounds the art/rim to it. The panel itself
	# still draws normally, so the card's outer color glow (set in _make_card) shows.
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.05, 0.05, 0.08)
	body.set_corner_radius_all(12)
	face.add_theme_stylebox_override("panel", body)
	face.clip_children = CanvasItem.CLIP_CHILDREN_ONLY

	# Color rim: the gradient sits full-rect; the art is inset by RIM so the
	# gradient only shows as a thin glowing edge (the card's color identity).
	var frame := TextureRect.new()
	frame.texture = _frame_texture(d)
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(frame)

	# Art fills the whole card (full-bleed, minus the thin rim).
	var art := _art_full(def_id)
	_anchor_inset(art, RIM)
	face.add_child(art)

	# State tints over the art -- pure overlays, they never change the layout.
	if typeof(runtime) == TYPE_DICTIONARY and int(runtime.get("frozen", 0)) > 0:
		var ice := ColorRect.new()
		ice.color = Color(0.45, 0.72, 1.0, 0.30)
		ice.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_anchor_inset(ice, RIM)
		face.add_child(ice)
	if typeof(runtime) == TYPE_DICTIONARY and bool(runtime.get("sick", false)):
		var sleep := ColorRect.new()
		sleep.color = Color(0.05, 0.07, 0.18, 0.46)
		sleep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_anchor_inset(sleep, RIM)
		face.add_child(sleep)

	# Legibility scrims: a soft dark fade at the top (under cost/status) and
	# bottom (under the stat gems) so chrome reads over any bright art. The card
	# name is intentionally NOT drawn on the face -- it shows on hover (tooltip /
	# zoom) where long names have room, so the face never risks clipped text.
	face.add_child(_scrim(true, GEM + PAD))
	face.add_child(_scrim(false, GEM + PAD))

	# Cost badge (top-left): generic number plus one colored pip per colored pip.
	var cost_badge := _cost_badge(d.get("cost", {}))
	cost_badge.anchor_left = 0
	cost_badge.anchor_top = 0
	cost_badge.anchor_right = 0
	cost_badge.anchor_bottom = 0
	cost_badge.offset_left = PAD
	cost_badge.offset_top = PAD
	cost_badge.offset_right = PAD
	cost_badge.offset_bottom = PAD
	cost_badge.grow_horizontal = Control.GROW_DIRECTION_END
	cost_badge.grow_vertical = Control.GROW_DIRECTION_END
	face.add_child(cost_badge)

	# Stat gems (bottom corners) for creatures.
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
		_anchor_corner(atk_gem, 0, 1, PAD, -GEM - PAD)
		face.add_child(atk_gem)
		var hp_color := Color(0.55, 0.95, 0.5) if hp >= max_hp else Color(0.97, 0.4, 0.4)
		var hp_gem := _gem(str(hp), hp_color)
		_anchor_corner(hp_gem, 1, 1, -GEM - PAD, -GEM - PAD)
		face.add_child(hp_gem)

	# Status icons (top-right), right-aligned and growing left, capped with +N.
	if typeof(runtime) == TYPE_DICTIONARY:
		var status_row = _status_icons(runtime)
		if status_row != null:
			status_row.anchor_left = 1
			status_row.anchor_right = 1
			status_row.offset_left = -PAD
			status_row.offset_right = -PAD
			status_row.offset_top = PAD
			status_row.offset_bottom = PAD
			status_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			status_row.grow_vertical = Control.GROW_DIRECTION_END
			face.add_child(status_row)
	return face


# A vertical dark gradient used as a legibility scrim under the top/bottom chrome.
# `from_top` fades dark->clear downward; otherwise clear->dark toward the bottom.
func _scrim(from_top: bool, height: float) -> TextureRect:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	var dark := Color(0.0, 0.0, 0.0, 0.62)
	var clear := Color(0.0, 0.0, 0.0, 0.0)
	grad.colors = PackedColorArray([dark, clear]) if from_top else PackedColorArray([clear, dark])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0.5, 0.0)
	tex.fill_to = Vector2(0.5, 1.0)
	var tr := TextureRect.new()
	tr.texture = tex
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.anchor_left = 0
	tr.anchor_right = 1
	tr.offset_left = RIM
	tr.offset_right = -RIM
	if from_top:
		tr.anchor_top = 0
		tr.anchor_bottom = 0
		tr.offset_top = RIM
		tr.offset_bottom = RIM + height
	else:
		tr.anchor_top = 1
		tr.anchor_bottom = 1
		tr.offset_top = -RIM - height
		tr.offset_bottom = -RIM
	return tr


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
	var path := "res://art/%s.png" % _display_id(def_id)
	if ResourceLoader.exists(path):
		var tex := TextureRect.new()
		tex.texture = load(path)
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		return tex
	var ph := ColorRect.new()
	ph.color = Palette.primary(_def(def_id)).darkened(0.4)
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
	# Collect first, then render at most STATUS_MAX icons + a "+N" overflow chip,
	# so a heavily-statused creature never overflows the card edge.
	var specs := []
	if int(cr.get("frozen", 0)) > 0:
		specs.append(["snowflake", Color(0.6, 0.85, 1.0)])
	if bool(cr.get("shield", false)):
		specs.append(["shield", Color(0.97, 0.88, 0.4)])
	if bool(cr.get("ward", false)):
		specs.append(["halo", Color(0.72, 0.95, 1.0)])
	if bool(cr.get("stealth", false)):
		specs.append(["eye", Color(0.75, 0.55, 0.97)])
	if int(cr.get("blind", 0)) > 0:
		specs.append(["eye", Color(0.97, 0.5, 0.5)])
	if bool(cr.get("sick", false)):
		specs.append(["moon", Color(0.72, 0.77, 0.87)])
	if specs.is_empty():
		return null
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 3)
	var shown: int = mini(specs.size(), STATUS_MAX)
	for i in shown:
		row.add_child(Ui.icon(specs[i][0], 20, specs[i][1]))
	if specs.size() > STATUS_MAX:
		var more := Ui.label("+%d" % (specs.size() - STATUS_MAX), 13, Color(0.92, 0.94, 1.0))
		more.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(more)
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

func _zone_style(mine: bool) -> StyleBoxFlat:
	var accent := Color(0.3, 0.75, 0.6) if mine else Color(0.75, 0.35, 0.4)
	var sb := Ui.glass(accent, 0.22)
	sb.shadow_size = 0   # board zones stay calm; only cards/heroes glow
	return sb


# --- controls + hints --------------------------------------------------------

func _controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var end_btn := Ui.neon_button("Завершить ход", Color(1.0, 0.62, 0.3))
	end_btn.disabled = not _my_turn()
	end_btn.pressed.connect(func() -> void:
		_send({"action": "endTurn"}))
	row.add_child(end_btn)

	var hint := Ui.label("", 0, Color(0.62, 0.66, 0.78))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.text = "тащите карту на стол — разыграть · на цель — заклинание/атака · двойной тап — в ману"
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


# Play a creature onto your board at the slot the cursor dropped it.
func _play_at_drop(data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var pos := _drop_insert_index()
	if data.get("kind", "") == "awaken":
		_send({"action": "awaken", "manaRowIndex": int(data["manaRowIndex"]), "target": 0, "pos": pos})
	else:
		_send({"action": "play", "handIndex": int(data["index"]), "target": 0, "pos": pos})


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
	elif colors.size() == 1:
		_send({"action": "placeMana", "handIndex": idx, "color": String(colors[0])})
	else:
		# Multicolor card: let the player choose which crystal it becomes.
		_show_color_picker(idx, colors)


func _show_color_picker(idx: int, colors: Array) -> void:
	# In-scene chooser: a dim full-screen backdrop (click to cancel) with a radial
	# color wheel near the cursor -- one sector per color, fixed footprint for any
	# number of colors. The center hole cancels.
	_close_picker()
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	# Force it above everything (hovered cards lift to z_index 20).
	layer.z_as_relative = false
	layer.z_index = 4096
	var backdrop := Button.new()
	backdrop.flat = true
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.pressed.connect(_close_picker)
	layer.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(Color(0.6, 0.62, 0.8), 0.97))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(Ui.label("Каким кристаллом?", 13, null, true))
	var wheel := RadialPicker.new()
	var ids := PackedStringArray()
	for c in colors:
		ids.append(String(c))
	wheel.colors = ids
	wheel.picked.connect(func(cid: String) -> void:
		_send({"action": "placeMana", "handIndex": idx, "color": cid})
		_close_picker())
	wheel.cancelled.connect(_close_picker)
	vb.add_child(wheel)
	panel.add_child(vb)
	layer.add_child(panel)
	add_child(layer)

	var pos := get_global_mouse_position() - Vector2(110, 110)
	pos.x = clampf(pos.x, 8.0, size.x - 210.0)
	pos.y = clampf(pos.y, 8.0, size.y - 230.0)
	panel.position = pos
	_picker = layer


func _close_picker() -> void:
	if _picker != null:
		_picker.queue_free()
		_picker = null


# --- hand double-tap (bank to mana) -----------------------------------------

# Double-tap a hand card to bank it as mana (color picker for multicolor).
func _on_hand_double(idx: int, card_id: String) -> void:
	# Banking to mana is once per turn: if it's already spent (or not your turn),
	# do nothing -- don't pop the color picker for an action the server will reject.
	if not _can_place_mana():
		return
	_place_mana(idx, card_id)


# A non-targeted awaken (e.g. a creature) plays straight to your board on a
# single click. Targeted awaken cards are aimed by dragging the chip instead.
func _on_awaken_clicked(p: Dictionary) -> void:
	if not _my_turn():
		return
	if not bool(p.get("needs_target", false)):
		_send({"action": "awaken", "manaRowIndex": int(p["manaRowIndex"]), "target": 0})
