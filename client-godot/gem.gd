class_name GemNode
extends Control

# A faceted crystal badge that holds a number (atk / hp / hero hp / armor). Drawn
# procedurally as a cut octagonal gem: a dark base, height-shaded crown facets in
# the accent colour, a darker central table the number reads over, and crisp facet
# edges. This carries the game's prism/crystal identity into the board chrome.

var ring: Color = Color.WHITE
var bg_alpha: float = 0.96
var glow: bool = false


func _ready() -> void:
	resized.connect(queue_redraw)


func _draw() -> void:
	var s: float = minf(size.x, size.y)
	if s <= 0.0:
		return
	var c := size * 0.5
	var r := s * 0.5 - 1.5
	var n := 8
	var rot := PI / float(n)  # rotate so the gem has a flat top edge
	var outer := _ring(c, r, n, rot)

	# Soft accent halo behind the gem (for the hero's HP, etc.).
	if glow:
		for k in 3:
			draw_colored_polygon(_ring(c, r + float(k) * 2.0, n, rot),
				Color(ring.r, ring.g, ring.b, 0.10))

	# Dark base, then the central table.
	draw_colored_polygon(outer, Color(0.05, 0.05, 0.08, bg_alpha))
	var inner := _ring(c, r * 0.5, n, rot)

	# Crown facets between the outer edge and the table, shaded by height so the
	# top catches light and the bottom falls into shadow -- reads as a cut stone.
	for i in n:
		var j := (i + 1) % n
		var quad := PackedVector2Array([outer[i], outer[j], inner[j], inner[i]])
		var t := clampf(1.0 - (outer[i].y + outer[j].y) * 0.5 / maxf(size.y, 1.0), 0.0, 1.0)
		var fc := ring.darkened(0.35).lerp(ring.lightened(0.25), t)
		fc.a = bg_alpha
		draw_colored_polygon(quad, fc)

	# Darker table so the number stays legible over the bright crown.
	var tc := ring.darkened(0.55)
	tc.a = bg_alpha
	draw_colored_polygon(inner, tc)

	# Facet edges: bright outer rim, faint radial cut lines, soft table outline.
	draw_polyline(_closed(outer), Color(ring.r, ring.g, ring.b, 0.95), 1.5, true)
	for i in n:
		draw_line(outer[i], inner[i], Color(ring.lightened(0.2), 0.4), 1.0, true)
	draw_polyline(_closed(inner), Color(ring.lightened(0.4), 0.55), 1.0, true)


func _ring(c: Vector2, r: float, n: int, rot: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := -PI / 2.0 + TAU * float(i) / float(n) + rot
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts


func _closed(p: PackedVector2Array) -> PackedVector2Array:
	var q := p.duplicate()
	q.append(p[0])
	return q
