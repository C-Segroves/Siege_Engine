class_name SSStartPositions
extends RefCounted
## Where Starsiege mission vehicles start: the player squad at the mission's first drop point (squad
## slots around it), every vehicle on the terrain or above it, out of any building it would start in.
## A position below the terrain inside an interior keeps its height: HA0 starts in a mole tunnel (the
## map's holes.png opens it).

const PLAYER_START_LIFT := 1.0
## A mission position this far below the terrain is underground (inside a tunnel or base interior).
const UNDERGROUND_MARGIN := 3.0

var rt: StarsiegeMissionRuntime
var _clearance: SpawnClearance


func _init(runtime: StarsiegeMissionRuntime) -> void:
	rt = runtime


## Start transform of player slot `k`.
func make_player_spawn(k: int) -> Transform3D:
	var drops := MissionRuntime._arr(rt.m.get("drop_points"))
	if drops.is_empty():
		return Transform3D.IDENTITY
	var d: Dictionary = drops[0]
	var xf := Transform3D(Basis(Vector3.UP, float(d.get("yaw", 0.0))), SSObjectTree.position_of_def(d))
	xf.origin += xf.basis * Formation.squad_slot(k)
	xf.origin = make_start_position(xf.origin, PLAYER_START_LIFT)
	return xf


## Where a vehicle placed at mission position `p` starts: on the terrain (or `p` when that is above
## it, standing on a floor there: a position the file puts in the air comes down onto the surface below it, one the file
## buries in the terrain comes up onto it, SpawnClearance.make_supported_origin), `lift` metres up, then raised onto any
## building it would start inside.
func make_start_position(p: Vector3, lift: float) -> Vector3:
	var g := ground_height_at(p)
	var start := p
	if not (p.y < g - UNDERGROUND_MARGIN and _get_clearance().is_under_cover(p + Vector3.UP * lift)):
		start.y = maxf(p.y, g)
	start = _get_clearance().make_supported_origin(start)   # (underground only while a floor of the tunnel is under it)
	start.y += lift
	return _get_clearance().make_clear_origin(start)


## Terrain height under p (p.y where there is no terrain).
func ground_height_at(p: Vector3) -> float:
	var g := MapBuilder.ground_height(rt.battle, p)
	return g if g > -1e8 else p.y


func _get_clearance() -> SpawnClearance:
	if _clearance == null:
		_clearance = SpawnClearance.make(rt.battle)
	return _clearance
