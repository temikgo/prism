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
var _peek: Control = null     # open floodlight card-peek popup, if any
var _overlay: Control = null  # full-screen overlay layer (game-over screen)
var _topbar: Control = null   # always-on-top leave button + status pill
var _status_pill: Control = null  # the status message pill (hidden when empty)
var _fx: Control = null        # transient effects layer (damage numbers, ghosts)
var _anim: Fx = null           # board feedback animations (lunge/shake/pop/etc.)
var _prev_hp := {}             # creature id -> hp last seen (damage/death diff)
var _prev_hero_hp := {}        # player index (0/1) -> hero hp last seen (face damage)
# Board creatures live in two persistent layers (yours / opponent's), keyed by
# creature id, so a living creature keeps its node across views. Reattached into
# the freshly-built half each rebuild (rescued before teardown).
var _layer_mine: BoardLayer = null
var _layer_opp: BoardLayer = null
var _hand: HandRow = null              # persistent hand fan (slides on draw/play)
var _my_board_zone: Control = null     # your board drop zone (for hover test)
# Your right-flank chrome nodes (rebuilt each view), pulsed when their value
# changes -- see _animate_piles.
# Deck/discard/hand count tiles, keyed "<side>_<pile>" (side: me|foe), with the last
# seen counts -- _animate_piles pulses any tile whose number changed this view, so
# the feedback fires for both players (yours on your turn, the foe's on theirs).
var _pile_nodes := {}
var _prev_piles := {}
var _mull_sel := {}                    # mulligan: hand indices marked for replacing
var _scry_sel := {}                    # scry: peeked indices marked for the bottom
var _pending_lunge := {}               # {attacker, pos}: a just-sent attack to animate
var _enemy_hero_node = null            # enemy hero medallion node (lunge target)
var _my_hero_node = null               # your hero medallion node (face-damage numbers)

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
		and _layer_mine != null and is_instance_valid(_layer_mine) \
		and _my_board_zone != null and is_instance_valid(_my_board_zone) \
		and _my_board_zone.get_global_rect().has_point(get_global_mouse_position())
	if not ok:
		_remove_board_gap()
		return
	var idx := _drop_insert_index()
	if _layer_mine.gap_index != idx:
		_layer_mine.gap_index = idx
		_layer_mine._layout(true)  # the slot opens smoothly


func _remove_board_gap() -> void:
	if _layer_mine != null and is_instance_valid(_layer_mine) and _layer_mine.gap_index != -1:
		_layer_mine.gap_index = -1
		_layer_mine._layout(true)  # the slot closes smoothly


func _send(obj: Dictionary) -> void:
	if _send_action.is_valid():
		_send_action.call(obj)


# Apply a fresh view: diff creature HP against the last one (GameState) to drive
# damage / death / summon animations, then rebuild.
func _ingest_view(new_view: Dictionary) -> void:
	# A new view means the board changed: an open mana picker would point at a
	# now-stale index, so drop it (and any open floodlight peek).
	_close_picker()
	_dismiss_peek()
	var d := GameState.diff(_prev_hp, new_view)
	var new_hp: Dictionary = d["hp"]
	# A creature we had is gone: detach its persistent node and fade it out.
	for id in GameState.departed(_prev_hp, new_hp):
		var dead := _take_creature(int(id))
		if dead != null:
			_anim.fade_out_dead(dead)

	var hero_dmg := _diff_hero_hp(new_view)
	view = new_view
	_rebuild()  # reattaches the board layers and reconciles them
	_prev_hp = new_hp
	_animate_changes(d["dmg"], d["summoned"], hero_dmg)


# Update the per-side hero HP record and return {player index -> damage taken}
# for any hero whose HP dropped this view (face damage / pierce overflow).
func _diff_hero_hp(new_view: Dictionary) -> Dictionary:
	var dmg := {}
	for s in 2:
		var hp := int(new_view["players"][s].get("hero", {}).get("hp", 0))
		if _prev_hero_hp.has(s) and hp < _prev_hero_hp[s]:
			dmg[s] = _prev_hero_hp[s] - hp
		_prev_hero_hp[s] = hp
	return dmg


