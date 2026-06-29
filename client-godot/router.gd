class_name Router
extends Control

# The application shell root and network hub. Owns the screen stack, the shared
# persisted settings (server address), and the single WebSocket connection used
# for the whole play flow -- the lobby (create/join a room) and then the match.
# Screens are lightweight Controls reporting choices up via signals; the Router
# routes incoming messages (lobby replies vs. match views) to the right place.
# See APP_SHELL.md.

const MATCH_SCENE := preload("res://Main.tscn")
const CONFIG_PATH := "user://settings.cfg"

var server_url := SettingsScreen.DEFAULT_URL
var chosen_hero := ""   # picked in LoadoutSelect, sent with create/join room
var chosen_deck := ""   # deck id; resolved to its card list when sent
var _screen: Control = null
var _net: Net = null
var _open := false
var _pending: Array = []  # actions queued while the socket is still connecting


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Project typography inherited by every screen below the router.
	theme = Fonts.default_theme()
	# Card data is needed app-wide now (the loadout screen lists heroes/decks),
	# not just inside a match; load it once here (Main re-loads idempotently).
	CardData.load_file("res://cards.json")
	CardData.load_file("res://tokens.json")
	# On the web build, default to the same origin the page was served from (the VPS
	# runs caddy: static client at / + a wss proxy to prism_server at /ws). Desktop
	# keeps the localhost default. A saved setting (below) overrides either.
	server_url = _default_server_url()
	_load_settings()
	# One shared backdrop lives here, behind every screen, instead of each screen
	# making its own. Screens swap above it, so the drifting particle field is
	# continuous and never resets/re-randomizes when routing between screens.
	add_child(Backdrop.new())
	_go_main()


# The server address to default to. On web that's the page's own origin as a
# WebSocket URL (wss on https) with the /ws path caddy proxies to prism_server;
# elsewhere the localhost dev default.
func _default_server_url() -> String:
	if OS.has_feature("web"):
		var host := str(JavaScriptBridge.eval("location.host", true))
		if host != "":
			var secure := str(JavaScriptBridge.eval("location.protocol", true)) == "https:"
			return ("wss://" if secure else "ws://") + host + "/ws"
	return SettingsScreen.DEFAULT_URL


func _swap(screen: Control) -> void:
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	_screen = screen
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(screen)


# --- screens -----------------------------------------------------------------

func _go_main() -> void:
	var m := MainMenu.new()
	m.play_pressed.connect(_go_loadout)
	m.decks_pressed.connect(func() -> void: _go_decks())
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


# Pressing "Играть" first picks the loadout (hero + deck); confirming enters the
# room flow with that choice.
func _go_loadout() -> void:
	var l := LoadoutSelect.new()
	l.setup(chosen_hero, chosen_deck)
	l.confirmed.connect(func(hero: String, deck: String) -> void:
		chosen_hero = hero
		chosen_deck = deck
		_save_settings()
		_go_play())
	l.back_pressed.connect(_leave_play)  # also drops a socket if one is open
	l.create_deck.connect(func() -> void: _go_deck_builder("", _go_loadout))
	l.edit_deck.connect(func(deck_id: String) -> void: _go_deck_builder(deck_id, _go_loadout))
	_swap(l)


# The deck collection (from the main menu or the loadout's "Создать колоду").
# `return_to` is where Back -- and a finished build -- goes: the screen that
# opened the collection, not always the main menu.
func _go_decks(return_to: Callable = Callable()) -> void:
	var ret := return_to if return_to.is_valid() else _go_main
	var m := DeckManager.new()
	# Editing from the collection returns to the collection (preserving its own
	# return target); the collection's Back goes to whoever opened it.
	m.edit_deck.connect(func(deck_id: String) -> void:
		_go_deck_builder(deck_id, func() -> void: _go_decks(ret)))
	m.back_pressed.connect(ret)
	_swap(m)


# Open the deck builder. `on_done` is where to go after saving or cancelling: back
# to the collection when opened from it, or straight to the loadout when the
# loadout's "Создать колоду" jumped here directly. A saved deck is selected.
func _go_deck_builder(deck_id: String, on_done: Callable) -> void:
	var b := DeckBuilder.new()
	if deck_id != "":
		b.setup(Decks.by_id(deck_id))
	b.saved.connect(func(deck: Dictionary) -> void:
		Decks.save_deck(deck)
		chosen_deck = String(deck["id"])
		_save_settings()
		on_done.call())
	b.back_pressed.connect(on_done)
	_swap(b)


func _go_play() -> void:
	_connect()  # open the socket while the player reads the menu
	var p := PlayMenu.new()
	p.create_pressed.connect(_go_create)
	p.join_pressed.connect(_go_join)
	p.train_pressed.connect(_go_train)
	p.mirror_train_pressed.connect(_go_mirror_train)
	p.back_pressed.connect(_go_loadout)  # back to re-pick hero/deck
	_swap(p)


