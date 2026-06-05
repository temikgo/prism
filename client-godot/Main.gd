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

const BOARD_LIMIT := 8  # max creatures per side (mirrors the engine)
# Card geometry lives in Tokens (shared with CardView); aliases keep call sites short.
const CARD_SIZE := Tokens.CARD_SIZE
const RIM := Tokens.RIM
const PAD := Tokens.PAD
const GEM := Tokens.GEM
const STATUS_MAX := Tokens.STATUS_MAX

# Raised when the player leaves the match (game over -> menu, or the back arrow).
# The Router listens, returns to the main menu, and frees this screen.
signal exit_to_menu

var _send_action: Callable = Callable()  # set by Router.bind(); sends actions out
var view := {}
var cards := {}            # card id -> definition (from cards.json)

# Click-fallback selection state (drag-and-drop ignores these).
var _picker: Control = null   # open mana-color chooser, if any
var _overlay: Control = null  # full-screen overlay layer (game-over screen)
var _topbar: Control = null   # always-on-top leave button + status pill
var _status_pill: Control = null  # the status message pill (hidden when empty)
var _fx: Control = null        # transient effects layer (damage numbers, ghosts)
var _anim: Fx = null           # board feedback animations (lunge/shake/pop/etc.)
var _prev_hp := {}             # creature id -> hp last seen (damage/death diff)
var _card_nodes := {}          # creature id -> its card node this rebuild
var _my_creatures_row: Control = null  # the HBox holding your board creatures
var _my_board_zone: Control = null     # your board drop zone (for hover test)
var _board_gap: Control = null         # slot opened while dragging a creature in
var _mull_sel := {}                    # mulligan: hand indices marked for replacing
var _scry_sel := {}                    # scry: peeked indices marked for the bottom
var _pending_lunge := {}               # {attacker, pos}: a just-sent attack to animate
var _enemy_hero_node = null            # enemy hero medallion node (lunge target)

var status_label: Label
var root_box: VBoxContainer


# Color identity, rules glossary, and generic widget/style builders live in their
# own files: palette.gd (Palette), glossary.gd (Glossary), ui.gd (Ui).


# UiCard (the draggable/droppable card-or-zone widget) and FxLayer (the aiming
# arrow overlay) live in their own files: ui_card.gd and fx_layer.gd.


# --- lifecycle ---------------------------------------------------------------

func _ready() -> void:
	# Project typography (also covers the screenshot harness, which loads this
	# scene standalone). Under the router the same theme is already inherited.
	theme = Fonts.default_theme()
	_load_cards()
	_build_shell()
	# Remove the default dark tooltip wrapper window-wide so our custom card
	# tooltip shows without a panel behind it. The auto-created tooltip popup
	# resolves its style from the window theme, not from the tooltip control.
	var th := Fonts.default_theme()
	th.set_stylebox("panel", "TooltipPanel", StyleBoxEmpty.new())
	get_window().theme = th


func _load_cards() -> void:
	# Deck cards (mirror of the server's pool) plus client-only token display
	# data (sprouts and other generated tokens that never sit in a deck). The
	# database lives in CardData; `cards` is the same dict for direct readers.
	CardData.load_file("res://cards.json")
	CardData.load_file("res://tokens.json")
	cards = CardData.db


func _build_shell() -> void:
	# Shared atmospheric backdrop (gradient, glows, vignette, drifting motes); it
	# fits its own motes to the window, so we only need to rebuild the board here.
	add_child(Backdrop.new())
	get_tree().root.size_changed.connect(_on_window_resized)

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

	# Board feedback animations (shakes this root; floats nodes on the fx layer).
	_anim = Fx.new()
	add_child(_anim)
	_anim.setup(self, _fx)

	# Persistent top bar above every overlay, so "В меню" is always reachable --
	# even during the mulligan/game-over screens (e.g. if the server drops).
	_build_topbar()


# The leave-to-menu button plus a status pill, on their own always-on-top layer.
func _build_topbar() -> void:
	_topbar = Control.new()
	_topbar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_topbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_topbar.z_index = 110  # above the fx layer and any overlay panel
	add_child(_topbar)

	var row := HBoxContainer.new()
	row.position = Vector2(20, 12)
	row.add_theme_constant_override("separation", 10)
	_topbar.add_child(row)

	var leave := Ui.neon_button("В меню", Color(0.6, 0.64, 0.74))
	leave.custom_minimum_size = Vector2(96, 0)
	leave.pressed.connect(func() -> void: exit_to_menu.emit())
	row.add_child(leave)

	# A glass pill that only appears when there is a message to show.
	_status_pill = PanelContainer.new()
	_status_pill.add_theme_stylebox_override("panel", Ui.glass(Color(0.95, 0.7, 0.35), 0.55))
	_status_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_pill.visible = false
	status_label = Ui.label("", 14, Color(1.0, 0.88, 0.62), false, true)
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_pill.add_child(status_label)
	row.add_child(_status_pill)


