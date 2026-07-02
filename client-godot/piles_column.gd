class_name PilesColumn
extends VBoxContainer

# The right-flank column for one player: the mana crystals (height-capped scroll),
# your peekable awaken cards / an enemy's floodlit banked cards, the deck and
# graveyard stacks, and the hand count. Built from the view via Rules/CardData --
# the only thing it reports back is `awaken_clicked` (the click-to-awaken fallback;
# dragging an awaken chip is data-driven through its payload). For the owner's side
# it also exposes the chrome nodes the coordinator pulses on change.

signal awaken_clicked(payload: Dictionary)
signal peek_requested(card_id: String)   # click a floodlit enemy crystal to peek it

# Pulse targets (read by Main._animate_piles) -- exposed for both sides so the
# coordinator can pulse the deck/discard/hand counts whenever they change.
var mana_node: Control = null
var deck_node: Control = null
var grave_node: Control = null
var hand_node: Control = null


# Capped height for the mana crystal scroll: ~one row per ~4 crystals, capped at 3
# rows. Beyond that the crystals scroll instead of growing the column (which would
# push the hand off the bottom on a tall mana pool).
static func cap_h(mana: Dictionary) -> float:
	var crystals: Dictionary = mana.get("crystals", {})
	var avail: Dictionary = mana.get("available", {})
	var total := 0
	for color in CardData.ALL_COLORS:
		total += maxi(int(crystals.get(color, 0)), int(avail.get(color, 0)))
	if total <= 0:
		return 26.0  # the "нет маны" line
	# Crystals all share one wrapping flow now, so rows = ceil(total / PER_ROW);
	# cap at 3 rows -- beyond that the pool scrolls instead of growing the column.
	var rows := int(ceil(float(total) / float(Chrome.PER_ROW)))
	return float(mini(rows, 3) * 40)


func setup(p: Dictionary, mine: bool, view: Dictionary) -> void:
	custom_minimum_size = Vector2(142, 0)
	size_flags_vertical = Control.SIZE_FILL
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 8)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The Spectrum: a fixed "СПЕКТР" tag + a height-capped scroll of the crystals, so
	# a huge pool scrolls instead of growing the column and clipping the hand below.
	# (The zone is the player's accumulated colours of light; the resource is mana.)
	var mana_block := VBoxContainer.new()
	mana_block.alignment = BoxContainer.ALIGNMENT_CENTER
	mana_block.add_theme_constant_override("separation", 3)
	mana_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mana_tag := Ui.label("СПЕКТР", 10, Color(0.66, 0.7, 0.82), true, true)
	mana_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mana_block.add_child(mana_tag)
	# Height-capped, wheel-scrollable clip that keeps the crystal rows at full width
	# (so they stay centred) -- a tall pool scrolls instead of growing the column or
	# breaking the centring (which a plain ScrollContainer would).
	var mana_scroll := ScrollClip.new()
	# Floodlit enemy crystals are built from the manaRow (each = a banked card you can
	# click to peek); otherwise the crystals are the plain colour-count pips.
	var crystals: Control
	if not mine and _has_revealed(p.get("manaRow", [])):
		crystals = _floodlit_crystals(p.get("manaRow", []), p.get("mana", {}))
	else:
		crystals = Chrome.mana_pips(p.get("mana", {}))
	mana_scroll.setup(crystals, cap_h(p.get("mana", {})))
	mana_block.add_child(mana_scroll)
	add_child(mana_block)

	var mr := _manarow(p.get("manaRow", []), mine, view)
	if mr != null:
		add_child(mr)

	# Deck / discard / hand as three glass tiles in a row. Deck and discard are real
	# stacks (stack illusion); the hand tile is the side-tinted variant (no stack).
	var side := Ui.SIDE_ME if mine else Ui.SIDE_FOE
	var piles := HBoxContainer.new()
	piles.alignment = BoxContainer.ALIGNMENT_CENTER
	piles.add_theme_constant_override("separation", 9)
	piles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var deck_stack := Chrome.pile_stack(int(p.get("deckCount", 0)), "колода", side)
	var grave_stack := Chrome.pile_stack(int(p.get("graveyardCount", 0)), "сброс", side)
	var hand_stack := Chrome.pile_stack(int(p.get("handCount", 0)), "рука", side, true)
	piles.add_child(deck_stack)
	piles.add_child(grave_stack)
	piles.add_child(hand_stack)
	add_child(piles)

	# Chrome nodes for both sides, so the coordinator can pulse them on a count
	# change -- yours on your turn, the enemy's on theirs (they drew / discarded).
	mana_node = mana_block
	deck_node = deck_stack
	grave_node = grave_stack
	hand_node = hand_stack


