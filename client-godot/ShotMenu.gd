extends SceneTree

# Dev-only: render the app shell (router -> main menu, then settings) to PNGs.
#   Godot --path . -s ShotMenu.gd
# Not shipped.

var _router
var _frame := 0


func _initialize() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1500, 900))
	_router = load("res://App.tscn").instantiate()
	root.add_child(_router)


func _process(_dt: float) -> bool:
	_frame += 1
	if _frame == 10:
		root.get_texture().get_image().save_png("res://_menu.png")
	if _frame == 12:
		_router._go_settings()
	if _frame == 22:
		root.get_texture().get_image().save_png("res://_settings.png")
		print("SHOTS_SAVED")
		return true
	return false
