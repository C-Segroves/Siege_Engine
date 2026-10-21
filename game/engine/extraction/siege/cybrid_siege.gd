class_name CybridSiege
extends Node
## Varuna's Fall easter egg: the Cybrid siege (child "CybridSiege" of the ExtractionDirector, every peer;
## docs/design/cybrid_siege.md). Three buried ark beacon relays, dug out in the right order, call a relentless Cybrid
## siege against everyone; the factions drop their feuds, the exfils close one by one, a safe area shrinks and kills
## outside it, and after the final time nothing survives.
## Host-authoritative: SiegeHost runs it (host only); this node carries it over the LAN and shows it:
##   to everyone  the broadcast (_show_text_all), the truce (_truce), the state of the siege 4 times a second (_state_update)
##   to one peer  where he stands to a relay (_tell_band: nothing, a hum, in reach), a line (_show_text), a radio fragment (_learn_hint)
##   from a peer  dig (_request_dig): the interact key at a relay
## and on every peer: the Cybrid look by team (CybridLook), the safe area's wall (SiegeZoneFx), the banner (SiegeHud).

const NODE_NAME := "CybridSiege"
const OFFER_REACH_DISTANCE := 0.5
const OFFER_SENSE_DISTANCE := 8.0
const DEFAULT_SECONDS := 4.0

var director: ExtractionDirector
## Host only (null elsewhere and on maps without the siege).
var host: SiegeHost
## The latest siege state (SiegeHost.make_state) on every peer.
var state := {}
## Where the local player stands to a relay (SiegeRelays.Band).
var my_band := 0
## The radio fragments the local player found: rank -> line.
var my_hints := {}
## Broadcast lines shown on this peer (tests read them).
var lines_shown := 0
var zone_fx: SiegeZoneFx
var hud: SiegeHud
var _state_clock := MissionClock.new()
var _look_clock := MissionClock.new()
var _is_present := false


func _init(p_director: ExtractionDirector) -> void:
	director = p_director
	name = NODE_NAME


func _ready() -> void:
	_is_present = CybridRules.is_available(director.built)
	if not _is_present or ServerProfile.is_collision_only():
		return
	zone_fx = SiegeZoneFx.new()
	add_child(zone_fx)
	hud = SiegeHud.new(self)
	director.battle.overlay.add_child(hud)
	var interaction := InfantryInteraction.of(director.battle)
	if interaction != null:
		interaction.add_provider(make_relay_offer)


## True when the built map carries the siege.
func is_present() -> bool:
	return _is_present


## Host, once the map and the squads exist: lays the hidden chain out.
func start_host(seed_value: int) -> void:
	if not _is_present:
		return
	host = SiegeHost.new(self)
	if not host.start(director.built, seed_value):
		host = null


func get_phase() -> int:
	return int(state.get("phase", SiegePhase.ARMED))


# ------------------------------------------------------------------ host: every frame

func _physics_process(delta: float) -> void:
	if host == null or not multiplayer.is_server() or director.battle.is_over():
		return
	host.apply_tick(delta)
	if _state_clock.make_step(delta, float(CybridRules.data().get("state_sync_s", 0.25))) > 0.0:
		ExtractionDirector.send_all_from(self, "_state_update", [host.make_state()])


## Host: a player took `stacks` out of a container (the radio fragments tell their lines).
func apply_stacks_taken(peer: int, stacks: Array) -> void:
	if host != null:
		host.apply_stacks_taken(peer, stacks)


## Host: the bonus an extraction of a haul worth `value` pays now (0 outside the siege).
func make_extraction_bonus(value: int) -> int:
	return host.make_extraction_bonus(value) if host != null else 0


# ------------------------------------------------------------------ host: sending

## Host: a line on every screen (the siege broadcast).
func say_all(text: String, seconds: float) -> void:
	ExtractionDirector.send_all_from(self, "_show_text_all", [text, seconds])


## Host: a line on `peer`'s screen only.
func tell(peer: int, text: String, seconds := DEFAULT_SECONDS) -> void:
	director.send_to(peer, self, "_show_text", [text, seconds])


