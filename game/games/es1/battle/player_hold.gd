class_name PlayerHold
## Stops or resumes the local player's controls without pausing the battle (the LAN battle menu, BattleExit; the
## open chat, BattleChat): the pilot node stops processing input, and the vehicle's turn, triggers and flight
## inputs are zeroed so nothing stays held (the throttle stays set).


static func apply(battle: Battle, on: bool) -> void:
	if battle.pilot == null or not is_instance_valid(battle.pilot):
		return
	battle.pilot.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT
	if on and is_instance_valid(battle.player):
		_apply_released(battle.player)


static func _apply_released(h: Herc) -> void:
	h.turn = 0.0
	for w in h.weapons:
		w.trigger = false
	if h is Flyer:
		(h as Flyer).yaw_input = 0.0
		(h as Flyer).pitch_input = 0.0
		(h as Flyer).lift_input = 0.0
	if h is Infantry:
		(h as Infantry).jump_input = false
		(h as Infantry).jet_input = false
