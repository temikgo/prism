class_name Audio

# Static facade over the Sfx autoload node (/root/Sfx). Call sites use Audio.play()
# rather than the autoload's global `Sfx` identifier, because that global is only
# bound in the running project -- under the headless test runner (-s mode, which
# skips autoloads but registers /root/Sfx by hand) the global is undefined. Going
# through the tree resolves in both, so the audio wiring is exercised, not skipped.
# All calls are null-safe: if the node is absent, they quietly do nothing.


static func _n() -> Node:
	var ml := Engine.get_main_loop()
	return (ml as SceneTree).root.get_node_or_null("Sfx") if ml is SceneTree else null


static func play(name: String, jitter := 0.06) -> void:
	var n := _n()
	if n != null:
		n.play(name, jitter)


static func start_ambient() -> void:
	var n := _n()
	if n != null:
		n.start_ambient()


static func set_music(v: float) -> void:
	var n := _n()
	if n != null:
		n.set_music(v)


static func set_sfx(v: float) -> void:
	var n := _n()
	if n != null:
		n.set_sfx(v)


static func music_vol() -> float:
	var n := _n()
	return float(n.music_vol) if n != null else 0.6


static func sfx_vol() -> float:
	var n := _n()
	return float(n.sfx_vol) if n != null else 0.9