func tell_band(peer: int, band: int) -> void:
	director.send_to(peer, self, "_tell_band", [band])


func tell_hint(peer: int, rank: int, text: String) -> void:
	director.send_to(peer, self, "_learn_hint", [rank, text, float(CybridRules.section("fragments").get("seconds", 14.0))])


## Host: the relation table with the truce goes to every peer.
func send_truce() -> void:
	ExtractionDirector.send_all_from(self, "_truce", [TeamRelations.make_state()])


@rpc("authority", "reliable", "call_local")
func _show_text_all(text: String, seconds: float) -> void:
	lines_shown += 1
	director.battle.overlay.show_message(text, seconds)


@rpc("authority", "reliable")
func _show_text(text: String, seconds: float) -> void:
	director.battle.overlay.show_message(text, seconds)


@rpc("authority", "reliable")
func _tell_band(band: int) -> void:
	my_band = band


@rpc("authority", "reliable")
func _learn_hint(rank: int, text: String, seconds: float) -> void:
	my_hints[rank] = text
	director.battle.overlay.show_message(text, seconds)


@rpc("authority", "reliable", "call_local")
func _truce(relations: Dictionary) -> void:
	TeamRelations.apply_state(relations)


@rpc("authority", "unreliable", "call_local")
func _state_update(new_state: Dictionary) -> void:
	state = new_state
	if zone_fx != null:
		zone_fx.apply_circle(Vector2(float(state.get("cx", 0.0)), float(state.get("cz", 0.0))), float(state.get("r", 4400.0)),
			get_phase() == SiegePhase.SIEGE)


# ------------------------------------------------------------------ every peer: the interact offer

## Interact offer (InfantryInteraction provider): dig out the relay the host says is in reach, or listen for it.
func make_relay_offer(soldier: Infantry) -> Dictionary:
	if my_band == SiegeRelays.Band.NONE or get_phase() != SiegePhase.ARMED or director.my_status != ExtractionDirector.STATUS_IN_RAID \
			or DownedState.is_downed(soldier):
		return {}
	var in_reach := my_band == SiegeRelays.Band.REACH
	return {"distance": OFFER_REACH_DISTANCE if in_reach else OFFER_SENSE_DISTANCE,
		"text": CybridRules.text("trigger", "reach" if in_reach else "sense"), "apply": _ask_dig}


func _ask_dig() -> void:
	if multiplayer.is_server():
		_request_dig()
	else:
		rpc_id(1, "_request_dig")


@rpc("any_peer", "reliable")
func _request_dig() -> void:
	if host == null or not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	host.apply_dig(multiplayer.get_unique_id() if peer == 0 else peer)


# ------------------------------------------------------------------ every peer: looks

func _process(delta: float) -> void:
	if not _is_present or ServerProfile.is_collision_only() or get_phase() == SiegePhase.ARMED:
		return
	if _look_clock.make_step(delta, float(CybridRules.data().get("tick_s", 0.5))) > 0.0:
		apply_looks()


## The Cybrid look over every Cybrid-team soldier and stand-in Herc that has none yet.
func apply_looks() -> int:
	var team := CybridRules.make_cybrid_team()
	var made := 0
	for v in director.battle.vehicles.values():
		if is_instance_valid(v) and v.team == team and not CybridLook.is_applied(v) and CybridLook.is_wanted(v) and CybridLook.apply(v):
			made += 1
	return made


## The objective lines of the siege for the local player: the fragments found, then what to do.
func make_objective_lines() -> Array:
	var out := []
	var ranks := my_hints.keys()
	ranks.sort()
	for rank in ranks:
		out.append({"text": str(CybridRules.section("fragments").get("hint_line", "%s")) % str(my_hints[rank]), "done": false})
	match get_phase():
		SiegePhase.WARNING:
			out.append({"text": "Brace: the Cybrids arrive in %s" % SiegeHud.make_clock_text(float(state.get("t", 0.0))), "done": false})
		SiegePhase.SIEGE:
			out.append({"text": "Stay inside the safe area and get out before the exfils close", "done": false})
	return out
