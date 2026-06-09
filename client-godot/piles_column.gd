class_name PilesColumn
extends VBoxContainer

# The right-flank column for one player: the mana crystals (height-capped scroll),
# your peekable awaken cards / an enemy's floodlit banked cards, the deck and
# graveyard stacks, and the hand count. Built from the view via Rules/CardData --
# the only thing it reports back is `awaken_clicked` (the click-to-awaken fallback;
# dragging an awaken chip is data-driven through its payload). For the owner's side
# it also exposes the chrome nodes the coordinator pulses on change.

signal awaken_clicked(payload: Dictionary)

# Pulse targets for the owner's side (read by Main._animate_piles); null for the enemy.
var mana_node: Control = null
var deck_node: Control = null
var grave_node: Control = null


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
	return float(mini(int(ceil(float(total) / 4.0)), 3) * 40)


func setup(p: Dictionary, mine: bool, view: Dictionary) -> void:
	custom_minimum_size = Vector2(142, 0)
	size_flags_vertical = Control.SIZE_FILL
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 8)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

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
	mana_sc.custom_minimum_size = Vector2(140, cap_h(p.get("mana", {})))
	mana_sc.add_child(Chrome.mana_pips(p.get("mana", {})))
	mana_block.add_child(mana_sc)
	add_child(mana_block)

	var mr := _manarow(p.get("manaRow", []), mine, view)
	if mr != null:
		add_child(mr)

	var piles := HBoxContainer.new()
	piles.alignment = BoxContainer.ALIGNMENT_CENTER
	piles.add_theme_constant_override("separation", 12)
	piles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var deck_stack := Chrome.pile_stack(int(p.get("deckCount", 0)), "колода", Color(0.5, 0.7, 0.95))
	var grave_stack := Chrome.pile_stack(int(p.get("graveyardCount", 0)), "сброс", Color(0.62, 0.6, 0.68))
	piles.add_child(deck_stack)
	piles.add_child(grave_stack)
	add_child(piles)

	# The owner's chrome nodes, so the coordinator can pulse them on change.
	if mine:
		mana_node = mana_block
		deck_node = deck_stack
		grave_node = grave_stack

	var il := Ui.label("рука %d" % int(p.get("handCount", 0)), 11, Color(0.6, 0.64, 0.74), true)
	il.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(il)


# The banked cards themselves are just hidden mana (their count shows as crystals),
# so we surface only your own awaken-able cards (or, under floodlight, every enemy
# banked card). Returns null when there is nothing to show; height-capped + scrolls.
func _manarow(mana_row: Array, mine: bool, view: Dictionary) -> Control:
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
	var cap := 0.0
	if mine:
		# Your awaken cards stay full interactive chips (usually few); cap ~2 tall.
		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 3)
		for c in slots:
			inner.add_child(_awaken_chip(int(c["i"]), c["slot"], view))
		sc.add_child(inner)
		cap = mini(slots.size(), 2) * 57.0
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
		cap = mini(rows, 2) * 39.0  # show up to 2 rows, scroll the rest
	sc.custom_minimum_size = Vector2(138, cap)
	box.add_child(sc)
	return box


# A compact peek thumbnail (floodlight): art only, with the full hover tooltip.
func _revealed_thumb(card_id: String, color: String) -> Control:
	var t := UiCard.new()
	t.custom_minimum_size = Vector2(36, 36)
	t.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.09, 0.10, 0.15, 0.92), 6, 1, Color(0.7, 0.62, 0.32), 2))
	t.tooltip_text = CardData.name_of(card_id)
	t.tooltip_builder = func() -> Control: return CardView.tooltip(card_id, null)
	t.hoverable = true
	t.add_child(Tokens.art(card_id, 30, Palette.color_for(color)))
	return t


# A peekable awaken card in your mana row: a mini-card (art + name + tag) with a
# gold frame. It brightens and glows once you can pay for it this turn; otherwise
# it is dimmed. A decoy that has aged enough awakens for just its own crystal.
func _awaken_chip(idx: int, slot: Dictionary, view: Dictionary) -> Control:
	var card_id := String(slot["card"])
	var color := String(slot.get("color", "colorless"))
	var age := int(slot.get("age", 0))
	var free := CardData.has_keyword(card_id, "decoy") and age >= CardData.keyword_n(card_id, "decoy")
	var gold := Color(0.95, 0.85, 0.3)
	var affordable := Rules.can_awaken(view, card_id, color, age)
	var chip := UiCard.new()
	chip.custom_minimum_size = Vector2(132, 54)
	var sb := Ui.bordered(Color(0.09, 0.10, 0.15, 0.94), 8, 2,
		gold if affordable else gold.darkened(0.4), 5)
	if affordable:
		sb.shadow_size = 10
		sb.shadow_color = Color(gold.r, gold.g, gold.b, 0.6)
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
