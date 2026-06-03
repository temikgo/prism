extends Control

# Prism client. Connects to the C++ WebSocket server, renders the redacted view
# it receives, and sends JSON actions. Static card data (names, costs, stats,
# text) is read from res://cards.json; per-instance runtime state comes from the
# server view. The UI is built in code, so no scene editing is needed.
#
# Interaction is drag-and-drop with a click fallback:
#   * hand card  -> drag onto your board to play, or onto the MANA zone to bank,
#                   or (targeted spell) onto an enemy creature to cast at it;
#   * your creature -> drag onto an enemy creature or the enemy hero to attack;
#   * revealed awaken card in your mana row -> drag like a hand card to awaken it.
# Clicking does the same via a two-step "select, then pick target" flow.

const DEFAULT_URL := "ws://127.0.0.1:8080"
const CARD_SIZE := Vector2(150, 210)
const FRAME := 5.0     # colored-gradient frame thickness around the art
const GEM := 34.0      # diameter of the cost / atk / hp corner gems

var socket := WebSocketPeer.new()
var was_open := false
var view := {}
var cards := {}            # card id -> definition (from cards.json)

# Click-fallback selection state (drag-and-drop ignores these).
var attacker_id := -1      # your selected creature, waiting for an attack target
var casting_index := -1    # hand index of a targeted spell waiting for a target
var awaken_index := -1     # mana-row index of a targeted awaken card
var pending_side := ""     # side a pending targeted spell can hit: enemy/friendly/any
var _picker: Control = null   # open mana-color chooser, if any

var url_edit: LineEdit
var status_label: Label
var root_box: VBoxContainer


# --- color palette -----------------------------------------------------------

const COLOR_MAP := {
	"red": Color(0.86, 0.24, 0.26),
	"yellow": Color(0.92, 0.78, 0.24),
	"green": Color(0.34, 0.74, 0.40),
	"blue": Color(0.32, 0.56, 0.92),
	"violet": Color(0.62, 0.38, 0.86),
	"colorless": Color(0.72, 0.72, 0.78),
}


# Plain-language meaning of each keyword, shown in the card tooltip. "N" is
# replaced by the keyword's value.
const KW_DESC := {
	"pierce": "Пробитие: лишний урон по существу переходит вражескому герою.",
	"bypass": "Сквозь строй: может бить героя даже при наличии защитников.",
	"lingering": "Неугасимость: раны, нанесённые им, не лечатся.",
	"regen": "Регенерация N: в начале вашего хода +N HP этому существу.",
	"self_lifesteal": "Алый дар: его урон лечит его самого на столько же.",
	"provoke": "Маяк: вражеские существа обязаны атаковать это.",
	"shield": "Щит: игнорирует следующий источник урона целиком.",
	"blind": "Ослепление N: не может атаковать N ход(ов).",
	"flash": "Вспышка N: ослепляет всех врагов на N ход(ов).",
	"photosynthesis": "Фотосинтез N: в начале вашего хода +N кристалл(ов).",
	"growth": "Рост N: в начале вашего хода +N/+N этому существу.",
	"compost": "Компост N: когда ваше существо умирает, +N/+N этому.",
	"spores": "Споры N: при смерти призывает N ростков 1/1.",
	"undergrowth": "Подлесок N: +N/+N за каждое другое ваше существо.",
	"resonance": "Резонанс N: +N/+N за каждый ваш кристалл.",
	"freeze": "Заморозка N: не атакует N ход(ов); не пробуждается от урона.",
	"chill": "Стужа N: вражеские существа -N к атаке, пока аура в игре.",
	"stealth": "Незримость: нельзя выбрать целью, пока это не атакует.",
	"split": "Расщепление N: при выходе создаёт N иллюзий (1 HP).",
	"haunt": "Морок: при смерти оставляет иллюзорную копию (1 HP).",
	"awaken": "Awaken: эту карту-кристалл можно разбудить за её стоимость.",
}

# Plain-language meaning of each spell-effect action (the inline grammar used by
# spells/battlecries). "N" is replaced by the effect's value.
const EFFECT_DESC := {
	"freeze": "Заморозка N: цель не атакует N ход(ов); не пробуждается от урона.",
	"blind": "Ослепление N: цель не может атаковать N ход(ов).",
	"flash": "Вспышка N: ослепляет всех врагов на N ход(ов).",
	"damage": "Урон N: наносит N урона цели.",
	"damage_all": "Выметание N: наносит N урона всем существам.",
	"destroy": "Устранение: уничтожает выбранное существо.",
	"draw": "Добор N: возьмите N карт(ы).",
	"scatter": "Рассеяние: возвращает вражеское существо в руку.",
	"mirage": "Мираж: создаёт иллюзорную копию существа (1 HP).",
}


func _color_for(name: String) -> Color:
	return COLOR_MAP.get(name, COLOR_MAP["colorless"])


func _primary_color(d: Dictionary) -> Color:
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		return _color_for("colorless")
	return _color_for(String(colors[0]))


func _icon(icon_name: String, px: float, color: Color) -> TextureRect:
	var tex := TextureRect.new()
	tex.texture = load("res://icons/%s.svg" % icon_name)
	tex.custom_minimum_size = Vector2(px, px)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.modulate = color
	return tex


# --- a draggable / droppable card or zone -------------------------------------