# Apply damage / death / summon effects once the new board has laid out.
# Attack helpers: record the target's on-screen position and the attacker, then
# send. _animate_changes plays the lunge on the (rebuilt) attacker node.
func _attack_creature(attacker_id: int, target_cid: int) -> void:
	_pending_lunge = {"attacker": attacker_id, "pos": _node_center(_creature_node(target_cid))}
	_send({"action": "attackCreature", "attacker": attacker_id, "target": target_cid})


func _attack_hero(attacker_id: int) -> void:
	# Lunge toward the actual enemy hero medallion (it sits on the flank, so a
	# straight-up lunge looked wrong -- aim at where the hero really is).
	var target := _node_center(_enemy_hero_node)
	_pending_lunge = {"attacker": attacker_id, "pos": target}
	_send({"action": "attackHero", "attacker": attacker_id})


func _node_center(n) -> Vector2:
	if n != null and is_instance_valid(n):
		return n.global_position + n.size * 0.5
	return Vector2(get_viewport_rect().size.x * 0.5, 70.0)  # fallback: enemy side


# The persistent card node for a creature id, from whichever board layer holds
# it (or null).
func _creature_node(cid: int) -> Control:
	if _layer_mine != null and _layer_mine.has(cid):
		return _layer_mine.node_for(cid)
	if _layer_opp != null and _layer_opp.has(cid):
		return _layer_opp.node_for(cid)
	return null


# Detach a creature's node from its layer (for the death animation).
func _take_creature(cid: int) -> Control:
	if _layer_mine != null and _layer_mine.has(cid):
		return _layer_mine.take(cid)
	if _layer_opp != null and _layer_opp.has(cid):
		return _layer_opp.take(cid)
	return null


# Apply damage / death / summon effects once the new board has laid out. Owns the
# orchestration (which ids changed); the Fx module owns the animations.
func _animate_changes(dmg: Dictionary, summoned: Dictionary, hero_dmg: Dictionary = {}) -> void:
	# Two frames so the containers finish positioning the rebuilt board: effects
	# below read each node's global_position, which is only valid once the row
	# has laid out (one frame is not enough -- numbers landed at the top edge).
	await get_tree().process_frame
	await get_tree().process_frame
	if not _pending_lunge.is_empty():
		var att := _creature_node(int(_pending_lunge["attacker"]))
		if att != null:
			_anim.lunge(att, _pending_lunge["pos"])
		_pending_lunge = {}
	for id in summoned:
		var sn := _creature_node(int(id))
		if sn != null:
			# A creature settles into its slot where it was dropped (you dragged it
			# there -- no fly-in from elsewhere). Neighbours reflow to make room.
			_anim.pop_in(sn)
	var total := 0
	for id in dmg:
		var nd := _creature_node(int(id))
		if nd != null:
			_anim.flash(nd)
			_anim.float_number(
				nd.global_position + Vector2(nd.size.x * 0.5, nd.size.y * 0.18), int(dmg[id]))
		total += int(dmg[id])
	# Face damage: the same flash + floating number on the hero medallion that took
	# the hit (yours or the enemy's), so chip/burst damage to a hero reads too.
	for s in hero_dmg:
		var hn = _my_hero_node if int(s) == int(view.get("you", 0)) else _enemy_hero_node
		if hn != null and is_instance_valid(hn):
			_anim.flash(hn)
			_anim.float_number(hn.global_position + hn.size * Vector2(0.5, 0.2), int(hero_dmg[s]))
		total += int(hero_dmg[s])
	if total > 0:
		_anim.shake(minf(4.0 + total * 1.7, 16.0))  # impact scales with the hit
	_animate_piles()


# Pulse each deck/discard/hand count tile whose number changed this view -- for
# both players, so drawing (deck down / hand up), a death or play (discard up),
# and the same on the enemy's turn all read. One-shot, on the freshly-built nodes.
func _animate_piles() -> void:
	if view.is_empty():
		return
	var you := int(view["you"])
	var counts := {
		"me_deck": int(view["players"][you].get("deckCount", 0)),
		"me_grave": int(view["players"][you].get("graveyardCount", 0)),
		"me_hand": int(view["players"][you].get("handCount", 0)),
		"foe_deck": int(view["players"][1 - you].get("deckCount", 0)),
		"foe_grave": int(view["players"][1 - you].get("graveyardCount", 0)),
		"foe_hand": int(view["players"][1 - you].get("handCount", 0)),
	}
	for key in counts:
		# Pulse on ANY change (not just a direction), so it always fires; skip the
		# first view (no baseline yet) to avoid a pulse on entering the match.
		if _prev_piles.has(key) and counts[key] != _prev_piles[key]:
			_anim.pulse(_pile_nodes.get(key))
		_prev_piles[key] = counts[key]


