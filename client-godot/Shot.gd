extends SceneTree

# Dev-only screenshot harness: instantiate the real client, feed it a mock view
# (no server), let it build the board, then save a PNG. Run with:
#   Godot --path . -s Shot.gd
# Not shipped to players.

var _main
var _frame := 0


func _cr(id_num: int, card: String, atk: int, hp: int, max_hp: int, extra := {}) -> Dictionary:
	var c := {
		"id": id_num, "card": card, "atk": atk, "hp": hp, "maxHp": max_hp,
		"sick": false, "attacked": false, "usedActive": false,
		"frozen": 0, "blind": 0, "shield": false, "ward": false,
		"stealth": false, "token": false,
	}
	for k in extra:
		c[k] = extra[k]
	return c


func _mana(r: int, y: int, g: int, b: int, v: int, n: int) -> Dictionary:
	return {"red": r, "yellow": y, "green": g, "blue": b, "violet": v, "colorless": n}


func _hero(card: String, name: String, passive: String, hp: int, armor: int) -> Dictionary:
	return {"hp": hp, "armor": armor, "card": card, "name": name,
		"passive": [{"id": passive}]}


func _mock() -> Dictionary:
	var me := {
		"hero": _hero("hero_prism", "Ирида", "spectral_shift", 27, 0),
		"mana": {"crystals": _mana(2, 0, 1, 1, 0, 1), "available": _mana(1, 0, 1, 1, 0, 1)},
		"manaRow": [{"color": "red", "card": "red_scarlet_sting", "age": 1},
			{"color": "green", "age": 2}, {"color": "colorless", "age": 0}],
		"handCount": 4,
		"hand": ["green_forest_matron", "blue_deep_oracle", "yellow_blue_blinding_rime",
			"prismatic_seraph"],
		"shiftUsed": false, "deckCount": 18, "graveyardCount": 3, "pendingCount": 0,
		"mulliganDone": true,
		"board": [
			_cr(11, "red_scarlet_sting", 2, 1, 1),
			_cr(12, "green_forest_matron", 2, 3, 3, {"shield": true}),
			_cr(13, "yellow_beacon_ward", 1, 3, 3),
		],
		"auras": [{"card": "green_lightsprout"}],
	}
	var opp := {
		"hero": _hero("hero_eclipse", "Эреб", "umbra", 24, 2),
		"mana": {"crystals": _mana(1, 2, 0, 0, 1, 1), "available": _mana(1, 2, 0, 0, 1, 1)},
		"manaRow": [{"color": "yellow"}, {"color": "violet"}],
		"handCount": 5,
		"deckCount": 16, "graveyardCount": 1, "pendingCount": 1,
		"mulliganDone": true,
		"board": [
			_cr(21, "blue_deep_oracle", 4, 6, 6, {"frozen": 1}),
			_cr(22, "violet_dusk_stalker", 3, 2, 2, {"stealth": true}),
		],
		"auras": [],
	}
	return {"turn": 5, "current": 0, "you": 0, "mulligan": false,
		"over": false, "winner": -1, "players": [me, opp]}


func _initialize() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1500, 900))
	_main = load("res://Main.tscn").instantiate()
	root.add_child(_main)


func _process(_dt: float) -> bool:
	_frame += 1
	if _frame == 3:
		_main.view = _mock()
		_main._rebuild()
		_main._topbar.visible = false  # hide the leave button for the mock shot
	if _frame == 16:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot.png")
		print("SHOT_SAVED")
		return true
	return false
