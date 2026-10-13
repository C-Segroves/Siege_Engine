extends Node3D
## Target damage readout for every game (docs/formats/cockpit.md section 4, engine/target_view/):
##   1. an Earthsiege target in the Earthsiege cockpit keeps its original 2D damage diagram, recoloured
##      by the original's 5 damage levels;
##   2. Battledrome, Earthsiege 2, Starsiege and Tribes targets render their 3D model in the same spot
##      (a non-empty picture), and their parts change damage level when a component is damaged / destroyed;
##   3. LAN: a puppet's damage and weapon triggers follow the host's snapshots (BattleNetSync,
##      HercSnapshots), and the damage block is only resent around changes;
##   4. the plain HUD (a flyer) shows its target's model too.
## Needs a window (rendering); --shots=<dir> also saves the cockpit / HUD screenshots:
##   godot --audio-driver Dummy --path game res://tests/target_view_check.tscn [-- --shots=<dir>]

const HOST := "es1:RAPTOR"
const NATIVE_TARGET := "es1:APOLLO"
const FOREIGN_TARGETS := ["bd:STRYDER", "es2:OUTLAW", "starsiege:cy_exec", "tribes:LAPC"]
const SHOT_TARGETS := ["es1:APOLLO", "bd:STRYDER", "es2:OUTLAW", "starsiege:cy_exec"]
const HUD_FLYER := "tribes2:SHRIKE"
const HUD_TARGET := "starsiege:cy_exec"
## A rendered target must cover at least this share of its picture.
const MIN_COVERAGE := 0.08
const HALF_HEALTH := 0.5
const SETTLE_FRAMES := 4
## 3Space DMG components of the left leg (quad, shin, foot; gameplay.md section 5): Cybrid records
## carry no component names.
const THREE_SPACE_LEFT_LEG := [7, 9, 11]

