class_name LogoEmblem
extends Control

# The PRISM mark, drawn procedurally so the palette is exact: a low-poly faceted
# crystal in the game's own five colours plus white. The 3D read is faked in 2D by
# flat shadow tones -- each facet is a single flat tone (a lit/mid/shadow tier of
# its colour), no gradients and no black seams between facets. The silhouette is
# deliberately a little irregular so it reads as a real crystal, not a logo decal.

enum { LIT, MID, DARK }

const WHITE := Color(0.94, 0.95, 1.0)


func _ready() -> void:
	resized.connect(queue_redraw)


func _draw() -> void:
	var s: float = minf(size.x, size.y)
	if s <= 0.0:
		return
	var o := (size - Vector2(s, s)) * 0.5  # centre a square crystal in the rect

	# Slightly irregular crystal: apex, uneven shoulders, uneven flanks, a bottom
	# point, and a central ridge (M -> C) that folds the body into left/right.
	var p_t := o + Vector2(0.50, 0.05) * s
	var p_a := o + Vector2(0.23, 0.34) * s
	var p_b := o + Vector2(0.79, 0.30) * s
	var p_m := o + Vector2(0.50, 0.42) * s
	var p_l := o + Vector2(0.12, 0.61) * s
	var p_r := o + Vector2(0.90, 0.56) * s
	var p_c := o + Vector2(0.50, 0.72) * s
	var p_bot := o + Vector2(0.48, 0.97) * s

	# Light comes from the upper-left: left/top facets are lit, the right body and
	# the down-facing pavilion fall into shadow. One colour per facet, exact palette.
	var facets := [
		[PackedVector2Array([p_t, p_a, p_m]), Palette.color_for("red"), LIT],
		[PackedVector2Array([p_t, p_m, p_b]), Palette.color_for("yellow"), MID],
		[PackedVector2Array([p_a, p_l, p_c, p_m]), Palette.color_for("green"), LIT],
		[PackedVector2Array([p_b, p_m, p_c, p_r]), Palette.color_for("blue"), DARK],
		[PackedVector2Array([p_l, p_bot, p_c]), Palette.color_for("violet"), MID],
		[PackedVector2Array([p_r, p_c, p_bot]), WHITE, MID],
	]
	for f in facets:
		draw_colored_polygon(f[0], _shade(f[1], f[2]))

	# A faint light catches the top-left silhouette edge -- lifts the crystal off
	# the dark menu without drawing hard outlines.
	draw_polyline(PackedVector2Array([p_l, p_a, p_t, p_b]),
		Color(1, 1, 1, 0.22), maxf(1.0, s * 0.006), true)


# Flat tone tiers of a base colour -- the only source of "depth" (no gradients).
func _shade(c: Color, tier: int) -> Color:
	match tier:
		LIT:
			return c.lightened(0.16)
		DARK:
			return c.darkened(0.36)
	return c
