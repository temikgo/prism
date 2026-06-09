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
var _end_btn: Button = null   # pinned End Turn (always visible, never pushed off)
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
var _mana_block_node: Control = null
var _deck_pile_node: Control = null
var _grave_pile_node: Control = null
var _prev_deck := -1
var _prev_grave := -1
var _prev_crystals := -1
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

	# End Turn lives on this always-on-top layer, pinned to the bottom-left of the
	# VIEWPORT, so it is never pushed off-screen when the side column (lots of mana
	# / awaken chips) grows the board layout taller than the window. Positioned by
	# viewport height (anchoring to the parent fails -- the parent grows with the
	# overflowing board). Repositioned on resize and each rebuild.
	_end_btn = Ui.neon_button("Завершить ход", Color(1.0, 0.62, 0.3))
	_end_btn.custom_minimum_size = Vector2(180, 46)
	_end_btn.add_theme_font_size_override("font_size", 16)
	_end_btn.pressed.connect(func() -> void: _send({"action": "endTurn"}))
	_topbar.add_child(_end_btn)
	get_tree().root.size_changed.connect(_reposition_end_btn)
	_reposition_end_btn()


func _reposition_end_btn() -> void:
	if _end_btn != null and is_inside_tree():
		_end_btn.position = Vector2(20.0, get_viewport_rect().size.y - 62.0)


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
	# now-stale index, so drop it.
	_close_picker()
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


func _attach_ready_pulse(card: Control) -> void: _anim.ready_pulse(card)


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


# Pulse your right-flank chrome when its value changed: a gained crystal (banked
# a card / ramp), a drawn card (deck shrank), or a card sent to the graveyard
# (death / spell). One-shot feedback on the freshly-built nodes.
func _animate_piles() -> void:
	if view.is_empty():
		return
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var deck := int(me.get("deckCount", 0))
	var grave := int(me.get("graveyardCount", 0))
	var crystals := 0
	for v in me.get("mana", {}).get("crystals", {}).values():
		crystals += int(v)
	if _prev_deck >= 0:
		if crystals > _prev_crystals:
			_anim.pulse(_mana_block_node)
		if deck < _prev_deck:
			_anim.pulse(_deck_pile_node)
		if grave > _prev_grave:
			_anim.pulse(_grave_pile_node)
	_prev_deck = deck
	_prev_grave = grave
	_prev_crystals = crystals


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
		go.setup(int(view.get("winner", -1)) == you)
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

	# Refresh the pinned End Turn: hidden while an overlay (mulligan/scry/game-over)
	# owns the screen, disabled when it is not your turn.
	if _end_btn != null:
		_reposition_end_btn()
		_end_btn.visible = not bool(view.get("over", false)) \
			and not bool(view.get("mulligan", false)) and not view.has("scry")
		_end_btn.disabled = not _my_turn()


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
	if mine:
		_my_hero_node = card  # where your own face-damage numbers spawn
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


# Capped height for the mana crystal scroll: ~one row per ~4 crystals, capped at
# 3 rows. Beyond that the crystals scroll instead of growing the column (which
# would push the hand off the bottom on a tall mana pool).
func _mana_cap_h(mana: Dictionary) -> float:
	var crystals: Dictionary = mana.get("crystals", {})
	var avail: Dictionary = mana.get("available", {})
	var total := 0
	for color in CardData.ALL_COLORS:
		total += maxi(int(crystals.get(color, 0)), int(avail.get(color, 0)))
	if total <= 0:
		return 26.0  # the "нет маны" line
	return float(mini(int(ceil(float(total) / 4.0)), 3) * 40)


