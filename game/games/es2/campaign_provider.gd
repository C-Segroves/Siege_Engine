extends RefCounted
## Saga provider for Earthsiege 2: wraps CampaignES2 (see game/engine/saga.gd). Missions resolve
## to pack "es2" dictionaries, which Battle runs with MissionRuntimeES2.


static func start(_variant: String) -> Object:
	return CampaignES2.start(1)


static func restore(d: Dictionary) -> Object:
	return CampaignES2.from_dict(d)
