class_name DecisionPanel
extends Control

# Penta wave-2 sub-game prompt: Ultimatum / Standoff / Blood Auction. The panel
# is rebuilt from the server's `decision` view and emits `choose(value)`, which
# Main forwards as {"action":"decision","choice":value}. For Auction the local
# +/- stepper composes the raise; its label updates in place (no server round
# trip) until the player commits with "Поставить" or "Пас".

signal choose(value: int)

const ACCENT := Color(0.85, 0.55, 1.0)

var _bid_amount := 0
var _bid_min := 0
var _bid_max := 0
var _bid_label: Label
var _bid_button: Button


func _shell() -> VBoxContainer:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Ui.glass(ACCENT, 0.92))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(440, 0)
	panel.add_child(vb)
	center.add_child(panel)
	return vb


func _title(vb: VBoxContainer, t: String) -> void:
	vb.add_child(Ui.label(t, 30, ACCENT.lightened(0.3), true, true))


func _body(vb: VBoxContainer, t: String) -> void:
	var l := Ui.label(t, 15, Color(0.78, 0.8, 0.88), true)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(400, 0)
	vb.add_child(l)


func _act(vb: VBoxContainer, t: String, value: int) -> void:
	var b := Ui.neon_button(t, ACCENT)
	b.custom_minimum_size = Vector2(0, 42)
	b.pressed.connect(func() -> void: choose.emit(value))
	vb.add_child(b)


# The interactive prompt shown to the deciding player.
func setup(dec: Dictionary, can_sacrifice: bool) -> void:
	var vb := _shell()
	match String(dec.get("kind", "")):
		"ultimatum":
			_title(vb, "Ультиматум")
			_body(vb, "Соперник ставит ультиматум — выберите:")
			if can_sacrifice:
				_act(vb, "Пожертвовать сильнейшее существо", 0)
			_act(vb, "Потерять %d HP" % int(dec.get("value", 5)), 1)
		"standoff":
			_title(vb, "Противостояние")
			_body(vb, "Тайно выберите. Оба Удара — обоим 5. Удар против Защиты — ударивший наносит 3. Обе Защиты — оба берут 2 карты.")
			_act(vb, "Удар", 0)
			_act(vb, "Защита", 1)
		"auction":
			_auction(vb, dec)


func _auction(vb: VBoxContainer, dec: Dictionary) -> void:
	_title(vb, "Кровавый Аукцион")
	var bid := int(dec.get("bid", 0))
	var hp := int(dec.get("yourHp", 0))
	_body(vb, "Ставка HP за «уничтожить все вражеские существа». Текущая ставка: %d. Ваше HP: %d. Победитель платит ставку HP." % [bid, hp])
	_bid_min = bid + 1
	_bid_max = hp - 1
	if _bid_min <= _bid_max:
		_bid_amount = clampi(_bid_amount, _bid_min, _bid_max)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 10)
		var minus := Ui.neon_button("−", ACCENT)
		minus.custom_minimum_size = Vector2(48, 40)
		minus.pressed.connect(_on_minus)
		row.add_child(minus)
		_bid_label = Ui.label("%d HP" % _bid_amount, 22, ACCENT.lightened(0.3), true, true)
		_bid_label.custom_minimum_size = Vector2(90, 0)
		row.add_child(_bid_label)
		var plus := Ui.neon_button("+", ACCENT)
		plus.custom_minimum_size = Vector2(48, 40)
		plus.pressed.connect(_on_plus)
		row.add_child(plus)
		vb.add_child(row)
		_bid_button = Ui.neon_button("Поставить %d HP" % _bid_amount, ACCENT)
		_bid_button.custom_minimum_size = Vector2(0, 42)
		_bid_button.pressed.connect(_on_bid)
		vb.add_child(_bid_button)
	else:
		_body(vb, "Поднять ставку нечем — только пас.")
	_act(vb, "Пас", -1)


func _on_minus() -> void:
	_bid_amount = maxi(_bid_min, _bid_amount - 1)
	_refresh_bid()


func _on_plus() -> void:
	_bid_amount = mini(_bid_max, _bid_amount + 1)
	_refresh_bid()


func _on_bid() -> void:
	choose.emit(_bid_amount)


func _refresh_bid() -> void:
	if _bid_label:
		_bid_label.text = "%d HP" % _bid_amount
	if _bid_button:
		_bid_button.text = "Поставить %d HP" % _bid_amount


# A non-interactive notice while the OTHER player is deciding.
func setup_waiting(kind: String) -> void:
	var vb := _shell()
	var names := {"ultimatum": "Ультиматум", "standoff": "Противостояние", "auction": "Кровавый Аукцион"}
	_title(vb, String(names.get(kind, "Решение")))
	_body(vb, "Соперник принимает решение…")
