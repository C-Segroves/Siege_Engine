extends Node
## Riders in vehicles (docs/formats/tribes_vehicles.md section 6, "Riders on their seats"): every seat of every
## Tribes 1 / Tribes 2 vehicle gets a soldier, taken aboard through the occupancy state message every peer runs
## (OccupancyDirector._apply_state), and must
##   1. show on its seat node (T1 visibleDriver, T2 mounted players), in the seat's pose sequence;
##   2. hold its weapon only where the original keeps it (not the pilot, not the gunner);
##   3. follow the seat when the vehicle moves and turns, also as a network puppet (clients);
##   4. stay out of targeting, carry their own name plates (not the vehicle), and come back upright on foot;
##   5. a Herc pilot stays hidden (the Herc games never draw one).
##   godot --headless --audio-driver Dummy --path game res://tests/vehicle_riders_check.tscn
##   [-- --shots=<dir>]   (windowed run: one render per vehicle with every seat taken, saved as riders_<id>.png)

const VEHICLES := ["tribes:SCOUT", "tribes:LAPC", "tribes:HAPC", "tribes2:SHRIKE", "tribes2:THUNDERSWORD",
	"tribes2:HAVOC", "tribes2:BEOWULF", "tribes2:WILDCAT", "tribes2:JERICHO"]
const HERC := "es1:RAPTOR"
const ARMOR := {"tribes": "tribes:LIGHT", "tribes2": "tribes2:LIGHT"}
## Fake peers of the riders (never the local peer 1: no control or camera change).
const FIRST_PEER := 1001
const SITE := Vector3(-400, 0, 300)
const SETTLE_FRAMES := 10
const ON_SEAT := 0.05
const MOVE := Vector3(30.0, 0.0, 12.0)
const TURN := 1.1
const SHOT_DISTANCE := 0.75
const SHOT_SIZE := Vector2i(960, 600)
## Camera directions (vehicle frame, times the vehicle's size): front-left quarter, and from above behind.
const SHOT_SIDES := {"front": Vector3(-0.8, 0.5, -1.0), "above": Vector3(0.3, 1.2, 0.7),
	"pilot": Vector3(-0.6, 0.5, -0.8)}
## The pilot close-up: this far (m) from his seat node, aimed this high above it.
const PILOT_SHOT_DISTANCE := 3.5
const PILOT_SHOT_RISE := 0.8

var _failures := 0
var _shots := ""
var _battle: Battle
var _next_peer := FIRST_PEER


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	if Packs.vehicle("tribes2:SHRIKE").is_empty() or Packs.vehicle("tribes:SCOUT").is_empty():
		_expect(false, "Tribes packs with vehicles installed")
		_finish()
		return
	_battle = await _start_battle()
	for vid in VEHICLES:
		await _check_vehicle(vid)
	await _check_herc_pilot_hidden()
	await _check_own_body_hidden_inside()
	_finish()