class UiCard extends PanelContainer:
	signal clicked(payload: Dictionary)
	# Shared across all cards: the payload of the drag currently in flight, so
	# any card can decide whether to light up as a legal drop target.
	static var active_drag = null
	var payload: Dictionary = {}        # non-empty + draggable=true => can drag
	var drag_label: String = ""
	var preview_builder: Callable = Callable()   # returns the drag-preview Control
	var tooltip_builder: Callable = Callable()   # returns the hover-tooltip Control
	var can_drop_fn: Callable = Callable()
	var drop_fn: Callable = Callable()
	var hoverable := false                        # lift + scale on mouse-over
	var rest_modulate := Color.WHITE              # modulate to restore after a drag
	var _is_drag_source := false

	func _ready() -> void:
		mouse_entered.connect(_on_hover_in)
		mouse_exited.connect(_on_hover_out)

	func _on_hover_in() -> void:
		if not hoverable:
			return
		pivot_offset = size / 2.0
		z_index = 20
		create_tween().tween_property(self, "scale", Vector2(1.08, 1.08), 0.08)

	func _on_hover_out() -> void:
		if not hoverable:
			return
		z_index = 0
		create_tween().tween_property(self, "scale", Vector2.ONE, 0.08)

	func _make_custom_tooltip(_for_text: String) -> Object:
		if tooltip_builder.is_valid():
			return tooltip_builder.call()
		return null

	func _gui_input(event: InputEvent) -> void:
		# Fire on release, not press: a press that turns into a drag is consumed
		# by the drag system, so a real click never collides with dragging.
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT \
				and not event.pressed:
			clicked.emit(payload)

	func _get_drag_data(_at: Vector2) -> Variant:
		if not bool(payload.get("draggable", false)):
			return null
		active_drag = payload
		_is_drag_source = true
		if preview_builder.is_valid():
			set_drag_preview(preview_builder.call())
		else:
			var ghost := Label.new()
			ghost.text = drag_label
			ghost.add_theme_color_override("font_color", Color.WHITE)
			set_drag_preview(ghost)
		return payload

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		if can_drop_fn.is_valid():
			return bool(can_drop_fn.call(data))
		return false

	func _drop_data(_at: Vector2, data: Variant) -> void:
		if drop_fn.is_valid():
			drop_fn.call(data)

	func _notification(what: int) -> void:
		# While a drag is in flight: dim the source card, glow legal targets.
		if what == NOTIFICATION_DRAG_BEGIN:
			if _is_drag_source:
				modulate = Color(1, 1, 1, 0.35)
			elif active_drag != null and can_drop_fn.is_valid() \
					and bool(can_drop_fn.call(active_drag)):
				modulate = Color(1.45, 1.45, 1.1)
		elif what == NOTIFICATION_DRAG_END:
			active_drag = null
			_is_drag_source = false
			modulate = rest_modulate


# --- lifecycle ---------------------------------------------------------------

func _ready() -> void:
	_load_cards()
	_build_shell()
	# Remove the default dark tooltip wrapper window-wide so our custom card
	# tooltip shows without a panel behind it. The auto-created tooltip popup
	# resolves its style from the window theme, not from the tooltip control.
	var th := Theme.new()
	th.set_stylebox("panel", "TooltipPanel", StyleBoxEmpty.new())
	get_window().theme = th


func _load_cards() -> void:
	# Deck cards (mirror of the server's pool) plus client-only token display
	# data (sprouts and other generated tokens that never sit in a deck).
	_load_card_file("res://cards.json")
	_load_card_file("res://tokens.json")


func _load_card_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_ARRAY:
		for c in data:
			cards[c["id"]] = c


func _build_shell() -> void:
	var bg := TextureRect.new()
	bg.texture = _bg_texture()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	root_box = VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 8)
	margin.add_child(root_box)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	url_edit = LineEdit.new()
	url_edit.text = DEFAULT_URL
	url_edit.custom_minimum_size = Vector2(280, 0)
	bar.add_child(url_edit)
	var connect_btn := _neon_button("Connect", Color(0.4, 0.8, 1.0))
	connect_btn.pressed.connect(_on_connect)
	bar.add_child(connect_btn)
	status_label = Label.new()
	status_label.text = "disconnected"
	status_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	bar.add_child(status_label)
	root_box.add_child(bar)


func _bg_texture() -> Texture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray([
		Color(0.07, 0.08, 0.15), Color(0.10, 0.06, 0.16), Color(0.02, 0.02, 0.05)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.42)
	tex.fill_to = Vector2(1.05, 1.1)
	return tex


# Translucent dark "glass" with a neon accent border and a soft accent glow.
func _glass(accent: Color, bg_alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.15, bg_alpha)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.85)
	sb.shadow_size = 16
	sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.42)
	sb.set_content_margin_all(8)
	return sb


