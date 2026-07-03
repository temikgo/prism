class_name BoardRow
extends UiCard

# One player's battlefield lane: the drop zone (this UiCard), an aura shelf, and
# the creatures laid out in a persistent BoardLayer (owned by Main, passed in, so
# nodes survive a rebuild). Queries are answered purely via Rules/CardData; the
# only things it reports up are the four interaction INTENTS below -- Main wires
# them to the network/fx dispatch. Built fresh each view; the layer is reattached.

signal play_requested(data: Variant)                       # drop a play onto the zone/creature
signal cast_requested(data: Variant, target_cid: int)      # drop a targeted spell on a creature
signal attack_requested(attacker_id: int, target_cid: int) # drop an attacker on an enemy creature
signal activate_requested(cid: int)                        # press a creature's ability button

const CARD_SIZE := Tokens.CARD_SIZE
const GEM := Tokens.GEM
const PAD := Tokens.PAD

var _view := {}
var _anim: Fx = null


# `layer` is the persistent BoardLayer for this side; `anim` drives the ready
# pulse on attack-ready creatures. Both are owned by Main and outlive this row.
func setup(board: Array, auras: Array, mine: bool, view: Dictionary,
		layer: BoardLayer, anim: Fx) -> void:
	_view = view
	_anim = anim
	custom_minimum_size = Vector2(0, CARD_SIZE.y + 12)
	add_theme_stylebox_override("panel", _zone_style(mine))
	# The whole row is a drop zone: dropping a playable hand/awaken card here plays
	# it (creatures land on your own side). Auras sit on a side shelf so they take
	# horizontal, not vertical, space.
	if mine:
		glow_self = true  # glow the zone border, not the creatures/auras in it
		can_drop_fn = func(data: Variant) -> bool: return Rules.can_play_here(_view, data)
		drop_fn = func(data: Variant) -> void: play_requested.emit(data)

	var outer := HBoxContainer.new()
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_theme_constant_override("separation", 10)
	if not auras.is_empty():
		outer.add_child(_aura_shelf(auras, mine))

	# The creatures live in the persistent layer (kept across views, reattached
	# here each rebuild). It owns the overlap fan and the drag-in gap, so cards
	# keep their nodes -- the base for smooth animations.
	layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if layer.get_parent() != null:
		layer.get_parent().remove_child(layer)
	outer.add_child(layer)
	add_child(outer)
	layer.sync(board,
		func(cr: Dictionary) -> UiCard: return _creature_card(cr, mine),
		func(node: UiCard, cr: Dictionary) -> void: _refresh_creature(node, cr, mine))


func _zone_style(mine: bool) -> StyleBoxFlat:
	# The rail slab is the glass now, so the field itself is just the drop area: a
	# faint side-tinted outline at rest that the drop-legal self_modulate brightens
	# into a clear glowing border (no second glass box fighting the rail).
	# Only your own field needs a resting outline (the drop hint the self_modulate
	# brightens); the enemy field never receives drops, so it stays open glass.
	var accent := Ui.SIDE_ME
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(16)
	sb.set_border_width_all(1)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.12 if mine else 0.0)
	sb.set_content_margin_all(6)
	return sb


# --- auras -------------------------------------------------------------------

func _aura_shelf(auras: Array, mine: bool) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var tag := Ui.label("ВАШИ АУРЫ" if mine else "АУРЫ ВРАГА", 10, Color(0.6, 0.64, 0.74))
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(tag)
	for i in auras.size():
		box.add_child(_aura_tile(String(auras[i].get("card", "")), i, mine))
	return box