# --- view queries ------------------------------------------------------------

# Card-database lookups delegate to CardData (pure module); board/turn logic stays
# here. These thin adapters keep call sites unchanged.
func _display_id(id: String) -> String: return CardData.display_id(id)
func _def(id: String) -> Dictionary: return CardData.def(id)
func _name_of(card_id: String) -> String: return CardData.name_of(card_id)
func _text_of(card_id: String) -> String: return CardData.text_of(card_id)


func _my_turn() -> bool: return Rules.my_turn(view)
func _can_place_mana() -> bool: return Rules.can_place_mana(view)


func _needs_target(card_id: String) -> bool: return CardData.needs_target(card_id)
func _target_side(card_id: String) -> String: return CardData.target_side(card_id)
func _target_required(card_id: String) -> bool: return CardData.target_required(card_id)
func _is_creature(card_id: String) -> bool: return CardData.is_creature(card_id)
func _can_afford(cost: Dictionary, avail: Dictionary) -> bool: return CardData.can_afford(cost, avail)
func _can_afford_with_shift(cost: Dictionary, avail: Dictionary) -> bool: return CardData.can_afford_with_shift(cost, avail)


func _hero_has(p: Dictionary, passive_id: String) -> bool: return Rules.hero_has(p, passive_id)
func _is_playable(card_id: String) -> bool: return Rules.is_playable(view, card_id)
func _has_legal_target(card_id: String) -> bool: return Rules.has_legal_target(view, card_id)
func _has_keyword(card_id: String, kw: String) -> bool: return CardData.has_keyword(card_id, kw)
func _keyword_n(card_id: String, kw: String) -> int: return CardData.keyword_n(card_id, kw)
func _enemy_has_provoke() -> bool: return Rules.enemy_has_provoke(view)
func _valid_attack_target(cr: Dictionary) -> bool: return Rules.valid_attack_target(view, cr)


# --- top-level rebuild -------------------------------------------------------

func _rebuild() -> void:
	# Rescue the persistent layers (board halves + hand) so the teardown below
	# never frees them; they are reattached into the freshly-built rows.
	for layer in [_layer_mine, _layer_opp, _hand]:
		if layer != null and is_instance_valid(layer) and layer.get_parent() != null:
			layer.get_parent().remove_child(layer)
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
	# setup() sets the panel's full-rect anchors and builds its children before it
	# enters the tree -- a plain Control parent won't re-lay-out an anchor change
	# made after add_child, so the panel must be sized first.
	if bool(view.get("over", false)):
		var go := GameOverPanel.new()
		go.to_menu.connect(func() -> void: exit_to_menu.emit())
		go.setup(_verdict(you))
		_overlay.add_child(go)
	elif bool(view.get("mulligan", false)):
		var mp := MulliganPanel.new()
		mp.toggle.connect(_toggle_mulligan)
		mp.submit.connect(_send_mulligan)
		mp.setup(me.get("hand", []), _mull_sel, bool(me.get("mulliganDone", false)))
		_overlay.add_child(mp)
	elif view.has("scry"):
		var sp := ScryPanel.new()
		sp.toggle.connect(_toggle_scry)
		sp.submit.connect(_send_scry)
		sp.setup(view["scry"], _scry_sel)
		_overlay.add_child(sp)
	elif view.has("decision") and bool(view["decision"].get("youDecide", false)):
		var dp := DecisionPanel.new()
		dp.choose.connect(_send_decision)
		dp.setup(view["decision"], not (me.get("board", []) as Array).is_empty())
		_overlay.add_child(dp)
	elif view.has("decision"):
		var wp := DecisionPanel.new()
		wp.setup_waiting(String(view["decision"].get("kind", "")))
		_overlay.add_child(wp)


