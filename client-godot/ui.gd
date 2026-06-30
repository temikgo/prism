class_name Ui

# Generic, stateless widget/style builders shared across the client: labels,
# the neon "glass" and bordered panels, buttons, icons and the mana/cost pips.
# Nothing here reads game state -- callers pass in everything.

# Board design tokens (the "light-table arena" board redesign, now in Godot).
# Near-black glass base, three ink tints for text, and the side-rail glass fill +
# hairline stroke. Shared so every chrome surface mixes from one source.
const BG_0 := Color(0.024, 0.024, 0.047)        # #06060c
const BG_1 := Color(0.039, 0.039, 0.078)        # #0a0a14
const INK := Color(0.933, 0.941, 0.984)         # #eef0fb
const INK_DIM := Color(0.604, 0.627, 0.741)     # #9aa0bd
const INK_FAINT := Color(0.365, 0.384, 0.502)   # #5d6280
const PANEL_FILL := Color(0.059, 0.067, 0.118, 0.55)   # rgba(15,17,30,0.55)
const PANEL_STROKE := Color(1, 1, 1, 0.085)
# Side accents (your blue / the enemy red), the turn/awaken gold.
const SIDE_ME := Color(0.341, 0.62, 0.98)       # #579EFA
const SIDE_FOE := Color(0.922, 0.361, 0.42)     # #EB5C6B
const GOLD := Color(0.957, 0.776, 0.341)        # #F4C657
const ACC_VIOLET := Color(0.678, 0.322, 0.941)  # #AD52F0
const COLORLESS := Color(0.8, 0.8, 0.878)       # #CCCCE0


# --- shell chrome (menu + lobby): the neon-glass "mbtn", glowing titles, glass
# panels and styled inputs. One source so every shell screen reads identically to
# the board's "light-table" language; ported from the Claude Design handoff. ---

# A screen title in the heavy display weight with a soft cool halo, so it reads as
# lit glass like the board. Cyrillic, so Exo 2 Black (Chakra Petch has no Cyrillic
# -- that face is reserved for Latin room codes / numerals). NO outline/contour
# at all: exactly the menu PRISM recipe -- a crisp near-white face with a soft
# dark drop shadow for legibility, lit by a soft RADIAL bloom texture behind it
# (not a font outline, which is what read as a ring). The bloom is an additive
# soft-dot stretched into a wide ellipse sized to the word.
const _TITLE_GLOW := Color(0.5, 0.56, 1.0)  # periwinkle, warmer than flat #579EFA

static func title(text: String, size: int) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := Fonts.spaced(Fonts.BLACK, 1)
	var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	holder.custom_minimum_size = ts

	# Soft elliptical bloom behind the word (additive), wider than the text so it
	# reads as light spilling out, not an edge on the glyphs.
	var bloom := TextureRect.new()
	bloom.texture = Tokens.soft_dot()
	bloom.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bloom.stretch_mode = TextureRect.STRETCH_SCALE
	bloom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bw := ts.x + size * 2.2
	var bh := ts.y * 2.4
	bloom.set_anchors_preset(Control.PRESET_CENTER)
	bloom.offset_left = -bw * 0.5
	bloom.offset_right = bw * 0.5
	bloom.offset_top = -bh * 0.5
	bloom.offset_bottom = bh * 0.5
	bloom.modulate = Color(_TITLE_GLOW.r, _TITLE_GLOW.g, _TITLE_GLOW.b, 0.22)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bloom.material = mat
	holder.add_child(bloom)

	# The readable face over the bloom: clean near-white glyphs + a soft dark
	# drop shadow (no outline), the same lockup as the menu wordmark.
	var l := Label.new()
	l.text = text
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.964, 0.972, 1.0))
	l.add_theme_color_override("font_shadow_color", Color(0.02, 0.03, 0.08, 0.5))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 3)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(l)
	return holder


# The neon-glass pill button (the mockup's `.mbtn`). `kind`: "primary" (large
# blue call-to-action), "ghost" (compact, neutral), "muted" (dim, carries a
# "скоро" note, inert). Accent drives the border/glow; pass your own for colour.
static func mbtn(text: String, kind: String, accent: Color = SIDE_ME,
		width: int = 340) -> Button:
	var primary := kind == "primary"
	var muted := kind == "muted"
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(width, 66 if primary else (52 if kind == "ghost" else 58))
	b.add_theme_font_override("font", Fonts.spaced(Fonts.SEMIBOLD, 1))
	b.add_theme_font_size_override("font_size", 21 if primary else (16 if kind == "ghost" else 18))
	var ink := Color(0.918, 0.949, 1.0) if primary else (INK_DIM if muted else INK)
	b.add_theme_color_override("font_color", ink)
	b.add_theme_color_override("font_hover_color", Color(0.957, 0.969, 1.0))
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.43, 0.5))
	b.add_theme_stylebox_override("normal", _pill(accent, primary, false))
	b.add_theme_stylebox_override("hover", _pill(accent, primary, true))
	b.add_theme_stylebox_override("pressed", _pill(accent, primary, true))
	var dis := _pill(Color(0.32, 0.34, 0.42), false, false)
	dis.shadow_size = 0
	b.add_theme_stylebox_override("disabled", dis)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.focus_mode = Control.FOCUS_NONE
	if muted:
		var note := label("СКОРО", 11, INK_FAINT)
		note.add_theme_font_override("font", Fonts.spaced(Fonts.SEMIBOLD, 2))
		note.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
		note.offset_right = -20
		note.offset_left = -70
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		note.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(note)
	return b


