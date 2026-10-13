class_name BattleFx
extends RefCounted
## Plays one battle effect on this peer. Battle.fx() runs it locally and, on the host, on every client;
## `args` per kind:
##   beam [from, to, color, fire sound, weapon_id?, surface?, hit sound?]   (surface "" = the beam hit nothing;
##        weapon_id names the weapon whose fx data draws beam, muzzle and impact: FxPlayer, weapon_fx.md)
##   spark [at, size, sound]   projectile [from, dir, weapon_id, target, shooter]
##   message [text, seconds?]        radio [speaker, text, voice?] (Battle.radio)        turret_down [node path]   structure_down [structure index]
##   nav_index [index]   (the host's mission reached a nav point: every peer's compass and objectives follow)
##   objectives [lines]  (the host's mission objectives, [{text, done}]: every client's ObjectivesPanel shows them)

const DEFAULT_MESSAGE_SECONDS := 4.0
const SPARK_VOLUME_DB := -4.0
const BEAM_SPARK_SIZE := 0.8

var battle: Battle


func _init(p_battle: Battle) -> void:
	battle = p_battle


func play(kind: String, a: Array) -> void:
	match kind:
		"beam":
			_play_beam(a)
		"spark":
			Effects.spark(battle, a[0], a[1])
			Sfx.play_at(a[2], a[0], SPARK_VOLUME_DB)
		"projectile":
			_play_projectile(a)
		"message":
			battle.overlay.show_message(a[0], a[1] if a.size() > 1 else DEFAULT_MESSAGE_SECONDS)
		"radio":
			_play_radio(a)
		"turret_down":
			_play_turret_down(a)
		"structure_down":
			_play_structure_down(a)
		"nav_index":
			_play_nav_index(a)
		"objectives":
			if not _is_host() and battle.overlay.objectives != null:
				battle.overlay.objectives.apply_host_lines(a[0])


func _is_host() -> bool:
	return battle.multiplayer.is_server()


func _play_beam(a: Array) -> void:
	var wdef := Packs.weapon(String(a[4])) if a.size() > 4 else {}
	if wdef.is_empty():
		Effects.beam(battle, a[0], a[1], a[2])
	else:
		Effects.fx.play_beam(battle, wdef, a[0], a[1])
		Effects.fx.play_muzzle(battle, wdef, a[0], (a[1] - a[0]).normalized())
	if not _is_host():
		Sfx.play_at(a[3], a[0])
	if a.size() > 6 and String(a[5]) != "":
		_play_beam_impact(wdef, a[1], String(a[5]), a[6], (a[0] - a[1]).normalized())


func _play_beam_impact(wdef: Dictionary, at: Vector3, surface: String, hit_sound: String, normal: Vector3) -> void:
	var has_sound := false
	if wdef.is_empty():
		Effects.spark(battle, at, BEAM_SPARK_SIZE)
	else:
		has_sound = Effects.fx.play_impact(battle, wdef, surface, at, normal)
	if not has_sound:
		Sfx.play_at(hit_sound, at, SPARK_VOLUME_DB)


## Every peer: the muzzle flash; clients also a visual copy of a host projectile (the host's own
## projectile does the damage).
func _play_projectile(a: Array) -> void:
	var wdef := Packs.weapon(String(a[2]))
	if wdef.is_empty():
		return
	Effects.fx.play_muzzle(battle, wdef, a[0], a[1])
	if _is_host():
		return
	var p := Weapon.make_projectile(wdef, null, a[0], a[1], battle.vehicles.get(int(a[3])), true)
	battle.add_child(p)
	p.global_position = a[0]
	var shooter: Herc = battle.vehicles.get(int(a[4])) if a.size() > 4 else null
	if shooter:
		shooter.missile_steering.adopt(p, Weapon.make_fire_group(wdef))   # the missile cam and steering on clients
	Sfx.play_at(wdef.get("sounds", {}).get("fire", wdef.name), a[0])


func _play_turret_down(a: Array) -> void:
	var t := battle.get_node_or_null(a[0])
	if t and not _is_host() and t.has_method("apply_destroyed"):
		t.apply_destroyed()


func _play_structure_down(a: Array) -> void:
	var mission := battle.mission
	if mission and not _is_host() and int(a[0]) < mission.structures.size():
		mission.structures[int(a[0])].destroy()


func _play_nav_index(a: Array) -> void:
	var mission := battle.mission
	if mission and not _is_host() and "nav_index" in mission:
		mission.nav_index = int(a[0])


func _play_radio(a: Array) -> void:
	if battle.chat == null:
		push_warning("BattleFx: radio line before the chat exists: %s" % str(a[1]))
		return
	battle.chat.radio.say(str(a[0]), str(a[1]), str(a[2]) if a.size() > 2 else "")