func _separator() -> Control:
	# Just a small gap between the two armies (no decorative line -- the lane
	# borders and the side accents already separate the sides).
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


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


func _send_decision(value: int) -> void:
	_send({"action": "decision", "choice": value})


# The match outcome from `you`'s point of view: "win" | "lose" | "draw".
# Only meaningful once view.over is true (winner -1 then means a double-KO draw).
func _verdict(you: int) -> String:
	var w := int(view.get("winner", -1))
	return "draw" if w < 0 else ("win" if w == you else "lose")


func _banner(you: int) -> Control:
	if bool(view.get("over", false)):
		var res := _verdict(you)
		var word := "ПОБЕДА"
		var col := Color(0.5, 0.95, 0.6)
		if res == "draw":
			word = "НИЧЬЯ"
			col = Color(0.85, 0.8, 0.5)
		elif res == "lose":
			word = "ПОРАЖЕНИЕ"
			col = Color(0.95, 0.45, 0.45)
		return Chrome.turn_pill(word, 0, col)
	if bool(view.get("mulligan", false)):
		return Chrome.turn_pill("МУЛИГАН", 0, Color(0.45, 0.85, 1.0))
	# Normal turn: on your turn the pill IS the end-turn button (indicator + action
	# merged); on the foe's it's a plain indicator. Not clickable during scry.
	var mine := _my_turn()
	var accent := ME_ACCENT.lightened(0.12) if mine else ENEMY_ACCENT.lightened(0.05)
	# On your turn the pill itself is the End-Turn button (its label says so); on the
	# foe's it's a plain indicator. Not clickable during scry.
	var clickable := mine and not view.has("scry")
	var on_end := Callable()
	if clickable:
		on_end = func() -> void: _send({"action": "endTurn"})
	var label := ("ЗАВЕРШИТЬ ХОД" if clickable else "ВАШ ХОД") if mine else "ХОД СОПЕРНИКА"
	return Chrome.turn_pill(label, int(view.get("turn", 0)), accent, on_end)


# --- hero strips -------------------------------------------------------------

const ENEMY_ACCENT := Color(0.92, 0.36, 0.42)
const ME_ACCENT := Color(0.34, 0.62, 0.98)


# One player's band: a glass rail slab wrapping [hero medallion | board (center,
# expands) | piles column]. The rail is tinted by the side accent and glows on
# that side's turn (the active cue lives on the slab, not just the banner).
func _player_half(p: Dictionary, mine: bool) -> Control:
	var half := HBoxContainer.new()
	half.add_theme_constant_override("separation", 10)
	half.size_flags_vertical = Control.SIZE_EXPAND_FILL
	half.mouse_filter = Control.MOUSE_FILTER_IGNORE
	half.add_child(_hero_medallion(p.get("hero", {}), mine))
	var board := _board_row(p.get("board", []), p.get("auras", []), mine)
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	half.add_child(board)
	half.add_child(_piles_column(p, mine))

	var active := int(view.get("current", -1)) == int(view["you"]) if mine \
		else int(view.get("current", -1)) != int(view["you"])
	var rail := PanelContainer.new()
	rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rail.add_theme_stylebox_override("panel",
		Ui.rail_panel(ME_ACCENT if mine else ENEMY_ACCENT, active))
	rail.add_child(half)
	return rail


# The hero medallion (portrait + HP/armor + passive). The enemy one is the
# face-attack drop target; Main keeps the node ref for lunge/face-damage targeting.
func _hero_medallion(hero: Dictionary, mine: bool) -> Control:
	var m := HeroMedallion.new()
	if not mine:
		m.attack_hero_requested.connect(_attack_hero)
	m.setup(hero, mine, view)
	if mine:
		_my_hero_node = m   # where your own face-damage numbers spawn
	else:
		_enemy_hero_node = m  # lunge target for face attacks
	return m


