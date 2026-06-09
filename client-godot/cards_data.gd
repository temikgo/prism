class_name CardData

# Static, pure access to the card/token database (loaded once from cards.json +
# tokens.json). No game-state here -- only what a card *is* (identity, cost,
# keywords, target rules). Everything that depends on the live board lives in
# GameState/Main. This is the testable seam: pass data in, get answers out.

static var db := {}  # card id -> definition dictionary

const COLORS := ["red", "yellow", "green", "blue", "violet"]
const ALL_COLORS := ["red", "yellow", "green", "blue", "violet", "colorless"]


static func load_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_ARRAY:
		for c in data:
			db[c["id"]] = c


# Generated tokens are numbered per size (e.g. germinate's "token_sprout2"); fall
# back to the base family ("token_sprout") so they share its name and art.
static func display_id(id: String) -> String:
	if db.has(id):
		return id
	var base := id.rstrip("0123456789")
	if base != "" and base != id and db.has(base):
		return base
	return id


static func def(id: String) -> Dictionary:
	return db.get(display_id(id), {})


static func name_of(card_id: String) -> String:
	var d := def(card_id)
	if d.has("name"):
		return d["name"].get("ru", card_id)
	return card_id


static func text_of(card_id: String) -> String:
	if db.has(card_id) and db[card_id].has("text"):
		return db[card_id]["text"].get("ru", "")
	return ""


static func is_creature(card_id: String) -> bool:
	return String(db.get(card_id, {}).get("type", "")) == "creature"


static func is_spell(card_id: String) -> bool:
	return String(db.get(card_id, {}).get("type", "")) == "spell"


# Every hero id in the database (cards of type "hero"), for the loadout screen.
static func heroes() -> Array:
	var ids := []
	for id in db:
		if String(db[id].get("type", "")) == "hero":
			ids.append(id)
	ids.sort()
	return ids


# Every non-hero card id (a deck card), for building the standard deck.
static func deck_cards() -> Array:
	var ids := []
	for id in db:
		if String(db[id].get("type", "")) != "hero" and not String(id).begins_with("token_"):
			ids.append(id)
	ids.sort()
	return ids


# Which side a targeted spell can hit: "enemy", "friendly", "any", or "" (none).
static func target_side(card_id: String) -> String:
	var d: Dictionary = db.get(card_id, {})
	for e in d.get("effects", []):
		match String(e.get("selector", "")):
			"chosen_enemy_minion":
				return "enemy"
			"chosen_friendly_minion":
				return "friendly"
			"chosen_any_minion":
				return "any"
	return ""


static func needs_target(card_id: String) -> bool:
	return target_side(card_id) != ""


# True if a targeted effect is a cost (`required`): the card cannot be played at
# all without a legal target. Optional targeted effects just skip with no target.
static func target_required(card_id: String) -> bool:
	var d: Dictionary = db.get(card_id, {})
	for e in d.get("effects", []):
		if String(e.get("selector", "")).begins_with("chosen_") and bool(e.get("required", false)):
			return true
	return false


# Human descriptions of the card's targeted on_play effects -- used to warn the
# player which effect(s) will be lost when the card is played with no target.
static func targeted_effect_texts(card_id: String) -> Array:
	var d: Dictionary = db.get(card_id, {})
	var out := []
	for e in d.get("effects", []):
		if String(e.get("trigger", "")) == "on_play" \
				and String(e.get("selector", "")).begins_with("chosen_"):
			var s := Glossary.effect_text(e)
			if s != "":
				out.append(s)
	return out


static func has_keyword(card_id: String, kw: String) -> bool:
	for k in db.get(card_id, {}).get("keywords", []):
		if String(k.get("id", "")) == kw:
			return true
	return false


static func keyword_n(card_id: String, kw: String) -> int:
	for k in db.get(card_id, {}).get("keywords", []):
		if String(k.get("id", "")) == kw:
			return int(k.get("n", 0))
	return 0


static func total_cost(cost: Dictionary) -> int:
	var t := int(cost.get("generic", 0))
	for c in COLORS:
		t += int(cost.get(c, 0))
	return t


# Can the available pool pay this cost? Colored pips come from their own color;
# the generic part comes from whatever is left (matches the engine).
static func can_afford(cost: Dictionary, avail: Dictionary) -> bool:
	var pool := {}
	for c in ALL_COLORS:
		pool[c] = int(avail.get(c, 0))
	for c in COLORS:
		var need := int(cost.get(c, 0))
		if pool[c] < need:
			return false
		pool[c] -= need
	var left := 0
	for c in pool:
		left += int(pool[c])
	return left >= int(cost.get("generic", 0))


# Affordable if one available crystal may be retuned to a spectrum-adjacent
# color (Prism spectral_shift). Mirrors the engine's shiftedPool check.
static func can_afford_with_shift(cost: Dictionary, avail: Dictionary) -> bool:
	for xi in range(5):
		for yi in range(5):
			if absi(xi - yi) != 1:
				continue
			if int(avail.get(COLORS[yi], 0)) < 1:
				continue
			var swapped := avail.duplicate()
			swapped[COLORS[yi]] = int(swapped.get(COLORS[yi], 0)) - 1
			swapped[COLORS[xi]] = int(swapped.get(COLORS[xi], 0)) + 1
			if can_afford(cost, swapped):
				return true
	return false
