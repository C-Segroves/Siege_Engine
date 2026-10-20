class_name NetLog
extends RefCounted
## Persistent network log (host and client): user://logs/siege_net.log, one line per event: connects, disconnects,
## kicks / refusals with their reason, protocol mismatches, start gating and peer timeouts. Rotates to
## siege_net.log.1 (one generation) past MAX_BYTES, so it never grows without bound.

const PATH := "user://logs/siege_net.log"
const MAX_BYTES := 256 * 1024


static func write(event: String, detail := "") -> void:
	var dir := PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	_rotate()
	var f := FileAccess.open(PATH, FileAccess.READ_WRITE if FileAccess.file_exists(PATH) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("%s [pid %d] %-14s %s" % [Time.get_datetime_string_from_system(false, true), OS.get_process_id(), event, detail])
	f.close()


static func _rotate() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	var size := f.get_length() if f else 0
	if f:
		f.close()
	if size > MAX_BYTES:
		DirAccess.rename_absolute(PATH, PATH + ".1")
