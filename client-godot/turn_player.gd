class_name TurnPlayer
extends Node

# Plays incoming server views out in ARRIVAL ORDER, pacing the opponent's turn so
# you see what they did. Every view is annotated by the server with `event` (the
# public action that produced it -- see publicEventJson). Your own actions and
# prompt views (mulligan/scry/decision/over) apply instantly; the opponent's
# actions are paced: a pre-fx (card reveal / attack lunge) fires, then the state
# is applied, then a short settle beat. A click/space fast-forwards the rest.
#
# The queue is the ONLY path from socket to Main._ingest_view, so order is never
# broken (each _ingest_view diffs against the previous state it applied). The
# ordering/pacing decisions are pure static funcs, tested headless in tests/run.gd.

var _queue: Array = []
var _running := false
var _fast := false
var _apply: Callable  # Main._ingest_view(view) -- applies state + diff animations
var _pre: Callable    # Main._play_pre_fx(event) -- reveal / lunge before the apply


func setup(apply: Callable, pre: Callable) -> void:
	_apply = apply
	_pre = pre


# Drop any queued playback (a fresh match owns a fresh queue; called on teardown).
func reset() -> void:
	_queue.clear()
	_fast = false


# Fast-forward: apply the rest of the queue with no reveals or pauses.
func flush() -> void:
	if _running or not _queue.is_empty():
		_fast = true


func feed(view: Dictionary) -> void:
	_queue.append(view)
	if not _running:
		_pump()


func _pump() -> void:
	_running = true
	while not _queue.is_empty():
		var v: Dictionary = _queue.pop_front()
		var e: Dictionary = _event_of(v)
		var paced := not _fast and is_paced(v, e)
		if paced:
			_pre.call(e)  # start the reveal / set up the lunge
			var lead := reveal_secs(e)
			if lead > 0.0:
				await get_tree().create_timer(lead).timeout
		_apply.call(v)  # Main._ingest_view: rebuild + damage/death/summon/lunge
		if paced:
			await get_tree().create_timer(settle_secs(e)).timeout
	_running = false
	_fast = false


static func _event_of(view: Dictionary) -> Dictionary:
	var e: Variant = view.get("event", {})
	return e if typeof(e) == TYPE_DICTIONARY else {}


# --- pure ordering / pacing (tested headless) --------------------------------

# A view is PACED (played as an opponent step) iff it carries an event by the
# OTHER seat and is not a prompt the viewer must answer now. Everything else --
# your own actions, reconnect syncs, private resolutions, prompts -- applies
# instantly (0 lead, 0 settle), so it still flows through the queue in order.
static func is_paced(view: Dictionary, event: Dictionary) -> bool:
	if event.is_empty():
		return false  # reconnect sync / rejected action / private resolution
	if int(event.get("seat", -1)) == int(view.get("you", -2)):
		return false  # your own action -- already shown optimistically
	if is_prompt(view):
		return false  # mulligan / scry / decision / game-over show at once
	return true


static func is_prompt(view: Dictionary) -> bool:
	return bool(view.get("mulligan", false)) or view.has("scry") \
		or view.has("decision") or bool(view.get("over", false))


# Seconds to hold the reveal before applying the board change (0 = no lead). A
# creature has no reveal (its board pop-in is the reveal), so it leads with 0;
# a spell/aura reveal needs time to read + fly onto its target.
static func reveal_secs(event: Dictionary) -> float:
	match String(event.get("action", "")):
		"play", "awaken":
			return 0.0 if CardData.is_creature(String(event.get("card", ""))) else 1.1
		_:
			return 0.0


# Seconds to let the applied state's animations breathe before the next step.
static func settle_secs(event: Dictionary) -> float:
	match String(event.get("action", "")):
		"play", "awaken":
			return 0.65
		"attackCreature", "attackHero":
			return 0.75
		"placeMana":
			return 0.45
		"endTurn":
			return 0.55
		_:
			return 0.45
