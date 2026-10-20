class_name ProtectedLostRule
extends FailRule
## Lost when one of the guarded units is no longer alive.

var units: Array[String] = []


func _init(p_code := 0, p_text := "", p_units: Array[String] = []) -> void:
	super(p_code, p_text)
	units = p_units


func make_verdict(world: MissionWorld, _dt: float) -> MissionVerdict:
	for u in units:
		if not world.is_unit_alive(u):
			return MissionVerdict.make_loss(get_code(), text)
	return null
