class_name LeftAreaRule
extends FailRule
## Lost when the player has been outside the playable area for `grace` seconds (Earthsiege 1 and 2: 4.9 s).

var grace := 0.0


func _init(p_code := 0, p_text := "", p_grace := 0.0) -> void:
	super(p_code, p_text)
	grace = p_grace


func make_verdict(world: MissionWorld, _dt: float) -> MissionVerdict:
	if world.get_out_of_area_seconds() < grace:
		return null
	return MissionVerdict.make_loss(get_code(), text).apply_rearm_on_code_change()
