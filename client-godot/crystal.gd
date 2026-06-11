class_name CrystalNode
extends Control

# A faceted mana crystal, drawn procedurally from the redesign's kite geometry
# (SVG viewBox 0 0 32 44, body M16 1 L29 13 L16 43 L3 13 Z). A diagonal light->color
# gradient fills the stone, dark facet seams cut it, a white highlight catches the
# top-left crown, and the crystal's own colour haloes behind it. Three states:
# available (bright + glow), spent (desaturated + dimmed), temporary (green ramp
# ring -- bonus mana for this turn only, e.g. photosynthesis).

var crystal_color: Color = Color(0.8, 0.8, 0.88)
var spent: bool = false
var temp: bool = false

# Kite + facet geometry in the SVG's 32x44 space; scaled to the node in _draw.
const VBOX := Vector2(32.0, 44.0)
const TOP := Vector2(16, 1)
const RIGHT := Vector2(29, 13)
const BOTTOM := Vector2(16, 43)
const LEFT := Vector2(3, 13)
const MID_L := Vector2(10, 13)
const MID_R := Vector2(22, 13)
const HILITE_B := Vector2(16, 25)


func _ready() -> void:
	resized.connect(queue_redraw)


func _p(v: Vector2) -> Vector2:
	# Map an SVG-space point into the node's pixel rect.
	return Vector2(v.x / VBOX.x * size.x, v.y / VBOX.y * size.y)


# Colour at a kite vertex along the diagonal (0,0)->(1,1) gradient:
# white@a.85 -> color@1.0 (at 0.4) -> color@a.85 (at 1.0).
func _grad(v: Vector2) -> Color:
	var t := clampf((v.x / VBOX.x + v.y / VBOX.y) * 0.5, 0.0, 1.0)
	if t <= 0.4:
		return Color(1, 1, 1, 0.85).lerp(Color(crystal_color, 1.0), t / 0.4)
	return Color(crystal_color, 1.0).lerp(Color(crystal_color, 0.85), (t - 0.4) / 0.6)


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var col := crystal_color
	var alpha := 1.0
	if spent:
		# Spent this turn: drain the colour to a dark stone so available vs spent
		# reads as bright vs dark (matches the redesign's grayscale+dim treatment).
		var g := col.get_luminance()
		col = Color(g, g, g).lerp(col, 0.25).darkened(0.55)
		alpha = 0.5

	var body := PackedVector2Array([_p(TOP), _p(RIGHT), _p(BOTTOM), _p(LEFT)])

	# Colour halo behind the stone (only when live).
	if not spent:
		var glow_n := 3
		for k in range(glow_n, 0, -1):
			var spread := 1.0 + float(k) * 0.06
			var halo := PackedVector2Array()
			var c := size * 0.5
			for pt in body:
				halo.append(c + (pt - c) * spread)
			draw_colored_polygon(halo, Color(crystal_color.r, crystal_color.g, crystal_color.b,
				0.07 * float(glow_n - k + 1)))

	# Gradient fill via per-vertex colours over the kite's two triangles.
	if spent:
		draw_colored_polygon(body, Color(col, alpha))
	else:
		var cols := PackedColorArray([_grad(TOP), _grad(RIGHT), _grad(BOTTOM), _grad(LEFT)])
		draw_polygon(body, cols)

	# Facet seams: centre spine, the crown crossbar, and the two upper cuts.
	var seam := Color(0, 0, 0, 0.28 * alpha)
	draw_line(_p(TOP), _p(BOTTOM), seam, 0.7, true)
	draw_line(_p(LEFT), _p(RIGHT), seam, 0.7, true)
	draw_line(_p(TOP), _p(MID_L), seam, 0.7, true)
	draw_line(_p(MID_L), _p(BOTTOM), seam, 0.7, true)
	draw_line(_p(TOP), _p(MID_R), seam, 0.7, true)

	# White highlight on the upper-left crown facet.
	draw_colored_polygon(PackedVector2Array([_p(TOP), _p(MID_L), _p(HILITE_B)]),
		Color(1, 1, 1, 0.28 * alpha))

	# Crisp outer rim.
	var rim := PackedVector2Array(body)
	rim.append(body[0])
	draw_polyline(rim, Color(1, 1, 1, 0.55 * alpha), 0.9, true)

	# Temporary (ramp) mana: ring the stone in green so it reads as bonus this turn.
	if temp:
		var g := Color(0.42, 0.9, 0.5)
		for k in 2:
			var ring := PackedVector2Array()
			var c := size * 0.5
			var spread := 1.05 + float(k) * 0.09
			for pt in body:
				ring.append(c + (pt - c) * spread)
			ring.append(ring[0])
			draw_polyline(ring, Color(g.r, g.g, g.b, 0.6 - float(k) * 0.25), 1.4, true)
