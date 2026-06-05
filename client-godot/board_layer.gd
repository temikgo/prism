class_name BoardLayer
extends Control

# A persistent, manually-positioned row of board-creature cards, keyed by
# creature id. Reconciled on every view (reuse / create / remove) so a living
# creature keeps its node across updates -- the foundation for inter-state
# animations (smooth reflow, fly-in). Layout (the overlap fan) is computed here
# rather than by a container, so each card's position can be tweened.
#
# P1 places cards instantly (visual parity with the old HBox row); P2 turns the
# position writes into tweens.

const CARD := Tokens.CARD_SIZE
const SEP := 6

var _nodes := {}      # cid -> card node (persists across syncs)
var _order := []      # cids in current board order (drives layout)
var _pos_tweens := {} # cid -> active position tween (killed on retarget)
var gap_index := -1   # while dragging a creature in: open a slot here (-1 = none)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0, CARD.y)
	# A window resize snaps instantly (no slide during a resize drag).
	resized.connect(func() -> void: _layout(false))


# Reconcile to `board`: reuse a node for a surviving creature, build one for a
# new creature (`make(cr) -> node`), and refresh reused ones (`refresh(node, cr)`).
# Departed creatures are handed off by the caller (see take()) before this runs.
func sync(board: Array, make: Callable, refresh: Callable) -> void:
	_order = []
	var fresh := {}  # newly created this sync: placed instantly, not slid
	for cr in board:
		var cid := int(cr["id"])
		_order.append(cid)
		var node = _nodes.get(cid)
		if node == null or not is_instance_valid(node):
			node = make.call(cr)
			_nodes[cid] = node
			add_child(node)
			fresh[cid] = true
		else:
			refresh.call(node, cr)
	# Existing creatures slide to their new slots (smooth reflow); fresh ones are
	# placed instantly (their entrance is animated by the caller -- pop-in / fly).
	_layout(true, fresh)


func node_for(cid: int):
	var n = _nodes.get(cid)
	return n if (n != null and is_instance_valid(n)) else null


func has(cid: int) -> bool:
	return _nodes.has(cid)


func ids() -> Array:
	return _nodes.keys()


# Forget a node and hand it back (e.g. for the death animation). It is left
# parented here so the caller can still read its global_position; the caller
# (fade_out_dead) reparents it.
func take(cid: int):
	var n = _nodes.get(cid)
	_nodes.erase(cid)
	var tw = _pos_tweens.get(cid)
	if tw != null and tw.is_valid():
		tw.kill()
	_pos_tweens.erase(cid)
	if n != null and is_instance_valid(n):
		return n
	return null


# Position the cards across the available width, overlapping when a full board
# would otherwise run off the edge. `gap_index` opens one empty slot for a
# creature being dragged in. When `animate`, existing cards slide to their slot;
# cids in `instant` always snap (newly created cards whose entrance is animated
# elsewhere).
func _layout(animate := true, instant := {}) -> void:
	var n := _order.size()
	if n == 0:
		return
	var slots := n + (1 if gap_index >= 0 else 0)
	var sep := float(SEP)
	var w := size.x
	if slots > 1:
		var needed := slots * CARD.x + (slots - 1) * SEP
		if needed > w:
			sep = (w - slots * CARD.x) / float(slots - 1)
			sep = maxf(sep, -CARD.x * 0.6)
	var total := slots * CARD.x + (slots - 1) * sep
	var x := (w - total) * 0.5
	for i in n:
		if gap_index == i:
			x += CARD.x + sep  # leave a hole for the incoming creature
		var cid := int(_order[i])
		var node = _nodes.get(cid)
		if node != null and is_instance_valid(node):
			node.size = CARD  # manual layout: set the rect explicitly
			_place(cid, node, Vector2(x, 0), animate and not instant.has(cid))
		x += CARD.x + sep


# Move a card to `target`: tween it (smooth reflow) or snap it. Any in-flight
# position tween for this card is killed first so retargets never fight.
func _place(cid: int, node: Control, target: Vector2, animate: bool) -> void:
	var old = _pos_tweens.get(cid)
	if old != null and old.is_valid():
		old.kill()
	_pos_tweens.erase(cid)
	if not animate or node.position.distance_to(target) < 0.5:
		node.position = target
		return
	var tw := node.create_tween()
	tw.tween_property(node, "position", target, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_pos_tweens[cid] = tw