func _neon_button(text: String, accent: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", accent.lightened(0.5))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.43, 0.5))
	b.add_theme_stylebox_override("normal", _glass(accent, 0.4))
	b.add_theme_stylebox_override("hover", _glass(accent, 0.62))
	b.add_theme_stylebox_override("pressed", _glass(accent, 0.8))
	var dis := _glass(Color(0.32, 0.34, 0.42), 0.22)
	dis.shadow_size = 0
	b.add_theme_stylebox_override("disabled", dis)
	return b


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


func _clear_selection() -> void:
	attacker_id = -1
	casting_index = -1
	awaken_index = -1
	pending_side = ""


# --- view queries ------------------------------------------------------------

func _name_of(card_id: String) -> String:
	if cards.has(card_id) and cards[card_id].has("name"):
		return cards[card_id]["name"].get("ru", card_id)
	return card_id


func _text_of(card_id: String) -> String:
	if cards.has(card_id) and cards[card_id].has("text"):
		return cards[card_id]["text"].get("ru", "")
	return ""


func _my_turn() -> bool:
	return int(view.get("current", -1)) == int(view.get("you", -2))


func _needs_target(card_id: String) -> bool:
	return _target_side(card_id) != ""


# Which side a targeted spell can hit: "enemy", "friendly", "any", or "" (none).
func _target_side(card_id: String) -> String:
	var d: Dictionary = cards.get(card_id, {})
	for e in d.get("effects", []):
		match String(e.get("selector", "")):
			"chosen_enemy_minion":
				return "enemy"
			"chosen_friendly_minion":
				return "friendly"
			"chosen_any_minion":
				return "any"
	return ""


func _is_creature(card_id: String) -> bool:
	return String(cards.get(card_id, {}).get("type", "")) == "creature"


# Can the current available mana pay this cost? Colored pips come from their own
# color; the generic part comes from whatever is left (matches the engine).
func _can_afford(cost: Dictionary, avail: Dictionary) -> bool:
	var pool := {}
	for c in ["red", "yellow", "green", "blue", "violet", "colorless"]:
		pool[c] = int(avail.get(c, 0))
	for c in ["red", "yellow", "green", "blue", "violet"]:
		var need := int(cost.get(c, 0))
		if pool[c] < need:
			return false
		pool[c] -= need
	var left := 0
	for c in pool:
		left += int(pool[c])
	return left >= int(cost.get("generic", 0))


# Playable right now: my turn, affordable, and (for creatures) the board has room.
func _is_playable(card_id: String) -> bool:
	if not _my_turn():
		return false
	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	if not _can_afford(cards.get(card_id, {}).get("cost", {}), me["mana"].get("available", {})):
		return false
	if _is_creature(card_id) and int(me.get("board", []).size()) >= 8:
		return false
	return true


func _has_keyword(card_id: String, kw: String) -> bool:
	for k in cards.get(card_id, {}).get("keywords", []):
		if String(k.get("id", "")) == kw:
			return true
	return false


# Does the enemy control a (visible) provoker, forcing attacks onto it?
func _enemy_has_provoke() -> bool:
	var you := int(view["you"])
	var opp: Dictionary = view["players"][1 - you]
	for c in opp.get("board", []):
		if bool(c.get("stealth", false)):
			continue
		if _has_keyword(String(c["card"]), "provoke"):
			return true
	return false


# A legal attack target: not hidden, and if a provoker exists you may only hit
# a provoker.
func _valid_attack_target(cr: Dictionary) -> bool:
	if bool(cr.get("stealth", false)):
		return false
	if _enemy_has_provoke() and not _has_keyword(String(cr["card"]), "provoke"):
		return false
	return true


# --- top-level rebuild -------------------------------------------------------

func _rebuild() -> void:
	# Tear down everything below the connection bar and redraw from the view.
	while root_box.get_child_count() > 1:
		var n := root_box.get_child(1)
		root_box.remove_child(n)
		n.queue_free()
	if view.is_empty():
		return

	var you := int(view["you"])
	var me: Dictionary = view["players"][you]
	var opp: Dictionary = view["players"][1 - you]

	root_box.add_child(_banner(you))
	root_box.add_child(_enemy_strip(opp))
	root_box.add_child(_board_row(opp.get("board", []), false))
	root_box.add_child(_separator())
	root_box.add_child(_board_row(me.get("board", []), true))
	root_box.add_child(_me_strip(me))
	root_box.add_child(_hand_row(me.get("hand", [])))
	root_box.add_child(_controls())


func _separator() -> Control:
	var line := HSeparator.new()
	line.add_theme_constant_override("separation", 6)
	return line


func _banner(you: int) -> Control:
	var banner := Label.new()
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_theme_font_size_override("font_size", 22)
	if bool(view.get("over", false)):
		var w := int(view.get("winner", -1))
		var win := w == you
		banner.text = "GAME OVER - " + ("YOU WIN" if win else "YOU LOSE")
		banner.add_theme_color_override("font_color",
			Color(0.5, 0.95, 0.6) if win else Color(0.95, 0.45, 0.45))
	else:
		var who := "YOUR TURN" if _my_turn() else "OPPONENT'S TURN"
		banner.text = "%s   -   turn %d" % [who, int(view.get("turn", 0))]
		banner.add_theme_color_override("font_color",
			Color(0.45, 0.85, 1.0) if _my_turn() else Color(0.6, 0.62, 0.72))
	return banner


# --- hero strips -------------------------------------------------------------

func _enemy_strip(opp: Dictionary) -> Control:
	var zone := UiCard.new()
	zone.add_theme_stylebox_override("panel", _hero_style(Color(0.9, 0.32, 0.38)))
	zone.can_drop_fn = func(data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.get("kind", "") == "attacker" \
			and not _enemy_has_provoke()
	zone.drop_fn = func(data: Variant) -> void:
		_send({"action": "attackHero", "attacker": int(data["id"])})
		_clear_selection()
	zone.clicked.connect(func(_p: Dictionary) -> void: _on_enemy_hero())
	if attacker_id >= 0 and not _enemy_has_provoke():
		zone.modulate = Color(1.5, 1.4, 1.1)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 14)
	row.add_child(_hero_block(opp["hero"], "ENEMY"))
	row.add_child(_counts_label(opp))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	row.add_child(_mana_crystals(opp.get("mana", {})))
	row.add_child(_manarow_view(opp.get("manaRow", []), false))
	zone.add_child(row)
	return zone


func _me_strip(me: Dictionary) -> Control:
	var zone := UiCard.new()
	zone.add_theme_stylebox_override("panel", _hero_style(Color(0.32, 0.6, 0.98)))

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 14)
	row.add_child(_hero_block(me["hero"], "YOU"))
	var power := _neon_button("Сила героя", Color(0.72, 0.45, 0.95))
	power.disabled = true
	power.tooltip_text = "Сила героя - появится позже"
	row.add_child(power)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	row.add_child(_mana_crystals(me.get("mana", {})))
	row.add_child(_manarow_view(me.get("manaRow", []), true))
	var auras: Array = me.get("auras", [])
	if not auras.is_empty():
		var names := []
		for a in auras:
			names.append(_name_of(String(a.get("card", ""))))
		row.add_child(_info_label("ауры: " + ", ".join(names), 12))
	row.add_child(_counts_label(me))
	zone.add_child(row)
	return zone


