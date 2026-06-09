class_name HeroMedallion
extends UiCard

# One player's hero: a big framed portrait with HP/armor gems, name, and the
# passive badge. The enemy medallion doubles as the face-attack drop target and
# reports an `attack_hero_requested` intent; your own medallion is the spawn point
# for face-damage numbers (Main keeps the node ref for that). Transient -- rebuilt
# each view, so its drop hook always captures the live row's data via Rules.

signal attack_hero_requested(attacker_id: int)

const ME_ACCENT := Color(0.34, 0.62, 0.98)
const ENEMY_ACCENT := Color(0.92, 0.36, 0.42)


func setup(hero: Dictionary, mine: bool, view: Dictionary) -> void:
	var accent := ME_ACCENT if mine else ENEMY_ACCENT
	custom_minimum_size = Vector2(158, 0)
	size_flags_vertical = Control.SIZE_FILL
	add_theme_stylebox_override("panel", Ui.glass(accent, 0.4))
	if not mine:
		# Attack the face: blocked by a provoker unless the attacker has Bypass.
		can_drop_fn = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY or data.get("kind", "") != "attacker":
				return false
			return not Rules.enemy_has_provoke(view) or bool(data.get("bypass", false))
		drop_fn = func(data: Variant) -> void:
			attack_hero_requested.emit(int(data["id"]))

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
	add_child(v)
