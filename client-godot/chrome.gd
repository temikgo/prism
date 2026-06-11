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


# Mana crystals in color order, wrapping within the flank column width. All
# crystals share ONE HFlowContainer (not a per-color HBox each), so its minimum
# width stays one crystal wide -- a tall single-color pool wraps to new rows
# instead of stretching one row and shoving the creature board sideways. Colors
# stay clustered by adjacency; PER_ROW (the count that fits the column) keeps
# cap_h's row estimate in sync with the actual wrap.
const PER_ROW := 5


static func mana_pips(mana: Dictionary) -> Control:
	var flow := HFlowContainer.new()
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 3)
	flow.custom_minimum_size = Vector2(134, 0)
	var avail: Dictionary = mana.get("available", {})
	var total: Dictionary = mana.get("crystals", {})
	var any := false
	for color in CardData.ALL_COLORS:
		var t := int(total.get(color, 0))
		var av := int(avail.get(color, 0))
		# Show permanent crystals plus any temporary mana on top (available beyond
		# the permanent stock -- e.g. photosynthesis ramp), so bonus mana is visible.
		var count := maxi(t, av)
		if count <= 0:
			continue
		any = true
		for i in count:
			flow.add_child(Ui.mana_pip(color, i < av, i >= t))
	if not any:
		var l := Ui.label("нет маны", 11, Color(0.5, 0.53, 0.62))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		flow.add_child(l)
	return flow


# A deck/graveyard pile: up to three offset card-backs with the count on top.
static func pile_stack(count: int, label: String, accent: Color) -> Control:
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
	var cl := Ui.label(str(count), 18, accent.lightened(0.5), true)
	cl.add_theme_font_override("font", Fonts.BLACK)
	cl.add_theme_constant_override("outline_size", 5)
	cl.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 0.9))
	cl.size = Vector2(w, h)
	cl.position = Vector2((depth - 1) * 3, 0)
	cl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(cl)
	box.add_child(stack)
	var ll := Ui.label(label, 10, Color(0.64, 0.68, 0.78), true, true)
	ll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ll)
	return box
