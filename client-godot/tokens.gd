class_name Tokens

# Shared visual factories + layout tokens: one place for the round stat/cost gem,
# card art nodes, small reusable textures/styles, and the card geometry both the
# board (Main) and the card visual (CardView) share. Pure -- no game state.

# Card geometry (single source of truth for board, hand and the card face).
const CARD_SIZE := Vector2(176, 246)
const RIM := 2.0        # thin colored light-rim around the full-bleed art
const PAD := 6.0        # inset of cost / stats / status from the card edge
const GEM := 34.0       # diameter of the cost / atk / hp corner gems
const STATUS_MAX := 4   # status icons shown before collapsing to a +N chip

# A round badge with a number (cost / atk / hp / hero hp / armor). `size` is the
# diameter; `font` defaults to ~0.42*size; `glow` adds a soft colored shadow.
static func gem(text: String, ring: Color, size: float, font: int = 0,
		glow: bool = false, bg_alpha: float = 0.96) -> Control:
	var g := GemNode.new()
	g.ring = ring
	g.bg_alpha = bg_alpha
	g.glow = glow
	g.custom_minimum_size = Vector2(size, size)
	g.size = Vector2(size, size)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fs := font if font > 0 else int(size * 0.46)
	var l := Ui.label(text, fs, ring.lightened(0.6), true)
	# Chakra Petch (numeric face) + a dark rim so the number stays crisp over any
	# art behind it; the techy digits carry the crystal/prism identity into stats.
	l.add_theme_font_override("font", Fonts.NUM_BLACK)
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 0.9))
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_child(l)
	return g


# Card art as a node. `px > 0` => a square thumbnail of that size; `px <= 0` =>
# full-bleed (the caller anchors it). Falls back to a tinted rect if the png is
# missing. `card_id` is resolved through the token-family fallback.
static func art(card_id: String, px: float = 0.0,
		fallback: Color = Color(0.1, 0.1, 0.14), thumb := false) -> Control:
	# `thumb` reads a small downscaled copy (art_thumb/, mipmapped) instead of the
	# 896x1344 master -- for grids of many cards (the deck builder) where the full
	# art's VRAM/upload cost stalls; identical at card size. Falls back to master.
	var did := CardData.display_id(card_id)
	var path := "res://art/%s.png" % did
	if thumb:
		var tpath := "res://art_thumb/%s.png" % did
		if ResourceLoader.exists(tpath):
			path = tpath
	if ResourceLoader.exists(path):
		var tex := TextureRect.new()
		tex.texture = load(path)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		# The source art is high-res (896x1344) shown small (cards ~110px, portrait
		# 124, aura 50). Without mipmaps that minification aliases into grain ("low
		# quality in-game"); the art imports now generate mipmaps and this filter
		# makes the 2D canvas actually sample them, so downscaling stays crisp.
		tex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if px > 0:
			tex.custom_minimum_size = Vector2(px, px)
		return tex
	var ph := ColorRect.new()
	ph.color = fallback.darkened(0.4)
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if px > 0:
		ph.custom_minimum_size = Vector2(px, px)
	return ph


# A rounded dark style for the circular passive/ability badges. `glow` adds a
# soft colored shadow.
static func round_style(border: Color, glow: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.11, 0.96)
	sb.set_corner_radius_all(15)  # half of 30 -> a circle
	sb.set_border_width_all(2)
	sb.border_color = border
	sb.set_content_margin_all(5)
	if glow:
		sb.shadow_size = 8
		sb.shadow_color = Color(border.r, border.g, border.b, 0.6)
	return sb


# A soft round dot texture (radial white -> transparent), for light particles.
static func soft_dot() -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 1.0)
	t.width = 96
	t.height = 96
	return t
