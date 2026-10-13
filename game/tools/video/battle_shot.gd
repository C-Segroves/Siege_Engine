class_name BattleShot
extends Node
## Trailer shot in a real Battle: the player's Herc either fights by itself (an AIPilot in place of
## the PlayerPilot) or flies a script of SiegeInput actions; the enemies are staged in front of it
## so the action starts at once, and the view is the original cockpit or a cinematic chase camera.
## Parameters: see VideoShots.

const BATTLE_SCENE := preload("res://games/es1/battle.tscn")
const SPAWN_FRAMES := 10
const PLAYER_TOUGHNESS := 6.0       # the star of the shot should not die mid-shot
const AI_PLAYER_SKILL := 1.0
const AI_PLAYER_RANGE := 90.0       # metres; the player's AI closes in for the camera
const GROUND_PROBE := 400.0         # metres above / below for the staging ray
const STAGE_DROP := 1.0             # metres above the ground a staged Herc starts
## The trailer lays one soundtrack over all its shots, so the battle music stays silent.
const MUTED_MUSIC_DB := -80.0

var spec: Dictionary
var battle: Battle
var _rig: CinematicChaseRig
var _inputs: ScriptedInputs
var _playing := false
var _clock := 0.0     # seconds since play()


func _ready() -> void:
	process_priority = VideoShots.DIRECTOR_PRIORITY


func prepare() -> void:
	Sfx.music_volume_db = MUTED_MUSIC_DB
	battle = BATTLE_SCENE.instantiate() as Battle
	battle.config = _make_config()
	add_child(battle)
	for i in SPAWN_FRAMES:
		await get_tree().physics_frame
	if battle.player == null:
		push_error("battle_shot: no player vehicle for %s" % spec.get("herc"))
		return
	_apply_toughness(battle.player, PLAYER_TOUGHNESS)
	_stage_vehicles()
	_apply_view()
	if spec.get("pilot") == "inputs":
		_inputs = ScriptedInputs.new(spec.get("inputs", []), spec.get("taps", []))
	await get_tree().create_timer(float(spec.get("settle", 1.0))).timeout


func play() -> void:
	_playing = true
	if _inputs:
		_inputs.start()
	else:
		_hand_player_to_ai()


func _process(delta: float) -> void:
	if battle == null or battle.overlay == null:
		return
	_clear_messages()
	if _playing:
		_clock += delta
	if _rig and is_rig_live(_clock):
		_rig.update(delta)
	elif _rig:
		_rig.restart()


## Whether the cinematic rig drives the chase camera at `t` s into the action (always, unless the
## spec limits it to rig_windows).
func is_rig_live(t: float) -> bool:
	if not spec.has("rig_windows"):
		return true
	return (spec.rig_windows as Array).any(func(w: Array) -> bool: return t >= float(w[0]) and t < float(w[1]))


func _physics_process(delta: float) -> void:
	if _inputs:
		_inputs.update(delta)


# ------------------------------------------------------------------ config

func _make_config() -> Dictionary:
	var config := BattleSetup.make_default_config(Assets.qualify(String(spec.herc)))
	config.merge(spec.get("config", {}), true)
	config.ai = (spec.get("ai", []) as Array).duplicate(true)
	return config


# ------------------------------------------------------------------ control

## The player's Herc fights by itself from now on (an AIPilot replaces the PlayerPilot).
func _hand_player_to_ai() -> void:
	battle.pilot.queue_free()
	var p := AIPilot.new()
	p.herc = battle.player
	p.skill = AI_PLAYER_SKILL
	p.order = AIPilot.Order.SEARCH
	p.preferred_range = AI_PLAYER_RANGE
	battle.player.add_child(p)


## Multiplies every component's hit points (and the shields) by `factor`.
static func _apply_toughness(h: Herc, factor: float) -> void:
	for c in h.components:
		c.hp *= factor
		c.max *= factor
	h.shield_front *= factor
	h.shield_rear *= factor
	h.shield_max *= factor


## Leaves the enemy `health` (0..1) of the armour it can lose before it falls, and no shields,
## for a short fight.
static func _apply_weakness(h: Herc, health: float) -> void:
	var share := lerpf(HercDamage.DEATH_INTEGRITY, 1.0, health)
	for c in h.components:
		c.hp *= share
	h.integrity = HercDamage.integrity_of(h.components)
	h.shield_front = 0.0
	h.shield_rear = 0.0


# ------------------------------------------------------------------ staging

func _stage_vehicles() -> void:
	var p := battle.player
	var enemies := []
	var allies := []
	for v in battle.vehicles.values():
		if v == p or v is Flyer:
			continue
		(allies if v.team == p.team else enemies).append(v)
	_stage(enemies, spec.get("stage", []))
	_stage(allies, spec.get("stage_allies", []))
	var health: Array = spec.get("enemy_health", [])
	for i in mini(enemies.size(), health.size()):
		_apply_weakness(enemies[i], float(health[i]))


## Puts vehicles[i] at offset i ([ahead, right] metres from the player), facing the player.
func _stage(vehicles: Array, offsets: Array) -> void:
	var p := battle.player
	var fwd := -p.global_basis.z
	var right := p.global_basis.x
	for i in mini(vehicles.size(), offsets.size()):
		var h: Herc = vehicles[i]
		var at: Vector3 = p.global_position + fwd * float(offsets[i][0]) + right * float(offsets[i][1])
		at.y = _make_ground_height(at) + STAGE_DROP
		h.global_position = at
		h.velocity = Vector3.ZERO
		var look := Vector3(p.global_position.x, at.y, p.global_position.z)
		if at.distance_to(look) > 1.0:
			h.look_at(look, Vector3.UP)


## Ground under `at`: a ray down through the scene (buildings included), else the height field.
func _make_ground_height(at: Vector3) -> float:
	var space := battle.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * GROUND_PROBE, at - Vector3.UP * GROUND_PROBE)
	q.exclude = battle.vehicles.values().map(func(v): return v.get_rid())
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		return (hit.position as Vector3).y
	return MapTerrain.ground_height(battle, at)


# ------------------------------------------------------------------ view

## "game" keeps the game's own cameras, HUD and cockpit (the script switches views with view_toggle);
## "chase" / "cockpit" fix the view for the whole shot. rig_windows [[from s, to s], ...]: in the
## "game" view the cinematic rig frames the vehicle's chase view then, the game's camera otherwise.
func _apply_view() -> void:
	if spec.get("view") == "game":
		if spec.has("rig_windows"):
			_rig = CinematicChaseRig.new(battle.cameras.chase_cam, battle.player, spec.get("chase", {}))
		return
	var chase: bool = spec.get("view") == "chase"
	battle.use_chase = chase
	battle.overlay.hud.visible = false
	battle.overlay.visible = not chase
	if chase:
		_rig = CinematicChaseRig.new(battle.cameras.chase_cam, battle.player, spec.get("chase", {}))


func _clear_messages() -> void:
	battle.overlay.hud.messages.clear()
	if battle.overlay.cockpit:
		battle.overlay.cockpit.messages.clear()
