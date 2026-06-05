extends SceneTree

# Dev-only: render each shell screen standalone (no socket) to a PNG.
#   Godot --path . -s ShotMenu.gd
# Not shipped.

var _shots := []
var _i := 0
var _frame := 0
var _cur


func _initialize() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1100, 680))
	_shots = [
		["_menu", func(): return MainMenu.new()],
		["_play", func(): return PlayMenu.new()],
		["_create", func(): return CreateRoom.new()],
		["_join", func(): return JoinRoom.new()],
		["_wait", func():
			var w := RoomWait.new()
			w.setup("PEKY", "ws://127.0.0.1:8080")
			return w],
		["_settings", func(): return SettingsScreen.new()],
	]


func _process(_dt: float) -> bool:
	_frame += 1
	var phase := _frame % 8
	if phase == 1:
		if _i >= _shots.size():
			print("SHOTS_SAVED")
			return true
		_cur = _shots[_i][1].call()
		_cur.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.add_child(_cur)
	elif phase == 6:
		root.get_texture().get_image().save_png("res://%s.png" % _shots[_i][0])
		_cur.queue_free()
		_i += 1
	return false
