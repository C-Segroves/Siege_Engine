class_name SSFlyerOrders
extends RefCounted
## Starsiege flyers (dropships, cargo ships, Banshees ...) are Flyers moved by the shared FlightModel
## and steered by FlyerAI. A flyer the mission places on the ground (a parked dropship, HA0's downed
## cargo ship) stays landed until a script orders it to fly; one placed in the air circles its
## spawn point. The scripts' order(guard <route>) / order(attack <unit>) start its flight.

## A flyer placed lower than this above the terrain stands on its landing gear (the exported
## campaign flyers: parked ones 2-30 m, airborne ones 60 m and up).
const PARKED_HEIGHT := 40.0
## Flyers circle their drop point until a script orders them elsewhere (FlyerAI patrol loop), metres.
const PATROL_RADIUS := 300.0
const PATROL_POINTS := 4


static func is_parked_placement(rt: StarsiegeMissionRuntime, def: Dictionary) -> bool:
	var p := SSObjectTree.position_of_def(def)
	return p.y - rt.ground_height_at(p) < PARKED_HEIGHT


static func make_patrol(centre: Vector3) -> Array:
	var pts := []
	for k in PATROL_POINTS:
		var a := TAU * k / PATROL_POINTS
		pts.append(centre + Vector3(cos(a), 0.0, sin(a)) * PATROL_RADIUS)
	return pts


## Lands a freshly spawned AI flyer and stops its pilot until an order arrives.
static func park(fl: Flyer) -> void:
	fl.ai = null
	fl.apply_landed_start()


## order(<flyer>, what, args): guard <group/object> flies its route (or to the object), attack <unit>
## hunts it; other orders are not modelled for flyers.
static func order(tree: SSObjectTree, fl: Flyer, what: String, args: Array) -> void:
	var goal := tree.resolve(args[0] if args.size() > 0 else "")
	match what:
		"guard":
			if goal == 0:
				return
			var pts: Array[Vector3] = []
			if tree.kind_of(goal) == "group":
				pts = tree.route_points(goal)
			if pts.is_empty():
				pts.append(tree.position_of(goal))
			fl.patrol.clear()
			for p in pts:
				fl.patrol.append(p + Vector3.UP * fl.altitude)
			fl.patrol_i = 0
			_launch(fl)
		"attack":
			var t := tree.node_of(goal)
			if t != null:
				fl.target = t
				_launch(fl)


static func _launch(fl: Flyer) -> void:
	if fl.ai == null:
		fl.start_ai()
