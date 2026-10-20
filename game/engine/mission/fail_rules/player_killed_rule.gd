class_name PlayerKilledRule
extends FailRule
## Lost when the player is dead; `delay` seconds pass before the end (Starsiege: an 8 s death debrief).

var delay := 0.0


func _init(p_code := 0, p_text := "", p_delay := 0.0) -> void:
	super(p_code, p_text)
	delay = p_delay


func make_verdict(world: MissionWorld, _dt: float) -> MissionVerdict:
	if world.is_player_alive():
		return null
	return MissionVerdict.make_loss(get_code(), text, delay)
