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

# One-shot cast arrow: when the opponent plays a targeted spell, an arrow grows
# from the revealed card to its target and lingers, so you see how it is cast (the
# same beam as the live drag-aim). Drawn only between cast_beam() and its fade;
# never overlaps the drag beam (that is your turn, this is theirs). The fade rides
# on `modulate.a`, so the internal beam always draws at full alpha.
var _cast_active := false
var _cast_from := Vector2.ZERO
var _cast_to := Vector2.ZERO
var _cast_grow := 0.0  # 0..1, the tip growing from source to target
var _cast_gen := 0     # bumped per cast so a stale tween can't clear a newer beam
var _cast_tween: Tween = null


func _process(dt: float) -> void:
	_t += dt
	queue_redraw()  # redraw every frame so the beam also clears on release


func _draw() -> void:
	if UiCard.aim_from != Vector2.INF:
		_beam(UiCard.aim_from, get_global_mouse_position(), C0, C1)
	if _cast_active:
		_beam(_cast_from, _cast_from.lerp(_cast_to, _cast_grow), C0, C1)


# Fire the cast arrow from `from_pos` to `to_pos`: it grows to the target, holds,
# then fades. Global coords (the layer sits at the origin, like the drag beam).
func cast_beam(from_pos: Vector2, to_pos: Vector2) -> void:
	# A new cast replaces any in-flight one (only ever one arrow at a time): kill
	# the old tween so its modulate fade can't fight the new one, and tag this cast
	# so the old tween's end-callback (if it still fires) is ignored.
	if _cast_tween != null and _cast_tween.is_valid():
		_cast_tween.kill()
	_cast_gen += 1
	var gen := _cast_gen
	_cast_from = from_pos
	_cast_to = to_pos
	_cast_grow = 0.0
	_cast_active = true
	modulate.a = 1.0
	_cast_tween = create_tween()
	_cast_tween.tween_property(self, "_cast_grow", 1.0, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_cast_tween.tween_interval(0.62)
	_cast_tween.tween_property(self, "modulate:a", 0.0, 0.44)
	_cast_tween.tween_callback(func() -> void: _end_cast(gen))


func _end_cast(gen: int) -> void:
	if gen != _cast_gen:
		return  # a newer cast has taken over -- don't clear its beam
	_cast_active = false
	modulate.a = 1.0

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
