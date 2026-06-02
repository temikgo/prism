extends Control

# Minimal Prism client. Connects to the C++ WebSocket server, renders the
# redacted view it receives, and sends JSON actions. Static card data (names,
# costs, stats) is read from res://cards.json; per-instance runtime state comes
# from the server view. The UI is built in code so no scene editing is needed.

const DEFAULT_URL := "ws://127.0.0.1:8080"

var socket := WebSocketPeer.new()
var was_open := false
var view := {}
var cards := {}          # card id -> definition (from cards.json)
var attacker_id := -1    # your selected creature, waiting for an attack target
var casting_index := -1  # hand index of a spell waiting for a target

var url_edit: LineEdit
var status_label: Label
var board_box: VBoxContainer


func _ready() -> void:
	_load_cards()
	_build_shell()


func _load_cards() -> void:
	var f := FileAccess.open("res://cards.json", FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_ARRAY:
		for c in data:
			cards[c["id"]] = c


func _build_shell() -> void:
	var outer := VBoxContainer.new()
	outer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(outer)

	var bar := HBoxContainer.new()
	url_edit = LineEdit.new()
	url_edit.text = DEFAULT_URL
	url_edit.custom_minimum_size = Vector2(300, 0)
	bar.add_child(url_edit)
	var connect_btn := Button.new()
	connect_btn.text = "Connect"
	connect_btn.pressed.connect(_on_connect)
	bar.add_child(connect_btn)
	status_label = Label.new()
	status_label.text = "disconnected"
	bar.add_child(status_label)
	outer.add_child(bar)

	board_box = VBoxContainer.new()
	board_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(board_box)


func _on_connect() -> void:
	var err := socket.connect_to_url(url_edit.text)
	if err != OK:
		status_label.text = "connect error %d" % err
	else:
		status_label.text = "connecting..."


func _process(_dt: float) -> void:
	socket.poll()
	var st := socket.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not was_open:
			was_open = true
			status_label.text = "connected"
		while socket.get_available_packet_count() > 0:
			var txt := socket.get_packet().get_string_from_utf8()
			var data: Variant = JSON.parse_string(txt)
			if typeof(data) == TYPE_DICTIONARY:
				view = data
				_rebuild()
	elif st == WebSocketPeer.STATE_CLOSED and was_open:
		was_open = false
		status_label.text = "closed"


func _send(obj: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(obj))


func _name_of(card_id: String) -> String:
	if cards.has(card_id) and cards[card_id].has("name"):
		return cards[card_id]["name"].get("ru", card_id)
	return card_id


func _my_turn() -> bool:
	return int(view.get("current", -1)) == int(view.get("you", -2))


func _rebuild() -> void:
	for c in board_box.get_children():
		c.queue_free()
	if view.is_empty():
		return

	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var opp: Dictionary = view["players"][1 - you]

	var banner := Label.new()
	if bool(view.get("over", false)):
		var w := int(view.get("winner", -1))
		banner.text = "GAME OVER — " + ("you win" if w == you else "you lose")
	else:
		var who := "YOUR TURN" if _my_turn() else "opponent's turn"
		banner.text = "%s   (turn %d)" % [who, int(view.get("turn", 0))]
	board_box.add_child(banner)

	var opp_hero := Button.new()
	opp_hero.text = "ENEMY HERO   hp %d  armor %d   |  hand %d   deck %d" % [
		int(opp["hero"]["hp"]), int(opp["hero"]["armor"]),
		int(opp.get("handCount", 0)), int(opp.get("deckCount", 0))]
	opp_hero.pressed.connect(_on_enemy_hero)
	board_box.add_child(opp_hero)

	board_box.add_child(_board_row(opp.get("board", []), false))
	board_box.add_child(_board_row(me.get("board", []), true))

	var me_hero := Label.new()
	me_hero.text = "YOU   hp %d  armor %d   |  mana %s" % [
		int(me["hero"]["hp"]), int(me["hero"]["armor"]), _mana_str(me["mana"])]
	board_box.add_child(me_hero)

	board_box.add_child(_hand_row(me.get("hand", [])))

	var end_btn := Button.new()
	end_btn.text = "End Turn"
	end_btn.disabled = not _my_turn()
	end_btn.pressed.connect(func() -> void:
		attacker_id = -1
		casting_index = -1
		_send({"action": "endTurn"}))
	board_box.add_child(end_btn)

	var hint := Label.new()
	if casting_index >= 0:
		hint.text = "pick an enemy creature as the target (click the hand card again to cancel)"
	elif attacker_id >= 0:
		hint.text = "pick an enemy creature or the enemy hero to attack"
	board_box.add_child(hint)


func _mana_str(mana: Dictionary) -> String:
	var avail: Dictionary = mana.get("available", {})
	var out := ""
	for color in ["red", "yellow", "green", "blue", "violet", "colorless"]:
		var v := int(avail.get(color, 0))
		if v > 0:
			out += "%s:%d  " % [color, v]
	return out if out != "" else "0"


func _board_row(board: Array, mine: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	var tag := Label.new()
	tag.text = "YOUR BOARD:  " if mine else "ENEMY BOARD:  "
	row.add_child(tag)
	for cr in board:
		var b := Button.new()
		var status := ""
		if int(cr.get("frozen", 0)) > 0:
			status += " ice"
		if int(cr.get("blind", 0)) > 0:
			status += " blind"
		if bool(cr.get("shield", false)):
			status += " shield"
		if bool(cr.get("stealth", false)):
			status += " hidden"
		if bool(cr.get("sick", false)):
			status += " zzz"
		b.text = "%s\n%d / %d%s" % [_name_of(cr["card"]), int(cr["atk"]), int(cr["hp"]), status]
		var cid := int(cr["id"])
		if mine:
			b.pressed.connect(func() -> void: _on_my_creature(cid))
		else:
			b.pressed.connect(func() -> void: _on_enemy_creature(cid))
		row.add_child(b)
	return row


func _hand_row(hand: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	var tag := Label.new()
	tag.text = "HAND:  "
	row.add_child(tag)
	for i in hand.size():
		var cid: String = hand[i]
		var idx := i
		var box := VBoxContainer.new()
		var play := Button.new()
		play.text = _card_label(cid)
		play.disabled = not _my_turn()
		play.pressed.connect(func() -> void: _on_hand_card(idx, cid))
		box.add_child(play)
		var to_mana := Button.new()
		to_mana.text = "-> mana"
		to_mana.disabled = not _my_turn()
		to_mana.pressed.connect(func() -> void: _on_place_mana(idx, cid))
		box.add_child(to_mana)
		row.add_child(box)
	return row


func _card_label(card_id: String) -> String:
	var d: Dictionary = cards.get(card_id, {})
	var cost: Dictionary = d.get("cost", {})
	var stats: Variant = d.get("stats", null)
	var stat_str := ""
	if typeof(stats) == TYPE_DICTIONARY:
		stat_str = "  %d/%d" % [int(stats.get("atk", 0)), int(stats.get("hp", 0))]
	return "%s\n(%d)%s" % [_name_of(card_id), int(cost.get("generic", 0)), stat_str]


func _needs_target(card_id: String) -> bool:
	var d: Dictionary = cards.get(card_id, {})
	for e in d.get("effects", []):
		if String(e.get("selector", "")) == "chosen_enemy_minion":
			return true
	return false


func _on_hand_card(idx: int, card_id: String) -> void:
	if not _my_turn():
		return
	if casting_index == idx:
		casting_index = -1
		_rebuild()
		return
	if _needs_target(card_id):
		casting_index = idx
		attacker_id = -1
		_rebuild()
	else:
		casting_index = -1
		_send({"action": "play", "handIndex": idx})


func _on_place_mana(idx: int, card_id: String) -> void:
	var d: Dictionary = cards.get(card_id, {})
	var colors: Array = d.get("color", [])
	var color := "colorless" if colors.is_empty() else String(colors[0])
	_send({"action": "placeMana", "handIndex": idx, "color": color})


func _on_my_creature(cid: int) -> void:
	attacker_id = cid
	casting_index = -1
	_rebuild()


func _on_enemy_creature(cid: int) -> void:
	if casting_index >= 0:
		_send({"action": "play", "handIndex": casting_index, "target": cid})
		casting_index = -1
	elif attacker_id >= 0:
		_send({"action": "attackCreature", "attacker": attacker_id, "target": cid})
		attacker_id = -1


func _on_enemy_hero() -> void:
	if attacker_id >= 0:
		_send({"action": "attackHero", "attacker": attacker_id})
		attacker_id = -1
