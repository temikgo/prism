class_name GameState

# Pure view-diffing helpers. Given the previous per-creature HP and a fresh view,
# work out what changed (damage / summons) so the coordinator can drive the right
# animations. No nodes, no UI -- just data in, data out (testable).

# Returns { "hp": {id: hp}, "dmg": {id: amount}, "summoned": {id: true} } for the
# board in `new_view`, comparing against `prev_hp`.
static func diff(prev_hp: Dictionary, new_view: Dictionary) -> Dictionary:
	var hp := {}
	for s in 2:
		for cr in new_view["players"][s].get("board", []):
			hp[int(cr["id"])] = int(cr["hp"])
	var dmg := {}
	var summoned := {}
	for id in hp:
		if prev_hp.has(id):
			if hp[id] < prev_hp[id]:
				dmg[id] = prev_hp[id] - hp[id]
		else:
			summoned[id] = true
	return {"hp": hp, "dmg": dmg, "summoned": summoned}


# Ids that were present last time but are gone now (creatures that died/left).
static func departed(prev_hp: Dictionary, new_hp: Dictionary) -> Array:
	var gone := []
	for id in prev_hp:
		if not new_hp.has(id):
			gone.append(id)
	return gone