func _hero_block(hero: Dictionary, title: String) -> Control:
	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 5)
	var t := Label.new()
	t.text = title
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.add_theme_font_size_override("font_size", 15)
	box.add_child(t)
	box.add_child(_icon("heart", 22, Color(0.95, 0.42, 0.46)))
	box.add_child(_gem(str(int(hero["hp"])), Color(0.95, 0.42, 0.46)))
	if int(hero.get("armor", 0)) > 0:
		box.add_child(_icon("shield", 20, Color(0.72, 0.82, 0.98)))
		var arm := Label.new()
		arm.text = str(int(hero["armor"]))
		arm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		arm.add_theme_font_size_override("font_size", 16)
		arm.add_theme_color_override("font_color", Color(0.72, 0.82, 0.98))
		box.add_child(arm)
	return box


func _counts_label(p: Dictionary) -> Control:
	var l := Label.new()
	l.text = "рука %d   колода %d   сброс %d" % [
		int(p.get("handCount", 0)), int(p.get("deckCount", 0)),
		int(p.get("graveyardCount", 0))]
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.6, 0.64, 0.74))
	return l


func _info_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	return l


func _mana_crystals(mana: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	var avail: Dictionary = mana.get("available", {})
	var total: Dictionary = mana.get("crystals", {})
	var any := false
	for color in ["red", "yellow", "green", "blue", "violet", "colorless"]:
		var t := int(total.get(color, 0))
		if t <= 0:
			continue
		any = true
		var av := int(avail.get(color, 0))
		var group := HBoxContainer.new()
		group.mouse_filter = Control.MOUSE_FILTER_IGNORE
		group.add_theme_constant_override("separation", 2)
		for i in t:
			group.add_child(_mana_pip(color, i < av))
		row.add_child(group)
	if not any:
		var l := Label.new()
		l.text = "нет маны"
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.5, 0.53, 0.62))
		row.add_child(l)
	return row


# A single mana crystal: bright and glowing when available, dim when spent.
func _mana_pip(color: String, filled: bool) -> Control:
	var pip := Panel.new()
	pip.custom_minimum_size = Vector2(15, 22)
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var c := _color_for(color)
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(3)
	sb.set_border_width_all(1)
	if filled:
		sb.bg_color = c
		sb.border_color = c.lightened(0.45)
		sb.shadow_size = 6
		sb.shadow_color = Color(c.r, c.g, c.b, 0.65)
	else:
		sb.bg_color = Color(c.r, c.g, c.b, 0.10)
		sb.border_color = Color(c.r, c.g, c.b, 0.5)
	pip.add_theme_stylebox_override("panel", sb)
	return pip


# --- mana row (face-down backs + peekable awaken cards) ----------------------

func _manarow_view(mana_row: Array, mine: bool) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 3)
	var tag := Label.new()
	tag.text = "mana row:"
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_font_size_override("font_size", 11)
	row.add_child(tag)
	for i in mana_row.size():
		var slot: Dictionary = mana_row[i]
		var color := String(slot.get("color", "colorless"))
		if mine and slot.has("card"):
			row.add_child(_awaken_chip(int(i), String(slot["card"]), color))
		else:
			row.add_child(_mana_back(color))
	return row


func _mana_back(color: String) -> Control:
	var chip := Panel.new()
	chip.custom_minimum_size = Vector2(20, 28)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_for(color).darkened(0.45)
	sb.set_border_width_all(1)
	sb.border_color = _color_for(color)
	sb.set_corner_radius_all(3)
	chip.add_theme_stylebox_override("panel", sb)
	return chip


func _awaken_chip(idx: int, card_id: String, color: String) -> Control:
	var chip := UiCard.new()
	chip.custom_minimum_size = Vector2(26, 28)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _color_for(color).darkened(0.2)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.95, 0.85, 0.3)   # gold = peekable awaken
	sb.set_corner_radius_all(3)
	chip.add_theme_stylebox_override("panel", sb)
	chip.tooltip_text = "%s - awaken" % _name_of(card_id)
	var draggable := _my_turn()
	chip.payload = {
		"kind": "awaken", "manaRowIndex": idx, "card_id": card_id,
		"needs_target": _needs_target(card_id), "draggable": draggable,
		"target_side": _target_side(card_id),
	}
	chip.drag_label = "awaken: " + _name_of(card_id)
	chip.clicked.connect(func(p: Dictionary) -> void: _on_awaken_clicked(p))
	var star := Label.new()
	star.text = "AW"
	star.mouse_filter = Control.MOUSE_FILTER_IGNORE
	star.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	star.add_theme_font_size_override("font_size", 11)
	chip.add_child(star)
	return chip


# --- board rows --------------------------------------------------------------

func _board_row(board: Array, mine: bool) -> Control:
	# The whole row is a drop zone: dropping a playable hand/awaken card here
	# plays it (creatures land on your own side).
	var zone := UiCard.new()
	zone.custom_minimum_size = Vector2(0, CARD_SIZE.y + 12)
	zone.add_theme_stylebox_override("panel", _zone_style(mine))
	if mine:
		zone.can_drop_fn = func(data: Variant) -> bool: return _can_play_here(data)
		zone.drop_fn = func(data: Variant) -> void: _play_payload(data, 0)

	var row := HBoxContainer.new()
	# IGNORE so drops in the gaps fall through to the zone; the creature cards
	# (mouse_filter STOP) still receive their own input regardless.
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for cr in board:
		row.add_child(_creature_card(cr, mine))
	zone.add_child(row)
	return zone


