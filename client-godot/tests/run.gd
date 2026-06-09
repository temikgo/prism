extends SceneTree

# Headless client test runner: asserts the pure client logic (CardData rules,
# GameState diffing) and the view-query helpers on Main, using DevKit mock views.
# No server, no rendering needed. Run with:
#   Godot --headless --path . -s tests/run.gd
# Prints "PASS n/n" and exits non-zero on any failure (so CI can gate on it).
# Card ids used below are real entries in cards.json -- if one is renamed/removed
# the relevant assert fails loudly, which is the point.

var _pass := 0
var _fail := 0
var _main


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: %s" % msg)


func _eq(actual, expected, msg: String) -> void:
	_ok(actual == expected, "%s (got %s, want %s)" % [msg, str(actual), str(expected)])


func _approx(actual: float, expected: float, msg: String) -> void:
	_ok(is_equal_approx(actual, expected), "%s (got %f, want %f)" % [msg, actual, expected])


func _initialize() -> void:
	DevKit.ensure_cards()
	_test_devkit()
	_test_card_data()
	_test_rules()
	_test_game_state()
	_test_main_helpers()
	print("PASS %d/%d" % [_pass, _pass + _fail])
	quit(1 if _fail > 0 else 0)


func _test_devkit() -> void:
	# The shared demo board (used by Shot.gd) must reference only real cards -- this
	# is what stops the screenshot mock from silently rotting when a card is renamed.
	_eq(DevKit.validate(DevKit.demo_view()), [], "demo_view references only real cards")
	# validate() actually catches a bad id
	var bad := DevKit.view(DevKit.player({"board": [DevKit.creature(1, "no_such_card", 1, 1)]}),
		DevKit.player({}))
	_ok(not DevKit.validate(bad).is_empty(), "validate flags an unknown card id")


func _test_card_data() -> void:
	# target side / needs_target on real cards
	_eq(CardData.target_side("blue_frost_shackles"), "enemy", "frost_shackles targets enemy")
	_eq(CardData.target_side("blue_ebbing_tide"), "any", "ebbing_tide targets any")
	_eq(CardData.target_side("red_stinging_glint"), "", "plain creature has no target")
	_ok(CardData.needs_target("blue_frost_shackles"), "frost_shackles needs a target")
	_ok(not CardData.needs_target("red_stinging_glint"), "plain creature needs no target")

	# target_required: no current card is a required-target cost -> all false...
	_ok(not CardData.target_required("blue_frost_shackles"), "optional target not required")
	# ...but the flag is honored when present (synthetic fixture).
	CardData.db["__test_sacrifice"] = {
		"id": "__test_sacrifice", "type": "spell", "name": {"ru": "T"},
		"effects": [{"trigger": "on_play", "selector": "chosen_friendly_minion",
			"action": "damage", "value": 99, "required": true}],
	}
	_ok(CardData.target_required("__test_sacrifice"), "required flag detected")
	CardData.db.erase("__test_sacrifice")

	# type predicates
	_ok(CardData.is_creature("red_stinging_glint"), "stinging_glint is a creature")
	_ok(CardData.is_spell("blue_frost_shackles"), "frost_shackles is a spell")

	# token display id falls back to the base family
	_eq(CardData.display_id("token_sprout2"), "token_sprout", "numbered token -> base family")

	# affordability (colored pip from its color, generic from anything left)
	_ok(CardData.can_afford({"red": 1}, {"red": 1}), "red pip paid by a red crystal")
	_ok(not CardData.can_afford({"red": 1}, {"red": 0, "blue": 3}), "no red crystal -> cannot pay red pip")
	_ok(CardData.can_afford({"generic": 2, "red": 1}, {"red": 1, "blue": 2}),
		"1 red + 2 generic from blue")
	_ok(not CardData.can_afford({"generic": 2, "red": 1}, {"red": 1, "blue": 1}),
		"not enough generic")
	_eq(CardData.total_cost({"generic": 2, "red": 1, "blue": 1}), 4, "total cost sums pips+generic")

	# spectral_shift: a spectrum-adjacent crystal may retune to pay a foreign pip
	_ok(not CardData.can_afford({"red": 1}, {"yellow": 1}), "yellow can't normally pay red")
	_ok(CardData.can_afford_with_shift({"red": 1}, {"yellow": 1}), "yellow shifts to red (adjacent)")
	_ok(not CardData.can_afford_with_shift({"red": 1}, {"green": 1}), "green is not adjacent to red")


