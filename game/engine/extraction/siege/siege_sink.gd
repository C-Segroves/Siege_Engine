class_name SiegeSink
extends MissionSink
## The output port of the siege's MissionAnnouncer: every line goes to `say` as (text, seconds), which CybridSiege
## sends to all peers (the map-wide broadcast). The announcer queues the lines (FIFO), each held for its seconds.

var say := Callable()
var lines_said := 0


func apply_message(message: MissionMessage) -> void:
	lines_said += 1
	if say.is_valid():
		say.call(message.text, message.seconds)
