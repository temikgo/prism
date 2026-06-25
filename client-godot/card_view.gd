class_name CardView

# The card visual: the fixed-size face (art + cost/atk/hp/status, no text), the
# hover tooltip (name + generated rules + flavor + live statuses), and widget() --
# the interactive UiCard wrapping face + tooltip + drag preview. Pure builders --
# read CardData/Glossary/Palette/Tokens/Ui, take plain data, return Controls.

# Full card visual as a fixed-size Control with everything anchored to corners, so
# the size is constant regardless of contents (card and drag preview alike).
static func face(def_id: String, runtime, thumb := false) -> Control:
	var d: Dictionary = CardData.def(def_id)
	var has_stats: bool = d.has("stats") or (typeof(runtime) == TYPE_DICTIONARY and runtime.has("atk"))
	var face_node := Panel.new()
	face_node.custom_minimum_size = Tokens.CARD_SIZE
	face_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Rounded dark body; clip_children rounds the art/rim to it. The panel itself
	# still draws normally, so the card's outer color glow (set in Main) shows.
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.05, 0.05, 0.08)
	body.set_corner_radius_all(12)
	face_node.add_theme_stylebox_override("panel", body)
	face_node.clip_children = CanvasItem.CLIP_CHILDREN_ONLY

	# Color rim: the gradient sits full-rect; the art is inset by RIM so the
	# gradient only shows as a thin glowing edge (the card's color identity).
	var frame := TextureRect.new()
	frame.texture = _frame_texture(d)
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face_node.add_child(frame)

	# Art fills the whole card (full-bleed, minus the thin rim).
	var art := Tokens.art(def_id, 0.0, Palette.primary(d), thumb)
	_anchor_inset(art, Tokens.RIM)
	face_node.add_child(art)

	# State is shown by the status icons (snowflake/moon/...) only -- no colour-wash
	# overlay over the art.

	# Legibility scrims: a soft dark fade at the top (under cost/status) and bottom
	# (under the stat gems) so chrome reads over any bright art. The card name is
	# intentionally NOT drawn on the face -- it shows on hover, so the face never
	# risks clipped text.
	face_node.add_child(_scrim(true, Tokens.GEM + Tokens.PAD))
	face_node.add_child(_scrim(false, Tokens.GEM + Tokens.PAD))

	# Cost badge (top-left): generic number plus one colored pip per colored pip.
	var cost_badge := _cost_badge(d.get("cost", {}))
	cost_badge.anchor_left = 0
	cost_badge.anchor_top = 0
	cost_badge.anchor_right = 0
	cost_badge.anchor_bottom = 0
	cost_badge.offset_left = Tokens.PAD
	cost_badge.offset_top = Tokens.PAD
	cost_badge.offset_right = Tokens.PAD
	cost_badge.offset_bottom = Tokens.PAD
	cost_badge.grow_horizontal = Control.GROW_DIRECTION_END
	cost_badge.grow_vertical = Control.GROW_DIRECTION_END
	face_node.add_child(cost_badge)

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
		_anchor_corner(atk_gem, 0, 1, Tokens.PAD, -Tokens.GEM - Tokens.PAD)
		face_node.add_child(atk_gem)
		var hp_color := Color(0.55, 0.95, 0.5) if hp >= max_hp else Color(0.97, 0.4, 0.4)
		var hp_gem := _gem(str(hp), hp_color)
		_anchor_corner(hp_gem, 1, 1, -Tokens.GEM - Tokens.PAD, -Tokens.GEM - Tokens.PAD)
		face_node.add_child(hp_gem)

	# Status icons (top-right), right-aligned and growing left, capped with +N.
	if typeof(runtime) == TYPE_DICTIONARY:
		var status_row = _status_icons(runtime)
		if status_row != null:
			status_row.anchor_left = 1
			status_row.anchor_right = 1
			status_row.offset_left = -Tokens.PAD
			status_row.offset_right = -Tokens.PAD
			status_row.offset_top = Tokens.PAD
			status_row.offset_bottom = Tokens.PAD
			status_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			status_row.grow_vertical = Control.GROW_DIRECTION_END
			face_node.add_child(status_row)
	return face_node


