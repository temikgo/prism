class_name UiCard
extends PanelContainer

# The one interactive widget the whole board is built from: a draggable /
# droppable card or zone. Hand cards, board creatures, hero drop-targets, the
# mana zone and the aura shelf are all UiCards configured through the callable
# hooks below (can_drop_fn / drop_fn / tooltip_builder / preview_builder).

signal clicked(payload: Dictionary)
signal double_clicked(payload: Dictionary)
var _swallow_click := false   # the release after a double-click is not a click
# Shared across all cards: the payload of the drag currently in flight, so
# any card can decide whether to light up as a legal drop target.
static var active_drag = null
# While an attacker is being dragged: viewport position to draw the attack
# arrow from (Vector2.INF when no attacker drag is in flight).
static var aim_from := Vector2.INF
static var aim_color := Color(0.5, 0.95, 1.0)  # arrow color: attack vs spell
var payload: Dictionary = {}        # non-empty + draggable=true => can drag
var drag_label: String = ""
var preview_builder: Callable = Callable()   # returns the drag-preview Control
var tooltip_builder: Callable = Callable()   # returns the hover-tooltip Control
var can_drop_fn: Callable = Callable()
var drop_fn: Callable = Callable()
# Optional: decides whether to glow as a drop target (when it differs from
# what we actually accept -- e.g. a creature accepts a play-drop but should
# not light up as if the card were played "onto" it).
var highlight_check: Callable = Callable()
var hoverable := false                        # scale up on mouse-over
var rest_modulate := Color.WHITE              # modulate to restore after a drag
var glow_self := false                        # glow own panel only (drop zones)
var _is_drag_source := false

func _ready() -> void:
	mouse_entered.connect(_on_hover_in)
	mouse_exited.connect(_on_hover_out)

func _on_hover_in() -> void:
	# Don't lift while dragging or aiming at a target: only the legal-target
	# glow should read as interactive then.
	if not hoverable or active_drag != null:
		return
	pivot_offset = size / 2.0
	z_index = 20
	create_tween().tween_property(self, "scale", Vector2(1.08, 1.08), 0.08)

func _on_hover_out() -> void:
	if not hoverable:
		return
	z_index = 0
	create_tween().tween_property(self, "scale", Vector2.ONE, 0.08)

func _make_custom_tooltip(_for_text: String) -> Object:
	if tooltip_builder.is_valid():
		return tooltip_builder.call()
	return null

func _gui_input(event: InputEvent) -> void:
	# Fire on release, not press: a press that turns into a drag is consumed
	# by the drag system, so a real click never collides with dragging.
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return
	# Native double-click (fires on the second press): emit it, and swallow the
	# release that follows so it is not also read as a single click.
	if event.pressed and event.double_click:
		_swallow_click = true
		double_clicked.emit(payload)
		return
	if not event.pressed:
		if _swallow_click:
			_swallow_click = false
			return
		clicked.emit(payload)

func _get_drag_data(_at: Vector2) -> Variant:
	if not bool(payload.get("draggable", false)):
		return null
	active_drag = payload
	_is_drag_source = true
	# Drop the hover lift so the source never overlaps the drag preview.
	z_index = 0
	scale = Vector2.ONE
	if payload.get("kind", "") == "attacker" or bool(payload.get("needs_target", false)):
		# Attacks and targeted spells show an aiming arrow, not a floating
		# card: use a tiny invisible preview and record where the arrow starts.
		aim_from = global_position + size * 0.5
		aim_color = Color(0.5, 0.95, 1.0) if payload.get("kind", "") == "attacker" \
			else Color(0.82, 0.55, 1.0)
		var dot := Control.new()
		dot.custom_minimum_size = Vector2(2, 2)
		set_drag_preview(dot)
	elif preview_builder.is_valid():
		set_drag_preview(preview_builder.call())
	else:
		var ghost := Label.new()
		ghost.text = drag_label
		ghost.add_theme_color_override("font_color", Color.WHITE)
		set_drag_preview(ghost)
	return payload

func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if can_drop_fn.is_valid():
		return bool(can_drop_fn.call(data))
	return false

func _drop_data(_at: Vector2, data: Variant) -> void:
	if drop_fn.is_valid():
		drop_fn.call(data)

func _notification(what: int) -> void:
	# While a drag is in flight: dim the source card, glow legal targets.
	if what == NOTIFICATION_DRAG_BEGIN:
		if _is_drag_source:
			modulate = Color(1, 1, 1, 0.35)
		elif active_drag != null:
			var check := highlight_check if highlight_check.is_valid() else can_drop_fn
			if check.is_valid() and bool(check.call(active_drag)):
				# self_modulate glows only this node's own panel, not its
				# children, so a drop ZONE lights up without brightening the
				# cards/auras sitting inside it.
				if glow_self:
					self_modulate = Color(1.45, 1.45, 1.1)
				else:
					modulate = Color(1.45, 1.45, 1.1)
	elif what == NOTIFICATION_DRAG_END:
		active_drag = null
		aim_from = Vector2.INF
		_is_drag_source = false
		modulate = rest_modulate
		self_modulate = Color.WHITE
