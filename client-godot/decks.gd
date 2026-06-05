class_name Decks

# The player's decks. For now there is a single built-in "Standard" deck (one of
# every card -- mirrors the server's old demoDeck), derived from the card
# database so it always matches the current card pool. The list is modelled as
# the player's collection: it could be empty (then a match cannot start) and will
# later hold user-built decks. A deck is { id, name, cards: [card_id, ...] }.

const STANDARD_ID := "standard"


# All decks the player can pick. Today: just the standard deck. Later: persisted
# user decks too. May be empty -- callers must handle "no decks" (cannot play).
static func all() -> Array:
	return [standard()]


static func standard() -> Dictionary:
	return {
		"id": STANDARD_ID,
		"name": "Стандартная колода",
		"cards": CardData.deck_cards(),
	}


static func by_id(deck_id: String) -> Dictionary:
	for d in all():
		if d["id"] == deck_id:
			return d
	return {}
