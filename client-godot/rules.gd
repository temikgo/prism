class_name Rules

# Pure legality queries over a live server `view`: whose turn it is, whether a
# card is playable, whether a target/attack is legal, how the generic cost may be
# paid. The companion to CardData (which answers "what a card IS"); Rules answers
# "what is legal right now". No nodes, no Main state -- data in, answer out -- so
# both Main and the view widgets can ask without reaching into the coordinator.
# This is the testable seam for interaction rules (see tests/run.gd).

const BOARD_LIMIT := 8  # max creatures per side (mirrors the engine)


static func my_turn(view: Dictionary) -> bool:
	if bool(view.get("over", false)):
		return false  # the game is decided -- no actions
	return int(view.get("current", -1)) == int(view.get("you", -2))


# You may bank exactly one card to mana per turn (engine: placedManaThisTurn).
static func can_place_mana(view: Dictionary) -> bool:
	if not my_turn(view):
		return false
	var you := int(view.get("you", -1))
	if you < 0:
		return false
	return not bool(view["players"][you].get("placedMana", false))


# Does this player's hero carry the given passive keyword?
static func hero_has(p: Dictionary, passive_id: String) -> bool:
	for kw in p.get("hero", {}).get("passive", []):
		if String(kw.get("id", "")) == passive_id:
			return true
	return false


# Playable right now: your turn, affordable (incl. Prism spectral_shift), and (for
# creatures) the board has room; auras you already control are blocked; a targeted
# spell with no legal target is still playable unless the target is a required cost.
# Blue haze: each enemy haze aura makes YOUR spells cost that much more generic
# (mirrors Game::playCard). 0 for non-spells or when there is no enemy haze.
static func haze_surcharge(view: Dictionary, card_id: String) -> int:
	if view.is_empty() or not CardData.is_spell(card_id):
		return 0
	var you := int(view["you"])
	var opp: Dictionary = view["players"][1 - you]
	var n := 0
	for a in opp.get("auras", []):
		n += CardData.keyword_n(String(a.get("card", "")), "haze")
	return n


# The card's cost as it must actually be paid right now: base cost + haze.
static func effective_cost(view: Dictionary, card_id: String) -> Dictionary:
	var cost: Dictionary = (CardData.def(card_id).get("cost", {})).duplicate(true)
	var hz := haze_surcharge(view, card_id)
	if hz > 0:
		cost["generic"] = int(cost.get("generic", 0)) + hz
	return cost


static func is_playable(view: Dictionary, card_id: String) -> bool:
	if not my_turn(view):
		return false
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var cost: Dictionary = effective_cost(view, card_id)
	var avail: Dictionary = me["mana"].get("available", {})
	var shift_ready: bool = hero_has(me, "spectral_shift") and not bool(me.get("heroPowerUsed", false))
	if not CardData.can_afford(cost, avail) and not (shift_ready and CardData.can_afford_with_shift(cost, avail)):
		return false
	if CardData.is_creature(card_id) and int(me.get("board", []).size()) >= BOARD_LIMIT:
		return false
	if String(CardData.def(card_id).get("type", "")) == "aura":
		for a in me.get("auras", []):
			if String(a.get("card", "")) == card_id:
				return false
	if CardData.needs_target(card_id) and not has_legal_target(view, card_id) and CardData.target_required(card_id):
		return false
	return true


# Is there at least one legal target for this card's targeted effect?
static func has_legal_target(view: Dictionary, card_id: String) -> bool:
	var side := CardData.target_side(card_id)
	if side == "":
		return true
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var opp: Dictionary = view["players"][1 - you]
	if side == "enemy" or side == "any":
		for c in opp.get("board", []):
			if not bool(c.get("stealth", false)):
				return true
	if side == "friendly" or side == "any":
		if not me.get("board", []).is_empty():
			return true
	if side == "enemy_aura":
		return not opp.get("auras", []).is_empty()
	return false