func _aura_tile(card_id: String, index: int, mine: bool) -> Control:
	# Art-only square tile (name + rules on hover) so it never wraps/overflows.
	var col := Palette.primary(CardData.def(card_id))
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
	tile.tooltip_text = CardData.name_of(card_id)
	tile.tooltip_builder = func() -> Control: return CardView.tooltip(card_id, null)
	tile.hoverable = true
	tile.add_child(Tokens.art(card_id, 50, col))
	# An enemy aura is a drop target for a dispel-choose spell: aim the arrow at it
	# and it reports its index as the play target (like aiming at a creature).
	if not mine:
		tile.can_drop_fn = func(data: Variant) -> bool: return Rules.can_cast_on_aura(data)
		tile.highlight_check = func(data: Variant) -> bool: return Rules.can_cast_on_aura(data)
		tile.drop_fn = func(data: Variant) -> void: cast_requested.emit(data, index)
	return tile


# --- creatures ---------------------------------------------------------------

# Build a NEW persistent creature card: just the outer node and the fixed,
# cr-independent visuals. The interaction hooks are (re)bound in _refresh_creature
# every view, because the node outlives this transient BoardRow -- binding them
# here would capture a BoardRow that is freed on the next rebuild.
func _creature_card(cr: Dictionary, mine: bool) -> UiCard:
	var card := UiCard.new()
	card.custom_minimum_size = CARD_SIZE
	card.hoverable = true
	card.set_meta("cid", int(cr["id"]))
	# Color glow in the card's own colour (fixed -- depends only on the card id).
	var col := Palette.primary(CardData.def(String(cr["card"])))
	var glow := StyleBoxFlat.new()
	glow.bg_color = Color(0, 0, 0, 0)
	glow.set_corner_radius_all(12)
	glow.shadow_size = 10
	glow.shadow_color = Color(col.r, col.g, col.b, 0.6)
	card.add_theme_stylebox_override("panel", glow)
	_refresh_creature(card, cr, mine)
	return card


# (Re)bind the drop/highlight hooks for a persistent creature node to THIS (live)
# BoardRow. Must run every rebuild: the node is reused across views, but the row
# that owns the intent signals is recreated, so a hook captured once would dangle.
func _bind_creature_hooks(card: UiCard, cid: int, mine: bool) -> void:
	if mine:
		# Your creature: a drop target for a creature play-drop or a friendly/any
		# spell; only glow for the spell case.
		card.can_drop_fn = func(data: Variant) -> bool:
			return Rules.can_play_here(_view, data) or Rules.can_cast_on(data, "friendly")
		card.highlight_check = func(data: Variant) -> bool:
			return Rules.can_cast_on(data, "friendly")
		card.drop_fn = func(data: Variant) -> void:
			if Rules.can_cast_on(data, "friendly"):
				cast_requested.emit(data, cid)
			else:
				play_requested.emit(data)
	else:
		# Enemy creature: accept an attacker (provoke/stealth permitting) or an
		# enemy/any spell. Reads the live cr from meta (the node is reused).
		card.can_drop_fn = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY:
				return false
			var c: Dictionary = card.get_meta("cr")
			if data.get("kind", "") == "attacker":
				return Rules.valid_attack_target(_view, c)
			return Rules.can_cast_on(data, "enemy") and not bool(c.get("stealth", false))
		card.drop_fn = func(data: Variant) -> void:
			if data.get("kind", "") == "attacker":
				attack_requested.emit(int(data["id"]), cid)
			else:
				cast_requested.emit(data, cid)


# Update an existing creature node for fresh data: rebind its hooks to this live
# row, store the live cr, rebuild the inner content (face + ability dock + ready
# pulse) on the same outer node so its identity (and any in-flight animation)
# survives, and refresh the attack/dim state.
func _refresh_creature(card: UiCard, cr: Dictionary, mine: bool) -> void:
	_bind_creature_hooks(card, int(cr["id"]), mine)
	card.set_meta("cr", cr)
	for ch in card.get_children():
		card.remove_child(ch)
		ch.queue_free()
	var def_id := String(cr["card"])
	var face := CardView.face(def_id, cr)
	card.add_child(face)
	card.tooltip_text = CardData.name_of(def_id)
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
		var can_attack := Rules.my_turn(_view) and int(cr.get("atk", 0)) > 0 \
			and int(cr.get("frozen", 0)) == 0 and int(cr.get("blind", 0)) == 0 \
			and not bool(cr.get("sick", false)) and not bool(cr.get("attacked", false))
		card.payload = {
			"kind": "attacker", "id": cid, "draggable": can_attack,
			"bypass": CardData.has_keyword(def_id, "bypass"),
		}
		card.drag_label = CardData.name_of(def_id)
		# On your turn, dim creatures that cannot attack so the ready ones glow.
		if Rules.my_turn(_view) and not can_attack:
			card.modulate = Color(0.6, 0.62, 0.7, 0.92)
			card.rest_modulate = Color(0.6, 0.62, 0.7, 0.92)
		else:
			card.modulate = Color.WHITE
			card.rest_modulate = Color.WHITE
			if can_attack:
				_anim.ready_pulse(card)
		# Activated abilities (e.g. germinate): icon buttons along the bottom edge,
		# added to the face (a Panel that respects anchors).
		var dock := _ability_dock(cr, cid)
		if dock != null:
			face.add_child(dock)
	else:
		card.payload = {}
		card.modulate = Color.WHITE
		card.rest_modulate = Color.WHITE


# --- activated abilities -----------------------------------------------------

# An activated-ability keyword -> its dock icon and accent (empty = not one).
static func _ability_meta(kid: String) -> Dictionary:
	match kid:
		"germinate":
			return {"icon": "leaf", "accent": Color(0.38, 0.82, 0.46)}
		"spark":
			return {"icon": "spark", "accent": Color(0.95, 0.43, 0.36)}
	return {}


func _ability_dock(cr: Dictionary, cid: int) -> Control:
	var dock := HBoxContainer.new()
	dock.add_theme_constant_override("separation", 4)
	dock.alignment = BoxContainer.ALIGNMENT_CENTER
	dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for kw in CardData.def(String(cr["card"])).get("keywords", []):
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
	b.add_theme_stylebox_override("normal", Tokens.round_style(frame_col, ready))
	b.add_theme_stylebox_override("hover", Tokens.round_style(frame_col.lightened(0.25), ready))
	b.add_theme_stylebox_override("pressed", Tokens.round_style(frame_col, true))
	b.add_theme_stylebox_override("disabled", Tokens.round_style(frame_col, false))
	# Styled hover panel (a non-empty tooltip_text is still required to trigger).
	b.tooltip_text = Glossary.keyword_name({"id": kid, "n": CardData.keyword_n(String(cr["card"]), kid)})
	b.tooltip_builder = func() -> Control: return _ability_tooltip_panel(cr, kid, used)
	b.pressed.connect(func() -> void:
		Audio.play("ui_click")
		activate_requested.emit(cid))
	return b


func _can_ability(cr: Dictionary, kid: String) -> bool:
	return _ability_reason(cr, kid) == ""


# Why this ability can't be used right now (specific), or "" if it can.
func _ability_reason(cr: Dictionary, kid: String) -> String:
	if not Rules.my_turn(_view):
		return "Не ваш ход."
	if bool(cr.get("usedActive", false)):
		return "Уже использовано в этом ходу."
	var you := int(_view["you"])
	var me: Dictionary = _view["players"][you]
	match kid:
		"germinate":
			if int(me.get("board", []).size()) >= Rules.BOARD_LIMIT:
				return "Стол заполнен (%d существ)." % Rules.BOARD_LIMIT
			if _mana_total(me) < 1:
				return "Нет свободного кристалла (нужен 1)."
		"spark":
			if _mana_total(me) < 1:
				return "Нет свободного кристалла (нужен 1)."
	return ""


func _mana_total(me: Dictionary) -> int:
	var avail: Dictionary = me["mana"].get("available", {})
	var total := 0
	for c in CardData.ALL_COLORS:
		total += int(avail.get(c, 0))
	return total


func _ability_tooltip_panel(cr: Dictionary, kid: String, used: bool) -> Control:
	var meta := _ability_meta(kid)
	var acc: Color = meta["accent"]
	var kw := {"id": kid, "n": CardData.keyword_n(String(cr["card"]), kid)}

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
