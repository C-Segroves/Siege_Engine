extends Node
## Leg animation on the real play paths (engine/herc_animator.gd), with frame strips for the eye:
##   a. versus match (MatchFlow.make_match_config) - the player's non-Earthsiege-1 Herc in the chase view,
##      walking on the throttle;
##   b. skirmish - AI Hercs of every pack, filmed by a side camera;
##   c. campaign mission (Session.mission_config, garage Herc instead of the mission Herc);
##   d. LAN puppet - a Herc fed server snapshots animates like the server's.
## Each check asserts that the legs move (leg node transforms change) while the Herc walks.
## Needs a renderer:  godot --audio-driver Dummy --path game res://tests/anim_battle_shots.tscn -- --out=<dir>

const FRAMES := 6
const FRAME_SIZE := Vector2i(320, 180)
const SETTLE_SECONDS := 1.5
const WALK_SECONDS := 2.5
const MIN_LEG_MOTION := 0.05
const MIN_MOVING_SPEED := 0.5
const PLAYER_HERCS := ["bd:THOR", "es2:OUTLAW", "starsiege:tr_talo"]
const AI_HERCS := ["starsiege:kn_basl", "bd:STRYDER", "es2:PITBULL", "starsiege:cy_adju"]
const CAMPAIGN_HERC := "starsiege:tr_apoc"
const SIDE_CAMERA_DISTANCE := 22.0
## Chase strips: crop (fraction of the screen) around the player's Herc.
const CHASE_CROP := Vector2(0.28, 0.28)
const CHASE_CROP_TOP := 0.42