func _creature_card(cr: Dictionary, mine: bool) -> UiCard:
	var card := _make_card(String(cr["card"]), cr)
	var cid := int(cr["id"])
	if mine:
		# Your creature: drag to attack; also a drop target for playing a creature
		# here or casting a friendly/any-target spell on it.
		var can_attack := _my_turn() and int(cr.get("atk", 0)) > 0 \
			and int(cr.get("frozen", 0)) == 0 \
			and not bool(cr.get("sick", false)) and not bool(cr.get("attacked", false))
		card.payload = {"kind": "attacker", "id": cid, "draggable": can_attack}
		card.drag_label = _name_of(String(cr["card"]))
		card.can_drop_fn = func(data: Variant) -> bool:
			return _can_play_here(data) or _can_cast_on(data, "friendly")
		card.drop_fn = func(data: Variant) -> void:
			if _can_cast_on(data, "friendly"):
				_play_payload(data, cid)
			else:
				_play_payload(data, 0)
		card.clicked.connect(func(_p: Dictionary) -> void: _on_my_creature(cid))
		# On your turn, dim creatures that cannot attack so the ready ones glow.
		if _my_turn() and not can_attack:
			card.modulate = Color(0.6, 0.62, 0.7, 0.92)
			card.rest_modulate = Color(0.6, 0.62, 0.7, 0.92)
		# A friendly/any spell awaiting a target lights up your creatures.
		if (casting_index >= 0 or awaken_index >= 0) and pending_side in ["friendly", "any"]:
			card.modulate = Color(1.45, 1.45, 1.1)
			card.rest_modulate = Color(1.45, 1.45, 1.1)
	else:
		# Enemy creature: accept an attacker (subject to provoke/stealth), or an
		# enemy/any-target spell (not on a hidden creature).
		card.can_drop_fn = func(data: Variant) -> bool:
			if typeof(data) != TYPE_DICTIONARY:
				return false
			if data.get("kind", "") == "attacker":
				return _valid_attack_target(cr)
			return _can_cast_on(data, "enemy") and not bool(cr.get("stealth", false))
		card.drop_fn = func(data: Variant) -> void:
			if data.get("kind", "") == "attacker":
				_send({"action": "attackCreature", "attacker": int(data["id"]), "target": cid})
				_clear_selection()
			else:
				_play_payload(data, cid)
		card.clicked.connect(func(_p: Dictionary) -> void: _on_enemy_creature(cid))
		# Light up only valid targets: attackable ones (respecting provoke/stealth)
		# while attacking, castable ones while a spell awaits a target.
		var await_attack := attacker_id >= 0 and _valid_attack_target(cr)
		var await_spell := (casting_index >= 0 or awaken_index >= 0) \
			and pending_side in ["enemy", "any"] and not bool(cr.get("stealth", false))
		if await_attack or await_spell:
			card.modulate = Color(1.45, 1.45, 1.1)
	return card


# --- hand --------------------------------------------------------------------

func _hand_row(hand: Array) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	var mana_zone := _mana_zone()
	box.add_child(mana_zone)

	for i in hand.size():
		var cid: String = hand[i]
		var card := _make_card(cid, null)
		var playable := _is_playable(cid)
		card.payload = {
			"kind": "hand", "index": int(i), "card_id": cid,
			"needs_target": _needs_target(cid), "is_creature": _is_creature(cid),
			"draggable": _my_turn(), "playable": playable,
			"target_side": _target_side(cid),
		}
		card.drag_label = _name_of(cid)
		# Dim cards you cannot play this turn so the playable ones stand out.
		if not playable:
			card.modulate = Color(0.62, 0.62, 0.68, 0.92)
			card.rest_modulate = Color(0.62, 0.62, 0.68, 0.92)
		var idx := i
		card.clicked.connect(func(_p: Dictionary) -> void: _on_hand_card(idx, cid))
		box.add_child(card)
	return box


func _mana_zone() -> Control:
	var zone := UiCard.new()
	zone.custom_minimum_size = Vector2(84, CARD_SIZE.y)
	zone.add_theme_stylebox_override("panel", _glass(Color(0.55, 0.55, 0.7), 0.32))
	zone.can_drop_fn = func(data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.get("kind", "") == "hand"
	zone.drop_fn = func(data: Variant) -> void:
		_place_mana(int(data["index"]), String(data["card_id"]))
	var l := Label.new()
	l.text = "TO\nMANA"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	zone.add_child(l)
	return zone


# --- card visual -------------------------------------------------------------

func _make_card(def_id: String, runtime) -> UiCard:
	# Minimal card face: art + cost/atk/hp gems + a color frame. Name, rules
	# text and keywords live in the hover tooltip, not on the face.
	var card := UiCard.new()
	card.custom_minimum_size = CARD_SIZE
	# Neon glow in the card's own color (drawn by the card panel, behind the
	# rounded face, so it is not clipped).
	var col := _primary_color(cards.get(def_id, {}))
	var glow := StyleBoxFlat.new()
	glow.bg_color = Color(0, 0, 0, 0)
	glow.set_corner_radius_all(12)
	glow.shadow_size = 10
	glow.shadow_color = Color(col.r, col.g, col.b, 0.6)
	card.add_theme_stylebox_override("panel", glow)
	card.add_child(_card_face(def_id, runtime))
	# Pretty hover tooltip (built lazily) instead of the plain text one. A
	# non-empty tooltip_text is still required for the tooltip to trigger.
	card.tooltip_text = _name_of(def_id)
	card.tooltip_builder = func() -> Control: return _build_tooltip(def_id)
	card.hoverable = true
	# The drag preview is the card itself, centered under the cursor.
	card.preview_builder = func() -> Control:
		var wrapper := Control.new()
		var f := _card_face(def_id, runtime)
		f.size = CARD_SIZE
		f.position = -CARD_SIZE / 2.0
		wrapper.add_child(f)
		return wrapper
	return card


func _build_tooltip(def_id: String) -> Control:
	var d: Dictionary = cards.get(def_id, {})
	var col := _primary_color(d)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.15, 0.98)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = col
	sb.set_content_margin_all(11)
	panel.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.custom_minimum_size = Vector2(250, 0)
	panel.add_child(v)

	var header := HBoxContainer.new()
	var name_l := Label.new()
	name_l.text = _name_of(def_id)
	name_l.add_theme_font_size_override("font_size", 18)
	name_l.add_theme_color_override("font_color", col.lightened(0.4))
	header.add_child(name_l)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sp)
	var cost_l := Label.new()
	cost_l.text = "%d" % _total_cost(d.get("cost", {}))
	cost_l.add_theme_font_size_override("font_size", 18)
	cost_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.98))
	header.add_child(cost_l)
	v.add_child(header)

	var type_l := Label.new()
	type_l.text = _type_label(d)
	type_l.add_theme_font_size_override("font_size", 12)
	type_l.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	v.add_child(type_l)

	var txt := _text_of(def_id)
	if txt != "":
		v.add_child(HSeparator.new())
		var text_l := Label.new()
		text_l.text = txt
		text_l.add_theme_font_size_override("font_size", 14)
		text_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text_l.custom_minimum_size = Vector2(250, 0)
		v.add_child(text_l)

	# Plain-language explanation of each keyword and each spell effect.
	var lines := []
	for kw in d.get("keywords", []):
		var kl := _keyword_desc(kw)
		if kl != "":
			lines.append(kl)
	for e in d.get("effects", []):
		var el := _effect_desc(e)
		if el != "":
			lines.append(el)
	if not lines.is_empty():
		v.add_child(HSeparator.new())
		for line in lines:
			v.add_child(_explain_label(line))
	return panel


