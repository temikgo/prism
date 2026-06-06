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
	# Living luminous energy: slow domain-warped fbm tinted across the cool
	# spectrum, added over the dark base so it reads as light, not paint. This is
	# what makes the void feel like the painterly card art rather than flat space.
	add_child(_energy_layer())
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
	_fit_motes(true)


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
func _fit_motes(reseed: bool = false) -> void:
	if _motes == null or not is_inside_tree():
		return
	var vp := get_viewport_rect().size
	_motes.position = vp * 0.5
	var mat: ParticleProcessMaterial = _motes.process_material
	mat.emission_box_extents = Vector3(vp.x * 0.55, vp.y * 0.6, 0)
	# Only re-seed on first fit (so the screen starts populated). On a window
	# resize we just move/resize the emitter -- existing motes keep drifting, so
	# the field doesn't visibly reset/re-randomize.
	if reseed:
		_motes.restart()


func _bg_texture() -> Texture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray([
		Color(0.07, 0.08, 0.15), Color(0.09, 0.05, 0.15), Color(0.01, 0.01, 0.03)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.42)
	tex.fill_to = Vector2(1.05, 1.1)
	return tex


# Full-screen additive shader: domain-warped value-noise fbm tinted indigo ->
# azure -> violet, concentrated toward the Mega-Prism (top-centre) and faded at
# the edges, drifting slowly. Pure procedural -- no assets.
func _energy_layer() -> ColorRect:
	var sh := Shader.new()
	sh.code = ENERGY_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var rect := ColorRect.new()
	rect.material = mat
	rect.color = Color(1, 1, 1, 1)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


const ENERGY_SHADER := "
shader_type canvas_item;
render_mode blend_add;

uniform float u_intensity = 0.82;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 uv = UV;
	float t = TIME * 0.06;
	vec2 q = vec2(fbm(uv * 3.2 + vec2(0.0, t)), fbm(uv * 3.2 + vec2(5.2, 1.3) - t));
	float f = fbm(uv * 3.2 + q * 2.3 + vec2(t * 1.2, -t));
	vec3 indigo = vec3(0.10, 0.12, 0.34);
	vec3 azure = vec3(0.18, 0.34, 0.80);
	vec3 violet = vec3(0.52, 0.26, 0.78);
	vec3 col = mix(indigo, azure, smoothstep(0.25, 0.6, f));
	col = mix(col, violet, smoothstep(0.55, 0.95, f));
	float d = distance(uv, vec2(0.5, 0.16));
	float mask = smoothstep(1.3, 0.03, d);
	float glow = pow(f, 1.7) * mask * u_intensity;
	COLOR = vec4(col * glow, 1.0);
}
"


func _ambient_motes() -> GPUParticles2D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(820, 520, 0)
	mat.direction = Vector3(0, -1, 0)
	mat.spread = 45.0
	mat.gravity = Vector3(0, -8, 0)
	mat.initial_velocity_min = 7.0
	mat.initial_velocity_max = 24.0
	mat.scale_min = 0.05
	mat.scale_max = 0.42
	# A little turbulence so motes drift rather than rise in straight lines, and a
	# random per-particle hue shift so the cloud picks up faint spectral colour.
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 0.6
	mat.turbulence_noise_scale = 1.3
	mat.hue_variation_min = -0.18
	mat.hue_variation_max = 0.18
	# Fade in then out over each mote's life, tinted cool light.
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	ramp.colors = PackedColorArray([
		Color(0.7, 0.82, 1.0, 0.0), Color(0.80, 0.88, 1.0, 0.9),
		Color(0.84, 0.92, 1.0, 0.85), Color(0.84, 0.92, 1.0, 0.0)])
	var rtex := GradientTexture1D.new()
	rtex.gradient = ramp
	mat.color_ramp = rtex

	var p := GPUParticles2D.new()
	p.process_material = mat
	p.texture = Tokens.soft_dot()
	p.amount = 120
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