# Your awaken cards as peekable chips. (The enemy's floodlit cards are no longer a
# separate thumbnail row -- their crystals in the Spectrum are clickable to peek,
# see _floodlit_crystals.) Returns null when you have no awaken cards banked.
func _manarow(mana_row: Array, mine: bool, view: Dictionary) -> Control:
	if not mine:
		return null
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
	var tag := Ui.label("разбудить:", 11, Color(0.95, 0.85, 0.4), true)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(tag)
	var inner := VBoxContainer.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_constant_override("separation", 4)
	for c in slots:
		inner.add_child(_awaken_chip(int(c["i"]), c["slot"], view))
	# One or two chips stack directly so the hover-lift isn't clipped. But a facet
	# hero makes every banked crystal awakable -- past two, cap the height and scroll
	# (like the Spectrum) instead of growing the column and shoving the piles off-screen.
	if slots.size() <= 2:
		box.add_child(inner)
	else:
		var scroll := ScrollClip.new()
		scroll.setup(inner, 132.0)  # ~2 chips tall + a peek of the next
		box.add_child(scroll)
	return box


func _has_revealed(mana_row: Array) -> bool:
	for slot in mana_row:
		if slot.has("card"):
			return true
	return false


# The enemy's Spectrum under floodlight: each banked card becomes a crystal you can
# click to peek (a yellow spotlight rim marks them). Built from the manaRow (every
# slot = one crystal); available/spent is approximated from the colour counts.
func _floodlit_crystals(mana_row: Array, mana: Dictionary) -> Control:
	var avail: Dictionary = mana.get("available", {})
	var by_color := {}
	for slot in mana_row:
		var col := String(slot.get("color", "colorless"))
		if not by_color.has(col):
			by_color[col] = []
		by_color[col].append(slot)
	var cells := []
	for color in CardData.ALL_COLORS:
		if not by_color.has(color):
			continue
		var slots: Array = by_color[color]
		var av := int(avail.get(color, 0))
		for i in slots.size():
			cells.append(_floodlit_crystal(color, String(slots[i].get("card", "")), i < av))
	return Chrome.crystal_rows(cells)


func _floodlit_crystal(color: String, card_id: String, available: bool) -> Control:
	var cell := Control.new()
	cell.custom_minimum_size = Vector2(22, 30)
	var peekable := card_id != ""
	cell.mouse_filter = Control.MOUSE_FILTER_STOP if peekable else Control.MOUSE_FILTER_IGNORE
	if peekable:
		cell.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var cr := CrystalNode.new()
	cr.crystal_color = Palette.crystal_color(color)
	cr.spent = not available
	cr.floodlit = peekable
	cr.set_anchors_preset(Control.PRESET_FULL_RECT)
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(cr)
	if peekable:
		cell.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				peek_requested.emit(card_id))
	return cell


# A peekable awaken card in your mana row: a mini-card (art + name + tag) with a
# gold frame. It brightens and glows once you can pay for it this turn; otherwise
# it is dimmed. A decoy that has aged enough awakens for just its own crystal.
func _awaken_chip(idx: int, slot: Dictionary, view: Dictionary) -> Control:
	var card_id := String(slot["card"])
	var gold := Ui.GOLD
	var color := String(slot.get("color", "colorless"))  # the banked crystal's colour
	# A decoy aged past its threshold wakes for just its own crystal (no surcharge).
	var free := CardData.has_keyword(card_id, "decoy") \
		and int(slot.get("age", 0)) >= CardData.keyword_n(card_id, "decoy")
	# Engine-authoritative: the server marks each banked slot canAwaken (dup-aura,
	# caps, cost, target all decided by legalActions) -- no client re-derivation.
	var affordable := bool(slot.get("canAwaken", false))
	var chip := UiCard.new()
	chip.custom_minimum_size = Vector2(132, 54)
	# Clean dark-glass chip (no gold wash): a thin gold rim + a lit top edge, and a
	# soft gold glow only when you can awaken it this turn -- dim, no glow, otherwise.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.055, 0.062, 0.10, 0.96)  # opaque dark, so no glow/art bleeds into a muddy fill
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.border_color = Color(gold.r, gold.g, gold.b, 0.6 if affordable else 0.22)
	sb.set_content_margin_all(5)
	if affordable:
		sb.shadow_size = 12
		sb.shadow_color = Color(gold.r, gold.g, gold.b, 0.45)
	chip.add_theme_stylebox_override("panel", sb)
	chip.tooltip_text = CardData.name_of(card_id)
	chip.tooltip_builder = func() -> Control: return CardView.tooltip(card_id, null)
	chip.hoverable = true
	if not affordable:
		chip.modulate = Color(0.62, 0.62, 0.68, 0.92)
		chip.rest_modulate = chip.modulate
	chip.payload = {
		"kind": "awaken", "manaRowIndex": idx, "card_id": card_id,
		"needs_target": CardData.needs_target(card_id), "draggable": Rules.my_turn(view),
		"target_side": CardData.target_side(card_id),
	}
	chip.drag_label = "awaken: " + CardData.name_of(card_id)
	chip.clicked.connect(func(p: Dictionary) -> void: awaken_clicked.emit(p))

	# Art + a short status tag only (the name shows on hover) -- no wrapping text.
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(Tokens.art(card_id, 42, Palette.color_for(color)))
	var tag_txt := "без доплаты" if free else "разбудить"
	var tag := Ui.label(tag_txt, 11, gold if affordable else gold.darkened(0.25))
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tag)
	chip.add_child(row)
	return chip