func _explain_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.74, 0.8, 0.64))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(250, 0)
	return l


func _effect_desc(e: Dictionary) -> String:
	var a := String(e.get("action", ""))
	if not EFFECT_DESC.has(a):
		return ""
	var s: String = EFFECT_DESC[a]
	if e.has("value"):
		s = s.replace("N", str(int(e["value"])))
	return s


func _keyword_desc(kw: Dictionary) -> String:
	var id := String(kw.get("id", ""))
	if not KW_DESC.has(id):
		return ""
	var s: String = KW_DESC[id]
	if kw.has("n"):
		s = s.replace("N", str(int(kw["n"])))
	return s


func _type_label(d: Dictionary) -> String:
	var ru_type := {"creature": "Существо", "spell": "Заклинание", "aura": "Аура"}
	var line: String = ru_type.get(String(d.get("type", "")), String(d.get("type", "")))
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		return line + " - нейтральная"
	var ru_color := {
		"red": "красный", "yellow": "жёлтый", "green": "зелёный",
		"blue": "синий", "violet": "фиолетовый",
	}
	var names := []
	for c in colors:
		names.append(ru_color.get(String(c), String(c)))
	return line + " - " + ", ".join(names)


# Full card visual as a fixed-size Control with everything anchored to corners,
# so the size is constant regardless of contents (used for the card and the
# drag preview alike).
func _card_face(def_id: String, runtime) -> Control:
	var d: Dictionary = cards.get(def_id, {})
	var face := Panel.new()
	face.custom_minimum_size = CARD_SIZE
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Rounded body; clip_children rounds the gradient frame and art to it. The
	# corner gems are circles and sit clear of the rounded corners, so they read
	# fully. clip_children draws the panel normally, so the shadow still shows.
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.07, 0.07, 0.10)
	body.set_corner_radius_all(12)
	face.add_theme_stylebox_override("panel", body)
	face.clip_children = CanvasItem.CLIP_CHILDREN_ONLY

	# Color frame: gradient built from the card's colors (neutral = white).
	var frame := TextureRect.new()
	frame.texture = _frame_texture(d)
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(frame)

	# Art inset by FRAME px so the gradient shows as a ring around it.
	var art := _art_full(def_id)
	_anchor_inset(art, FRAME)
	face.add_child(art)

	# Status overlays that cover the art so they read at a glance.
	if typeof(runtime) == TYPE_DICTIONARY and int(runtime.get("frozen", 0)) > 0:
		var ice := ColorRect.new()
		ice.color = Color(0.45, 0.72, 1.0, 0.32)
		ice.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_anchor_inset(ice, FRAME)
		face.add_child(ice)
	if typeof(runtime) == TYPE_DICTIONARY and bool(runtime.get("sick", false)):
		var sleep := ColorRect.new()
		sleep.color = Color(0.08, 0.10, 0.24, 0.42)
		sleep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_anchor_inset(sleep, FRAME)
		face.add_child(sleep)

	# Cost badge (top-left): generic number plus one colored pip per colored
	# requirement, so the color cost is visible at a glance.
	var cost_badge := _cost_badge(d.get("cost", {}))
	cost_badge.anchor_left = 0
	cost_badge.anchor_top = 0
	cost_badge.anchor_right = 0
	cost_badge.anchor_bottom = 0
	cost_badge.offset_left = FRAME
	cost_badge.offset_top = FRAME
	cost_badge.offset_right = FRAME
	cost_badge.offset_bottom = FRAME
	cost_badge.grow_horizontal = Control.GROW_DIRECTION_END
	cost_badge.grow_vertical = Control.GROW_DIRECTION_END
	face.add_child(cost_badge)

	# Stat gems (bottom corners) for creatures.
	var has_stats: bool = d.has("stats") or (typeof(runtime) == TYPE_DICTIONARY and runtime.has("atk"))
	if has_stats:
		var atk := 0
		var hp := 0
		var max_hp := 0
		if typeof(runtime) == TYPE_DICTIONARY:
			atk = int(runtime.get("atk", 0))
			hp = int(runtime.get("hp", 0))
			max_hp = int(runtime.get("maxHp", hp))
		else:
			atk = int(d["stats"].get("atk", 0))
			hp = int(d["stats"].get("hp", 0))
			max_hp = hp
		var atk_gem := _gem(str(atk), Color(0.95, 0.8, 0.35))
		_anchor_corner(atk_gem, 0, 1, FRAME, -GEM - FRAME)
		face.add_child(atk_gem)
		var hp_color := Color(0.55, 0.95, 0.5) if hp >= max_hp else Color(0.97, 0.4, 0.4)
		var hp_gem := _gem(str(hp), hp_color)
		_anchor_corner(hp_gem, 1, 1, -GEM - FRAME, -GEM - FRAME)
		face.add_child(hp_gem)

	# Status icons (top-right), right-aligned and growing left/down.
	if typeof(runtime) == TYPE_DICTIONARY:
		var status_row = _status_icons(runtime)
		if status_row != null:
			status_row.anchor_left = 1
			status_row.anchor_right = 1
			status_row.offset_left = -FRAME
			status_row.offset_right = -FRAME
			status_row.offset_top = FRAME
			status_row.offset_bottom = FRAME
			status_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			status_row.grow_vertical = Control.GROW_DIRECTION_END
			face.add_child(status_row)
	return face


