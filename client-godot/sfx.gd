extends Node

# Autoload "Sfx": the client's whole audio surface. Owns a small pool of one-shot
# players on a dedicated "Sfx" bus and a looping ambient player on a "Music" bus,
# so their volumes are independent and persist (user://audio.cfg). Sounds are the
# procedural wavs in res://sfx/ (built by tools/gen_sfx.py). Any script can call
# Sfx.play("damage"); the settings screen drives set_music/set_sfx.

const DIR := "res://sfx/"
const CFG := "user://audio.cfg"
const NAMES := [
	"ui_click", "ui_tap", "ui_toggle", "ui_hover", "card_play", "card_reveal", "mana_place", "draw",
	"attack_hit", "damage", "hero_hit", "death", "summon", "heal", "aura",
	"aura_break", "turn_start", "decision_prompt", "victory", "defeat",
]
const POOL := 8

var _streams := {}       # name -> AudioStream
var _pool: Array = []     # round-robin AudioStreamPlayers on the Sfx bus
var _pool_i := 0
var _amb: AudioStreamPlayer = null
var music_vol := 0.6      # 0..1 linear; persisted
var sfx_vol := 0.9


func _ready() -> void:
	_ensure_buses()
	_load_cfg()
	for n in NAMES:
		if ResourceLoader.exists(DIR + n + ".wav"):
			_streams[n] = load(DIR + n + ".wav")
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "Sfx"
		add_child(p)
		_pool.append(p)
	_amb = AudioStreamPlayer.new()
	_amb.bus = "Music"
	add_child(_amb)
	if ResourceLoader.exists(DIR + "ambient.wav"):
		var s: AudioStream = load(DIR + "ambient.wav")
		if s is AudioStreamWAV:
			s.loop_mode = AudioStreamWAV.LOOP_FORWARD
			s.loop_begin = 0
			s.loop_end = int(s.data.size() / 2)  # 16-bit mono -> 2 bytes/frame
		_amb.stream = s
	_apply_volumes()


# Create the Music / Sfx buses (routed to Master) if a prior run has not already.
func _ensure_buses() -> void:
	for b in ["Music", "Sfx"]:
		if AudioServer.get_bus_index(b) == -1:
			var i := AudioServer.bus_count
			AudioServer.add_bus(i)
			AudioServer.set_bus_name(i, b)
			AudioServer.set_bus_send(i, "Master")


# Fire a one-shot by name, with a little pitch jitter so repeats never sound
# machine-gunned. Unknown names are silently ignored (safe to over-hook).
func play(name: String, pitch_jitter := 0.06) -> void:
	var s: AudioStream = _streams.get(name)
	if s == null:
		return
	var p: AudioStreamPlayer = _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	p.stream = s
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()


func start_ambient() -> void:
	if _amb != null and _amb.stream != null and not _amb.playing:
		_amb.play()


func stop_ambient() -> void:
	if _amb != null:
		_amb.stop()


# --- volume (0..1 linear) ----------------------------------------------------

func set_music(v: float) -> void:
	music_vol = clampf(v, 0.0, 1.0)
	_apply_volumes()
	_save_cfg()


func set_sfx(v: float) -> void:
	sfx_vol = clampf(v, 0.0, 1.0)
	_apply_volumes()
	_save_cfg()


func _apply_volumes() -> void:
	_bus_db("Music", music_vol)
	_bus_db("Sfx", sfx_vol)


func _bus_db(bus: String, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return
	AudioServer.set_bus_volume_db(i, -80.0 if linear <= 0.001 else linear_to_db(linear))


func _load_cfg() -> void:
	var c := ConfigFile.new()
	if c.load(CFG) == OK:
		music_vol = float(c.get_value("audio", "music", music_vol))
		sfx_vol = float(c.get_value("audio", "sfx", sfx_vol))


func _save_cfg() -> void:
	var c := ConfigFile.new()
	c.set_value("audio", "music", music_vol)
	c.set_value("audio", "sfx", sfx_vol)
	c.save(CFG)
