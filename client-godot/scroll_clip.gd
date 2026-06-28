class_name ScrollClip
extends Control

# A height-capped, wheel-scrollable vertical clip that holds its single child at the
# clip's FULL width -- so the child's own horizontal centring is preserved. Godot's
# ScrollContainer left-packs its content (which broke the mana crystals' centring),
# so this keeps the content centred and still lets a tall pool scroll. Each wheel
# tick eases the content by one STEP (so you can follow row-by-row), and a thin
# thumb on the right shows the position/extent. setup(content, capped_height).

const STEP := 34.0       # one crystal row per wheel tick
const EASE := 0.16       # seconds to glide to the new offset

var _content: Control = null
var _target_y := 0.0
var _tween: Tween = null


func setup(content: Control, cap: float) -> void:
	clip_contents = true
	custom_minimum_size = Vector2(0, cap)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_content = content
	add_child(content)
	resized.connect(_relayout)
	_relayout.call_deferred()  # once after the parent has sized us


func _content_h() -> float:
	return _content.get_combined_minimum_size().y if _content != null else 0.0


func _min_y() -> float:
	return minf(0.0, size.y - _content_h())


func _relayout() -> void:
	if _content == null:
		return
	# Hold the content at our full width (its rows centre within it) and clamp the
	# scroll offset to the content that overflows our capped height.
	_content.position.x = 0.0
	_content.size.x = size.x
	_content.size.y = _content_h()
	_target_y = clampf(_target_y, _min_y(), 0.0)
	_content.position.y = _target_y
	queue_redraw()


# Handled in _input (not _gui_input) so child chips with MOUSE_FILTER_STOP cannot
# swallow the wheel/pan before it reaches us -- the same reason the deck pool went
# to _input. Acts only when the cursor is over us and there is overflow.
func _input(e: InputEvent) -> void:
	if _content == null or not is_visible_in_tree() or _content_h() <= size.y:
		return
	if not get_global_rect().has_point(get_global_mouse_position()):
		return
	var dir := 0.0
	if e is InputEventPanGesture:
		dir = -signf(e.delta.y) if absf(e.delta.y) > 0.01 else 0.0
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dir = -1.0
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
			dir = 1.0
	if dir == 0.0:
		return
	get_viewport().set_input_as_handled()
	_target_y = clampf(_target_y + dir * STEP, _min_y(), 0.0)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_content, "position:y", _target_y, EASE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# Redraw the thumb as it glides.
	_tween.parallel().tween_method(func(_v: float) -> void: queue_redraw(), 0.0, 1.0, EASE)


func _draw() -> void:
	var content_h := _content_h()
	if content_h <= size.y + 1.0:
		return  # fits -- no scrollbar
	# A faint track and a brighter thumb sized to the visible fraction.
	var w := 3.0
	var x := size.x - w - 1.0
	draw_rect(Rect2(x, 0.0, w, size.y), Color(1, 1, 1, 0.06), true)
	var thumb_h := maxf(18.0, size.y * size.y / content_h)
	var frac := -_content.position.y / (content_h - size.y) if content_h > size.y else 0.0
	var thumb_y := clampf(frac, 0.0, 1.0) * (size.y - thumb_h)
	draw_rect(Rect2(x, thumb_y, w, thumb_h), Color(0.62, 0.7, 0.92, 0.55), true)
