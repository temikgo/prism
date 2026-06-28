class_name RadialPicker
extends Control

# A color chooser drawn as a ring split into equal sectors -- one per available
# color. The footprint is fixed no matter how many colors there are. Click a
# sector to pick it, or the hole in the middle to cancel.

signal picked(color_id: String)
signal cancelled

const R := 84.0    # outer radius
const HOLE := 30.0  # inner radius (the cancel hole)

var colors: PackedStringArray = PackedStringArray()
var _hover := -2  # -2 nothing, -1 the cancel hole, >=0 a sector
var _label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(R * 2.0 + 6.0, R * 2.0 + 6.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 13)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)


func _center() -> Vector2:
	return size * 0.5


# Which sector a point falls in: -1 = the cancel hole, -2 = outside, else index.
func _sector_at(p: Vector2) -> int:
	var d := p - _center()
	var dist := d.length()
	if dist < HOLE:
		return -1
	if dist > R:
		return -2
	var n := colors.size()
	if n == 0:
		return -2
	var a := fposmod(d.angle() + PI * 0.5, TAU)  # 0 at the top, clockwise
	return int(a / (TAU / n)) % n


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var h := _sector_at(event.position)
		if h != _hover:
			_hover = h
			if h == -1:
				_label.text = "отмена"
			elif h >= 0:
				_label.text = Palette.ru(String(colors[h]))
			else:
				_label.text = ""
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var s := _sector_at(event.position)
		if s == -1:
			cancelled.emit()
		elif s >= 0:
			picked.emit(String(colors[s]))


func _draw() -> void:
	var c := _center()
	var n := colors.size()
	if n == 0:
		return
	var step := TAU / n
	var start := -PI * 0.5  # first sector starts at the top
	for i in n:
		var col := Palette.color_for(String(colors[i]))
		if i == _hover:
			col = col.lightened(0.3)
		else:
			col = col.darkened(0.05)
		var a0 := start + i * step
		var a1 := start + (i + 1) * step
		var seg := maxi(4, int(step / 0.12))
		var pts := PackedVector2Array()
		for s in seg + 1:
			var a := lerpf(a0, a1, float(s) / seg)
			pts.append(c + Vector2(cos(a), sin(a)) * R)
		for s in range(seg, -1, -1):
			var a := lerpf(a0, a1, float(s) / seg)
			pts.append(c + Vector2(cos(a), sin(a)) * HOLE)
		draw_colored_polygon(pts, col)
		# Dark seam between sectors.
		var dir := Vector2(cos(a0), sin(a0))
		draw_line(c + dir * HOLE, c + dir * R, Color(0.05, 0.06, 0.09), 2.0)
	draw_arc(c, R, 0, TAU, 72, Color(0.85, 0.88, 0.96, 0.55), 2.0)
	draw_circle(c, HOLE, Color(0.06, 0.07, 0.11, 0.96))
	draw_arc(c, HOLE, 0, TAU, 36, Color(0.6, 0.63, 0.72, 0.6), 1.5)
