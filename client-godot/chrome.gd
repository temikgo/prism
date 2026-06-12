class_name Chrome

# Pure board-chrome visuals: the turn banner and the right-flank mana pips and
# deck/graveyard pile stacks. No game state -- callers pass resolved text/values.

# A centered header pill that glows in `col`, with a small diamond on each side.
static func banner(txt: String, col: Color) -> Control:
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
	row.add_child(_diamond(col))
	var bl := Ui.label(txt, 17, col.lightened(0.5), true, true)
	bl.add_theme_font_override("font", Fonts.BLACK)
	row.add_child(bl)
	row.add_child(_diamond(col))
	pill.add_child(row)
	var center := HBoxContainer.new()
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(pill)
	return center


static func _diamond(col: Color) -> Control:
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


# "МАНА" label over the wrapping crystal pips.
static func mana_block(mana: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	var tag := Ui.label("МАНА", 10, Color(0.66, 0.7, 0.82), true, true)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(tag)
	box.add_child(mana_pips(mana))
	return box


# Mana crystals in colour order as centred rows: a VBox of HBoxContainers, each
# ALIGNMENT_CENTER. An HBox row centres its crystals on the column axis reliably --
# the same way the deck/discard piles row centres -- so the crystals line up under
# the centred "МАНА" tag for any count (unlike an HFlowContainer, which left-packs).
# PER_ROW crystals per row; "нет маны" is a single centred row. Colours stay
# clustered by adjacency. Caller caps the height (see PilesColumn).
const PER_ROW := 5


static func mana_pips(mana: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	var avail: Dictionary = mana.get("available", {})
	var total: Dictionary = mana.get("crystals", {})
	# Flatten to an ordered crystal list: [color, available_this_turn, is_temporary].
	var pips := []
	for color in CardData.ALL_COLORS:
		var t := int(total.get(color, 0))
		var av := int(avail.get(color, 0))
		var count := maxi(t, av)  # permanent crystals + any temporary ramp on top
		for i in count:
			pips.append([color, i < av, i >= t])
	if pips.is_empty():
		box.add_child(_mana_row([Ui.label("нет маны", 11, Color(0.5, 0.53, 0.62))]))
		return box
	var i := 0
	while i < pips.size():
		var cells := []
		for j in range(i, mini(i + PER_ROW, pips.size())):
			cells.append(Ui.mana_pip(pips[j][0], pips[j][1], pips[j][2]))
		box.add_child(_mana_row(cells))
		i += PER_ROW
	return box


# One centred row of crystal cells (or the "нет маны" label).
static func _mana_row(cells: Array) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in cells:
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(c)
	return row


# A deck / discard / hand pile: a glass tile holding the count (heavy, glowing),
# with the label BELOW the tile -- on the column's full width, so a long Russian
# caption ("КОЛОДА") stays readable instead of being crammed inside a small tile.
# The hand tile tints its rim to the side accent (it isn't a physical pile). The
# returned VBox is the pulse target (Main pulses it when the count changes).
const PILE := Vector2(50, 44)


static func pile_stack(count: int, label: String, side: Color, is_hand := false) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 3)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The glass count tile.
	var tile := Panel.new()
	tile.custom_minimum_size = PILE
	tile.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Ui.PANEL_FILL
	sb.set_corner_radius_all(11)
	sb.set_border_width_all(1)
	sb.border_width_top = 2  # lit top rim
	sb.border_color = Ui.PANEL_STROKE.lerp(side, 0.45) if is_hand else Ui.PANEL_STROKE.lerp(side, 0.12)
	sb.shadow_size = 6
	sb.shadow_color = Color(0, 0, 0, 0.4)
	tile.add_theme_stylebox_override("panel", sb)

	var cl := Ui.label(str(count), 21, Ui.INK, true)
	cl.add_theme_font_override("font", Fonts.NUM_BOLD)
	cl.add_theme_color_override("font_shadow_color", Color(0.47, 0.63, 1.0, 0.45))
	cl.add_theme_constant_override("shadow_offset_x", 0)
	cl.add_theme_constant_override("shadow_offset_y", 0)
	cl.add_theme_constant_override("shadow_outline_size", 6)
	cl.set_anchors_preset(Control.PRESET_FULL_RECT)
	cl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(cl)
	box.add_child(tile)

	# Label on its own line below the tile -- full column width, comfortably readable.
	var ll := Ui.label(label.to_upper(), 10, Ui.INK_DIM, true)
	ll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ll)
	return box
