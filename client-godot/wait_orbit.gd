class_name WaitOrbit
extends Control

# The "waiting for opponent" loader from the lobby handoff: five faint
# concentric rings -- ONE PER SPECTRUM COLOUR -- each with a light-mote orbiting
# at its own radius and speed, alternating direction, around a soft glowing core.
# Drawn procedurally and composited additively, so it reads as living light over
# the dark scene. The prism sigil that sat in the core in the mockup is dropped
# (no logo) -- the core is a plain luminous point.

const DOTS := [
	[0.40, 4.0, 1, Color(0.922, 0.2, 0.298)],     # red,    innermost, 4s
	[0.52, 5.0, -1, Color(0.980, 0.761, 0.2)],    # yellow, 5s reverse
	[0.64, 6.0, 1, Color(0.259, 0.819, 0.439)],   # green,  6s
	[0.76, 7.0, -1, Color(0.239, 0.580, 0.980)],  # blue,   7s reverse
	[0.88, 8.0, 1, Color(0.678, 0.322, 0.941)],   # violet, outermost, 8s
]

var _t := 0.0
var _dot := Tokens.soft_dot()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	resized.connect(queue_redraw)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _glow(at: Vector2, radius: float, color: Color) -> void:
	draw_texture_rect(_dot, Rect2(at - Vector2(radius, radius),
		Vector2(radius, radius) * 2.0), false, color)


func _draw() -> void:
	var c := size * 0.5
	var R: float = minf(size.x, size.y) * 0.5
	if R <= 0.0:
		return

	# Soft breathing core.
	var pulse := 0.5 + 0.5 * sin(_t * TAU / 3.0)
	_glow(c, R * 0.34 * (1.0 + 0.08 * pulse),
		Color(0.62, 0.74, 1.0, 0.22 + 0.12 * pulse))

	# Faint concentric rings at each mote's radius.
	for d in DOTS:
		draw_arc(c, R * d[0], 0.0, TAU, 64, Color(0.55, 0.66, 1.0, 0.14), 1.5, true)

	# Orbiting light-motes (kept inside the rect: 0.88R + 0.12R glow < R).
	for d in DOTS:
		var ang: float = _t * (TAU / float(d[1])) * float(d[2])
		var p := c + Vector2(cos(ang), sin(ang)) * R * float(d[0])
		_glow(p, R * 0.12, d[3])
