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
	# Script mode (-s) does not start project autoloads, so the global `Sfx` used
	# by Ui/Main is undefined here. Register it by hand at /root/Sfx so those code
	# paths resolve (and stay silent -- the headless audio driver is a no-op).
	if not root.has_node("Sfx"):
		var sfx: Node = load("res://sfx.gd").new()
		sfx.name = "Sfx"
		root.add_child(sfx)
	DevKit.ensure_cards()
	_test_devkit()
	_test_card_data()
	_test_rules()
	_test_decks()
	_test_game_state()
	_test_main_helpers()
	_test_turn_player()
	print("PASS %d/%d" % [_pass, _pass + _fail])
	quit(1 if _fail > 0 else 0)


func _test_decks() -> void:
	# Prune drops ids no longer in the set (a removed/renamed card); real ids stay.
	_eq(Decks._prune(["red_cinder_moth", "no_such_card_xyz"]), ["red_cinder_moth"],
		"prune removes the dead card id")
	_eq(DeckRules.counts(["a", "a", "b"]), {"a": 2, "b": 1}, "counts tallies copies")
	# A deck left short by pruning reads as illegal (cannot be queued).
	_ok(not DeckRules.list_legal(["red_cinder_moth"]), "a short deck is illegal")


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
	_eq(CardData.target_side("blue_frostgrip"), "enemy", "frost_grip targets enemy")
	_eq(CardData.target_side("blue_undertow"), "any", "undertow targets any")
	_eq(CardData.target_side("red_cinder_moth"), "", "plain creature has no target")
	_ok(CardData.needs_target("blue_frostgrip"), "frost_grip needs a target")
	_ok(not CardData.needs_target("red_cinder_moth"), "plain creature needs no target")
	_ok(CardData.has("red_cinder_moth"), "has() true for a real card")
	_ok(not CardData.has("no_such_card_xyz"), "has() false for a removed card")

	# redesign targeting: any-target burn hits enemy creatures AND the face;
	# blinded-only removal targets enemy; fight is flagged two-target.
	_eq(CardData.target_side("red_firespit"), "enemy", "any-target burn targets enemy creatures")
	_ok(CardData.hits_face("red_firespit"), "any-target burn can hit the face")
	_ok(not CardData.hits_face("blue_frostgrip"), "a plain freeze cannot hit the face")
	_eq(CardData.target_side("violet_verdict_of_dark"), "enemy", "blinded-only removal targets enemy")
	_ok(CardData.is_fight("green_stranglevine"), "fight card is flagged two-target")
	_ok(not CardData.is_fight("red_firespit"), "a burn is not a fight")

	# target_required: no current card is a required-target cost -> all false...
	_ok(not CardData.target_required("blue_frostgrip"), "optional target not required")
	# ...but the flag is honored when present (synthetic fixture).
	CardData.db["__test_sacrifice"] = {
		"id": "__test_sacrifice", "type": "spell", "name": {"ru": "T"},
		"effects": [{"trigger": "on_play", "selector": "chosen_friendly_minion",
			"action": "damage", "value": 99, "required": true}],
	}
	_ok(CardData.target_required("__test_sacrifice"), "required flag detected")
	CardData.db.erase("__test_sacrifice")

	# type predicates
	_ok(CardData.is_creature("red_cinder_moth"), "barbed_wasp is a creature")
	_ok(CardData.is_spell("blue_frostgrip"), "frost_grip is a spell")

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
		DevKit.player({"board": [DevKit.creature(11, "red_cinder_moth", 2, 2, 3)]}),
		DevKit.player({"board": [DevKit.creature(21, "yellow_haze_wall", 0, 3, 4)]}))
	var d := GameState.diff({11: 3, 99: 5}, v)
	_eq(int(d["hp"][11]), 2, "diff records current hp")
	_eq(int(d["dmg"][11]), 1, "creature 11 took 1 damage (3->2)")
	_ok(d["summoned"].has(21), "creature 21 is newly summoned")
	_ok(not d["dmg"].has(21), "summoned creature is not counted as damaged")
	_eq(GameState.departed({11: 3, 99: 5}, d["hp"]), [99], "creature 99 departed")