# An interactive card widget: a UiCard wrapping the face, a glow in the card's
# color, the hover tooltip and a centered drag preview. The draggable/clickable
# unit used by the hand and the mulligan/scry pickers.
static func widget(def_id: String, runtime) -> UiCard:
	var card := UiCard.new()
	card.custom_minimum_size = Tokens.CARD_SIZE
	# Neon glow in the card's own color (drawn behind the rounded face, not clipped).
	var col := Palette.primary(CardData.def(def_id))
	var glow := StyleBoxFlat.new()
	glow.bg_color = Color(0, 0, 0, 0)
	glow.set_corner_radius_all(12)
	glow.shadow_size = 10
	glow.shadow_color = Color(col.r, col.g, col.b, 0.6)
	card.add_theme_stylebox_override("panel", glow)
	card.add_child(face(def_id, runtime))
	# Pretty hover tooltip (built lazily); a non-empty tooltip_text is still required
	# for the tooltip to trigger.
	card.tooltip_text = CardData.name_of(def_id)
	card.tooltip_builder = func() -> Control: return tooltip(def_id, runtime)
	card.hoverable = true
	# The drag preview is the card itself, centered under the cursor.
	card.preview_builder = func() -> Control:
		var wrapper := Control.new()
		var f := face(def_id, runtime)
		f.size = Tokens.CARD_SIZE
		f.position = -Tokens.CARD_SIZE / 2.0
		wrapper.add_child(f)
		return wrapper
	return card


# Compact text-only card info on hover: name, cost, type, generated rules, flavor,
# live statuses. Godot anchors and clamps it to the viewport.
static func tooltip(def_id: String, runtime = null) -> Control:
	var d: Dictionary = CardData.def(def_id)
	var col := Palette.primary(d)

	# The description is framed in the card's colours: a gradient border through all
	# of them (a single colour reads as solid).
	var colors := []
	for c in d.get("color", []):
		colors.append(Palette.color_for(String(c)))
	var border := GradientBorder.new()
	border.setup(colors, Color(0.10, 0.11, 0.15, 0.98))

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.custom_minimum_size = Vector2(250, 0)
	border.add_child(v)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	var name_lbl := Ui.label(CardData.name_of(def_id), 19, col.lightened(0.45), false, true)
	name_lbl.add_theme_font_override("font", Fonts.BLACK)
	header.add_child(name_lbl)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sp)
	# Creatures show their stats; then the full cost with its coloured pips.
	if String(d.get("type", "")) == "creature":
		var atk := 0
		var hp := 0
		var max_hp := 0
		if typeof(runtime) == TYPE_DICTIONARY and runtime.has("atk"):
			atk = int(runtime["atk"]); hp = int(runtime["hp"]); max_hp = int(runtime.get("maxHp", hp))
		elif d.has("stats"):
			atk = int(d["stats"].get("atk", 0)); hp = int(d["stats"].get("hp", 0)); max_hp = hp
		header.add_child(_gem(str(atk), Color(0.95, 0.8, 0.35)))
		header.add_child(_gem(str(hp), Color(0.55, 0.95, 0.5) if hp >= max_hp else Color(0.97, 0.4, 0.4)))
	header.add_child(_cost_badge(d.get("cost", {})))
	v.add_child(header)

	v.add_child(Ui.label(Glossary.type_label(d), 12, Color(0.6, 0.65, 0.75)))

	# Rules are generated from the card's data (single source of truth). The bold
	# "headline" is the card's printed text: keyword names plus the on_play effects,
	# prefixed by a precise "when" -- "При выходе:" for a creature, or "Через N
	# ход(ов):" when delay folds the timing in. Below it, each keyword is explained.
	var is_creature := String(d.get("type", "")) == "creature"
	# An illusion (token copy) inherits the original's keywords but can never
	# create more illusions, so haunt/split are inert on it -- hide them from the
	# generated rules so the text matches what the copy actually does.
	var illusion := typeof(runtime) == TYPE_DICTIONARY and bool(runtime.get("token", false))
	var delay_n := CardData.keyword_n(def_id, "delay")
	var effs := []
	for e in d.get("effects", []):
		if String(e.get("trigger", "")) == "on_play":
			var s := Glossary.effect_text(e)
			if s != "":
				effs.append(s)
	# Delay is shown as the effect's timing, not as a separate keyword.
	var fold_delay := delay_n > 0 and not effs.is_empty()

	# Keyword names are highlighted in the card's own colour so the rules read
	# with hierarchy (the name pops, the explanation stays calm).
	var kc := col.lightened(0.42).to_html(false)
	var head := ""
	for kw in d.get("keywords", []):
		var hid := String(kw.get("id", ""))
		if fold_delay and hid == "delay":
			continue
		if illusion and (hid == "haunt" or hid == "split"):
			continue
		var nm := Glossary.keyword_name(kw)
		if nm != "":
			head += "[b][color=#%s]%s[/color][/b]. " % [kc, nm]
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
		v.add_child(rich(head, 14, Color(0.9, 0.92, 0.97)))

	# Detailed keyword explanations (the bold name, then its meaning).
	var details := []
	var shown := {}
	for kw in d.get("keywords", []):
		var did := String(kw.get("id", ""))
		if fold_delay and did == "delay":
			continue
		if illusion and (did == "haunt" or did == "split"):
			continue
		var full := Glossary.keyword(kw)
		if full == "":
			continue
		shown[String(kw.get("id", ""))] = true
		var ci := full.find(":")
		details.append("[b][color=#%s]%s[/color][/b]%s" % [kc, full.substr(0, ci), full.substr(ci)] if ci > 0 else full)
	# Effects that apply a named status (freeze/blind) explain that status
	# too, even when the card carries no matching keyword.
	for e in d.get("effects", []):
		if String(e.get("trigger", "")) != "on_play":
			continue
		var act := String(e.get("action", ""))
		if act == "" or shown.has(act) or not Glossary.KW.has(act):
			continue
		shown[act] = true
		var fx: String = Glossary.keyword({"id": act, "n": int(e.get("value", 0))})
		var cix := fx.find(":")
		details.append("[b][color=#%s]%s[/color][/b]%s" % [kc, fx.substr(0, cix), fx.substr(cix)] if cix > 0 else fx)
	if not details.is_empty():
		for dline in details:
			v.add_child(rich(dline, 12, Color(0.74, 0.8, 0.64)))

	# Optional flavor (lore) line, shown dim under the rules when present.
	var flavor := CardData.text_of(def_id)
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
	return border