func _finish() -> void:
	print("vehicle_riders_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


# ------------------------------------------------------------------ one vehicle

func _check_vehicle(vid: String) -> void:
	print("%s:" % vid)
	var v := _spawn_vehicle(vid, SITE)
	var seats := InfantryGear.seats_of(vid)
	var riders: Array[Infantry] = []
	for i in seats.size():
		riders.append(_board(v, i, ARMOR[vid.get_slice(":", 0)]))
	await _frames(SETTLE_FRAMES)
	for r in riders:
		_check_rider(v, r)
	if _shots != "":
		await _save_shot(v, vid)
	v.global_transform = Transform3D(Basis(Vector3.UP, TURN), v.global_position + MOVE)
	await _frames(2)
	_expect(riders.all(func(r): return _seat_distance(r) < ON_SEAT), "riders follow their seats when the vehicle moves and turns")
	var puppet := riders[0]
	puppet.is_puppet = true
	v.global_transform = Transform3D(Basis(Vector3.UP, -TURN), v.global_position - MOVE)
	await _frames(2)
	_expect(_seat_distance(puppet) < ON_SEAT and puppet.visible, "a puppet rider (a client's view) sits on his seat too")
	puppet.is_puppet = false
	var in_group := get_tree().get_nodes_in_group("vehicles")
	_expect(riders.all(func(r): return not in_group.has(r)), "riders are out of the vehicles group (no targeting)")
	var named := Nameplates.make_teammates(_battle.player)
	_expect(riders.all(func(r): return named.has(r)) and not named.has(v),
		"a teammate sees each rider's name plate on his seat, none for the vehicle")
	_leave(v, riders[0])
	await _frames(2)
	var out := riders[0]
	_expect(not out.stowed and out.visible and is_zero_approx(out.rotation.x) and is_zero_approx(out.rotation.z)
		and out.held.world_shown, "the pilot gets out upright, visible, weapon in hand (stowed %s visible %s tilt %.2f / %.2f weapon %s)" % [
		out.stowed, out.visible, out.rotation.x, out.rotation.z, out.held.world_shown])
	for r in riders:
		r.queue_free()
	v.queue_free()
	await _frames(2)


func _check_rider(v: Herc, r: Infantry) -> void:
	var s := r.seat
	var tag := "seat %d (%s)" % [s.seat, s.role]
	_expect(s.shown and r.visible, "%s shows" % tag)
	_expect(_seat_distance(r) < ON_SEAT, "%s sits on its node %s (%.3f m)" % [tag, s.node.name if s.node else "?", _seat_distance(r)])
	var wanted := s.pose.map(func(n): return str(n).to_lower())
	_expect(wanted.has(r.make_pose_name().to_lower()), "%s pose %s (wanted %s)" % [tag, r.make_pose_name(), wanted])
	var held_shown := r.held.world_model != null and r.held.world_model.is_visible_in_tree()
	_expect(held_shown == s.weapon_shown or r.held.world_model == null,
		"%s weapon %s" % [tag, "in hand" if s.weapon_shown else "put away"])


func _check_herc_pilot_hidden() -> void:
	print("%s (Herc games draw no pilot):" % HERC)
	var v := _spawn_vehicle(HERC, SITE)
	var r := _board(v, VehicleOccupancy.PILOT_SEAT, ARMOR.tribes2)
	await _frames(SETTLE_FRAMES)
	_expect(not r.visible and not r.seat.shown, "the Herc's pilot is hidden")
	r.queue_free()
	v.queue_free()


## The local player piloting a Shrike: his seated body is on his own layer, which the cockpit camera leaves out and
## the chase camera draws.
func _check_own_body_hidden_inside() -> void:
	print("tribes2:SHRIKE, the local player piloting:")
	var v := _spawn_vehicle("tribes2:SHRIKE", SITE)
	var r := _board(v, VehicleOccupancy.PILOT_SEAT, ARMOR.tribes2, multiplayer.get_unique_id())
	await _frames(SETTLE_FRAMES)
	var meshes := r.shape.find_children("*", "MeshInstance3D", true, false)
	_expect(r.visible and meshes.all(func(m): return (m as MeshInstance3D).layers == BattleCameras.OWN_VEHICLE_LAYER),
		"his body is on the own-view layer")
	var cams := _battle.cameras
	_expect(cams.cockpit_cam != null and cams.cockpit_cam.cull_mask & BattleCameras.OWN_VEHICLE_LAYER == 0
		and cams.chase_cam.cull_mask & BattleCameras.OWN_VEHICLE_LAYER != 0,
		"the cockpit camera leaves it out, the chase camera draws it")


# ------------------------------------------------------------------ helpers

func _start_battle() -> Battle:
	var config := BattleSetup.make_default_config(HERC)
	config.ai = []
	config["infantry_pack"] = "tribes2"
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	await get_tree().process_frame
	get_tree().root.add_child(battle)
	await _frames(SETTLE_FRAMES)
	return battle


func _spawn_vehicle(vid: String, at: Vector3) -> Herc:
	var id := _battle.spawner.allocate_id()
	at.y = MapBuilder.ground_height(_battle, at)
	_battle.send_spawn({"net_id": id, "vehicle": vid, "team": 0, "owner": 0, "xf": Transform3D(Basis(), at),
		"loadout": [], "name": vid, "ai": {}, "parked": true})
	return _battle.vehicles.get(id)


## A soldier in `armor` for a new fake peer, put in seat `seat` by the state message every peer applies.
func _board(v: Herc, seat: int, armor: String, peer := 0) -> Infantry:
	if peer == 0:
		peer = _next_peer
		_next_peer += 1
	var spec := _battle.infantry.make_soldier_spec(peer, 0, "Rider %d" % seat, v.global_transform)
	spec.merge({"vehicle": armor, "armor": armor, "spawn_armor": armor,
		"loadout": InfantryCatalog.armor(armor).get("default_loadout", [])}, true)
	_battle.send_spawn(spec)
	var s := _battle.vehicles.get(spec.net_id) as Infantry
	var occ := VehicleOccupancy.of(v)
	occ.apply_seat(seat, peer)
	_battle.occupancy._apply_state(v.net_id, occ.seats.duplicate(), s.net_id, true, s.global_transform, peer)
	return s


## The host's exit (OccupancyDirector.apply_exit: out beside the hull, no remount by touch for a while).
func _leave(v: Herc, s: Infantry) -> void:
	_battle.occupancy.apply_exit(VehicleOccupancy.of(v).seats[s.seat.seat] as int, v)


static func _seat_distance(r: Infantry) -> float:
	if r.seat == null or not is_instance_valid(r.seat.node):
		return INF
	return r.global_position.distance_to(r.seat.node.global_position)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
		await get_tree().physics_frame


## Windowed: the vehicle with every seat taken, seen from the front-left quarter and a little above, through a
## viewport of its own on the battle's world (no HUD, the player's camera untouched).
func _save_shot(v: Herc, vid: String) -> void:
	var length := float(v.def.get("length_m", 0.0))
	var size := v.make_body_size()   # x = radius, y = height
	var reach := maxf(maxf(length, size.x * 2.0), size.y) * SHOT_DISTANCE
	var view := SubViewport.new()
	view.size = SHOT_SIZE
	view.world_3d = get_viewport().world_3d
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(view)
	var cam := Camera3D.new()
	view.add_child(cam)
	var centre := v.global_position + Vector3.UP * size.y * 0.4
	var pilot := InfantrySeat.find_node(v, VehicleSeats.make_node_name(v.vehicle_id, VehicleOccupancy.PILOT_SEAT))
	for side in SHOT_SIDES:
		var at := centre
		var dist := reach
		if side == "pilot" and pilot != null:
			at = pilot.global_position + Vector3.UP * PILOT_SHOT_RISE
			dist = PILOT_SHOT_DISTANCE
		cam.look_at_from_position(at + v.global_basis * (SHOT_SIDES[side] * dist), at)
		cam.current = true
		await _frames(3)
		await RenderingServer.frame_post_draw
		var path := _shots.path_join("riders_%s_%s.png" % [vid.replace(":", "_").to_lower(), side])
		view.get_texture().get_image().save_png(path)
		print("    render %s" % path)
	view.queue_free()
