class_name HeroView

# The hero's visuals: framed portrait, the HP/armor gems overhanging it, and the
# passive-power badge + its hover tooltip. Pure builders. The interactive medallion
# (the enemy face as an attack drop-target) is assembled in Main from these pieces.

const ACCENT := Color(0.8, 0.72, 0.98)  # heroes are off-color (light violet)


# Square portrait with the HP gem overhanging bottom-right (armor bottom-left).
# `accent` frames/glows the portrait in the side colour on the board (blue/red);
# the neutral hero-select screen passes nothing and keeps the off-colour ACCENT.
static func portrait_with_hp(hero: Dictionary, px: float, accent: Color = ACCENT) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(px, px)
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var portrait := _portrait(String(hero.get("card", "")), px, accent)
	portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(portrait)
	var hp := Tokens.gem(str(int(hero.get("hp", 0))), Color(0.95, 0.42, 0.46), 44, 0, true, 0.96)
	hp.position = Vector2(px - 40, px - 40)
	holder.add_child(hp)
	if int(hero.get("armor", 0)) > 0:
		var ar := Tokens.gem(str(int(hero["armor"])), Color(0.72, 0.82, 0.98), 34, 0, true, 0.96)
		ar.position = Vector2(-6, px - 30)
		holder.add_child(ar)
	return holder


# A large framed hero portrait (rounded, bordered, clipped). Falls back to a
# tinted placeholder until art/<heroId>.png exists (see ART_HEROES.md).
static func _portrait(card_id: String, px: float, accent: Color = ACCENT) -> Control:
	var holder := Panel.new()
	holder.custom_minimum_size = Vector2(px, px)
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.15)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.7)
	sb.shadow_size = 16
	sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.4)
	holder.add_theme_stylebox_override("panel", sb)
	holder.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var art := Tokens.art(card_id, px, accent)
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(art)
	# A top-to-bottom sheen over the art: a lit upper edge fading to a dark base, so
	# the portrait reads as glass-cased rather than a flat sticker.
	var sheen := TextureRect.new()
	sheen.set_anchors_preset(Control.PRESET_FULL_RECT)
	sheen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheen.texture = _sheen_tex()
	sheen.stretch_mode = TextureRect.STRETCH_SCALE
	holder.add_child(sheen)
	# A thin bright inner stroke just inside the frame: it reads as a lit bevel and
	# lifts the portrait off the board, so the hero feels framed, not pasted in.
	var inner := Panel.new()
	inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0, 0, 0, 0)
	isb.set_corner_radius_all(12)
	isb.set_border_width_all(1)
	isb.border_color = Color(1, 1, 1, 0.12)
	inner.add_theme_stylebox_override("panel", isb)
	holder.add_child(inner)
	holder.tooltip_text = CardData.name_of(card_id)
	return holder


# A cached vertical sheen gradient (white top -> clear mid -> dark base) painted
# over hero portraits. Built once; reused by every portrait.
static var _sheen: Texture2D = null


static func _sheen_tex() -> Texture2D:
	if _sheen != null:
		return _sheen
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.32, 0.72, 1.0])
	g.colors = PackedColorArray([
		Color(1, 1, 1, 0.14), Color(1, 1, 1, 0.0),
		Color(0.016, 0.02, 0.047, 0.0), Color(0.016, 0.02, 0.047, 0.5)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 64
	_sheen = gt
	return _sheen


# Maps a hero's passive keyword to its tinted icon (icons/<name>.svg).
static func _passive_icon(id: String) -> String:
	match id:
		"spectral_shift": return "prism"
		"palette": return "palette"
		"facet": return "facet"
		"lighteater": return "eclipse"
	return "eye"


# A round badge for the hero's passive: its icon, with a styled hover tooltip.
static func passive_badge(hero: Dictionary, accent: Color = ACCENT) -> Control:
	var passive: Array = hero.get("passive", [])
	if passive.is_empty():
		return null
	var kw: Dictionary = passive[0]
	var badge := UiCard.new()
	badge.custom_minimum_size = Vector2(30, 30)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	badge.add_theme_stylebox_override("panel", Tokens.round_style(accent, false))
	badge.add_child(Ui.icon(_passive_icon(String(kw.get("id", ""))), 18, accent.lightened(0.4)))
	badge.tooltip_text = Glossary.keyword_name(kw)
	badge.tooltip_builder = func() -> Control: return passive_tooltip(hero)
	return badge


static func passive_tooltip(hero: Dictionary) -> Control:
	var passive: Array = hero.get("passive", [])
	var kw: Dictionary = passive[0] if not passive.is_empty() else {}
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		Ui.bordered(Color(0.10, 0.11, 0.15, 0.98), 10, 2, ACCENT, 11))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.custom_minimum_size = Vector2(240, 0)
	panel.add_child(v)
	v.add_child(Ui.label(String(hero.get("name", "Герой")), 16, ACCENT.lightened(0.4)))
	v.add_child(Ui.label("Сила героя · пассив", 11, Color(0.6, 0.64, 0.74)))
	v.add_child(HSeparator.new())
	# The passive: its icon and bold name, then the plain-language explanation.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(Ui.icon(_passive_icon(String(kw.get("id", ""))), 20, ACCENT.lightened(0.3)))
	head.add_child(Ui.label(Glossary.keyword_name(kw), 15, ACCENT.lightened(0.3)))
	v.add_child(head)
	var full := Glossary.keyword(kw)
	var ci := full.find(":")
	v.add_child(CardView.rich(full.substr(ci + 1).strip_edges() if ci > 0 else full,
		13, Color(0.82, 0.86, 0.92)))
	# Flavor (the artist's words), if any.
	var flavor := CardData.text_of(String(hero.get("card", "")))
	if flavor != "":
		v.add_child(HSeparator.new())
		var fl := Ui.label(flavor, 12, Color(0.62, 0.6, 0.72))
		fl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fl.custom_minimum_size = Vector2(240, 0)
		v.add_child(fl)
	return panel
