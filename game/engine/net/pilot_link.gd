class_name PilotLink
extends RefCounted
## A body's tie to the network pilot that steers it (docs/DEDICATED_SERVER_SCALING.md section 2.2). Herc and Infantry
## call begin_step before and end_step after the movement of every physics step when they have a link; without one
## (a LAN host's default) nothing changes. The server side feeds queued input frames (ServerPilotLink), the client
## side predicts its own pilot (Prediction).


## The client simulates this body itself from its pilot's controls instead of following snapshots.
func is_predicting(_body: Herc) -> bool:
	return false


func begin_step(_body: Herc, _delta: float) -> void:
	pass


func end_step(_body: Herc) -> void:
	pass