func _anchor_inset(node: Control, inset: float) -> void:
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.offset_left = inset
	node.offset_top = inset
	node.offset_right = -inset
	node.offset_bottom = -inset


func _anchor_corner(node: Control, ax: float, ay: float, ox: float, oy: float) -> void:
	# Pin a GEM-sized node to corner (ax,ay in {0,1}) with offset (ox,oy).
	node.anchor_left = ax
	node.anchor_right = ax
	node.anchor_top = ay
	node.anchor_bottom = ay
	node.offset_left = ox
	node.offset_right = ox + GEM
	node.offset_top = oy
	node.offset_bottom = oy + GEM


func _gem(text: String, ring: Color) -> Control:
	var g := Panel.new()
	g.custom_minimum_size = Vector2(GEM, GEM)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.94)
	sb.set_corner_radius_all(int(GEM / 2.0))
	sb.set_border_width_all(2)
	sb.border_color = ring
	g.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", ring.lightened(0.4))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_child(l)
	return g


func _art_full(def_id: String) -> Control:
	var path := "res://art/%s.png" % def_id
	if ResourceLoader.exists(path):
		var tex := TextureRect.new()
		tex.texture = load(path)
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		return tex
	var ph := ColorRect.new()
	ph.color = _primary_color(cards.get(def_id, {})).darkened(0.4)
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return ph


func _frame_texture(d: Dictionary) -> Texture2D:
	var cols := PackedColorArray()
	var card_colors: Array = d.get("color", [])
	if card_colors.is_empty():
		# Colorless: a clean white frame. The prismatic rainbow is reserved for
		# a card that genuinely carries all five colors.
		cols.append(Color(0.93, 0.93, 0.97))
		cols.append(Color(0.78, 0.80, 0.88))
	else:
		for c in card_colors:
			cols.append(_color_for(String(c)))
		if cols.size() == 1:
			cols.append(cols[0])

	var grad := Gradient.new()
	var offs := PackedFloat32Array()
	for i in cols.size():
		offs.append(float(i) / float(cols.size() - 1))
	grad.offsets = offs
	grad.colors = cols

	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_LINEAR
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(1, 1)
	return tex


func _total_cost(cost: Dictionary) -> int:
	var t := int(cost.get("generic", 0))
	for c in ["red", "yellow", "green", "blue", "violet"]:
		t += int(cost.get(c, 0))
	return t


func _cost_badge(cost: Dictionary) -> Control:
	var pill := PanelContainer.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.09, 0.9)
	sb.set_corner_radius_all(9)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.55, 0.6, 0.75, 0.7)
	sb.set_content_margin_all(3)
	pill.add_theme_stylebox_override("panel", sb)

	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	var gen := int(cost.get("generic", 0))
	var has_color := false
	for c in ["red", "yellow", "green", "blue", "violet"]:
		if int(cost.get(c, 0)) > 0:
			has_color = true
	# Show the generic number when there is one, or when the card is free of any
	# colored pips (so a "0" still appears instead of an empty badge).
	if gen > 0 or not has_color:
		var n := Label.new()
		n.text = str(gen)
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
		n.add_theme_font_size_override("font_size", 18)
		n.add_theme_color_override("font_color", Color(0.95, 0.96, 1.0))
		box.add_child(n)
	for c in ["red", "yellow", "green", "blue", "violet"]:
		for _i in int(cost.get(c, 0)):
			box.add_child(_cost_pip(c))
	pill.add_child(box)
	return pill


func _cost_pip(color: String) -> Control:
	var c := _color_for(color)
	var pip := Panel.new()
	pip.custom_minimum_size = Vector2(13, 16)
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(3)
	sb.set_border_width_all(1)
	sb.border_color = c.lightened(0.45)
	pip.add_theme_stylebox_override("panel", sb)
	var holder := CenterContainer.new()   # vertical-center the pip beside the number
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(pip)
	return holder


func _status_icons(cr: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 3)
	var any := false
	if int(cr.get("frozen", 0)) > 0:
		row.add_child(_icon("snowflake", 20, Color(0.6, 0.85, 1.0)))
		any = true
	if bool(cr.get("shield", false)):
		row.add_child(_icon("shield", 20, Color(0.97, 0.88, 0.4)))
		any = true
	if bool(cr.get("stealth", false)):
		row.add_child(_icon("eye", 20, Color(0.75, 0.55, 0.97)))
		any = true
	if int(cr.get("blind", 0)) > 0:
		row.add_child(_icon("eye", 20, Color(0.97, 0.5, 0.5)))
		any = true
	if bool(cr.get("sick", false)):
		row.add_child(_icon("moon", 20, Color(0.72, 0.77, 0.87)))
		any = true
	if not any:
		return null
	# Dark chip behind the icons so they read over any art.
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.05, 0.7)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(3)
	chip.add_theme_stylebox_override("panel", sb)
	chip.add_child(row)
	return chip


# --- styles ------------------------------------------------------------------

func _hero_style(tint: Color) -> StyleBoxFlat:
	return _glass(tint, 0.4)


func _zone_style(mine: bool) -> StyleBoxFlat:
	var accent := Color(0.3, 0.75, 0.6) if mine else Color(0.75, 0.35, 0.4)
	var sb := _glass(accent, 0.22)
	sb.shadow_size = 0   # board zones stay calm; only cards/heroes glow
	return sb


# --- controls + hints --------------------------------------------------------

