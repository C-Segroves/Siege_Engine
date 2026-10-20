class_name StalemateRule
extends FailRule
## Lost when nobody is left on either side: nothing can move the mission on.


func make_verdict(world: MissionWorld, _dt: float) -> MissionVerdict:
	if world.get_living_count(0) > 0 or world.get_living_count(1) > 0:
		return null
	return MissionVerdict.make_loss(code, text)
