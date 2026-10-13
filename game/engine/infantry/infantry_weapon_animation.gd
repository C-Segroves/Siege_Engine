class_name InfantryWeaponAnimation
extends RefCounted
## Animates one model of a hand weapon (the world model on the hand or the first-person view model) as the
## originals' weapon images do (weapon record model.animation, tools/export_tribes_infantry.py; roles name the
## shape's sequences, any case):
##   activate  played once when the weapon is drawn; the model then rests at its last key (Tribes 1 shapes rest
##             at its first key, swung out of view; a Tribes 2 image whose Activate sequence the shape lacks
##             rests at the default pose)
##   ready     loops while nothing else plays (Tribes 2 disc "DiscSpin")
##   fire      once per shot, then reload once (Tribes 2 Fire / Reload states, Tribes 1 fire / reload)
##   no_ammo   held when the weapon is out of ammunition
##   ambient   loops all the time (Torque image "ambient", Darkstar "ambient")
##   spin      loops at a speed that ramps up over spin_up_s and down over spin_down_s, on while the trigger is
##             held (spin_on "trigger": the chainguns) or while ready (spin_on "ready": the Tribes 1 disc)
## A state's "<sequence>_Vis" companion plays with it (Torque ShapeBaseImageData finds sequenceVis = the state
## sequence's name + "_vis": the Tribes 2 Chaingun's muzzle flashes are in "Fire_Vis"). Muzzle flashes and other
## pieces hidden by default (T1 "hide ..." objects, T2 visibility 0) show only while a sequence's visibility keys
## say so; every pose starts from the default (ShapeInstance.reset_pose hides them again).
## Every sequence plays at its authored speed (stateScaleAnimation is never set in Tribes 2; Darkstar has none).

const VIS_SUFFIX := "_vis"

var model: ShapeInstance
var roles: Dictionary
var _seq := {}               # role -> sequence index (missing roles left out)
var _vis_seq := {}           # role -> its "<sequence>_Vis" companion (Torque image visibility thread)
var _action := ""            # "activate", "fire", "reload", "no_ammo" or "" (resting)
var _action_t := 0.0
var _after := ""             # role played when the current action ends
var _ambient_t := 0.0
var _spin_phase := 0.0
var _spin_speed := 0.0
var _drawn := false


func _init(p_model: ShapeInstance, p_roles: Dictionary) -> void:
	model = p_model
	roles = p_roles
	for role in ["activate", "ready", "fire", "reload", "no_ammo", "ambient", "spin"]:
		var i := InfantryHeldWeapon.find_sequence(model, str(roles.get(role, "")).to_lower())
		if i >= 0:
			_seq[role] = i
			var vis := InfantryHeldWeapon.find_sequence(model, str(roles.get(role, "")).to_lower() + VIS_SUFFIX)
			if vis >= 0:
				_vis_seq[role] = vis


## True when the shape has a sequence for `role`.
func has_role(role: String) -> bool:
	return _seq.has(role)


## The role playing now ("" when resting).
func make_action() -> String:
	return _action


## The weapon is drawn: its activation plays.
func apply_draw() -> void:
	_drawn = true
	_start("activate", "")


## A shot left the weapon: fire, then reload.
func apply_fired() -> void:
	_start("fire", "reload")


## One frame: advances the playing action, the loops and the spin (`trigger` held, `empty`: out of ammunition)
## and poses the model.
func update(delta: float, trigger: bool, empty: bool) -> void:
	_action_t += delta
	_ambient_t += delta
	_apply_action_end()
	if _action == "" and empty and _seq.has("no_ammo"):
		_start("no_ammo", "")
	_apply_spin(delta, trigger)
	_pose()


func _start(role: String, after: String) -> void:
	if not _seq.has(role):
		_action = ""
		_after = ""
		if after != "":
			_start(after, "")
		return
	_action = role
	_action_t = 0.0
	_after = after


func _apply_action_end() -> void:
	if _action == "" or _action == "no_ammo" or _action_t < _seconds(_action):
		return
	var next := _after
	_action = ""
	_after = ""
	if next != "":
		_start(next, "")


func _apply_spin(delta: float, trigger: bool) -> void:
	if not _seq.has("spin"):
		return
	var spin_on := str(roles.get("spin_on", ""))
	var wanted := trigger if spin_on == "trigger" else (_action == "" if spin_on == "ready" else false)
	var ramp := float(roles.get("spin_up_s" if wanted else "spin_down_s", 0.0))
	_spin_speed = move_toward(_spin_speed, 1.0 if wanted else 0.0, delta / ramp if ramp > 0.0 else 1.0)
	_spin_phase += delta * _spin_speed / maxf(_seconds("spin"), 0.01)


func _pose() -> void:
	model.reset_pose()
	if _seq.has("activate"):
		var drawing := _drawn and _action == "activate"
		ShapeCycles.pose(model, _seq.activate, _action_t / maxf(_seconds("activate"), 0.01) if drawing else 1.0, false)
	if _seq.has("ambient"):
		ShapeCycles.pose(model, _seq.ambient, _ambient_t / maxf(_seconds("ambient"), 0.01))
	if _action == "" and _seq.has("ready"):
		ShapeCycles.pose(model, _seq.ready, _ambient_t / maxf(_seconds("ready"), 0.01))
	if _seq.has("spin"):
		ShapeCycles.pose(model, _seq.spin, _spin_phase)
	if _action != "" and _action != "activate":
		var phase := _action_t / maxf(_seconds(_action), 0.01)
		ShapeCycles.pose(model, _seq[_action], phase, false)
		if _vis_seq.has(_action):
			ShapeCycles.pose(model, _vis_seq[_action], phase, false)


func _seconds(role: String) -> float:
	return ShapeCycles.cycle_seconds(model, int(_seq.get(role, -1)), 0.0)