# Right flank: mana, the banked-card peek, deck/graveyard stacks, counts, top card.
func _piles_column(p: Dictionary, mine: bool) -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(142, 0)
	col.size_flags_vertical = Control.SIZE_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Mana: a fixed "МАНА" tag + a height-capped scroll of the crystals, so a huge
	# pool scrolls instead of growing the column and clipping the hand below.
	var mana_block := VBoxContainer.new()
	mana_block.alignment = BoxContainer.ALIGNMENT_CENTER
	mana_block.add_theme_constant_override("separation", 3)
	mana_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mana_tag := Ui.label("МАНА", 10, Color(0.66, 0.7, 0.82), true, true)
	mana_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mana_block.add_child(mana_tag)
	var mana_sc := ScrollContainer.new()
	mana_sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mana_sc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mana_sc.mouse_filter = Control.MOUSE_FILTER_PASS
	mana_sc.custom_minimum_size = Vector2(140, _mana_cap_h(p.get("mana", {})))
	mana_sc.add_child(Chrome.mana_pips(p.get("mana", {})))
	mana_block.add_child(mana_sc)
	col.add_child(mana_block)
	var mr := _manarow_view(p.get("manaRow", []), mine)
	if mr != null:
		col.add_child(mr)
	var piles := HBoxContainer.new()
	piles.alignment = BoxContainer.ALIGNMENT_CENTER
	piles.add_theme_constant_override("separation", 12)
	piles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var deck_stack := Chrome.pile_stack(int(p.get("deckCount", 0)), "колода", Color(0.5, 0.7, 0.95))
	var grave_stack := Chrome.pile_stack(int(p.get("graveyardCount", 0)), "сброс", Color(0.62, 0.6, 0.68))
	piles.add_child(deck_stack)
	piles.add_child(grave_stack)
	col.add_child(piles)
	# Remember your own chrome nodes so _animate_piles can pulse them on change.
	if mine:
		_mana_block_node = mana_block
		_deck_pile_node = deck_stack
		_grave_pile_node = grave_stack
	var il := Ui.label("рука %d" % int(p.get("handCount", 0)), 11, Color(0.6, 0.64, 0.74), true)
	il.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(il)
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
	var tag_txt := "без доплаты" if free else "разбудить"
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

	# The creatures live in a persistent, manually-laid-out layer (kept across
	# views, reattached here each rebuild). It owns the overlap fan and the
	# drag-in gap, so cards keep their nodes -- the base for smooth animations.
	var layer := _ensure_layer(mine)
	layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if layer.get_parent() != null:
		layer.get_parent().remove_child(layer)
	outer.add_child(layer)
	zone.add_child(outer)
	layer.sync(board,
		func(cr: Dictionary) -> UiCard: return _creature_card(cr, mine),
		func(node: UiCard, cr: Dictionary) -> void: _refresh_creature(node, cr, mine))
	if mine:
		_my_board_zone = zone  # for the drag-over hit test
	return zone


func _ensure_layer(mine: bool) -> BoardLayer:
	if mine:
		if _layer_mine == null:
			_layer_mine = BoardLayer.new()
		return _layer_mine
	if _layer_opp == null:
		_layer_opp = BoardLayer.new()
	return _layer_opp


# Build a NEW persistent creature card: the outer node and its (cr-independent)
# interaction hooks. The current creature data is read from get_meta("cr") so the
# node can be reused across views; _refresh_creature paints the rest.
func _creature_card(cr: Dictionary, mine: bool) -> UiCard:
	var card := UiCard.new()
	card.custom_minimum_size = CARD_SIZE
	card.hoverable = true
	var cid := int(cr["id"])
	card.set_meta("cid", cid)
	# Color glow in the card's own colour (fixed -- depends only on the card id).
	var col := Palette.primary(_def(String(cr["card"])))
	var glow := StyleBoxFlat.new()
	glow.bg_color = Color(0, 0, 0, 0)
	glow.set_corner_radius_all(12)
	glow.shadow_size = 10
	glow.shadow_color = Color(col.r, col.g, col.b, 0.6)
	card.add_theme_stylebox_override("panel", glow)
	if mine:
		# Your creature: a drop target for a creature play-drop or a friendly/any
		# spell; only glow for the spell case.
		card.can_drop_fn = func(data: Variant) -> bool:
			return _can_play_here(data) or _can_cast_on(data, "friendly")
		card.highlight_check = func(data: Variant) -> bool:
			return _can_cast_on(data, "friendly")
		card.drop_fn = func(data: Variant) -> void:
			if _can_cast_on(data, "friendly"):
				_play_payload(data, cid)
			else:
				_play_at_drop(data)
	else:
		# Enemy creature: accept an attacker (provoke/stealth permitting) or an
		# enemy/any spell. Reads the live cr from meta (the node is reused).
		card.can_drop_fn = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY:
				return false
			var c: Dictionary = card.get_meta("cr")
			if data.get("kind", "") == "attacker":
				return _valid_attack_target(c)
			return _can_cast_on(data, "enemy") and not bool(c.get("stealth", false))
		card.drop_fn = func(data: Variant) -> void:
			if data.get("kind", "") == "attacker":
				_attack_creature(int(data["id"]), cid)
			else:
				_play_payload(data, cid)
	_refresh_creature(card, cr, mine)
	return card


