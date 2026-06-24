class_name Decks

# The player's decks, persisted in user://decks.cfg. A deck is
# { id, name, cards: [card_id, ...] }; a real match needs a 40/<=2 legal deck
# (DeckRules), which the server re-validates on join. Decks are built and managed
# in the "Колоды" screen (from the main menu); the pre-match loadout only selects
# an already-built deck.

const USER_PATH := "user://decks.cfg"


# Every deck the player can pick: built-in presets plus their saved decks.
static func all() -> Array:
	return builtin() + user_decks()


# Built-in decks shipped with the client (archetype presets land here in M4
# phase 3; none yet).
static func builtin() -> Array:
	return []


static func user_decks() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(USER_PATH) != OK:
		return []
	var out: Array = []
	if cfg.has_section("decks"):
		for id in cfg.get_section_keys("decks"):
			var v: Dictionary = cfg.get_value("decks", id, {})
			out.append({
				"id": id,
				"name": String(v.get("name", id)),
				"cards": v.get("cards", []),
			})
	return out


static func by_id(deck_id: String) -> Dictionary:
	for d in all():
		if d["id"] == deck_id:
			return d
	return {}


# Write (or overwrite) a user deck. deck = { id, name, cards }.
static func save_deck(deck: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(USER_PATH)  # ignore error on first save (new file)
	cfg.set_value("decks", String(deck["id"]),
		{"name": String(deck["name"]), "cards": deck["cards"]})
	cfg.save(USER_PATH)


static func delete_deck(deck_id: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(USER_PATH) != OK:
		return
	if cfg.has_section_key("decks", deck_id):
		cfg.erase_section_key("decks", deck_id)
		cfg.save(USER_PATH)