func _controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var end_btn := _neon_button("End Turn", Color(1.0, 0.62, 0.3))
	end_btn.disabled = not _my_turn()
	end_btn.pressed.connect(func() -> void:
		_clear_selection()
		_send({"action": "endTurn"}))
	row.add_child(end_btn)

	var hint := Label.new()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.78))
	if casting_index >= 0 or awaken_index >= 0:
		hint.text = "pick an enemy creature as the target (click the card again to cancel)"
	elif attacker_id >= 0:
		hint.text = "pick an enemy creature or the enemy hero to attack"
	else:
		hint.text = "drag a card to your board or the MANA zone, or drag a creature onto a target to attack"
	row.add_child(hint)
	return row


# --- drag drop helpers (shared by play / awaken) -----------------------------

func _can_play_here(data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not (data.get("kind", "") in ["hand", "awaken"]):
		return false
	# An unplayable hand card lights up no board zone (but can still go to mana).
	if data.get("kind", "") == "hand" and not bool(data.get("playable", true)):
		return false
	# A targeted spell must be dropped on a creature, not on the board.
	return not bool(data.get("needs_target", false))


# True if the dragged targeted spell/awaken may be cast on a creature of the
# given side ("friendly" or "enemy"). An "any" spell hits either side.
func _can_cast_on(data: Variant, want_side: String) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not (data.get("kind", "") in ["hand", "awaken"]):
		return false
	if not bool(data.get("needs_target", false)):
		return false
	var side := String(data.get("target_side", ""))
	if side != "any" and side != want_side:
		return false
	# Hand cards must be affordable; awaken legality is checked by the server.
	if data.get("kind", "") == "hand" and not bool(data.get("playable", true)):
		return false
	return true


func _play_payload(data: Variant, target: int) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	if data.get("kind", "") == "awaken":
		_send({"action": "awaken", "manaRowIndex": int(data["manaRowIndex"]), "target": target})
	else:
		_send({"action": "play", "handIndex": int(data["index"]), "target": target})
	_clear_selection()


func _place_mana(idx: int, card_id: String) -> void:
	var d: Dictionary = cards.get(card_id, {})
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		_send({"action": "placeMana", "handIndex": idx, "color": "colorless"})
		_clear_selection()
	elif colors.size() == 1:
		_send({"action": "placeMana", "handIndex": idx, "color": String(colors[0])})
		_clear_selection()
	else:
		# Multicolor card: let the player choose which crystal it becomes.
		_show_color_picker(idx, colors)


func _show_color_picker(idx: int, colors: Array) -> void:
	# In-scene chooser: a dim full-screen backdrop (click to cancel) with a small
	# panel of color buttons near the cursor. Avoids the flaky popup window.
	_close_picker()
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var backdrop := Button.new()
	backdrop.flat = true
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.pressed.connect(_close_picker)
	layer.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _glass(Color(0.6, 0.62, 0.8), 0.97))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "Каким кристаллом положить?"
	title.add_theme_font_size_override("font_size", 14)
	vb.add_child(title)
	for c in colors:
		var cc := String(c)
		var b := _neon_button(_color_ru(cc), _color_for(cc))
		b.pressed.connect(func() -> void:
			_send({"action": "placeMana", "handIndex": idx, "color": cc})
			_clear_selection()
			_close_picker())
		vb.add_child(b)
	panel.add_child(vb)
	layer.add_child(panel)
	add_child(layer)

	var pos := get_global_mouse_position() - Vector2(20, 20)
	pos.x = clampf(pos.x, 8.0, size.x - 200.0)
	pos.y = clampf(pos.y, 8.0, size.y - 180.0)
	panel.position = pos
	_picker = layer


func _close_picker() -> void:
	if _picker != null:
		_picker.queue_free()
		_picker = null


func _color_ru(color: String) -> String:
	return {
		"red": "красный", "yellow": "жёлтый", "green": "зелёный",
		"blue": "синий", "violet": "фиолетовый", "colorless": "бесцветный",
	}.get(color, color)


# --- click fallback ----------------------------------------------------------

func _on_hand_card(idx: int, card_id: String) -> void:
	if not _my_turn():
		return
	if casting_index == idx:
		casting_index = -1
		_rebuild()
		return
	if _needs_target(card_id):
		_clear_selection()
		casting_index = idx
		pending_side = _target_side(card_id)
		_rebuild()
	else:
		_clear_selection()
		_send({"action": "play", "handIndex": idx})


func _on_awaken_clicked(p: Dictionary) -> void:
	if not _my_turn():
		return
	var idx := int(p["manaRowIndex"])
	if awaken_index == idx:
		awaken_index = -1
		_rebuild()
		return
	if bool(p.get("needs_target", false)):
		_clear_selection()
		awaken_index = idx
		pending_side = _target_side(String(p.get("card_id", "")))
		_rebuild()
	else:
		_clear_selection()
		_send({"action": "awaken", "manaRowIndex": idx, "target": 0})


func _on_my_creature(cid: int) -> void:
	# Cast a pending friendly/any spell on this creature, else select it to attack.
	if casting_index >= 0 and pending_side in ["friendly", "any"]:
		_send({"action": "play", "handIndex": casting_index, "target": cid})
		_clear_selection()
		return
	if awaken_index >= 0 and pending_side in ["friendly", "any"]:
		_send({"action": "awaken", "manaRowIndex": awaken_index, "target": cid})
		_clear_selection()
		return
	_clear_selection()
	attacker_id = cid
	_rebuild()


func _on_enemy_creature(cid: int) -> void:
	if casting_index >= 0 and pending_side in ["enemy", "any"]:
		_send({"action": "play", "handIndex": casting_index, "target": cid})
		_clear_selection()
	elif awaken_index >= 0 and pending_side in ["enemy", "any"]:
		_send({"action": "awaken", "manaRowIndex": awaken_index, "target": cid})
		_clear_selection()
	elif attacker_id >= 0:
		_send({"action": "attackCreature", "attacker": attacker_id, "target": cid})
		_clear_selection()


func _on_enemy_hero() -> void:
	if attacker_id >= 0:
		_send({"action": "attackHero", "attacker": attacker_id})
		_clear_selection()