# Right flank: mana, the banked-card peek, deck/graveyard stacks, counts, top card.
func _piles_column(p: Dictionary, mine: bool) -> Control:
	var col := PilesColumn.new()
	col.awaken_clicked.connect(_on_awaken_clicked)
	col.peek_requested.connect(_show_peek)  # click a floodlit enemy crystal -> peek its card
	col.setup(p, mine, view)
	# Keep both sides' freshly-built count tiles so _animate_piles can pulse them.
	var side := "me" if mine else "foe"
	_pile_nodes[side + "_deck"] = col.deck_node
	_pile_nodes[side + "_grave"] = col.grave_node
	_pile_nodes[side + "_hand"] = col.hand_node
	return col


# --- mana row (face-down backs + peekable awaken cards) ----------------------

# --- board rows --------------------------------------------------------------

func _board_row(board: Array, auras: Array, mine: bool) -> Control:
	# BoardRow is the drop zone + aura shelf + creatures (in the persistent layer);
	# it reports interaction intents, which we route to the network/fx dispatch.
	var row := BoardRow.new()
	row.play_requested.connect(_play_at_drop)
	row.cast_requested.connect(_play_payload)
	row.attack_requested.connect(_attack_creature)
	row.activate_requested.connect(_activate)
	row.setup(board, auras, mine, view, _ensure_layer(mine), _anim)
	if mine:
		_my_board_zone = row  # for the drag-over hit test
	return row


func _ensure_layer(mine: bool) -> BoardLayer:
	if mine:
		if _layer_mine == null:
			_layer_mine = BoardLayer.new()
		return _layer_mine
	if _layer_opp == null:
		_layer_opp = BoardLayer.new()
	return _layer_opp


# --- hand --------------------------------------------------------------------

# The hand is a persistent HandRow (kept across views, reattached here each
# rebuild) so cards slide when one is drawn or played instead of snapping.
func _hand_row(hand: Array) -> Control:
	if _hand == null:
		_hand = HandRow.new()
	_hand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _hand.get_parent() != null:
		_hand.get_parent().remove_child(_hand)
	_hand.sync(hand,
		func(cid: String) -> UiCard: return _make_hand_card(cid),
		func(node: UiCard, cid: String, index: int) -> void: _refresh_hand_card(node, cid, index))
	return _hand


# Build a NEW hand card: its face is fixed (the node is only ever reused for the
# same card id), and a single double-click handler reads the live index from
# meta, so the index can change as the hand reflows without reconnecting.
func _make_hand_card(cid: String) -> UiCard:
	var card := _make_card(cid, null)
	card.set_meta("hand_index", 0)
	card.double_clicked.connect(func(_p: Dictionary) -> void:
		_on_hand_double(int(card.get_meta("hand_index")), cid))
	return card


# Update a hand card for its new position in the hand: the live index (payload +
# meta) and the dim/playable state. The face never changes (same card id).
func _refresh_hand_card(card: UiCard, cid: String, index: int) -> void:
	card.set_meta("hand_index", index)
	var playable := _is_playable(cid)
	card.payload = {
		"kind": "hand", "index": index, "card_id": cid,
		"needs_target": _needs_target(cid), "is_creature": _is_creature(cid),
		"draggable": _my_turn(), "playable": playable,
		"target_side": _target_side(cid),
	}
	card.drag_label = _name_of(cid)
	# Dim cards you cannot play this turn so the playable ones stand out.
	if playable:
		card.modulate = Color.WHITE
		card.rest_modulate = Color.WHITE
	else:
		card.modulate = Color(0.62, 0.62, 0.68, 0.92)
		card.rest_modulate = Color(0.62, 0.62, 0.68, 0.92)
	# Blue haze: enemy auras surcharge your spells -- show "+N" so the higher cost
	# is visible at rest (the dim/playable state and the pay-picker already use it).
	_apply_haze_badge(card, cid)


func _apply_haze_badge(card: UiCard, cid: String) -> void:
	var existing := card.get_node_or_null("HazeBadge")
	var hz := Rules.haze_surcharge(view, cid)
	if hz <= 0:
		if existing:
			existing.queue_free()
		return
	if existing == null:
		var chip := PanelContainer.new()
		chip.name = "HazeBadge"
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_theme_stylebox_override("panel",
			Ui.bordered(Color(0.08, 0.14, 0.26, 0.95), 8, 1, Palette.color_for("blue"), 4))
		chip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		chip.offset_left = -36
		chip.offset_top = 5
		chip.offset_right = -5
		chip.offset_bottom = 28
		chip.tooltip_text = "Дымка: это заклинание стоит на %d дороже." % hz
		var lbl := Ui.label("+%d" % hz, 15, Palette.color_for("blue").lightened(0.45), true, true)
		lbl.name = "L"
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(lbl)
		card.add_child(chip)
	else:
		existing.get_node("L").text = "+%d" % hz
		existing.tooltip_text = "Дымка: это заклинание стоит на %d дороже." % hz