func _test_rules() -> void:
	# A live board: your turn, you have mixed crystals, enemy has a provoker (warden)
	# and a stealthed creature.
	var enemy_board := [DevKit.creature(21, "yellow_haze_wall", 0, 4, 4),
		DevKit.creature(22, "violet_unseen_prowler", 2, 3, 3, {"stealth": true})]
	var v := DevKit.view(
		DevKit.player({"mana": DevKit.mana(DevKit.pool(2, 0, 0, 1, 1, 0), DevKit.pool(2, 0, 0, 1, 1, 0))}),
		DevKit.player({"board": enemy_board}))

	_ok(Rules.my_turn(v), "you=0, current=0 -> your turn")
	_ok(not Rules.my_turn(DevKit.view(DevKit.player({}), DevKit.player({}), {"current": 1})),
		"current=1 -> not your turn")
	_ok(Rules.has_legal_target(v, "blue_frostgrip"), "enemy has a non-stealth target")
	_ok(Rules.enemy_has_provoke(v), "warden provokes")
	_ok(Rules.valid_attack_target(v, enemy_board[0]), "the provoker is a valid attack target")
	_ok(not Rules.valid_attack_target(v, enemy_board[1]), "stealth/non-provoker is not")

	# generic-spend choice: needs >generic free crystals across >=2 colors
	_ok(not Rules.generic_choices(v, "red_blast_beetle").is_empty(),
		"two+ free colors -> offer a generic-spend choice")
	var v1 := v.duplicate(true)
	v1["players"][0]["mana"]["available"] = DevKit.pool(0, 0, 0, 3, 0, 0)
	_eq(Rules.generic_choices(v1, "red_blast_beetle"), {}, "one color free -> no choice")

	# awaken's generic (after the banked crystal pays its pip) is payable >1 way
	var awv := DevKit.view(
		DevKit.player({"mana": DevKit.mana(DevKit.pool(2, 0, 1, 1, 0, 0), DevKit.pool(2, 0, 1, 1, 0, 0))}),
		DevKit.player({}))
	_ok(not Rules.awaken_generic_choices(awv, "blue_deep_freeze", "blue", 0).is_empty(),
		"awaken: free crystals across colors -> generic choice")
	var awv1 := awv.duplicate(true)
	awv1["players"][0]["mana"]["available"] = DevKit.pool(0, 0, 0, 3, 0, 0)
	_eq(Rules.awaken_generic_choices(awv1, "blue_deep_freeze", "blue", 0), {},
		"awaken: one color free -> no choice")

	# no legal target when the enemy board is empty
	_ok(not Rules.has_legal_target(DevKit.view(DevKit.player({}), DevKit.player({})), "blue_frostgrip"),
		"empty enemy board -> no target")

	# can_play_here / can_cast_on operate on the drag payload
	_ok(Rules.can_cast_on({"kind": "hand", "needs_target": true, "target_side": "enemy", "playable": true}, "enemy"),
		"enemy spell may cast on an enemy creature")
	_ok(not Rules.can_cast_on({"kind": "hand", "needs_target": true, "target_side": "enemy", "playable": true}, "friendly"),
		"enemy spell may not cast on a friendly creature")


