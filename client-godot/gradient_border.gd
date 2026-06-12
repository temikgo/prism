class_name GradientBorder
extends MarginContainer

# A rounded panel whose border is a left-to-right gradient through a card's colours,
# so a multicolour card's description is framed in all of its colours (a single
# colour just reads as a solid border). Holds one child, inset by the padding; the
# dark fill + gradient stroke are drawn behind it.

var _colors := [Color.WHITE]
var _bg := Color(0.10, 0.11, 0.15, 0.98)
const RADIUS := 11.0
const BORDER := 2.0
const PAD := 12


func setup(colors: Array, bg: Color) -> void:
	_colors = colors if not colors.is_empty() else [Color.WHITE]
	_bg = bg
	for m in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + m, PAD)
	resized.connect(queue_redraw)


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	# Dark rounded fill, then the gradient stroke just inside the edge.
	draw_colored_polygon(_rrect(Rect2(Vector2.ZERO, size), RADIUS), _bg)
	var pts := _rrect(Rect2(Vector2.ZERO, size).grow(-BORDER * 0.5), RADIUS - BORDER * 0.5)
	pts.append(pts[0])
	var cols := PackedColorArray()
	for p in pts:
		cols.append(_grad(p.x / size.x))
	draw_polyline_colors(pts, cols, BORDER, true)


# Sample the colour list across 0..1 (left edge -> right edge).
func _grad(t: float) -> Color:
	if _colors.size() == 1:
		return _colors[0]
	var f := clampf(t, 0.0, 1.0) * float(_colors.size() - 1)
	var i := int(f)
	if i >= _colors.size() - 1:
		return _colors[-1]
	return _colors[i].lerp(_colors[i + 1], f - float(i))


# Perimeter points of a rounded rectangle, clockwise from the top-left corner.
func _rrect(r: Rect2, rad: float) -> PackedVector2Array:
	rad = minf(rad, minf(r.size.x, r.size.y) * 0.5)
	var pts := PackedVector2Array()
	var corners := [
		[Vector2(r.position.x + rad, r.position.y + rad), PI, PI * 1.5],
		[Vector2(r.end.x - rad, r.position.y + rad), PI * 1.5, TAU],
		[Vector2(r.end.x - rad, r.end.y - rad), 0.0, PI * 0.5],
		[Vector2(r.position.x + rad, r.end.y - rad), PI * 0.5, PI],
	]
	var steps := 8
	for c in corners:
		for i in steps + 1:
			var a := lerpf(c[1], c[2], float(i) / float(steps))
			pts.append(c[0] + Vector2(cos(a), sin(a)) * rad)
	return pts
