extends Node3D
## Target health / damage pictures in every game (user request 2026-10-12: no textures unless the game shows targets
## its own way; docs/formats/cockpit.md sections 4.1 / 4.2 / 9.2):
##   Earthsiege 1 / 2 MFD TARGET page: own Hercs their PDG damage diagram, own bases their BASES picture, own flyers the
##     FLYERS picture (the originals); any other target its live model untextured in the cockpit's damage ramp;
##   Starsiege HUD TARGET picture: its own lit model (HudMtrTarget, TargetLitPaint);
##   Battledrome / Tribes HUDs: no target picture in the original, none drawn;
##   the plain HUD (soldiers, vehicles without a cockpit): every target kind - vehicle, soldier, structure - as its
##     live model untextured in the Earthsiege damage colours (TargetFlatPaint), posed like the unit (torso twist).
## Saves renders/target_display_<case>.png. Needs a window:
##   godot --audio-driver Dummy --path game res://tests/target_display_check.tscn

const SETTLE_FRAMES := 6
const GROUND_SIZE := 4000.0
const SKY := Color(0.55, 0.65, 0.8)
const GROUND := Color(0.45, 0.4, 0.3)
const TARGET_AT := Vector3(0, 0, -60)
const TWIST := 0.7
const HALF := 0.5
const OWN_CYBRID := {"es1": "es1:APOLLO", "es2": "es2:DIABLO"}

var _failures := 0
var _layer: CanvasLayer
var _out := ""


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://").path_join("../renders")
	DirAccess.make_dir_recursive_absolute(_out)
	_build_world()
	_layer = CanvasLayer.new()
	add_child(_layer)
	await _check_es_cockpit("es1:RAPTOR", "es1")
	await _check_es_cockpit("es2:OUTLAW", "es2")
	await _check_meter_hud("starsiege:cy_prom", "starsiege", true)
	await _check_meter_hud("bd:STRYDER", "bd", false)
	await _check_meter_hud("tribes:SCOUT", "tribes", false)
	await _check_plain_hud()
	print("target_display_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


func _build_world() -> void:
	SceneLighting.add_studio_environment(self, {"background": SKY, "ambient_energy": 0.6})
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.4, 0.0)
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(GROUND_SIZE, GROUND_SIZE)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GROUND
	plane.material = mat
	ground.mesh = plane
	add_child(ground)


func _spawn(id: String, at: Vector3, team: int) -> Herc:
	var h: Herc = Flyer.new() if Packs.vehicle(id).get("flyer", false) else Herc.new()
	h.vehicle_id = id
	h.team = team
	h.position = at
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _spawn_structure(shape_id: String) -> Structure:
	var st := Structure.create(self, shape_id, Transform3D(Basis(), TARGET_AT), "es1:WORLD0", 1, 1000.0)
	st.add_to_group("targetables")
	return st


func _save(name: String) -> void:
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join("target_display_%s.png" % name))


## Damages `t` half way (its first component, or its hit points) and twists its torso.
static func _apply_wounds(t: Node3D) -> void:
	if t is Herc:
		var h := t as Herc
		h.components[0].hp = float(h.components[0].max) * HALF
		h.integrity = HercDamage.integrity_of(h.components)
		if h.torso:
			h.torso_yaw = TWIST
			h.torso.apply(TWIST, 0.0, h.animator.animates)
	else:
		t.set("hp", float(t.get("max_hp")) * HALF)
		t.set("integrity", HALF)


## Every copy mesh of `view` has its untextured damage material.
static func is_untextured(view: TargetView) -> bool:
	if not view.has_target():
		return false
	for mi in view.make_levels():
		var m := (mi as MeshInstance3D).material_override
		if not (m is ShaderMaterial) or (m as ShaderMaterial).shader != TargetFlatPaint.RAMP_SHADER:
			return false
	return true


func _cockpit_for(host: Herc) -> CockpitDisplay:
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(host)
	cams.cockpit_cam.current = true
	var c := CockpitDisplay.create(host, self)
	if c == null:
		return null
	_layer.add_child(c)
	c.set_camera(cams.cockpit_cam)
	c.set_process(false)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c


