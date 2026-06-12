class_name FxLayer
extends Control

# Attack/targeting beam-arrow drawn while a creature or targeted spell is dragged.
# A softly bowed beam from the source to the cursor: a faint gradient glow, a
# stream of bright motes flowing toward the target, a glowing origin spark and a
# glowing arrowhead. Colours come from UiCard's drag statics (gold->red for
# attacks; the spell's hue otherwise). Ported from the board-redesign reference
# (#attack-arrow). Redraws every frame so the beam clears the instant the drag ends.

const C0 := Color("fac233")  # beam origin spark -- gold
const C1 := Color("eb5c6b")  # beam head -- red

var _t := 0.0

func _process(dt: float) -> void:
	_t += dt
	queue_redraw()  # redraw every frame so the beam also clears on release

func _draw() -> void:
	if UiCard.aim_from == Vector2.INF:
		return
	_beam(UiCard.aim_from, get_global_mouse_position(), C0, C1)

func _beam(a: Vector2, b: Vector2, c0: Color, c1: Color) -> void:
	var dist := a.distance_to(b)
	if dist < 14.0:
		return
	# Gentle upward bow: midpoint control raised by min(120, dist*0.18) (reference).
	var ctrl := (a + b) * 0.5 + Vector2(0.0, -minf(120.0, dist * 0.18))
	var steps := 36
	var pts := PackedVector2Array()
	for i in steps + 1:
		var t := float(i) / float(steps)
		pts.append(a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t))
	var tip: Vector2 = pts[steps]
	var tip_dir := (tip - pts[steps - 1]).normalized()
	var perp := Vector2(-tip_dir.y, tip_dir.x)
	var head := 18.0

	# Soft glow underlay: the whole bowed beam, wide and faint, gradient c0->c1.
	var glow := PackedColorArray()
	for i in pts.size():
		var c := c0.lerp(c1, float(i) / float(steps))
		glow.append(Color(c.r, c.g, c.b, 0.16))
	draw_polyline_colors(pts, glow, 11.0, true)

	# Bright motes marching along the curve toward the target.
	_flow(pts, head, c0, c1)

	# Origin spark with a faint halo.
	draw_circle(a, 11.0, Color(c0.r, c0.g, c0.b, 0.22))
	draw_circle(a, 6.5, c0)

	# Glowing arrowhead at the tip.
	var hpts := PackedVector2Array([
		tip + tip_dir * 2.0,
		tip - tip_dir * head + perp * 13.0,
		tip - tip_dir * head - perp * 13.0])
	var hglow := PackedVector2Array([
		tip + tip_dir * 6.0,
		tip - tip_dir * (head + 4.0) + perp * 18.0,
		tip - tip_dir * (head + 4.0) - perp * 18.0])
	draw_colored_polygon(hglow, Color(c1.r, c1.g, c1.b, 0.28))
	draw_colored_polygon(hpts, c1)

# Bright motes spaced along the curve, offset by time so they flow to the target.
# Stops short of the arrowhead so motes never overlap it.
func _flow(pts: PackedVector2Array, trim: float, c0: Color, c1: Color) -> void:
	var seg := PackedFloat32Array()
	seg.append(0.0)
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
		seg.append(total)
	if total < 1.0:
		return
	var period := 22.0
	var speed := 46.0
	var d := fmod(_t * speed, period)
	while d < total - trim:
		var p := _along(pts, seg, d)
		var col := c0.lerp(c1, d / total)
		draw_circle(p, 5.0, Color(col.r, col.g, col.b, 0.25))  # mote glow
		draw_circle(p, 2.4, col)                                # mote core
		d += period

# Point at arc-length s along the polyline.
func _along(pts: PackedVector2Array, seg: PackedFloat32Array, s: float) -> Vector2:
	for i in range(1, seg.size()):
		if seg[i] >= s:
			var t := (s - seg[i - 1]) / maxf(0.001, seg[i] - seg[i - 1])
			return pts[i - 1].lerp(pts[i], t)
	return pts[pts.size() - 1]
