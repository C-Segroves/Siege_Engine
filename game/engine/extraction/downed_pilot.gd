class_name DownedPilot
extends Node
## The local player's controls while his soldier is downed (DownedState; ExtractionRevive builds it): the usual pilot
## is held (PlayerHold) and this one crawls: throttle / turn axes cut to crawl speed, the mouse or right stick turns
## the body. Every other on-foot action (interact, boarding, grenades, packs, weapons, inventory, exfil) is swallowed
## so nothing can be used lying down.

## Radians of body turn per pixel of mouse motion (a crawl turns slowly whatever the look sensitivity).
const MOUSE_TURN := 0.003
const BLOCKED_ACTIONS := ["interact", "vehicle_enter_exit", "seat_next", "grenade_throw", "mine_drop", "pack_use",
	"repair_kit_use", "weapon_next", "inventory_toggle", "exfil_call"]

var battle: Battle
var soldier: Infantry
var _yaw := 0.0


static func make(p_battle: Battle, p_soldier: Infantry) -> DownedPilot:
	var p := DownedPilot.new()
	p.battle = p_battle
	p.soldier = p_soldier
	p.name = "DownedPilot"
	p._yaw = p_soldier.rotation.y
	return p


func _ready() -> void:
	PlayerHold.apply(battle, true)


func _exit_tree() -> void:
	if is_instance_valid(battle) and not battle.is_over():
		PlayerHold.apply(battle, false)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw = wrapf(_yaw - (event as InputEventMouseMotion).relative.x * MOUSE_TURN, -PI, PI)
		return
	for action in BLOCKED_ACTIONS:
		if InputMap.has_action(action) and event.is_action(action):
			get_viewport().set_input_as_handled()
			return


func _physics_process(delta: float) -> void:
	if not is_instance_valid(soldier) or not soldier.alive:
		return
	_yaw = wrapf(_yaw - SiegeInput.make_stick_look(delta).x, -PI, PI)
	soldier.throttle = SiegeInput.make_throttle_axis()
	soldier.turn = SiegeInput.make_turn_axis()
	soldier.torso_target = _yaw
	soldier.pitch_target = 0.0
	DownedState.apply_held_controls(soldier, DownedState.make_crawl_share(soldier))