## The Earthsiege MFD TARGET page on an own Herc, an own base and another game's Herc.
func _check_es_cockpit(host_id: String, pack: String) -> void:
	if Packs.vehicle(host_id).is_empty():
		return
	var host := _spawn(host_id, Vector3.ZERO, 0)
	var c := _cockpit_for(host)
	_expect(c != null, "%s: a cockpit" % host_id)
	if c == null:
		host.free()
		return
	c.apply_mode(CockpitMfd.MODE_TARGET)
	var own := _spawn(OWN_CYBRID[pack], TARGET_AT, 1)
	await _show(c, host, own, "%s_own_herc" % pack)
	_expect(c.target_image.has_diagram(own) and not c.target_image.view.has_target(), "%s: own Herc shows its PDG diagram" % pack)
	own.free()
	var base := _spawn_structure("es1:BASES_1")
	await _show(c, host, base, "%s_base" % pack)
	if pack == "es1":
		_expect(c.target_image.make_base_picture(base) == 1 and not c.target_image.view.has_target(), "es1: own base shows its BASES picture")
	else:
		_expect(c.target_image.view.has_target(), "es2: another game's base shows its untextured model")
	base.free()
	if not Packs.vehicle("starsiege:cy_prom").is_empty():
		var foreign := _spawn("starsiege:cy_prom", TARGET_AT, 1)
		await _show(c, host, foreign, "%s_foreign" % pack)
		var view := c.target_image.view
		_expect(view.has_target() and view.make_levels().keys().all(func(mi): return mi.material_override is ShaderMaterial),
			"%s: another game's Herc as its untextured model in the cockpit ramp" % pack)
		foreign.free()
	c.free()
	host.free()


func _show(c: CockpitDisplay, host: Herc, t: Node3D, name: String) -> void:
	_apply_wounds(t)
	host.target = t
	c.target_image.view.apply_target(null)
	c.apply_pictures(true, 1.0)
	c.target_image.view.refresh()
	await _settle()
	c.queue_redraw()
	await _save(name)


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw


## A HUD drawn over the view (Starsiege: its own lit model; Battledrome / Tribes: no target picture).
func _check_meter_hud(host_id: String, pack: String, has_picture: bool) -> void:
	if Packs.vehicle(host_id).is_empty():
		return
	var host := _spawn(host_id, Vector3.ZERO, 0)
	if host is Flyer:
		host.position.y = 30.0
	var c := _cockpit_for(host)
	var t := _spawn("es1:APOLLO", TARGET_AT + Vector3(0, host.position.y, 0), 1)
	_apply_wounds(t)
	host.target = t
	if c:
		c.apply_pictures(true, 1.0)
		c.apply_pictures(true, 1.0)
		await _settle()
		c.queue_redraw()
		await _save("%s_hud" % pack)
		var views := c.find_children("*", "TargetView", true, false)
		var target_views := views.filter(func(v): return (v as TargetView).target == t)
		if has_picture:
			_expect(target_views.size() == 1 and (target_views[0] as TargetView).paint is TargetLitPaint,
				"%s: the HUD target picture is its own lit model" % pack)
		else:
			_expect(target_views.is_empty(), "%s: no target picture (none in the original)" % pack)
		c.free()
	t.free()
	host.free()


## The plain HUD with a vehicle, a soldier and a structure as targets.
func _check_plain_hud() -> void:
	var viewer := _spawn("es1:RAPTOR", Vector3.ZERO, 0)
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(viewer)
	cams.cockpit_cam.current = true
	var hud := HUD.new()
	hud.herc = viewer
	hud.camera = cams.cockpit_cam
	_layer.add_child(hud)
	var targets := [_spawn("starsiege:cy_prom" if not Packs.vehicle("starsiege:cy_prom").is_empty() else "es1:APOLLO", TARGET_AT, 1),
		_spawn_structure("es1:BASES_2")]
	var soldier := _spawn_soldier()
	if soldier:
		targets.append(soldier)
	for t in targets:
		_apply_wounds(t)
		viewer.target = t
		hud._process(1.0)
		hud.target_view.refresh()
		await _settle()
		var kind := "herc" if t is Herc and not (t is Infantry) else ("soldier" if t is Infantry else "structure")
		_expect(is_untextured(hud.target_view), "plain HUD: the %s target is drawn untextured" % kind)
		var levels: Array = hud.target_view.make_levels().values()
		_expect(levels.has(DamageLevels.MEDIUM) or levels.has(DamageLevels.HEAVY) or levels.has(DamageLevels.LIGHT),
			"plain HUD: the %s target's damage shows in its colours" % kind)
		await _save("plain_%s" % kind)
		t.free()
	hud.free()
	viewer.free()


func _spawn_soldier() -> Infantry:
	var pack := InfantryCatalog.make_default_pack()
	if pack == "":
		return null
	var s := Infantry.new()
	s.armor_id = InfantryCatalog.light_armor_id(pack)
	s.team = 1
	s.position = TARGET_AT * 0.3
	add_child(s)
	s.set_physics_process(false)
	return s
