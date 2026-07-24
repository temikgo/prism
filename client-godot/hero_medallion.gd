class_name HeroMedallion
extends UiCard

# One player's hero: a big framed portrait with HP/armor gems, name, and the
# passive badge. The enemy medallion doubles as the face-attack drop target and
# reports an `attack_hero_requested` intent; your own medallion is the spawn point
# for face-damage numbers (Main keeps the node ref for that). Transient -- rebuilt
# each view, so its drop hook always captures the live row's data via Rules.

signal attack_hero_requested(attacker_id: int)
signal cast_face_requested(data: Variant)  # a chosen_any_target burn dropped on the face

const ME_ACCENT := Color(0.34, 0.62, 0.98)
const ENEMY_ACCENT := Color(0.92, 0.36, 0.42)


func setup(hero: Dictionary, mine: bool, view: Dictionary) -> void:
	var accent := ME_ACCENT if mine else ENEMY_ACCENT
	custom_minimum_size = Vector2(158, 0)
	size_flags_vertical = Control.SIZE_FILL
	add_theme_stylebox_override("panel", Ui.medallion(accent))
	if not mine:
		# The face is a drop target for two things: an attacker (blocked by a
		# provoker unless it has Bypass), and a chosen_any_target burn spell (aim
		# it at the hero instead of a creature).
		can_drop_fn = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY:
				return false
			if data.get("kind", "") == "attacker":
				return not Rules.enemy_has_provoke(view) or bool(data.get("bypass", false))
			if data.get("kind", "") == "hand":
				return bool(data.get("hits_face", false)) and bool(data.get("playable", true))
			return false
		# The face lights up for whatever it can actually receive -- an attacker it
		# may be hit by, or a face-aimed burn. Mirrors can_drop_fn; the attacker
		# branch used to be missing, so a legal face attack drew no highlight.
		highlight_check = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY:
				return false
			if data.get("kind", "") == "attacker":
				return not Rules.enemy_has_provoke(view) or bool(data.get("bypass", false))
			return data.get("kind", "") == "hand" and bool(data.get("hits_face", false))
		drop_fn = func(data: Variant) -> void:
			if data.get("kind", "") == "attacker":
				attack_hero_requested.emit(int(data["id"]))
			else:
				cast_face_requested.emit(data)

	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 5)
	var tag := Ui.label("ВЫ" if mine else "СОПЕРНИК", 11, accent.lerp(Ui.INK_DIM, 0.35), true)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(tag)
	v.add_child(HeroView.portrait_with_hp(hero, 124, accent))
	var nm := Ui.label(String(hero.get("name", "Герой")), 17, Ui.INK, true)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A soft side-tinted halo around the name (0-offset shadow + outline = even glow).
	nm.add_theme_color_override("font_shadow_color", Color(accent.r, accent.g, accent.b, 0.55))
	nm.add_theme_constant_override("shadow_offset_x", 0)
	nm.add_theme_constant_override("shadow_offset_y", 0)
	nm.add_theme_constant_override("shadow_outline_size", 5)
	v.add_child(nm)
	var badge := HeroView.passive_badge(hero, accent)
	if badge != null:
		var brow := HBoxContainer.new()
		brow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		brow.alignment = BoxContainer.ALIGNMENT_CENTER
		brow.add_child(badge)
		v.add_child(brow)
	add_child(v)
