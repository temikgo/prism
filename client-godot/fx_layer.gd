class_name FxLayer
extends Control

# Top overlay that draws the aiming arrow while a creature/spell is being
# dragged. It reads the in-flight drag's origin/color from UiCard's statics and
# redraws every frame so the arrow also clears the instant the drag ends.

func _process(_dt: float) -> void:
	queue_redraw()  # redraw every frame so the arrow also clears on release

func _draw() -> void:
	if UiCard.aim_from == Vector2.INF:
		return
	_arrow(UiCard.aim_from, get_global_mouse_position())

func _arrow(a: Vector2, b: Vector2) -> void:
	var d := b - a
	var dist := d.length()
	if dist < 14.0:
		return
	# Sample a gently arced bezier from source to cursor.
	var ctrl := (a + b) * 0.5 + Vector2(0, -minf(dist * 0.28, 130.0))
	var steps := 26
	var pts := PackedVector2Array()
	for i in steps + 1:
		var t := float(i) / steps
		pts.append(a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t))
	var tip: Vector2 = pts[steps]
	var tip_dir := (tip - pts[steps - 1]).normalized()
	var perp := Vector2(-tip_dir.y, tip_dir.x)
	var head := minf(34.0, dist * 0.45)
	var core: Color = UiCard.aim_color
	var glow := Color(core.r, core.g, core.b, 0.22)
	# Tapered ribbon (glow underlay, then bright core), trimmed by the head
	# length so it meets the arrowhead with no gap.
	_ribbon(pts, 12.0, 4.0, head, glow, 6.0)
	_ribbon(pts, 7.0, 2.5, head, core, 0.0)
	# Arrowhead (glow, then core).
	draw_colored_polygon(PackedVector2Array([
		tip + tip_dir * 4.0, tip - tip_dir * head + perp * 21.0,
		tip - tip_dir * head - perp * 21.0]), glow)
	draw_colored_polygon(PackedVector2Array([
		tip + tip_dir * 2.0, tip - tip_dir * head + perp * 14.0,
		tip - tip_dir * head - perp * 14.0]), core)

func _ribbon(pts: PackedVector2Array, w0: float, w1: float, trim_len: float,
		c: Color, pad: float) -> void:
	var last := pts.size() - 1
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
	if total < 1.0:
		return
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var acc := 0.0
	for i in pts.size():
		if i > 0:
			acc += pts[i].distance_to(pts[i - 1])
		if total - acc < trim_len:
			break  # stop where the arrowhead begins -> no gap
		var t := acc / total
		var w := lerpf(w0, w1, t) + pad
		var tan := (pts[mini(i + 1, last)] - pts[maxi(i - 1, 0)]).normalized()
		var pp := Vector2(-tan.y, tan.x)
		left.append(pts[i] + pp * w * 0.5)
		right.append(pts[i] - pp * w * 0.5)
	if left.size() < 2:
		return
	right.reverse()
	draw_colored_polygon(left + right, c)