# Update an existing creature node for fresh data: store the live cr, rebuild the
# inner content (face + ability dock + ready pulse) on the same outer node so its
# identity (and any in-flight animation on it) survives, and refresh the
# attack/dim state.
func _refresh_creature(card: UiCard, cr: Dictionary, mine: bool) -> void:
	card.set_meta("cr", cr)
	for ch in card.get_children():
		card.remove_child(ch)
		ch.queue_free()
	var def_id := String(cr["card"])
	var face := CardView.face(def_id, cr)
	card.add_child(face)
	card.tooltip_text = _name_of(def_id)
	card.tooltip_builder = func() -> Control: return CardView.tooltip(def_id, card.get_meta("cr"))
	card.preview_builder = func() -> Control:
		var wrapper := Control.new()
		var f := CardView.face(def_id, card.get_meta("cr"))
		f.size = CARD_SIZE
		f.position = -CARD_SIZE / 2.0
		wrapper.add_child(f)
		return wrapper
	var cid := int(cr["id"])
	if mine:
		# Mirror Creature::canAttack: not sick/attacked/frozen/blinded and atk > 0.
		var can_attack := _my_turn() and int(cr.get("atk", 0)) > 0 \
			and int(cr.get("frozen", 0)) == 0 and int(cr.get("blind", 0)) == 0 \
			and not bool(cr.get("sick", false)) and not bool(cr.get("attacked", false))
		card.payload = {
			"kind": "attacker", "id": cid, "draggable": can_attack,
			"bypass": _has_keyword(def_id, "bypass"),
		}
		card.drag_label = _name_of(def_id)
		# On your turn, dim creatures that cannot attack so the ready ones glow.
		if _my_turn() and not can_attack:
			card.modulate = Color(0.6, 0.62, 0.7, 0.92)
			card.rest_modulate = Color(0.6, 0.62, 0.7, 0.92)
		else:
			card.modulate = Color.WHITE
			card.rest_modulate = Color.WHITE
			if can_attack:
				_attach_ready_pulse(card)
		# Activated abilities (e.g. germinate): icon buttons along the bottom edge,
		# added to the face (a Panel that respects anchors).
		var dock := _ability_dock(cr, cid)
		if dock != null:
			face.add_child(dock)
	else:
		card.payload = {}
		card.modulate = Color.WHITE
		card.rest_modulate = Color.WHITE


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


# --- card visual -------------------------------------------------------------

func _make_card(def_id: String, runtime) -> UiCard: return CardView.widget(def_id, runtime)


# --- styles ------------------------------------------------------------------

func _zone_style(mine: bool) -> StyleBoxFlat:
	var accent := Color(0.3, 0.75, 0.6) if mine else Color(0.75, 0.35, 0.4)
	var sb := Ui.glass(accent, 0.22)
	sb.shadow_size = 0   # board zones stay calm; only cards/heroes glow
	return sb


# --- controls + hints --------------------------------------------------------

# Just the drag hint now; End Turn is pinned on the top layer (see _build_topbar).
func _controls() -> Control:
	var hint := Ui.label("тащите карту на стол — разыграть · на цель — заклинание/атака · двойной тап — в ману",
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
		_spell_cast_fx(data)
		_send({"action": "awaken", "manaRowIndex": int(data["manaRowIndex"]), "target": target})
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
		_spell_cast_fx(data)
		_send({"action": "awaken", "manaRowIndex": int(data["manaRowIndex"]), "target": 0, "pos": pos})
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
