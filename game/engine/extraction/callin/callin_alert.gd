class_name CallinAlert
extends RefCounted
## How the AI reacts to a call-in (host; docs/design/lobby_loadout_economy.md section 9.7). A flare, a transport, a pod impact
## and a radar sweep are noise: within the call-in's alert radius every awake soldier of a faction hostile to the caller's team
## investigates the landing zone (a roaming soldier walks there, a guard only turns and faces it unless a target
## appears), and sleeping units there wake (BotSleep.wake_area). The investigation ends when it arrives, after
## INVESTIGATE_SECONDS, or when the soldier's brain was given another objective meanwhile.

const INVESTIGATE_SECONDS := 25.0
const ARRIVE_M := 15.0
const WAKE_HOLD_SECONDS := 10.0
const META_KEY := "callin"

## [{bot: InfantryBot, point: Vector3, left: float}] the soldiers walking to a landing zone.
var investigating: Array = []
var battle: Battle


func _init(p_battle: Battle) -> void:
	battle = p_battle


## Host: a noise of `radius` metres at `pos` made by a call-in of `caller_team`. Returns how many soldiers react.
func apply_noise(pos: Vector3, radius: float, caller_team: int) -> int:
	if radius <= 0.0:
		return 0
	if battle.bot_sleep != null:
		battle.bot_sleep.wake_area(pos, radius, WAKE_HOLD_SECONDS)
	var reacting := 0
	for h in battle.vehicles.values():
		var bot := _make_listener(h, pos, radius, caller_team)
		if bot != null:
			_send_to(bot, pos)
			reacting += 1
	return reacting


## The brain of `unit` when it is an awake soldier of a hostile faction that hears a noise at `pos`; else null.
func _make_listener(unit: Variant, pos: Vector3, radius: float, caller_team: int) -> InfantryBot:
	var s := unit as Infantry if is_instance_valid(unit) else null
	if s == null or not s.alive or s.stowed or s.has_meta("dormant") or not TeamRelations.is_hostile(s.team, caller_team):
		return null
	if Vector2(s.global_position.x - pos.x, s.global_position.z - pos.z).length() > radius:
		return null
	return s.get_node_or_null("Bot") as InfantryBot


func _send_to(bot: InfantryBot, pos: Vector3) -> void:
	var flat := pos - bot.soldier.global_position
	if bot.guard_radius > 0.0:
		bot.soldier.torso_target = atan2(-flat.x, -flat.z)   # a guard turns to face it
		bot.soldier.rotation.y = bot.soldier.torso_target
		return
	if not bot.objective.is_empty() and not bot.objective.has(META_KEY):
		return   # it has a goal of its own (a flag hunt)
	bot.objective = {"point": pos, "urgent": false, "radius": ARRIVE_M, "hold": false, META_KEY: true}
	investigating.append({"bot": bot, "point": pos, "left": INVESTIGATE_SECONDS})


## Host, every physics frame: soldiers that arrived or lost patience go back to what they were doing.
func apply_tick(delta: float) -> void:
	for e in investigating.duplicate():
		e.left = float(e.left) - delta
		var bot = e.bot   # a Variant: the soldier may be freed
		var done: bool = not is_instance_valid(bot) or not (bot as InfantryBot).soldier.alive or float(e.left) <= 0.0
		if not done and not (bot as InfantryBot).objective.has(META_KEY):
			done = true   # another goal replaced ours
		elif not done:
			var flat: Vector3 = (e.point as Vector3) - (bot as InfantryBot).soldier.global_position
			done = Vector2(flat.x, flat.z).length() <= ARRIVE_M
		if done:
			if is_instance_valid(bot) and (bot as InfantryBot).objective.has(META_KEY):
				(bot as InfantryBot).objective = {}
			investigating.erase(e)