# A wrapping label that honours [b]bold[/b] BBCode, for rules text. Shared by the
# card tooltip and the hero/ability tooltips in Main.
static func rich(bb: String, size: int, color: Color) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.custom_minimum_size = Vector2(250, 0)
	# Real weights so [b] keyword names read as bold (not faux-bold), in Manrope.
	r.add_theme_font_override("normal_font", Fonts.REGULAR)
	r.add_theme_font_override("bold_font", Fonts.BOLD)
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	r.add_theme_color_override("default_color", color)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.text = bb
	return r


# --- internal face sub-builders ---------------------------------------------

static func _gem(text: String, ring: Color) -> Control:
	return Tokens.gem(text, ring, Tokens.GEM, 17, false, 0.94)


# A vertical dark gradient legibility scrim under the top/bottom chrome.
static func _scrim(from_top: bool, height: float) -> TextureRect:
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
	tr.offset_left = Tokens.RIM
	tr.offset_right = -Tokens.RIM
	if from_top:
		tr.anchor_top = 0
		tr.anchor_bottom = 0
		tr.offset_top = Tokens.RIM
		tr.offset_bottom = Tokens.RIM + height
	else:
		tr.anchor_top = 1
		tr.anchor_bottom = 1
		tr.offset_top = -Tokens.RIM - height
		tr.offset_bottom = -Tokens.RIM
	return tr


static func _anchor_inset(node: Control, inset: float) -> void:
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.offset_left = inset
	node.offset_top = inset
	node.offset_right = -inset
	node.offset_bottom = -inset


static func _anchor_corner(node: Control, ax: float, ay: float, ox: float, oy: float) -> void:
	# Pin a GEM-sized node to corner (ax,ay in {0,1}) with offset (ox,oy).
	node.anchor_left = ax
	node.anchor_right = ax
	node.anchor_top = ay
	node.anchor_bottom = ay
	node.offset_left = ox
	node.offset_right = ox + Tokens.GEM
	node.offset_top = oy
	node.offset_bottom = oy + Tokens.GEM


static func _frame_texture(d: Dictionary) -> Texture2D:
	var cols := PackedColorArray()
	var card_colors: Array = d.get("color", [])
	if card_colors.is_empty():
		# Colorless: a clean white frame. The prismatic rainbow is reserved for a
		# card that genuinely carries all five colors.
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


static func _cost_badge(cost: Dictionary) -> Control:
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
	for c in CardData.COLORS:
		if int(cost.get(c, 0)) > 0:
			has_color = true
	# Show the generic number when there is one, or when the card is free of any
	# colored pips (so a "0" still appears instead of an empty badge).
	if gen > 0 or not has_color:
		var n := Ui.label(str(gen), 18, Color(0.95, 0.96, 1.0))
		n.add_theme_font_override("font", Fonts.NUM_BOLD)
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(n)
	for c in CardData.COLORS:
		for _i in int(cost.get(c, 0)):
			box.add_child(Ui.cost_pip(c))
	pill.add_child(box)
	return pill


static func _status_icons(cr: Dictionary) -> Control:
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
	var shown: int = mini(specs.size(), Tokens.STATUS_MAX)
	for i in shown:
		row.add_child(Ui.icon(specs[i][0], 20, specs[i][1]))
	if specs.size() > Tokens.STATUS_MAX:
		var more := Ui.label("+%d" % (specs.size() - Tokens.STATUS_MAX), 13, Color(0.92, 0.94, 1.0))
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