# Wiring from the Router: how this screen sends actions back to the server. The
# Router owns the socket (it carried the lobby flow); we just hand it actions.
func bind(sender: Callable) -> void:
	_send_action = sender


# A fresh server view pushed in by the Router (the socket lives there now).
func feed_view(new_view: Dictionary) -> void:
	_ingest_view(new_view)


# A short transient message in the top-bar pill (e.g. "соперник вышел"), set by
# the Router. Empty text hides the pill so it never sits as bare text.
func set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text
	if _status_pill != null:
		_status_pill.visible = text != ""


# Window resized (e.g. maximize): rebuild the board, since the hand fan and
# board-row overlap are sized from the window width and would otherwise stay
# stale (cards clumped or overflowing) until the next view. The backdrop refits
# its own motes.
func _on_window_resized() -> void:
	# Don't rebuild mid-drag (it would free the dragged node) or before any view.
	if view.is_empty() or UiCard.active_drag != null:
		return
	_rebuild()


func _process(_dt: float) -> void:
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
	if _send_action.is_valid():
		_send_action.call(obj)


# Apply a fresh view: diff creature HP against the last one (GameState) to drive
# damage / death / summon animations, then rebuild.
func _ingest_view(new_view: Dictionary) -> void:
	# A new view means the board changed: an open mana picker would point at a
	# now-stale index, so drop it.
	_close_picker()
	var d := GameState.diff(_prev_hp, new_view)
	var new_hp: Dictionary = d["hp"]
	# A creature we had is gone: rescue its node from the doomed tree and fade it.
	for id in GameState.departed(_prev_hp, new_hp):
		if _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			_anim.fade_out_dead(_card_nodes[id])

	view = new_view
	_card_nodes = {}
	_rebuild()  # refills _card_nodes
	_prev_hp = new_hp
	_animate_changes(d["dmg"], d["summoned"])


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


func _attach_ready_pulse(card: Control) -> void: _anim.ready_pulse(card)


# Apply damage / death / summon effects once the new board has laid out. Owns the
# orchestration (which ids changed); the Fx module owns the animations.
func _animate_changes(dmg: Dictionary, summoned: Dictionary) -> void:
	await get_tree().process_frame
	if not _pending_lunge.is_empty():
		var aid := int(_pending_lunge["attacker"])
		if _card_nodes.has(aid) and is_instance_valid(_card_nodes[aid]):
			_anim.lunge(_card_nodes[aid], _pending_lunge["pos"])
		_pending_lunge = {}
	for id in summoned:
		if _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			_anim.pop_in(_card_nodes[id])
	var total := 0
	for id in dmg:
		if _card_nodes.has(id) and is_instance_valid(_card_nodes[id]):
			var nd: Control = _card_nodes[id]
			_anim.flash(nd)
			_anim.float_number(
				nd.global_position + Vector2(nd.size.x * 0.5, nd.size.y * 0.18), int(dmg[id]))
		total += int(dmg[id])
	if total > 0:
		_anim.shake(minf(4.0 + total * 1.7, 16.0))  # impact scales with the hit


# --- view queries ------------------------------------------------------------

# Card-database lookups delegate to CardData (pure module); board/turn logic stays
# here. These thin adapters keep call sites unchanged.
func _display_id(id: String) -> String: return CardData.display_id(id)
func _def(id: String) -> Dictionary: return CardData.def(id)
func _name_of(card_id: String) -> String: return CardData.name_of(card_id)
func _text_of(card_id: String) -> String: return CardData.text_of(card_id)


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


func _needs_target(card_id: String) -> bool: return CardData.needs_target(card_id)
func _target_side(card_id: String) -> String: return CardData.target_side(card_id)
func _is_creature(card_id: String) -> bool: return CardData.is_creature(card_id)
func _can_afford(cost: Dictionary, avail: Dictionary) -> bool: return CardData.can_afford(cost, avail)
func _can_afford_with_shift(cost: Dictionary, avail: Dictionary) -> bool: return CardData.can_afford_with_shift(cost, avail)


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


