class_name GameModeDefenders
extends Node
## Host: a mode's base defenders (Starsiege WAR, WAR_Martian_Standoff.cs): the mission's AI Hercs (mode objects of
## kind "defender") guard their base; a destroyed one is dropped again at its re-drop point after ai_respawn_s, or
## ai_respawn_no_hq_s once its side's HQ is destroyed (vehicle::onDestroyed + trevorsCloneVehicle). Child
## "Defenders" of GameModeDirector.

const SKILL := 0.9                    # the script's defender pilots (skill and accuracy 0.9)
const GUARD_ORDER := 6                # AIPilot.order_from_original: GUARD
const GROUP_BASE := 9000
const DROP_LIFT := 1.0

var director: GameModeDirector
var _records := {}                    # net id -> mode object dict


func _init(p_director: GameModeDirector) -> void:
	director = p_director
	name = "Defenders"


## Host: drops every defender of the mode's objects.
func spawn_all() -> void:
	var k := 0
	for d in GameModes.make_mode_objects(director.mode_id, director.map_data):
		if str(d.get("kind", "")) != ModeObject.KIND_DEFENDER or Packs.vehicle(str(d.get("vehicle", ""))).is_empty():
			continue
		var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(float(d.get("yaw", 0.0)))), _on_ground(d.get("pos", [0, 0, 0])))
		var h := director.battle.spawn_ai(str(d.vehicle), int(d.team), xf, [], str(d.get("name", "Defender")),
			{"skill": SKILL, "group": GROUP_BASE + k, "order": GUARD_ORDER})
		k += 1
		if h == null:
			continue
		h.set_meta(GameModes.RESPAWNED_BY_MODE_META, true)
		h.set_meta(GameModeBrains.DEFENDER_META, true)
		_records[h.net_id] = d
		h.destroyed.connect(_on_destroyed)


func _on_destroyed(h: Herc, _killer: Node) -> void:
	var d: Dictionary = _records.get(h.net_id, {})
	if d.is_empty():
		return
	var delay := float(director.rules.settings.get("ai_respawn_s", 60.0))
	if is_hq_destroyed(int(d.team)):
		delay = float(director.rules.settings.get("ai_respawn_no_hq_s", delay))
	get_tree().create_timer(delay).timeout.connect(func() -> void: _redrop(h, d))


func _redrop(h: Herc, d: Dictionary) -> void:
	if not is_instance_valid(h) or director.rules.over or director.battle.is_over():
		return
	h.respawn(Transform3D(Basis(), _on_ground(d.get("respawn_pos", d.get("pos")))))


## True when `team`'s HQ structure (WAR: <colour>HQ) is destroyed.
func is_hq_destroyed(team: int) -> bool:
	for o in director.rules.objects.values():
		if o.team == team and o.name.to_lower().ends_with("hq") and o.state == ModeObject.DESTROYED:
			return true
	return false


func _on_ground(p: Array) -> Vector3:
	var at := Vector3(float(p[0]), float(p[1]), float(p[2]))
	at.y = MapBuilder.ground_height(director.battle, at) + DROP_LIFT
	return at