# The pill stylebox: a dark glass fill (blended toward the accent for primary), a
# hairline stroke with a lit top rim, and an accent glow that brightens on hover.
static func _pill(accent: Color, primary: bool, hot: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var base := Color(0.086, 0.094, 0.165, 0.82)
	sb.bg_color = base.lerp(Color(accent.r, accent.g, accent.b, 0.9), 0.22 if primary else 0.0)
	if hot and not primary:
		sb.bg_color = base.lerp(Color(accent.r, accent.g, accent.b, 0.9), 0.08)
	sb.set_corner_radius_all(15)
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.border_color = PANEL_STROKE.lerp(accent, (0.65 if hot else (0.55 if primary else 0.0)))
	if primary:
		sb.shadow_size = 40 if hot else 28
		sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.6 if hot else 0.42)
	elif hot:
		sb.shadow_size = 26
		sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.4)
	else:
		sb.shadow_size = 12
		sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	return sb


# The lobby/forms glass panel (the mockup's `.lobby-panel`): a translucent dark
# slab, hairline stroke, lit top rim and a soft cool glow -- deeper and calmer
# than the board's bright rails.
static func panel_glass() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.063, 0.071, 0.125, 0.66)
	sb.set_corner_radius_all(18)
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.border_color = PANEL_STROKE.lerp(SIDE_ME, 0.18)
	sb.shadow_size = 30
	sb.shadow_color = Color(SIDE_ME.r, SIDE_ME.g, SIDE_ME.b, 0.16)
	sb.set_content_margin_all(26)
	return sb


# Style a LineEdit to the design's `.field input`: dark inset glass, hairline
# stroke, a blue-lit focus ring. `mono`/`big` switches to the large Chakra-Petch
# room-code look (Latin codes only).
static func style_input(le: LineEdit, mono := false, big := false) -> LineEdit:
	var norm := StyleBoxFlat.new()
	norm.bg_color = Color(0.035, 0.04, 0.075, 0.85)
	norm.set_corner_radius_all(10)
	norm.set_border_width_all(1)
	norm.border_color = Color(1, 1, 1, 0.1)
	norm.set_content_margin_all(12)
	if big:
		norm.content_margin_top = 18
		norm.content_margin_bottom = 18
	var foc := norm.duplicate()
	foc.border_color = Color(SIDE_ME.r, SIDE_ME.g, SIDE_ME.b, 0.85)
	foc.shadow_size = 12
	foc.shadow_color = Color(SIDE_ME.r, SIDE_ME.g, SIDE_ME.b, 0.3)
	le.add_theme_stylebox_override("normal", norm)
	le.add_theme_stylebox_override("focus", foc)
	le.add_theme_color_override("font_color", INK)
	le.add_theme_color_override("font_placeholder_color", Color(0.42, 0.45, 0.56))
	le.add_theme_color_override("caret_color", SIDE_ME)
	if mono:
		le.add_theme_font_override("font", Fonts.NUM_BOLD)
	if big:
		le.add_theme_font_size_override("font_size", 48)
		le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	return le


# A small uppercase wide-tracked caption (field labels, the wait code label).
static func caption(text: String, color: Color = INK_DIM, track := 3) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", Fonts.spaced(Fonts.SEMIBOLD, track))
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", color)
	return l