func _test_main_helpers() -> void:
	_main = load("res://Main.tscn").instantiate()
	root.add_child(_main)

	# PilesColumn.cap_h: empty pool -> the "no mana" line; else ceil(total/PER_ROW)*40, capped at 3 rows
	_approx(PilesColumn.cap_h(DevKit.mana(DevKit.pool(0, 0, 0, 0, 0, 0), DevKit.pool(0, 0, 0, 0, 0, 0))),
		26.0, "no mana -> 26px line")
	_approx(PilesColumn.cap_h(DevKit.mana(DevKit.pool(2, 1, 1, 1, 0, 0), DevKit.pool(2, 1, 1, 1, 0, 0))),
		40.0, "5 crystals -> 1 row -> 40px")
	_approx(PilesColumn.cap_h(DevKit.mana(DevKit.pool(3, 3, 0, 0, 0, 0), DevKit.pool(3, 3, 0, 0, 0, 0))),
		80.0, "6 crystals -> 2 rows -> 80px")

	# _diff_hero_hp: only a drop counts; record updates
	var hv := DevKit.view(
		DevKit.player({"hero": DevKit.hero("hero_prism", "Ирида", "spectral_shift", 27, 0)}),
		DevKit.player({"hero": DevKit.hero("hero_eclipse", "Эреб", "lighteater", 20, 0)}))
	_main._prev_hero_hp = {0: 27, 1: 24}
	var hd: Dictionary = _main._diff_hero_hp(hv)
	_eq(int(hd.get(1, 0)), 4, "enemy hero took 4 face damage (24->20)")
	_ok(not hd.has(0), "your hero unchanged -> no entry")

	# _valid_view: a view is only safe to apply with players[2] and a seat in {0,1}
	# (ingest indexes players[you]/[1-you] unchecked below the guard -- B12/B13).
	_ok(_main._valid_view(hv), "a well-formed view is valid")
	_ok(not _main._valid_view({}), "empty view rejected (no players)")
	_ok(not _main._valid_view({"players": []}), "short players array rejected")
	_ok(not _main._valid_view({"turn": 3, "over": false}), "players-less view rejected")
	_ok(not _main._valid_view({"players": [{}, {}], "you": 2}),
		"seat outside {0,1} rejected")
	_ok(not _main._valid_view({"players": [{}, {}]}), "missing 'you' rejected")

	# Pile pulse wiring: the deck/discard/hand count tiles must be exposed for BOTH
	# sides (the coordinator pulses any tile whose number changed, either player's).
	var pmine := DevKit.player({"deckCount": 20, "graveyardCount": 2, "handCount": 5,
		"mana": DevKit.mana(DevKit.pool(3, 0, 0, 0, 0, 0), DevKit.pool(3, 0, 0, 0, 0, 0))})
	for mine in [true, false]:
		var pc := PilesColumn.new()
		root.add_child(pc)
		pc.setup(pmine, mine, {})
		_ok(is_instance_valid(pc.deck_node), "PilesColumn exposes deck tile (mine=%s)" % mine)
		_ok(is_instance_valid(pc.grave_node), "PilesColumn exposes grave tile (mine=%s)" % mine)
		_ok(is_instance_valid(pc.hand_node), "PilesColumn exposes hand tile (mine=%s)" % mine)
		pc.queue_free()


# TurnPlayer's ordering/pacing decisions: your own actions and prompts apply
# instantly; the opponent's actions are paced (reveal + settle). You (seat 0).
func _test_turn_player() -> void:
	# A creature play is paced (pop-in + settle) but has no centre reveal; a spell
	# play is paced AND reveals (it leaves no board entrance of its own).
	var opp_cr := {"you": 0, "event": {"seat": 1, "action": "play", "card": "red_cinder_moth"}}
	_ok(TurnPlayer.is_paced(opp_cr, opp_cr["event"]), "opponent creature play is paced")
	_approx(TurnPlayer.reveal_secs(opp_cr["event"]), 0.0, "creature play has no reveal lead")
	var opp_sp := {"you": 0, "event": {"seat": 1, "action": "play", "card": "yellow_eclipse"}}
	_approx(TurnPlayer.reveal_secs(opp_sp["event"]), 1.1, "spell play reveals before applying")

	var my_play := {"you": 0, "event": {"seat": 0, "action": "play", "card": "yellow_eclipse"}}
	_ok(not TurnPlayer.is_paced(my_play, my_play["event"]), "your own action is instant")

	var no_event := {"you": 0}
	_ok(not TurnPlayer.is_paced(no_event, {}), "an event-less sync is instant")

	# A prompt view (even if it also carries the opponent's play) is never paced.
	var opp_decision := {"you": 0, "decision": {"youDecide": true},
		"event": {"seat": 1, "action": "play", "card": "the_ultimatum"}}
	_ok(TurnPlayer.is_prompt(opp_decision), "decision view is a prompt")
	_ok(not TurnPlayer.is_paced(opp_decision, opp_decision["event"]), "a prompt shows at once")
	for k in ["mulligan", "scry", "over"]:
		var pv := {"you": 0}
		pv[k] = true if k != "scry" else [0]
		_ok(TurnPlayer.is_prompt(pv), "%s view is a prompt" % k)

	# An opponent attack lunges (no card reveal) then settles.
	var opp_atk := {"you": 0, "event": {"seat": 1, "action": "attackHero", "attacker": 5}}
	_approx(TurnPlayer.reveal_secs(opp_atk["event"]), 0.0, "attack has no reveal lead")
	_ok(TurnPlayer.settle_secs(opp_atk["event"]) > 0.0, "attack settles after the lunge")
