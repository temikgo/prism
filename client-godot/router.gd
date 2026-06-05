class_name Router
extends Control

# The application shell root. Owns the screen stack and the shared, persisted
# settings (server address), and switches between the menu screens and the live
# match. Screens are lightweight Controls that report choices up via signals;
# the Router decides where to go next. See APP_SHELL.md.

const MATCH_SCENE := preload("res://Main.tscn")
const CONFIG_PATH := "user://settings.cfg"

var server_url := SettingsScreen.DEFAULT_URL
var _screen: Control = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Project typography inherited by every screen below the router.
	theme = Fonts.default_theme()
	_load_settings()
	_go_main()


func _swap(screen: Control) -> void:
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	_screen = screen
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(screen)


func _go_main() -> void:
	var m := MainMenu.new()
	m.play_pressed.connect(_go_match)
	m.settings_pressed.connect(_go_settings)
	m.quit_pressed.connect(func() -> void: get_tree().quit())
	_swap(m)


func _go_settings() -> void:
	var s := SettingsScreen.new()
	s.setup(server_url)
	s.closed.connect(func(url: String) -> void:
		server_url = url
		_save_settings()
		_go_main())
	_swap(s)


func _go_match() -> void:
	var match_screen := MATCH_SCENE.instantiate()
	match_screen.exit_to_menu.connect(_go_main)
	_swap(match_screen)
	# start() opens the socket once the screen is in the tree.
	match_screen.start(server_url)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		server_url = String(cfg.get_value("net", "server_url", server_url))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "server_url", server_url)
	cfg.save(CONFIG_PATH)