# True if the dragged card targets an ENEMY AURA (dispel-choose). The aura tiles
# become its drop targets, reporting the aura's index as the play target.
static func can_cast_on_aura(data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not (data.get("kind", "") in ["hand", "awaken"]):
		return false
	if not bool(data.get("needs_target", false)):
		return false
	if String(data.get("target_side", "")) != "enemy_aura":
		return false
	if data.get("kind", "") == "hand" and not bool(data.get("playable", true)):
		return false
	return true


# Does the enemy control a (visible) provoker, forcing attacks onto it?
static func enemy_has_provoke(view: Dictionary) -> bool:
	var you := int(view["you"])
	var opp: Dictionary = view["players"][1 - you]
	for c in opp.get("board", []):
		if bool(c.get("stealth", false)):
			continue
		if CardData.has_keyword(String(c["card"]), "provoke"):
			return true
	return false


# A legal attack target: not hidden, and if a provoker exists you may only hit a provoker.
static func valid_attack_target(view: Dictionary, cr: Dictionary) -> bool:
	if bool(cr.get("stealth", false)):
		return false
	if enemy_has_provoke(view) and not CardData.has_keyword(String(cr["card"]), "provoke"):
		return false
	return true


# Can the dragged hand/awaken card be dropped on your board zone? A targeted spell
# is dropped on a creature instead -- unless it has no legal target and the effect
# is optional, in which case it may be played to the board (the effect skips).
static func can_play_here(view: Dictionary, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not (data.get("kind", "") in ["hand", "awaken"]):
		return false
	if data.get("kind", "") == "hand" and not bool(data.get("playable", true)):
		return false
	if bool(data.get("needs_target", false)):
		var cid := String(data.get("card_id", ""))
		return not has_legal_target(view, cid) and not CardData.target_required(cid)
	return true


# True if the dragged targeted spell/awaken may be cast on a creature of the given
# side ("friendly"/"enemy"). An "any" spell hits either side. (Independent of view.)
static func can_cast_on(data: Variant, want_side: String) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not (data.get("kind", "") in ["hand", "awaken"]):
		return false
	if not bool(data.get("needs_target", false)):
		return false
	var side := String(data.get("target_side", ""))
	if side != "any" and side != want_side:
		return false
	if data.get("kind", "") == "hand" and not bool(data.get("playable", true)):
		return false
	return true


# Can you awaken this banked card right now? Mirrors Game::awaken: its own crystal
# must be unspent and pays 1 of the cost in its color (else 1 generic); the
# remainder must be affordable. A decoy aged >= N awakens for just its own crystal.
static func can_awaken(view: Dictionary, card_id: String, color: String, age: int) -> bool:
	if not my_turn(view):
		return false
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var avail: Dictionary = me["mana"].get("available", {})
	if int(avail.get(color, 0)) < 1:
		return false  # the banked crystal itself must still be available
	if CardData.is_creature(card_id) and int(me.get("board", []).size()) >= BOARD_LIMIT:
		return false
	if CardData.has_keyword(card_id, "decoy") and age >= CardData.keyword_n(card_id, "decoy"):
		return true  # aged decoy: only the banked crystal is spent
	var cost: Dictionary = (CardData.def(card_id).get("cost", {})).duplicate(true)
	if int(cost.get(color, 0)) > 0:
		cost[color] = int(cost[color]) - 1
	elif int(cost.get("generic", 0)) > 0:
		cost["generic"] = int(cost["generic"]) - 1
	var pool: Dictionary = avail.duplicate(true)
	pool[color] = int(pool.get(color, 0)) - 1  # the banked crystal is consumed
	return CardData.can_afford(cost, pool)


# {generic, avail, pips} when paying the card's generic cost is ambiguous (free
# crystals -- available minus reserved pips -- span >= 2 colors and exceed the
# generic amount), else {} (pay greedily, no prompt).
static func generic_choices(view: Dictionary, card_id: String) -> Dictionary:
	if card_id == "" or view.is_empty():
		return {}
	var cost: Dictionary = effective_cost(view, card_id)  # base + haze surcharge
	var generic := int(cost.get("generic", 0))
	if generic <= 0:
		return {}
	var you := int(view["you"])
	var avail: Dictionary = view["players"][you].get("mana", {}).get("available", {})
	var total_free := 0
	var colors_with_free := 0
	var pips := {}
	for color in CardData.ALL_COLORS:
		pips[color] = int(cost.get(color, 0))
		var f: int = maxi(0, int(avail.get(color, 0)) - int(pips[color]))
		total_free += f
		if f > 0:
			colors_with_free += 1
	if total_free > generic and colors_with_free >= 2:
		return {"generic": generic, "avail": avail, "pips": pips}
	return {}
