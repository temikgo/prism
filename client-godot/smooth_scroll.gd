class_name SmoothScroll
extends ScrollContainer

# A ScrollContainer that eases toward a scroll target each frame instead of
# jumping. Raw touchpad panning / wheel steps are jittery; this glides. It also
# wears the slim scrollbar and disables horizontal scrolling. Drop-in: just use
# SmoothScroll.new() in place of ScrollContainer.new(). Each instance only reacts
# while the pointer is over its own rect, so several can coexist on one screen.

const WHEEL_PX := 80.0
const PAN_PX := 14.0
const SMOOTH := 22.0

var _target := -1.0


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	Ui.slim_scrollbar(self)


# Drop any in-flight glide (call after the content is rebuilt/shrunk so the eased
# target can't scroll past the new, shorter content).
func reset() -> void:
	_target = -1.0


func _input(e: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if not get_global_rect().has_point(get_global_mouse_position()):
		return
	var dy := 0.0
	if e is InputEventPanGesture:
		dy = e.delta.y * PAN_PX
	elif e is InputEventMouseButton and e.pressed:
		var f: float = e.factor if e.factor > 0.0 else 1.0
		if e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dy = WHEEL_PX * f
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
			dy = -WHEEL_PX * f
	if dy == 0.0:
		return
	var bar := get_v_scroll_bar()
	var max_y: float = maxf(0.0, bar.max_value - bar.page)
	var base: float = _target if _target >= 0.0 else float(scroll_vertical)
	_target = clampf(base + dy, 0.0, max_y)
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _target < 0.0:
		return
	var cur := scroll_vertical
	var diff := _target - float(cur)
	var t: float = clampf(SMOOTH * delta, 0.0, 1.0)
	var want := int(round(float(cur) + diff * t))
	# Reached (or as close as the integer scroll gets): snap and stop. The engine
	# clamps scroll_vertical to the real content range, so a target parked just
	# past the true max resolves here instead of lingering forever.
	if absf(diff) < 0.5 or want == cur:
		scroll_vertical = int(round(_target))
		_target = -1.0
		return
	scroll_vertical = want
	# The engine didn't let us move -> we're pinned at the top/bottom. Drop the
	# (possibly over-range) target so the next scroll starts from the true
	# position instead of unwinding a phantom overshoot. That phantom was the
	# bottom-edge glitch; the top clamps to exactly 0, so it never showed it.
	if scroll_vertical == cur:
		_target = -1.0
