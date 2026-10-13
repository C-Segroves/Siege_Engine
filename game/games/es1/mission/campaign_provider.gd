extends RefCounted
## Saga provider for Earthsiege: wraps Campaign (see game/engine/saga.gd).


static func start(_variant: String) -> Object:
	return Campaign.start(0)


static func restore(d: Dictionary) -> Object:
	return Campaign.from_dict(d)