var _out := "user://anim"
var _failures := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	for vid in PLAYER_HERCS:
		await _check_versus_player(vid)
	await _check_skirmish_ai()
	await _check_campaign()
	await _check_puppet()
	print("anim_battle_shots: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


# ------------------------------------------------------------------ a. versus, chase view

func _check_versus_player(vid: String) -> void:
	var settings := {"mode": "vs", "teams": false, "frag_limit": 10, "ai": 0, "balance": "original", "world_idx": 0}
	var cfg := MatchFlow.make_match_config(settings, Packs.pilotable())
	cfg["roster"] = {1: {"name": "Player", "vehicle": vid, "team": 0, "loadout": []}}
	cfg["ai"] = []
	var battle := await _start(cfg)
	battle.use_chase = true
	Input.action_press("throttle_up")
	var motion := await _film(battle.player, null, "anim_path_vs_%s.png" % vid.replace(":", "_"))
	Input.action_release("throttle_up")
	_expect(motion.speed > MIN_MOVING_SPEED and motion.legs > MIN_LEG_MOTION,
		"versus chase view %s walks %.1f m/s, legs move %.2f m" % [vid, motion.speed, motion.legs])
	await _end(battle)


# ------------------------------------------------------------------ b. skirmish AI

func _check_skirmish_ai() -> void:
	var cfg := BattleSetup.make_default_config("es1:RAPTOR")
	cfg["ai"] = []
	for vid in AI_HERCS:
		cfg.ai.append({"vehicle": vid, "team": 1, "skill": 0.5})
	var battle := await _start(cfg)
	battle.player.set_physics_process(false)   # a sitting target the AI walks towards
	battle.set_process(false)                  # keep the side camera current
	battle.overlay.visible = false
	var cam := Camera3D.new()
	battle.add_child(cam)
	var ai := battle.get_children().filter(func(n): return n is Herc and n != battle.player and str(n.vehicle_id) in AI_HERCS)
	for n in ai:
		if is_instance_valid(n):
			var motion := await _film(n, cam, "anim_path_ai_%s.png" % str(n.vehicle_id).replace(":", "_"))
			_expect(motion.speed > MIN_MOVING_SPEED and motion.legs > MIN_LEG_MOTION,
				"skirmish AI %s walks %.1f m/s, legs move %.2f m" % [n.vehicle_id, motion.speed, motion.legs])
	await _end(battle)


# ------------------------------------------------------------------ c. campaign mission

func _check_campaign() -> void:
	Session.start_campaign(0, true)
	var cfg := Session.mission_config({1: {"name": "Player", "vehicle": CAMPAIGN_HERC, "team": 0, "loadout": []}})
	cfg["use_mission_herc"] = false
	var battle := await _start(cfg)
	_expect(battle.player != null and str(battle.player.vehicle_id) == CAMPAIGN_HERC,
		"campaign mission flies the garage Herc %s" % CAMPAIGN_HERC)
	if battle.player:
		battle.use_chase = true
		Input.action_press("throttle_up")
		var motion := await _film(battle.player, null, "anim_path_campaign_%s.png" % CAMPAIGN_HERC.replace(":", "_"))
		Input.action_release("throttle_up")
		_expect(motion.speed > MIN_MOVING_SPEED and motion.legs > MIN_LEG_MOTION,
			"campaign %s walks %.1f m/s, legs move %.2f m" % [CAMPAIGN_HERC, motion.speed, motion.legs])
	await _end(battle)


# ------------------------------------------------------------------ d. LAN puppet

## A puppet Herc gets position/speed from snapshots only (Herc._puppet_update) and must walk too.
func _check_puppet() -> void:
	var cfg := BattleSetup.make_default_config("es1:RAPTOR")
	cfg["ai"] = []
	var battle := await _start(cfg)
	var xf: Transform3D = battle.player.global_transform.translated(Vector3(15, 0, 0))
	var puppet: Herc = battle.spawn_ai("bd:THOR", 1, xf, [], "Puppet", {"skill": 0.0})
	for c in puppet.get_children():
		if c is AIPilot:
			c.queue_free()
	puppet.is_puppet = true
	var start := _leg_pose(puppet)
	var pos := puppet.global_position
	var dt := 0.1
	for i in int(WALK_SECONDS / dt):
		pos += -puppet.global_basis.z * 6.0 * dt
		puppet.apply_snapshot([puppet.net_id, pos, puppet.rotation.y, 0.0, 0.0, 6.0, true, 0, 0, 1.0, 0, 0, 0], dt)
		await get_tree().create_timer(dt).timeout
	_expect(_leg_motion(puppet, start) > MIN_LEG_MOTION, "LAN puppet bd:THOR animates its legs from snapshots")
	await _end(battle)


# ------------------------------------------------------------------ helpers

func _start(cfg: Dictionary) -> Battle:
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = cfg
	await get_tree().process_frame
	get_tree().root.add_child(battle)
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	return battle


func _end(battle: Battle) -> void:
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


## Films `h` for WALK_SECONDS (battle camera, or `side_cam` from the side) into a FRAMES strip;
## returns {speed: mean ground speed m/s, legs: largest leg node change in model space}.
func _film(h: Herc, side_cam: Camera3D, file: String) -> Dictionary:
	var strip := Image.create(FRAME_SIZE.x * FRAMES, FRAME_SIZE.y, false, Image.FORMAT_RGBA8)
	var start := _leg_pose(h)
	var from := h.global_position
	var legs := 0.0
	for f in FRAMES:
		await get_tree().create_timer(WALK_SECONDS / FRAMES).timeout
		if side_cam:
			_aim_side_camera(side_cam, h)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		if side_cam == null:
			img = img.get_region(_chase_crop(img.get_size()))
		img.resize(FRAME_SIZE.x, FRAME_SIZE.y)
		strip.blit_rect(img, Rect2i(Vector2i.ZERO, FRAME_SIZE), Vector2i(FRAME_SIZE.x * f, 0))
		legs = maxf(legs, _leg_motion(h, start))
	strip.save_png(_out.path_join(file))
	var flat := Vector2(h.global_position.x - from.x, h.global_position.z - from.z)
	return {"speed": flat.length() / WALK_SECONDS, "legs": legs}


## The chase view's middle, where the player's Herc stands (legs large enough to see).
func _chase_crop(size: Vector2i) -> Rect2i:
	var crop := Vector2i(int(size.x * CHASE_CROP.x), int(size.y * CHASE_CROP.y))
	return Rect2i(Vector2i((size.x - crop.x) / 2, int(size.y * CHASE_CROP_TOP)), crop)


func _aim_side_camera(cam: Camera3D, h: Herc) -> void:
	var side := h.global_basis.x.normalized()
	var height := maxf(float(h.def.get("height_m", 8.0)), 3.0)
	cam.global_position = h.global_position + side * SIDE_CAMERA_DISTANCE + Vector3.UP * height * 0.5
	cam.look_at(h.global_position + Vector3.UP * height * 0.45)
	cam.make_current()


func _leg_pose(h: Herc) -> Array:
	var out := []
	for n in h.shape.nodes:
		out.append(n.transform)
	return out


## Largest change of a leg node (torso and cockpit nodes excluded: the aim turns them).
func _leg_motion(h: Herc, start: Array) -> float:
	var most := 0.0
	for i in mini(start.size(), h.shape.nodes.size()):
		if i == h._torso_index() or i == h._cockpit_index():
			continue
		var a: Transform3D = start[i]
		var b: Transform3D = h.shape.nodes[i].transform
		most = maxf(most, a.origin.distance_to(b.origin) * h.shape.scale.x + (a.basis.z - b.basis.z).length())
	return most