# --- card visual -------------------------------------------------------------

func _make_card(def_id: String, runtime) -> UiCard: return CardView.widget(def_id, runtime)


# --- styles ------------------------------------------------------------------

# --- controls + hints --------------------------------------------------------

# Just the drag hint now; End Turn lives in the turn pill at the top (see _banner).
func _controls() -> Control:
	var hint := Ui.label("тащите карту на стол — разыграть · на цель — заклинание/атака · двойной тап — преломить в спектр",
		0, Color(0.62, 0.66, 0.78), true)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return hint


# --- drag drop helpers (shared by play / awaken) -----------------------------

func _can_play_here(data: Variant) -> bool: return Rules.can_play_here(view, data)
func _can_cast_on(data: Variant, want_side: String) -> bool: return Rules.can_cast_on(data, want_side)


func _play_payload(data: Variant, target: int) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	if data.get("kind", "") == "awaken":
		_send_awaken(int(data["manaRowIndex"]), target, -1, data)
		return
	_dispatch_play(data, {"action": "play", "handIndex": int(data["index"]), "target": target})


# When a spell is played, dissolve a ghost of its face at the drop point so the
# card visibly spends itself (it never lands on the board). Creatures/auras don't.
func _spell_cast_fx(data: Variant) -> void:
	var card_id := String(data.get("card_id", ""))
	if card_id == "" or not _is_spell(card_id):
		return
	var face := CardView.face(card_id, null)
	_anim.cast_dissolve(face, get_global_mouse_position())


func _is_spell(card_id: String) -> bool: return CardData.is_spell(card_id)