func _has_keyword(card_id: String, kw: String) -> bool: return CardData.has_keyword(card_id, kw)
func _keyword_n(card_id: String, kw: String) -> int: return CardData.keyword_n(card_id, kw)


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
	# Tear down the board and redraw from the view. The leave button lives on its
	# own always-on-top layer (_topbar), so root_box holds only board content.
	while root_box.get_child_count() > 0:
		var n := root_box.get_child(0)
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
	# Roomier glass so the wide display word never sits flush against the frame.
	var sb := Ui.glass(accent, 0.9)
	sb.set_content_margin_all(34)
	panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 18)
	vb.custom_minimum_size = Vector2(440, 0)  # margin around the verdict text
	var verdict := Ui.label("ПОБЕДА" if win else "ПОРАЖЕНИЕ", 46, accent.lightened(0.3), true)
	verdict.add_theme_font_override("font", Fonts.DISPLAY)
	verdict.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(verdict)
	var to_menu := Ui.neon_button("В меню", accent)
	to_menu.custom_minimum_size = Vector2(200, 48)
	to_menu.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	to_menu.pressed.connect(func() -> void: exit_to_menu.emit())
	vb.add_child(to_menu)
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

	# Main reads the state; Chrome renders the pill (with a diamond each side).
	return Chrome.banner(txt, col)


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
	v.add_child(HeroView.portrait_with_hp(hero, 124))
	var nm := Ui.label(String(hero.get("name", "Герой")), 17, null, true)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nm)
	var badge := HeroView.passive_badge(hero)
	if badge != null:
		var brow := HBoxContainer.new()
		brow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		brow.alignment = BoxContainer.ALIGNMENT_CENTER
		brow.add_child(badge)
		v.add_child(brow)
	card.add_child(v)
	return card


# Right flank: mana, the banked-card peek, deck/graveyard stacks, counts, top card.
func _piles_column(p: Dictionary, mine: bool) -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(142, 0)
	col.size_flags_vertical = Control.SIZE_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(Chrome.mana_block(p.get("mana", {})))
	var mr := _manarow_view(p.get("manaRow", []), mine)
	if mr != null:
		col.add_child(mr)
	var piles := HBoxContainer.new()
	piles.alignment = BoxContainer.ALIGNMENT_CENTER
	piles.add_theme_constant_override("separation", 12)
	piles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	piles.add_child(Chrome.pile_stack(int(p.get("deckCount", 0)), "колода", Color(0.5, 0.7, 0.95)))
	piles.add_child(Chrome.pile_stack(int(p.get("graveyardCount", 0)), "сброс", Color(0.62, 0.6, 0.68)))
	col.add_child(piles)
	var il := Ui.label("рука %d" % int(p.get("handCount", 0)), 11, Color(0.6, 0.64, 0.74), true)
	il.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(il)
	# Lens clairvoyance: your revealed top card sits by your deck.
	if mine and p.has("topCard"):
		col.add_child(_topcard_chip(String(p["topCard"])))
	return col


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
	tile.tooltip_builder = func() -> Control: return CardView.tooltip(card_id, null)
	tile.hoverable = true
	tile.add_child(_art_thumb(card_id, col, 50))
	return tile


# A square art thumbnail for a card, or a tinted placeholder if the art is
# missing. Shared by the aura shelf and the awaken chips.
func _art_thumb(card_id: String, fallback: Color, px: float) -> Control:
	return Tokens.art(card_id, px, fallback)




# Lens clairvoyance: a small chip showing the revealed top card of your deck.
func _topcard_chip(card_id: String) -> Control:
	var col := Palette.primary(_def(card_id))
	var tile := UiCard.new()
	tile.custom_minimum_size = Vector2(0, 44)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.15, 0.92)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = HeroView.ACCENT
	sb.set_content_margin_all(4)
	tile.add_theme_stylebox_override("panel", sb)
	tile.tooltip_text = _name_of(card_id)
	tile.tooltip_builder = func() -> Control: return CardView.tooltip(card_id, null)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 5)
	row.add_child(Ui.icon("lens", 14, HeroView.ACCENT))
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
	t.tooltip_builder = func() -> Control: return CardView.tooltip(card_id, null)
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
	chip.tooltip_builder = func() -> Control: return CardView.tooltip(card_id, null)
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
	return Tokens.round_style(border, glow)


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
	v.add_child(CardView.rich(full.substr(ci + 1).strip_edges() if ci > 0 else full,
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
	card.add_child(CardView.face(def_id, runtime))
	# Pretty hover tooltip (built lazily) instead of the plain text one. A
	# non-empty tooltip_text is still required for the tooltip to trigger.
	card.tooltip_text = _name_of(def_id)
	card.tooltip_builder = func() -> Control: return CardView.tooltip(def_id, runtime)
	card.hoverable = true
	# The drag preview is the card itself, centered under the cursor.
	card.preview_builder = func() -> Control:
		var wrapper := Control.new()
		var f := CardView.face(def_id, runtime)
		f.size = CARD_SIZE
		f.position = -CARD_SIZE / 2.0
		wrapper.add_child(f)
		return wrapper
	return card


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
	_close_picker()
	var picker := ManaPicker.new()
	picker.picked.connect(func(cid: String) -> void:
		_send({"action": "placeMana", "handIndex": idx, "color": cid}))
	picker.tree_exited.connect(func() -> void: _picker = null)
	add_child(picker)
	picker.setup(colors, get_global_mouse_position(), size)
	_picker = picker


func _close_picker() -> void:
	if _picker != null and is_instance_valid(_picker):
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