# One side's whole "rail": a dark-glass slab tinted by the side accent, with a lit
# top edge and a soft accent glow that brightens on that side's turn. Godot has no
# backdrop blur, so the glass is faked with the translucent fill + a hairline
# accent-mixed stroke + the colored drop shadow (the depth cue).
static func rail_panel(side: Color, active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_FILL
	sb.set_corner_radius_all(22)
	sb.set_border_width_all(1)
	sb.border_width_top = 2  # lit top rim catches light -> reads as glass, not a box
	sb.border_color = PANEL_STROKE.lerp(side, 0.6 if active else 0.38)
	sb.shadow_size = 34 if active else 20
	sb.shadow_color = Color(side.r, side.g, side.b, 0.42 if active else 0.22)
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	return sb


# The hero medallion's own sub-panel: a darker side-tinted slab framed inside the
# rail (a defined portrait surround, not a second bright glass border competing
# with the rail's stroke). Lit top rim + a soft side glow.
static func medallion(side: Color) -> StyleBoxFlat:
	# The hero backing, matching Claude Design's `.medallion`: a side-tinted dark
	# glass slab (side ~14% over near-black), a translucent side border (~45%), a lit
	# top rim, and a soft side glow. A defined backing -- NOT a near-invisible line;
	# the earlier "too explicit" was the inner-stroke + sheen stacking on top, which
	# the portrait no longer adds.
	var sb := StyleBoxFlat.new()
	# Lighter + more side-tinted than the rail behind it, so the backing reads as a
	# raised slab rather than blending into the dark glass; a clear border and glow.
	sb.bg_color = Color(0.078, 0.084, 0.137, 0.92).lerp(Color(side.r, side.g, side.b, 0.95), 0.2)
	sb.set_corner_radius_all(16)
	sb.set_border_width_all(1)
	sb.border_width_top = 2  # lit top rim ~ the ref's inset top highlight
	sb.border_color = Color(side.r, side.g, side.b, 0.55)
	sb.shadow_size = 18
	sb.shadow_color = Color(side.r, side.g, side.b, 0.34)
	sb.set_content_margin_all(8)
	return sb

# One-liner Label builder. Only the arguments you pass are applied. Pass size <= 0
# / color = null to inherit the theme default; set `center` for centered text and
# `bold` for the semibold weight (otherwise the theme's Manrope Regular is used).
static func label(text: String, size: int = 0, color: Variant = null,
		center: bool = false, bold: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	if color != null:
		l.add_theme_color_override("font_color", color)
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if bold:
		l.add_theme_font_override("font", Fonts.SEMIBOLD)
	return l


# Translucent dark "glass" with a neon accent border and a soft accent glow.
static func glass(accent: Color, bg_alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.14, bg_alpha)
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(2)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.9)
	# A lit top edge: a brighter, thicker upper border reads as light catching the
	# rim of the glass, so panels feel like inked vellum rather than flat boxes.
	sb.border_width_top = 3
	sb.shadow_size = 20
	sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.45)
	sb.set_content_margin_all(8)
	return sb


# A plain rounded panel with a solid border (no shadow). Covers the small
# bordered chips/tiles/pills; overlay panels use glass() instead.
static func bordered(bg: Color, radius: int, border_w: int, border_c: Color, margin: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_border_width_all(border_w)
	sb.border_color = border_c
	if margin > 0:
		sb.set_content_margin_all(margin)
	return sb


static func neon_button(text: String, accent: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", Fonts.SEMIBOLD)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", accent.lightened(0.5))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.43, 0.5))
	b.add_theme_stylebox_override("normal", glass(accent, 0.4))
	b.add_theme_stylebox_override("hover", glass(accent, 0.62))
	b.add_theme_stylebox_override("pressed", glass(accent, 0.8))
	var dis := glass(Color(0.32, 0.34, 0.42), 0.22)
	dis.shadow_size = 0
	b.add_theme_stylebox_override("disabled", dis)
	# No focus rectangle: the press/hover glass is the only state feedback. The
	# default theme draws a focus outline that reads as a flat rectangle on click.
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.focus_mode = Control.FOCUS_NONE
	return b


static func icon(icon_name: String, px: float, color: Color) -> TextureRect:
	var tex := TextureRect.new()
	tex.texture = load("res://icons/%s.svg" % icon_name)
	tex.custom_minimum_size = Vector2(px, px)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.modulate = color
	return tex


# One faceted mana crystal. `filled` = still available this turn (bright), else
# spent (drained + dim); `temp` rings it green for bonus ramp mana. Colourless uses
# the neutral prism tint, every colour shares the same kite cut.
static func mana_pip(color: String, filled: bool, temp := false) -> Control:
	var crystal := CrystalNode.new()
	crystal.crystal_color = Palette.crystal_color(color)
	crystal.spent = not filled
	crystal.temp = temp
	crystal.custom_minimum_size = Vector2(22, 30)
	crystal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return crystal


# A small colored pip used to spell out a card's colored cost.
static func cost_pip(color: String) -> Control:
	var c := Palette.color_for(color)
	var pip := Panel.new()
	pip.custom_minimum_size = Vector2(13, 16)
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pip.add_theme_stylebox_override("panel", bordered(c, 3, 1, c.lightened(0.45)))
	var holder := CenterContainer.new()   # vertical-center the pip beside the number
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(pip)
	return holder


# A fixed-height vertical spacer for stacking screen sections.
static func gap(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s
