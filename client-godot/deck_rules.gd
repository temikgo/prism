class_name DeckRules

# Client-side mirror of the engine deck rule (engine/include/prism/deck.hpp):
# exactly DECK_SIZE cards, at most MAX_COPIES of each. The server is the
# authority (it re-checks on join and rejects with joinError "bad_deck"); this
# mirror only drives live build-time feedback so the player cannot save or queue
# an illegal deck.
const DECK_SIZE := 40
const MAX_COPIES := 2

# deck: { card_id: count }. Returns { ok, reason, detail }:
#   ok=true              -> legal
#   reason="copies"      -> detail = how many cards exceed MAX_COPIES
#   reason="under"/"over"-> detail = how many cards short / over DECK_SIZE
static func check(deck: Dictionary) -> Dictionary:
	var total := 0
	var over := 0
	for id in deck:
		var n: int = deck[id]
		total += n
		if n > MAX_COPIES:
			over += 1
	if over > 0:
		return {"ok": false, "reason": "copies", "detail": str(over)}
	if total < DECK_SIZE:
		return {"ok": false, "reason": "under", "detail": str(DECK_SIZE - total)}
	if total > DECK_SIZE:
		return {"ok": false, "reason": "over", "detail": str(total - DECK_SIZE)}
	return {"ok": true, "reason": "", "detail": ""}

static func is_legal(deck: Dictionary) -> bool:
	return check(deck).ok

static func total(deck: Dictionary) -> int:
	var t := 0
	for id in deck:
		t += int(deck[id])
	return t

# Human-readable status line for the deck counter, matching the mockup wording.
static func status_text(deck: Dictionary) -> String:
	var c := check(deck)
	if c.ok:
		return "колода готова"
	match c.reason:
		"copies":
			var n: int = int(c.detail)
			return str(n) + (" карта превышает" if n == 1 else " карт превышают") + \
				" лимит копий"
		"under":
			return "добавьте ещё " + c.detail
		"over":
			return "уберите " + c.detail
	return ""

# Flatten { id: count } into the card-id list the server expects (id repeated).
static func to_card_list(deck: Dictionary) -> Array:
	var out: Array = []
	for id in deck:
		for _i in range(int(deck[id])):
			out.append(id)
	return out
