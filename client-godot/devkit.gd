class_name DevKit

# Dev/test-only helper: build VALID mock views and mount the client without a
# server. Every card id passed in is checked against cards.json/tokens.json, so a
# mock that references a renamed or deleted card fails loudly instead of rendering
# an empty frame (the bug that bit the old hand-rolled Shot.gd mock). Used by
# Shot.gd and tests/run.gd. NOT shipped to players.

# Card ids that failed validation since the last reset (for harness assertions).
static var _problems: Array = []


static func ensure_cards() -> void:
	if CardData.db.is_empty():
		CardData.load_file("res://cards.json")
		CardData.load_file("res://tokens.json")


static func reset_problems() -> void:
	_problems = []


static func problems() -> Array:
	return _problems


# Resolve+validate a card id; record and warn if it is unknown.
static func _check(id: String) -> String:
	ensure_cards()
	if CardData.def(id).is_empty():
		if not _problems.has(id):
			_problems.append(id)
		push_error("DevKit: unknown card id '%s' (not in cards.json/tokens.json)" % id)
	return id


# A mana color->count map (the shape the view uses for crystals/available).
static func pool(r: int, y: int, g: int, b: int, v: int, n: int) -> Dictionary:
	return {"red": r, "yellow": y, "green": g, "blue": b, "violet": v, "colorless": n}


static func mana(crystals: Dictionary, available: Dictionary) -> Dictionary:
	return {"crystals": crystals, "available": available}


# A board creature entry. `extra` overrides any default field (e.g. {"shield": true}).
static func creature(eid: int, card_id: String, atk: int, hp: int,
		max_hp: int = -1, extra: Dictionary = {}) -> Dictionary:
	_check(card_id)
	var c := {
		"id": eid, "card": card_id, "atk": atk, "hp": hp,
		"maxHp": (hp if max_hp < 0 else max_hp),
		"sick": false, "attacked": false, "usedActive": false,
		"frozen": 0, "blind": 0, "shield": false, "ward": false,
		"stealth": false, "token": false,
	}
	for k in extra:
		c[k] = extra[k]
	return c


static func hero(card_id: String, name: String, passive: String,
		hp: int, armor: int) -> Dictionary:
	_check(card_id)
	return {"hp": hp, "armor": armor, "card": card_id, "name": name,
		"passive": [{"id": passive}]}


# One player side, with sane defaults; `opts` overrides any field. Pass `hand`
# (own side) as an array of card ids; handCount defaults to its size.
static func player(opts: Dictionary = {}) -> Dictionary:
	var hnd: Array = opts.get("hand", [])
	var p := {
		"hero": opts.get("hero", hero("hero_prism", "Ирида", "spectral_shift", 27, 0)),
		"mana": opts.get("mana", mana(pool(1, 0, 0, 0, 0, 0), pool(1, 0, 0, 0, 0, 0))),
		"manaRow": opts.get("manaRow", []),
		"handCount": opts.get("handCount", hnd.size()),
		"deckCount": opts.get("deckCount", 20),
		"graveyardCount": opts.get("graveyardCount", 0),
		"pendingCount": opts.get("pendingCount", 0),
		"mulliganDone": opts.get("mulliganDone", true),
		"board": opts.get("board", []),
		"auras": opts.get("auras", []),
	}
	if opts.has("hand"):
		p["hand"] = hnd
	if opts.has("heroPowerUsed"):
		p["heroPowerUsed"] = opts["heroPowerUsed"]
	if opts.has("placedMana"):
		p["placedMana"] = opts["placedMana"]
	return p


# A full top-level view for two players. `you`/`current`/`turn` default to a live
# board on your turn; pass overrides via `extra`.
static func view(me: Dictionary, opp: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var v := {
		"turn": extra.get("turn", 5), "current": extra.get("current", 0),
		"you": extra.get("you", 0), "mulligan": extra.get("mulligan", false),
		"over": extra.get("over", false), "winner": extra.get("winner", -1),
		"players": [me, opp],
	}
	if extra.has("scry"):
		v["scry"] = extra["scry"]
	return v


# Walk a view and return every card id that is not in the database (empty = good).
# Covers hero, board, hand, manaRow and auras on both sides.
static func validate(v: Dictionary) -> Array:
	ensure_cards()
	var bad := []
	var add := func(id: String) -> void:
		if id != "" and CardData.def(id).is_empty() and not bad.has(id):
			bad.append(id)
	for p in v.get("players", []):
		add.call(String(p.get("hero", {}).get("card", "")))
		for cr in p.get("board", []):
			add.call(String(cr.get("card", "")))
		for id in p.get("hand", []):
			add.call(String(id))
		for slot in p.get("manaRow", []):
			if slot.has("card"):
				add.call(String(slot["card"]))
		for a in p.get("auras", []):
			add.call(String(a.get("card", "")))
	return bad


# A canonical, fully-populated demo board (both sides: heroes, creatures with
# statuses, hand, mana row, aura). One shared source for the screenshot stand and
# the test runner, so its card ids are validated on every CI run (no silent rot).
static func demo_view() -> Dictionary:
	var me := player({
		"hero": hero("hero_prism", "Ирида", "spectral_shift", 27, 0),
		"mana": mana(pool(2, 0, 1, 1, 0, 1), pool(1, 0, 1, 1, 0, 1)),
		"manaRow": [
			{"color": "red", "card": "red_cinder_moth", "age": 1},
			{"color": "green", "age": 2},
			{"color": "colorless", "age": 0},
		],
		"hand": ["green_grove_warden", "blue_winter_stream", "yellow_corona_serpent",
			"blue_farsight"],
		"heroPowerUsed": false, "deckCount": 18, "graveyardCount": 3, "pendingCount": 0,
		"board": [
			creature(11, "red_cinder_moth", 2, 1, 1),
			creature(12, "green_bounty_tree", 1, 2, 2, {"shield": true}),
			creature(13, "yellow_haze_wall", 0, 4, 4),
		],
		"auras": [{"card": "blue_cold_snap"}],
	})
	var opp := player({
		"hero": hero("hero_eclipse", "Эреб", "lighteater", 24, 2),
		"mana": mana(pool(1, 2, 0, 0, 1, 1), pool(1, 2, 0, 0, 1, 1)),
		"manaRow": [{"color": "yellow"}, {"color": "violet"}],
		"handCount": 5, "deckCount": 16, "graveyardCount": 1, "pendingCount": 1,
		"board": [
			creature(21, "blue_frost_sentinel", 2, 4, 4, {"frozen": 1}),
			creature(22, "violet_pale_phantom", 2, 3, 3, {"stealth": true}),
		],
	})
	return view(me, opp, {"turn": 5, "current": 0, "you": 0})


# Instantiate the real Main scene and feed it a valid view. Returns the Main node
# with its card db and view wired in, ready for helper calls. NOTE: Main._ready
# (which builds the shell) is deferred to the next frame, so call _rebuild()
# yourself after one process frame if you need the board rendered (see Shot.gd).
static func mount(tree: SceneTree, v: Dictionary) -> Node:
	var bad := validate(v)
	assert(bad.is_empty(), "DevKit.mount: invalid card ids in view: %s" % str(bad))
	ensure_cards()
	var main: Node = load("res://Main.tscn").instantiate()
	tree.root.add_child(main)
	main.cards = CardData.db
	main.view = v
	return main