var _failures := 0
var _shots_dir := ""
var _layer: CanvasLayer


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots_dir = a.substr(8)
	_layer = CanvasLayer.new()
	add_child(_layer)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 5, 20)
	add_child(cam)
	cam.current = true
	await _run(cam)
	print("target_view_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _run(cam: Camera3D) -> void:
	var host := _spawn(HOST, Vector3.ZERO, false)
	var cockpit := CockpitDisplay.create(host, self)
	_expect(cockpit != null, "Earthsiege host has its cockpit")
	if cockpit == null:
		return
	_layer.add_child(cockpit)
	cockpit.set_camera(cam)
	cockpit.mfd_mode = CockpitMfd.MODE_TARGET
	_check_levels()
	_check_native(cockpit)
	for id in FOREIGN_TARGETS:
		await _check_foreign(cockpit, host, id)
	await _check_puppet(cockpit)
	if _shots_dir != "":
		await _save_cockpit_shots(cockpit, host)
	cockpit.queue_free()
	await _check_hud(cam)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _spawn(id: String, at: Vector3, flyer: bool) -> Herc:
	var h: Herc = Flyer.new() if flyer else Herc.new()
	h.vehicle_id = id
	h.position = at
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw


# ------------------------------------------------------------------ levels and native art

## The original's thresholds (DBSIM 0x30dc4): >= 90 % green, >= 74 % yellow, >= 51 % orange, >= 1 % red.
func _check_levels() -> void:
	_expect(DamageLevels.level_of(1.0) == DamageLevels.INTACT, "full health is intact")
	_expect(DamageLevels.level_of(0.8) == DamageLevels.LIGHT, "80 % is light damage")
	_expect(DamageLevels.level_of(0.6) == DamageLevels.MEDIUM, "60 % is medium damage")
	_expect(DamageLevels.level_of(0.2) == DamageLevels.HEAVY, "20 % is heavy damage")
	_expect(DamageLevels.level_of(0.0) == DamageLevels.DESTROYED, "0 % is destroyed")


func _check_native(cockpit: CockpitDisplay) -> void:
	var t := _spawn(NATIVE_TARGET, Vector3(0, 0, -30), false)
	var img := cockpit.target_image
	_expect(img.has_diagram(t) and not img.is_rendered(t), "%s keeps its original 2D diagram" % NATIVE_TARGET)
	img.follow(t, 1.0)
	_expect(not img.view.has_target(), "no 3D render for a native target")
	var key := CockpitPainter.make_unit_key(t)
	var intact := img.canvas.assets.diagram(key, CockpitTargetImage.SMALL_DIAGRAM, t).get_image()
	t.components[0].hp = 0.0
	t.components[1].hp = 0.0
	var wrecked := img.canvas.assets.diagram(key, CockpitTargetImage.SMALL_DIAGRAM, t).get_image()
	var before := 0
	var after := 0
	for k in DamageLevels.SHADES:
		var dark := DisplaySettings.make_corrected(img.canvas.assets.raw_color(DamageLevels.RAMP_BASES[DamageLevels.DESTROYED] + k), img.canvas.assets.gamma)
		before += _count_color(intact, dark)
		after += _count_color(wrecked, dark)
	_expect(after > before, "destroyed cockpit region turns the original dark ramp (%d -> %d px)" % [before, after])
	t.queue_free()


static func _count_color(img: Image, c: Color) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a > 0.0 and p.to_rgba32() == Color(c, 1.0).to_rgba32():
				n += 1
	return n


# ------------------------------------------------------------------ foreign targets

func _check_foreign(cockpit: CockpitDisplay, host: Herc, id: String) -> void:
	var t := _spawn(id, Vector3(0, 0, -30), false)
	host.target = t
	var img := cockpit.target_image
	_expect(img.is_rendered(t), "%s is drawn as a 3D model" % id)
	img.follow(t, 1.0)
	_expect(img.view.has_target(), "%s: target view follows it" % id)
	await _settle()
	var coverage := _coverage(img.view.get_texture().get_image())
	_expect(coverage >= MIN_COVERAGE, "%s renders in the picture area (%.0f %% covered)" % [id, coverage * 100.0])
	_check_tint(img.view, t, id)
	host.target = null
	img.follow(null, 1.0)
	t.queue_free()


static func _coverage(img: Image) -> float:
	if img == null or img.is_empty():
		return 0.0
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.5:
				n += 1
	return float(n) / float(img.get_width() * img.get_height())


## Damaging, then destroying the root component changes the level of the parts it covers.
func _check_tint(view: TargetView, t: Herc, id: String) -> void:
	var root := TargetDamageMap.root_component(t.def.get("damage", {}).get("components", []))
	var before := _levels_count(view, DamageLevels.INTACT)
	t.components[root].hp = float(t.components[root].max) * HALF_HEALTH
	view.refresh()
	_expect(_levels_count(view, DamageLevels.MEDIUM) + _levels_count(view, DamageLevels.HEAVY) > 0,
		"%s: damaged component tints its parts (%d intact before)" % [id, before])
	t.components[root].hp = 0.0
	view.refresh()
	_expect(_levels_count(view, DamageLevels.DESTROYED) > 0, "%s: destroyed component shows destroyed" % id)
	t.components[root].hp = float(t.components[root].max)
	view.refresh()


static func _levels_count(view: TargetView, level: int) -> int:
	return view.make_levels().values().filter(func(l): return l == level).size()


# ------------------------------------------------------------------ LAN puppets

func _check_puppet(cockpit: CockpitDisplay) -> void:
	var server := _spawn("es2:OUTLAW", Vector3(10, 0, -30), false)
	var puppet := Herc.new()
	puppet.vehicle_id = "es2:OUTLAW"
	puppet.is_puppet = true
	add_child(puppet)
	puppet.set_physics_process(false)
	puppet.equip(puppet.def.get("loadout", []))
	for w in puppet.weapons:
		w.set_physics_process(false)
	var sync := BattleNetSync.new(null)
	var now := 1000
	puppet.apply_snapshot(_snapshot_of(server, sync, now), 0.05)
	server.weapons[0].trigger = true
	server.components[4].hp = 0.0
	server.shape.set_cell_state(0, 1)
	now += 50
	puppet.apply_snapshot(_snapshot_of(server, sync, now), 0.05)
	_expect(puppet.weapons[0].trigger, "puppet shows the other pilot's fire trigger")
	_expect(float(puppet.components[4].hp) == 0.0, "puppet component destroyed from the snapshot")
	_expect(puppet.shape.get_cell_state(0) == 1, "puppet cell state from the snapshot")
	var img := cockpit.target_image
	img.follow(puppet, 1.0)
	_expect(_levels_count(img.view, DamageLevels.DESTROYED) > 0, "puppet target shows the replicated damage")
	img.follow(null, 1.0)
	_expect(not _snapshot_of(server, sync, now + BattleNetSync.DAMAGE_RESEND_MS / 2)[HercSnapshots.SNAP_DAMAGE].is_empty(),
		"damage block resent shortly after a change")
	_expect(_snapshot_of(server, sync, now + BattleNetSync.DAMAGE_RESEND_MS + 1)[HercSnapshots.SNAP_DAMAGE].is_empty(),
		"damage block left out once it is settled")
	_expect(not _snapshot_of(server, sync, now + BattleNetSync.DAMAGE_RESEND_MS + BattleNetSync.DAMAGE_KEEPALIVE_MS)[HercSnapshots.SNAP_DAMAGE].is_empty(),
		"damage block keepalive")
	sync.free()
	server.queue_free()
	puppet.queue_free()


static func _snapshot_of(h: Herc, sync: BattleNetSync, now_ms: int) -> Array:
	var s := h.snapshot()
	s.append(sync.make_damage_update(h, now_ms))
	return s


# ------------------------------------------------------------------ plain HUD

func _check_hud(cam: Camera3D) -> void:
	var flyer := _spawn(HUD_FLYER, Vector3(0, 10, 0), true)
	var t := _spawn(HUD_TARGET, Vector3(0, 0, -40), false)
	var hud := HUD.new()
	_layer.add_child(hud)
	hud.herc = flyer
	hud.camera = cam
	flyer.target = t
	t.components[2].hp = float(t.components[2].max) * 0.3
	t.components[5].hp = 0.0
	await _settle()
	await get_tree().create_timer(0.3).timeout
	await _settle()
	_expect(hud.target_view.has_target(), "plain HUD follows the flyer's target")
	var coverage := _coverage(hud.target_view.get_texture().get_image())
	_expect(coverage >= MIN_COVERAGE, "plain HUD renders the target (%.0f %% covered)" % [coverage * 100.0])
	if _shots_dir != "":
		_save("target_view_hud_flyer.png")
	hud.queue_free()


# ------------------------------------------------------------------ screenshots

func _save_cockpit_shots(cockpit: CockpitDisplay, host: Herc) -> void:
	for id in SHOT_TARGETS:
		var t := _spawn(id, Vector3(0, 0, -30), false)
		host.target = t
		var root := TargetDamageMap.root_component(t.def.get("damage", {}).get("components", []))
		for state in ["intact", "damaged", "destroyed"]:
			_apply_shot_damage(t, root, state)
			cockpit.target_image.view.refresh()
			await _settle()
			await get_tree().create_timer(0.15).timeout
			await _settle()
			_save("target_view_es1_%s_%s.png" % [id.replace(":", "_"), state])
		host.target = null
		t.queue_free()


## intact; damaged: body at 60 %, legs at 80 %; destroyed part: body at 80 %, the left leg destroyed
## (a vehicle without legs: its body at 20 %).
static func _apply_shot_damage(t: Herc, root: int, state: String) -> void:
	var legs := []
	for i in t.components.size():
		t.components[i].hp = float(t.components[i].max)
		if HercDamage.is_leg(t.components[i]) or (_is_3space(t) and i in THREE_SPACE_LEFT_LEG):
			legs.append(i)
	match state:
		"damaged":
			_set_health(t, [root], 0.6)
			_set_health(t, legs, 0.8)
		"destroyed":
			_set_health(t, [root], 0.8 if not legs.is_empty() else 0.2)
			_set_health(t, legs.filter(func(i): return str(t.components[i].name).begins_with("LEFT") or i in THREE_SPACE_LEFT_LEG), 0.0)
	t.integrity = HercDamage.integrity_of(t.components)


static func _is_3space(t: Herc) -> bool:
	return str(t.def.get("pack", "")) in ["es1", "es2"]


static func _set_health(t: Herc, indices: Array, f: float) -> void:
	for i in indices:
		t.components[i].hp = float(t.components[i].max) * f


func _save(file: String) -> void:
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	var path := _shots_dir.path_join(file)
	get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)