# Play a creature onto your board at the slot the cursor dropped it.
func _play_at_drop(data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var pos := _drop_insert_index()
	if data.get("kind", "") == "awaken":
		_send_awaken(int(data["manaRowIndex"]), 0, pos, data)
		return
	_dispatch_play(data, {"action": "play", "handIndex": int(data["index"]), "target": 0, "pos": pos})


# Route a play: warn if a targeted effect will be lost (played with no target),
# then handle ambiguous generic-mana payment, then send.
func _dispatch_play(data: Variant, msg: Dictionary) -> void:
	var card_id := String(data.get("card_id", ""))
	# Playing a targeted card with no target skips its effect(s) -- confirm first
	# so the player never wastes it by accident.
	if int(msg.get("target", 0)) == 0 and _needs_target(card_id) \
			and not _has_legal_target(card_id):
		var lost: Array = CardData.targeted_effect_texts(card_id)
		_confirm_lost_effect(_name_of(card_id), lost,
			func() -> void: _dispatch_play_mana(data, msg))
		return
	_dispatch_play_mana(data, msg)


# When the generic part of the cost can be paid more than one way, first let the
# player tap which crystals to spend; otherwise send the play immediately.
func _dispatch_play_mana(data: Variant, msg: Dictionary) -> void:
	var choices := _generic_choices(String(data.get("card_id", "")))
	if choices.is_empty():
		_spell_cast_fx(data)
		_send(msg)
		return
	_close_picker()
	var picker := ManaSpendPicker.new()
	picker.picked.connect(func(generic_pay: Dictionary) -> void:
		_spell_cast_fx(data)
		msg["genericPay"] = generic_pay
		_send(msg))
	picker.tree_exited.connect(func() -> void: _picker = null)
	add_child(picker)
	picker.setup(int(choices["generic"]), choices["avail"], choices["pips"])
	_picker = picker


# Send an awaken. When the generic part of its post-banked-crystal cost can be
# paid more than one way, prompt which crystals to spend first (parity with how a
# hard cast is handled in _dispatch_play_mana); otherwise send immediately. `fx`
# is the drag payload for the cast dissolve (pass {} for the click fallback).
func _send_awaken(mr_index: int, target: int, pos: int, fx: Variant) -> void:
	var msg := {"action": "awaken", "manaRowIndex": mr_index, "target": target, "pos": pos}
	var you := int(view["you"])
	var row: Array = view["players"][you].get("manaRow", [])
	if mr_index >= 0 and mr_index < row.size():
		var slot: Dictionary = row[mr_index]
		var choices := Rules.awaken_generic_choices(view, String(slot.get("card", "")),
			String(slot.get("color", "")), int(slot.get("age", 0)))
		if not choices.is_empty():
			_close_picker()
			var picker := ManaSpendPicker.new()
			picker.picked.connect(func(generic_pay: Dictionary) -> void:
				_spell_cast_fx(fx)
				msg["genericPay"] = generic_pay
				_send(msg))
			picker.tree_exited.connect(func() -> void: _picker = null)
			add_child(picker)
			picker.setup(int(choices["generic"]), choices["avail"], choices["pips"])
			_picker = picker
			return
	_spell_cast_fx(fx)
	_send(msg)


# Warn that playing this card now loses its targeted effect(s) -- no valid target.
# On confirm, run `on_yes` (which continues the play).
func _confirm_lost_effect(card_name: String, lost: Array, on_yes: Callable) -> void:
	_close_picker()
	var lines := []
	if lost.is_empty():
		lines.append("Нет цели — эффект карты пропадёт.")
	else:
		lines.append("Нет цели — пропадёт эффект:" if lost.size() == 1 else "Нет цели — пропадут эффекты:")
		for s in lost:
			lines.append("• " + String(s))
	var dlg := ConfirmDialog.new()
	dlg.confirmed.connect(on_yes)
	dlg.tree_exited.connect(func() -> void: _picker = null)
	add_child(dlg)
	dlg.setup(card_name, lines)
	_picker = dlg


func _generic_choices(card_id: String) -> Dictionary: return Rules.generic_choices(view, card_id)


# How many of your creatures sit left of the drop point -> the insertion slot.
func _drop_insert_index() -> int:
	var you := int(view["you"])
	var mx := get_global_mouse_position().x
	var n := 0
	for cr in view["players"][you].get("board", []):
		var nd = _creature_node(int(cr["id"]))
		if nd != null and nd.global_position.x + nd.size.x * 0.5 < mx:
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


# An activated ability costs 1 crystal of any color. Let the player pick which
# crystal to spend (same chooser as placing mana); skip the prompt when there is
# only one kind of crystal to spend.
func _activate(cid: int) -> void:
	var you := int(view.get("you", 0))
	var avail: Dictionary = view["players"][you].get("mana", {}).get("available", {})
	var colors: Array = []
	for col in avail:
		if int(avail[col]) > 0:
			colors.append(col)
	if colors.size() <= 1:
		var c: String = String(colors[0]) if colors.size() == 1 else "colorless"
		_send({"action": "activate", "id": cid, "color": c})
		return
	_close_picker()
	var picker := ManaPicker.new()
	picker.picked.connect(func(col: String) -> void:
		_send({"action": "activate", "id": cid, "color": col}))
	picker.tree_exited.connect(func() -> void: _picker = null)
	add_child(picker)
	picker.setup(colors, get_global_mouse_position(), size)
	_picker = picker


func _close_picker() -> void:
	if _picker != null and is_instance_valid(_picker):
		_picker.queue_free()
	_picker = null


# Peek a floodlit enemy card: a dimmed full-screen catcher with the card's info
# panel centred; a click anywhere (or the next view) dismisses it. The art loads
# only now -- one card -- so there is no reveal-everything freeze.
func _show_peek(card_id: String) -> void:
	_dismiss_peek()
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.z_index = 200
	layer.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			_dismiss_peek())
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.02, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var card := CardView.tooltip(card_id, null)  # name + art + rules
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE  # clicks fall through to the catcher
	center.add_child(card)
	layer.add_child(center)
	_peek = layer
	add_child(layer)


func _dismiss_peek() -> void:
	if _peek != null and is_instance_valid(_peek):
		_peek.queue_free()
	_peek = null


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
		_send_awaken(int(p["manaRowIndex"]), 0, -1, {})
