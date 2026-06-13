class_name PrismSigil
extends Control

# The menu's prism sigil -- the locked "triangle prism" mark from the Claude
# Design handoff: a white ray enters from the left, refracts through a glass
# triangle and fans out as the five-colour spectrum on the right. Drawn
# procedurally in the exact spectrum palette (no asset), composited additively so
# it reads as light over the dark scene. A halo bloom under the crystal pulses and
# the spectrum rays flicker, the same idle motion as the mockup's sigilPulse/
# rayFlick. Geometry is in the handoff's SVG viewBox (200x160), mapped uniformly
# into whatever rect we are given.

# Spectrum ray hues (the board's strict card palette).
const RAYS := [
	[Vector2(196, 58), Color(0.922, 0.2, 0.298)],    # red    #EB334C
	[Vector2(196, 76), Color(0.980, 0.761, 0.2)],    # yellow #FAC233
	[Vector2(196, 94), Color(0.259, 0.819, 0.439)],  # green  #42D170
	[Vector2(196, 112), Color(0.239, 0.580, 0.980)], # blue   #3D94FA
	[Vector2(196, 130), Color(0.678, 0.322, 0.941)], # violet #AD52F0
]
const RAY_FROM := Vector2(120, 96)
const RAY_IN_A := Vector2(6, 64)
const RAY_IN_B := Vector2(78, 92)
const TRI := [Vector2(100, 28), Vector2(142, 108), Vector2(58, 108)]
const TRI_INNER := [Vector2(100, 28), Vector2(121, 108), Vector2(100, 108)]
const GLASS_FILL := Color(0.627, 0.745, 1.0, 0.16)
const GLASS_EDGE := Color(0.875, 0.906, 1.0)
const FACET := Color(0.498, 0.639, 0.847, 0.30)
const RAY_IN := Color(0.933, 0.953, 1.0)
const HALO := Color(0.588, 0.706, 1.0)

var _t := 0.0
var _dot := Tokens.soft_dot()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Additive so the glass, edge and rays add light to the scene rather than
	# painting over it -- the whole sigil glows on the dark table.
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	resized.connect(queue_redraw)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


# Map a point from the SVG viewBox (200x160) into our rect, uniform + centred.
func _scale() -> float:
	return minf(size.x / 200.0, size.y / 160.0)


func _pt(v: Vector2) -> Vector2:
	var s := _scale()
	var off := (size - Vector2(200, 160) * s) * 0.5
	return off + v * s


func _draw() -> void:
	var s := _scale()
	if s <= 0.0:
		return

	# Halo bloom under the crystal: a soft radial that breathes (sigilPulse).
	var pulse := 0.5 + 0.5 * sin(_t * TAU / 4.5)
	var hr := 132.0 * s * (1.0 + 0.08 * pulse)
	var hc := _pt(Vector2(100, 84))
	draw_texture_rect(_dot, Rect2(hc - Vector2(hr, hr), Vector2(hr, hr) * 2.0), false,
		Color(HALO.r, HALO.g, HALO.b, 0.20 + 0.12 * pulse))

	# Glass triangle: translucent fill, a brighter inner facet, a lit edge.
	var tri := PackedVector2Array([_pt(TRI[0]), _pt(TRI[1]), _pt(TRI[2])])
	draw_colored_polygon(tri, GLASS_FILL)
	draw_colored_polygon(
		PackedVector2Array([_pt(TRI_INNER[0]), _pt(TRI_INNER[1]), _pt(TRI_INNER[2])]), FACET)
	draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]),
		GLASS_EDGE, 2.4 * s, true)

	# The incoming white ray, then the refracted spectrum fan (flickering).
	draw_line(_pt(RAY_IN_A), _pt(RAY_IN_B), RAY_IN, 3.0 * s, true)
	var flick := 0.85 + 0.15 * (0.5 + 0.5 * sin(_t * TAU / 6.0))
	var from := _pt(RAY_FROM)
	for r in RAYS:
		var c: Color = r[1]
		draw_line(from, _pt(r[0]), Color(c.r, c.g, c.b, flick), 3.4 * s, true)