func _test_game_state() -> void:
	var v := DevKit.view(
		DevKit.player({"board": [DevKit.creature(11, "red_stinging_glint", 2, 2, 3)]}),
		DevKit.player({"board": [DevKit.creature(21, "yellow_steadfast_warden", 0, 3, 4)]}))
	var d := GameState.diff({11: 3, 99: 5}, v)
	_eq(int(d["hp"][11]), 2, "diff records current hp")
	_eq(int(d["dmg"][11]), 1, "creature 11 took 1 damage (3->2)")
	_ok(d["summoned"].has(21), "creature 21 is newly summoned")
	_ok(not d["dmg"].has(21), "summoned creature is not counted as damaged")
	_eq(GameState.departed({11: 3, 99: 5}, d["hp"]), [99], "creature 99 departed")


func _test_rules() -> void:
	# A live board: your turn, you have mixed crystals, enemy has a provoker (warden)
	# and a stealthed creature.
	var enemy_board := [DevKit.creature(21, "yellow_steadfast_warden", 0, 4, 4),
		DevKit.creature(22, "violet_restless_phantom", 2, 3, 3, {"stealth": true})]
	var v := DevKit.view(
		DevKit.player({"mana": DevKit.mana(DevKit.pool(2, 0, 0, 1, 1, 0), DevKit.pool(2, 0, 0, 1, 1, 0))}),
		DevKit.player({"board": enemy_board}))

	_ok(Rules.my_turn(v), "you=0, current=0 -> your turn")
	_ok(not Rules.my_turn(DevKit.view(DevKit.player({}), DevKit.player({}), {"current": 1})),
		"current=1 -> not your turn")
	_ok(Rules.has_legal_target(v, "blue_frost_shackles"), "enemy has a non-stealth target")
	_ok(Rules.enemy_has_provoke(v), "warden provokes")
	_ok(Rules.valid_attack_target(v, enemy_board[0]), "the provoker is a valid attack target")
	_ok(not Rules.valid_attack_target(v, enemy_board[1]), "stealth/non-provoker is not")

	# generic-spend choice: needs >generic free crystals across >=2 colors
	_ok(not Rules.generic_choices(v, "red_scarlet_slash").is_empty(),
		"two+ free colors -> offer a generic-spend choice")
	var v1 := v.duplicate(true)
	v1["players"][0]["mana"]["available"] = DevKit.pool(0, 0, 0, 3, 0, 0)
	_eq(Rules.generic_choices(v1, "red_scarlet_slash"), {}, "one color free -> no choice")

	# no legal target when the enemy board is empty
	_ok(not Rules.has_legal_target(DevKit.view(DevKit.player({}), DevKit.player({})), "blue_frost_shackles"),
		"empty enemy board -> no target")

	# can_play_here / can_cast_on operate on the drag payload
	_ok(Rules.can_cast_on({"kind": "hand", "needs_target": true, "target_side": "enemy", "playable": true}, "enemy"),
		"enemy spell may cast on an enemy creature")
	_ok(not Rules.can_cast_on({"kind": "hand", "needs_target": true, "target_side": "enemy", "playable": true}, "friendly"),
		"enemy spell may not cast on a friendly creature")


func _test_main_helpers() -> void:
	_main = load("res://Main.tscn").instantiate()
	root.add_child(_main)

	# PilesColumn.cap_h: empty pool -> the "no mana" line; else ceil(total/4)*40, capped at 3 rows
	_approx(PilesColumn.cap_h(DevKit.mana(DevKit.pool(0, 0, 0, 0, 0, 0), DevKit.pool(0, 0, 0, 0, 0, 0))),
		26.0, "no mana -> 26px line")
	_approx(PilesColumn.cap_h(DevKit.mana(DevKit.pool(2, 1, 1, 1, 0, 0), DevKit.pool(2, 1, 1, 1, 0, 0))),
		80.0, "5 crystals -> 2 rows -> 80px")

	# _diff_hero_hp: only a drop counts; record updates
	var hv := DevKit.view(
		DevKit.player({"hero": DevKit.hero("hero_prism", "Ирида", "spectral_shift", 27, 0)}),
		DevKit.player({"hero": DevKit.hero("hero_eclipse", "Эреб", "lighteater", 20, 0)}))
	_main._prev_hero_hp = {0: 27, 1: 24}
	var hd: Dictionary = _main._diff_hero_hp(hv)
	_eq(int(hd.get(1, 0)), 4, "enemy hero took 4 face damage (24->20)")
	_ok(not hd.has(0), "your hero unchanged -> no entry")
