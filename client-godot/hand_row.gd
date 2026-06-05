class_name HandRow
extends Control

# A persistent, manually-laid-out fan of hand cards. The view's hand is just a
# list of card ids (no per-card instance id, and duplicates are possible), so on
# each sync we greedily match new cards to existing nodes by card id: a survivor
# keeps its node (and slides to its new slot), a drawn card gets a fresh node
# (fades in), a played card's leftover node is freed. A reused node always holds
# the same card, so its face never changes -- only its index/playable state.

const CARD := Tokens.CARD_SIZE
const SEP := 8

var _entries := []     # [{card_id, node}] in current hand order
var _pos_tweens := {}  # node -> active position tween (killed on retarget)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0, CARD.y)
	resized.connect(func() -> void: _layout(false))


# Reconcile to `hand` (a list of card ids). `make(card_id) -> node` builds a new
# card; `refresh(node, card_id, index) -> void` updates a reused/new one.
func sync(hand: Array, make: Callable, refresh: Callable) -> void:
	# Pool the existing nodes by card id, in order, to match duplicates greedily.
	var pool := {}
	for e in _entries:
		if not pool.has(e["card_id"]):
			pool[e["card_id"]] = []
		pool[e["card_id"]].append(e["node"])
	var used := {}
	var fresh := {}
	var next := []
	for i in hand.size():
		var cid := String(hand[i])
		var node = null
		for nd in pool.get(cid, []):
			if not used.has(nd) and is_instance_valid(nd):
				node = nd
				used[nd] = true
				break
		if node == null:
			node = make.call(cid)
			add_child(node)
			fresh[node] = true
		refresh.call(node, cid, i)
		next.append({"card_id": cid, "node": node})
	# Free the cards that left the hand (played / discarded).
	for e in _entries:
		if not used.has(e["node"]) and is_instance_valid(e["node"]):
			e["node"].queue_free()
	_entries = next
	_layout(true, fresh)


# Fan the cards across the width, overlapping when too many to sit side by side.
# Survivors slide to their slot when `animate`; nodes in `instant` snap (freshly
# drawn -- their entrance is a fade-in by the caller).
func _layout(animate := true, instant := {}) -> void:
	var n := _entries.size()
	if n == 0:
		return
	var sep := float(SEP)
	var w := size.x
	if n > 1:
		var needed := n * CARD.x + (n - 1) * SEP
		if needed > w:
			sep = (w - n * CARD.x) / float(n - 1)
			sep = maxf(sep, -CARD.x * 0.5)
	var total := n * CARD.x + (n - 1) * sep
	var x := (w - total) * 0.5
	for i in n:
		var node: Control = _entries[i]["node"]
		if is_instance_valid(node):
			node.size = CARD
			move_child(node, i)  # draw order = hand order (right card overlaps left)
			_place(node, Vector2(x, 0), animate and not instant.has(node))
		x += CARD.x + sep


func _place(node: Control, target: Vector2, animate: bool) -> void:
	var old = _pos_tweens.get(node)
	if old != null and old.is_valid():
		old.kill()
	_pos_tweens.erase(node)
	if not animate or node.position.distance_to(target) < 0.5:
		node.position = target
		return
	var tw := node.create_tween()
	tw.tween_property(node, "position", target, 0.16) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_pos_tweens[node] = tw
