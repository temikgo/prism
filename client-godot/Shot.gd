extends SceneTree

# Dev-only screenshot harness: instantiate the real client, feed it a VALID mock
# view (built via DevKit, so card ids are checked against cards.json and a stale
# mock fails loudly instead of rendering blank), then save a PNG. Run with:
#   Godot --path . -s Shot.gd
# Not shipped to players.

var _main
var _frame := 0


func _initialize() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1500, 900))
	_main = load("res://Main.tscn").instantiate()
	root.add_child(_main)


func _process(_dt: float) -> bool:
	_frame += 1
	if _frame == 3:
		var mock := DevKit.demo_view()
		var bad := DevKit.validate(mock)
		if not bad.is_empty():
			printerr("MOCK_INVALID: %s" % str(bad))
			quit(1)
			return true
		_main.view = mock
		_main._rebuild()
		_main._topbar.visible = false  # hide the leave button for the mock shot
	if _frame == 16:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot.png")
		print("SHOT_SAVED")
		return true
	return false