# Single-player: ask the server to seat the bot and start the match at once. The
# match begins via the normal matchStart -> _go_match path (no waiting room).
func _go_train() -> void:
	_send(_room_msg("createBotRoom", {}))


# Mirror training: the bot is seated with the player's exact deck and hero (only
# the shuffle differs), so it is a pure play-skill test.
func _go_mirror_train() -> void:
	_send(_room_msg("createBotRoom", {"mirror": true}))


func _go_create() -> void:
	var c := CreateRoom.new()
	c.submit.connect(func(pw: String) -> void:
		_send(_room_msg("createRoom", {"password": pw})))
	c.back_pressed.connect(_go_play)
	_swap(c)


func _go_join() -> void:
	var j := JoinRoom.new()
	j.submit.connect(func(code: String, pw: String) -> void:
		_send(_room_msg("joinRoom", {"code": code, "password": pw})))
	j.back_pressed.connect(_go_play)
	_swap(j)


# A create/join-room message carrying the chosen hero and the deck's card list,
# so the server seats this player with that loadout instead of randomizing.
func _room_msg(action: String, fields: Dictionary) -> Dictionary:
	var msg := {"action": action}
	for k in fields:
		msg[k] = fields[k]
	msg["hero"] = chosen_hero
	msg["deck"] = Decks.by_id(chosen_deck).get("cards", [])
	return msg


func _go_room_wait(code: String) -> void:
	var w := RoomWait.new()
	w.setup(code, server_url)
	w.cancel_pressed.connect(func() -> void:
		_send({"action": "leaveRoom"})
		_go_play())
	_swap(w)


func _go_match() -> void:
	var m := MATCH_SCENE.instantiate()
	m.exit_to_menu.connect(_leave_match)
	_swap(m)
	# Hand the match its sender; views arrive via the router and are pushed in.
	m.bind(func(obj: Dictionary) -> void: _send(obj))


# Leave the whole play flow (back from the lobby): drop the socket, go home.
func _leave_play() -> void:
	_disconnect()
	_go_main()


# Leave an in-progress match: tell the server (only if still connected -- no
# point reopening a socket just to announce leaving), then home.
func _leave_match() -> void:
	if _open and _net != null:
		_net.send({"action": "leaveRoom"})
	_leave_play()


# --- network -----------------------------------------------------------------

# Ensure a live socket exists, opening one if there is none. Idempotent: safe to
# call on entering the play flow and before every send.
func _connect() -> void:
	if _net != null:
		return
	_open = false
	_net = Net.new()
	add_child(_net)
	_net.opened.connect(_on_open)
	_net.closed.connect(_on_close)
	_net.message.connect(_on_message)
	_net.connect_to(server_url)


func _disconnect() -> void:
	_open = false
	_pending.clear()
	if _net != null:
		_net.queue_free()
		_net = null


func _send(obj: Dictionary) -> void:
	if _open and _net != null:
		_net.send(obj)
	else:
		# Queue and (re)open the socket -- this also recovers after a server that
		# dropped and came back, where the old socket was closed and freed.
		_pending.append(obj)
		_connect()


func _on_open() -> void:
	_open = true
	for obj in _pending:
		_net.send(obj)
	_pending.clear()


func _on_close() -> void:
	# Free the dead socket so the next _connect() makes a fresh one (otherwise a
	# server restart would leave a closed socket that never reconnects).
	_open = false
	if _net != null:
		_net.queue_free()
		_net = null
	if _in_match():
		_screen.set_status("Соединение потеряно — нажмите «В меню»")
	elif _screen != null and _screen.has_method("notify"):
		_screen.notify("Нет связи с сервером")
	else:
		_leave_play()


# Dispatch a server message: lobby replies carry a "type"; a board view does not.
func _on_message(data: Dictionary) -> void:
	if data.has("type"):
		match String(data["type"]):
			"roomCreated":
				_go_room_wait(String(data.get("code", "")))
			"joinError":
				if _screen is JoinRoom:
					_screen.show_error(String(data.get("reason", "")))
			"matchStart":
				if not _in_match():
					_go_match()
			"opponentLeft":
				if _in_match():
					_screen.set_status("Соперник покинул матч — нажмите «В меню»")
		return
	# No "type" -> it's a redacted board view for the live match.
	if _in_match():
		_screen.feed_view(data)


func _in_match() -> bool:
	return _screen != null and _screen.has_method("feed_view")


# --- settings ----------------------------------------------------------------

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		server_url = String(cfg.get_value("net", "server_url", server_url))
		chosen_hero = String(cfg.get_value("loadout", "hero", chosen_hero))
		chosen_deck = String(cfg.get_value("loadout", "deck", chosen_deck))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "server_url", server_url)
	cfg.set_value("loadout", "hero", chosen_hero)
	cfg.set_value("loadout", "deck", chosen_deck)
	cfg.save(CONFIG_PATH)
