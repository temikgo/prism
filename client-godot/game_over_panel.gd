class_name GameOverPanel
extends Control

# Full-screen end-of-match overlay: the verdict word over a dim, plus a button
# back to the menu. Self-contained -- it knows nothing about the match; the
# coordinator passes win/lose and listens for `to_menu`.

signal to_menu


func setup(result: String) -> void:  # "win" | "lose" | "draw"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks underneath
	var accent := Color(0.5, 0.95, 0.6)
	if result == "draw":
		accent = Color(0.85, 0.8, 0.5)
	elif result == "lose":
		accent = Color(0.95, 0.45, 0.45)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	# Roomier glass so the wide display word never sits flush against the frame.
	var sb := Ui.glass(accent, 0.9)
	sb.set_content_margin_all(34)
	panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 18)
	vb.custom_minimum_size = Vector2(440, 0)  # margin around the verdict text
	var word := "ПОБЕДА"
	if result == "draw":
		word = "НИЧЬЯ"
	elif result == "lose":
		word = "ПОРАЖЕНИЕ"
	var verdict := Ui.label(word, 46, accent.lightened(0.3), true)
	verdict.add_theme_font_override("font", Fonts.DISPLAY)
	verdict.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(verdict)
	var btn := Ui.neon_button("В меню", accent)
	btn.custom_minimum_size = Vector2(200, 48)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(func() -> void: to_menu.emit())
	vb.add_child(btn)
	panel.add_child(vb)
	center.add_child(panel)
