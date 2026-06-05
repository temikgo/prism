class_name Backdrop
extends Control

# The shared atmospheric backdrop -- "light on dark". A radial gradient base, a
# cool glow spilling from the top, a warm violet glow from the bottom, a centre
# vignette, and a slow drift of ambient light motes. Self-contained: add one as
# the first child of any screen. The motes refit themselves on window resize.

var _motes: GPUParticles2D = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Size to the whole window explicitly: built in code, the anchor layout pass
	# can leave us at the gradient's intrinsic size, so pin to the viewport.
	_fit_self()
	var bg := TextureRect.new()
	bg.texture = _bg_texture()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# The light of the Mega-Prism: a soft cool glow from the top, a violet glow
	# from below, and a vignette darkening the edges toward the centre.
	add_child(_glow_layer(Vector2(0.5, -0.05), 1.0,
		Color(0.46, 0.56, 1.0, 0.26), Color(0.46, 0.56, 1.0, 0.0)))
	add_child(_glow_layer(Vector2(0.5, 1.02), 0.7,
		Color(0.55, 0.28, 0.7, 0.16), Color(0.55, 0.28, 0.7, 0.0)))
	add_child(_glow_layer(Vector2(0.5, 0.5), 0.95,
		Color(0.0, 0.0, 0.0, 0.0), Color(0.0, 0.0, 0.02, 0.62)))
	_motes = _ambient_motes()
	add_child(_motes)
	get_tree().root.size_changed.connect(_on_resize)
	_fit_motes()


func _on_resize() -> void:
	_fit_self()
	_fit_motes()


# Pin our rect to the window; the layered children anchor to us in turn.
func _fit_self() -> void:
	if not is_inside_tree():
		return
	position = Vector2.ZERO
	size = get_viewport_rect().size


# Resize the mote cloud to the current window so it covers the whole screen
# (including the right-hand column in a match) after a maximize/resize.
func _fit_motes() -> void:
	if _motes == null or not is_inside_tree():
		return
	var vp := get_viewport_rect().size
	_motes.position = vp * 0.5
	var mat: ParticleProcessMaterial = _motes.process_material
	mat.emission_box_extents = Vector3(vp.x * 0.55, vp.y * 0.6, 0)
	_motes.restart()  # re-seed across the new area so it fills immediately


func _bg_texture() -> Texture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray([
		Color(0.07, 0.08, 0.15), Color(0.10, 0.06, 0.16), Color(0.02, 0.02, 0.05)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.42)
	tex.fill_to = Vector2(1.05, 1.1)
	return tex


func _ambient_motes() -> GPUParticles2D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(820, 520, 0)
	mat.direction = Vector3(0, -1, 0)
	mat.spread = 45.0
	mat.gravity = Vector3(0, -4, 0)
	mat.initial_velocity_min = 3.0
	mat.initial_velocity_max = 12.0
	mat.scale_min = 0.08
	mat.scale_max = 0.32
	# Fade in then out over each mote's life, tinted cool light.
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	ramp.colors = PackedColorArray([
		Color(0.7, 0.82, 1.0, 0.0), Color(0.78, 0.86, 1.0, 0.85),
		Color(0.82, 0.9, 1.0, 0.8), Color(0.82, 0.9, 1.0, 0.0)])
	var rtex := GradientTexture1D.new()
	rtex.gradient = ramp
	mat.color_ramp = rtex

	var p := GPUParticles2D.new()
	p.process_material = mat
	p.texture = Tokens.soft_dot()
	p.amount = 90
	p.lifetime = 8.0
	p.preprocess = 8.0          # start with the screen already populated
	return p                    # position/extents set by _fit_motes()


# A full-screen radial glow/vignette layer. `center`/`radius` are in UV (0..1);
# the gradient runs `inner` (at the centre) -> `outer` (at the radius).
func _glow_layer(center: Vector2, radius: float, inner: Color, outer: Color) -> TextureRect:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([inner, outer])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = center
	tex.fill_to = center + Vector2(0.0, radius)
	var tr := TextureRect.new()
	tr.texture = tex
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr
