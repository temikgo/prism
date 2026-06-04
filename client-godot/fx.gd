class_name Fx
extends Node

# Transient board feedback: attack lunge, screen shake, summon pop-in, damage
# flash + floating numbers, death dissolve, ready-to-attack pulse. A Node so it
# can own tweens. `host` is the root that shakes; `layer` is the overlay that
# holds detached/floating nodes (dead cards, damage numbers).

var host: Control = null   # the root control to shake
var layer: Control = null  # the FxLayer overlay (above the board)


func setup(p_host: Control, p_layer: Control) -> void:
	host = p_host
	layer = p_layer


# A quick lunge of `node` toward `target_pos` and back -- the attack hit.
func lunge(node: Control, target_pos: Vector2) -> void:
	var start := node.position
	var dir := target_pos - (node.global_position + node.size * 0.5)
	if dir.length() < 1.0:
		return
	dir = dir.normalized()
	node.z_index = 15
	var t := create_tween()
	t.tween_property(node, "position", start + dir * 32.0, 0.09) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "position", start, 0.15) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_callback(_reset_z.bind(node))


func _reset_z(node: Control) -> void:
	if is_instance_valid(node):
		node.z_index = 0


# A soft, slowly pulsing gold ring behind a ready-to-attack creature.
func ready_pulse(card: Control) -> void:
	var ring := Panel.new()
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring.offset_left = -3
	ring.offset_top = -3
	ring.offset_right = 3
	ring.offset_bottom = 3
	ring.show_behind_parent = true
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	var gold := Color(0.98, 0.85, 0.4)
	sb.border_color = gold
	sb.shadow_size = 12
	sb.shadow_color = Color(gold.r, gold.g, gold.b, 0.55)
	ring.add_theme_stylebox_override("panel", sb)
	card.add_child(ring)
	var t := create_tween()
	t.set_loops()
	t.tween_property(ring, "modulate:a", 0.35, 0.8).set_trans(Tween.TRANS_SINE)
	t.tween_property(ring, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE)


# Brief positional screen shake (impact feedback). Decays and returns to rest.
func shake(intensity: float) -> void:
	if host == null:
		return
	var steps := 5
	var t := create_tween()
	for i in steps:
		var amp := intensity * (1.0 - float(i) / steps)
		t.tween_property(host, "position",
			Vector2(randf_range(-amp, amp), randf_range(-amp, amp)), 0.035)
	t.tween_property(host, "position", Vector2.ZERO, 0.05)


func flash(card: Control) -> void:
	card.pivot_offset = card.size * 0.5
	var rest: Color = card.rest_modulate
	var t := create_tween()
	t.tween_property(card, "modulate", Color(2.2, 0.5, 0.5), 0.06)
	t.parallel().tween_property(card, "scale", Vector2(1.14, 1.14), 0.06)
	t.tween_property(card, "modulate", rest, 0.3)
	t.parallel().tween_property(card, "scale", Vector2.ONE, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func pop_in(card: Control) -> void:
	card.pivot_offset = card.size * 0.5
	var rest: Color = card.rest_modulate
	card.scale = Vector2(0.45, 0.45)
	card.modulate = Color(1.6, 1.6, 1.6, 0.0)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(card, "scale", Vector2.ONE, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(card, "modulate", rest, 0.26)


func fade_out_dead(node: Control) -> void:
	var gp := node.global_position
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)
	layer.add_child(node)
	node.global_position = gp
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.pivot_offset = node.size * 0.5
	var t := create_tween()
	t.tween_property(node, "modulate", Color(2.2, 0.4, 0.4), 0.08)  # death flash
	t.tween_property(node, "modulate", Color(1.4, 0.3, 0.3, 0.0), 0.4)
	t.parallel().tween_property(node, "scale", Vector2(0.55, 0.55), 0.4)
	t.parallel().tween_property(node, "rotation", deg_to_rad(18.0), 0.4)
	t.parallel().tween_property(node, "position", node.position + Vector2(0, 36), 0.4)
	t.chain().tween_callback(node.queue_free)


func float_number(pos: Vector2, amount: int) -> void:
	var lbl := Ui.label("-%d" % amount, 32, Color(1.0, 0.4, 0.4))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("outline_size", 6)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.pivot_offset = Vector2(14, 18)
	lbl.position = pos
	lbl.scale = Vector2(0.6, 0.6)
	layer.add_child(lbl)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(lbl, "position", pos + Vector2(0, -58), 0.7)
	t.tween_property(lbl, "scale", Vector2(1.15, 1.15), 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(lbl, "modulate", Color(1, 1, 1, 0), 0.7)
	t.chain().tween_callback(lbl.queue_free)
