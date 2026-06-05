class_name Net
extends Node

# WebSocket transport. Owns the socket, polls it, and surfaces lifecycle + JSON
# messages as signals. No game knowledge -- the coordinator (Main) decides what
# to do with each message.

signal opened
signal closed
signal message(data: Dictionary)

var _socket := WebSocketPeer.new()
var _was_open := false
var _active := false  # a connect attempt is live (so a CLOSED state means "ended")


func connect_to(url: String) -> int:
	_active = true
	_was_open = false
	return _socket.connect_to_url(url)


func is_open() -> bool:
	return _socket.get_ready_state() == WebSocketPeer.STATE_OPEN


func send(obj: Dictionary) -> void:
	if is_open():
		_socket.send_text(JSON.stringify(obj))


func _process(_dt: float) -> void:
	_socket.poll()
	var st := _socket.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			opened.emit()
		while _socket.get_available_packet_count() > 0:
			var txt := _socket.get_packet().get_string_from_utf8()
			var data: Variant = JSON.parse_string(txt)
			if typeof(data) == TYPE_DICTIONARY:
				message.emit(data)
	elif st == WebSocketPeer.STATE_CLOSED and _active:
		# Fires for a clean close and for a connection that never opened (server
		# down / refused), so the caller can surface either as "lost connection".
		_active = false
		_was_open = false
		closed.emit()
