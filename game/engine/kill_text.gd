class_name KillText
## The one wording of every kill / destruction message (chat system lines, the battle and cockpit message lines,
## the game modes' announcements): who it was - the LAN player, wingman, crew pilot, bot or AI callsign - and what
## they were in, never the vehicle name alone.
##   make_unit_label(unit)        "Ace (Apocalypse)", "Bot 3 (on foot, Light Armor)", "Ace (on foot, Bioderm
##                                light)", "Cybrid (Talon)" (an unnamed AI unit: its faction)
##   make_kill_text(victim, killer)  "Ace (Apocalypse) was killed by Bot 3 (on foot, Light Armor)",
##                                "Ace (Apocalypse) was killed by own splash", "... died out of bounds"
## A damage source the victim cannot name as a killer (the map's bounds, a fall, a collision) marks the victim
## with apply_cause before the damage lands.

const CAUSE_META := "kill_cause"
const CAUSE_BOUNDS := "bounds"
const CAUSE_FALL := "fall"
const CAUSE_COLLISION := "collision"
## Wedged in the world's geometry with no floor (Infantry HELD_DEATH_SECONDS).
const CAUSE_STUCK := "stuck"
## Fell below the world's floor (MapBounds: through a gap in the terrain or a building).
const CAUSE_FELL_THROUGH := "fell_through"
## Damage a mission script deals (Starsiege damageObject, Tribes calcRadiusDamage / applyDamage).
const CAUSE_SCRIPTED := "scripted"
## A flying vehicle's hard landing.
const CAUSE_CRASH := "crash"
const CAUSE_TEXTS := {CAUSE_BOUNDS: "%s died out of bounds", CAUSE_FALL: "%s was killed by a fall",
	CAUSE_COLLISION: "%s was killed in a collision", CAUSE_STUCK: "%s got stuck in the scenery",
	CAUSE_FELL_THROUGH: "%s fell out of the world", CAUSE_SCRIPTED: "%s was destroyed by the mission",
	CAUSE_CRASH: "%s crashed"}
const KILLED_BY := "%s was killed by %s"
const RAMMED_BY := "%s was rammed to death by %s"
const OWN_SPLASH := "%s was killed by own splash"
const ENVIRONMENT := "%s was killed by the environment"
const UNNAMED_AI := "AI pilot"
const UNMANNED := "Unmanned"
const AI_PREFIX := "AI "
## Vehicle catalogue sides (ES1 / ES2 / Starsiege "side") as a faction name for unnamed AI units.
const SIDE_NAMES := {"cybrid": "Cybrid", "herc": "Human"}


## "<name> (<vehicle or suit>)" for any unit (Herc, Infantry, Structure), "" for none.
static func make_unit_label(unit: Node) -> String:
	if unit == null or not is_instance_valid(unit):
		return ""
	if unit is Infantry:
		return "%s (%s)" % [str((unit as Infantry).display_name), make_suit_text(unit as Infantry)]
	if unit is Herc:
		return _make_vehicle_label(unit as Herc)
	return str(unit.get("display_name")) if unit.get("display_name") != null else str(unit.name)


## What a soldier is in: "on foot, Light Armor", "on foot, Bioderm light", "in Havoc".
static func make_suit_text(s: Infantry) -> String:
	if s.stowed and s.seat != null and is_instance_valid(s.seat.vehicle):
		return "in %s" % make_vehicle_name(s.seat.vehicle)
	if s.body_shape.contains("bioderm"):
		return "on foot, Bioderm %s" % str(s.armor.get("size", "light"))
	return "on foot, %s" % str(s.armor.get("name", "armour"))


static func make_vehicle_name(h: Herc) -> String:
	return str(h.def.get("name", h.vehicle_id))


## The whole message of `victim` destroyed by `killer` (null: the world; the victim itself: own splash).
static func make_kill_text(victim: Node, killer: Node) -> String:
	var who := make_unit_label(victim)
	var cause := str(victim.get_meta(CAUSE_META, "")) if victim != null and is_instance_valid(victim) else ""
	if killer == null or not is_instance_valid(killer):
		if not CAUSE_TEXTS.has(cause):
			push_warning("KillText: %s died with no killer and no cause (a death path that sets none)" % who)
		return str(CAUSE_TEXTS.get(cause, ENVIRONMENT)) % who
	if killer == victim:
		return OWN_SPLASH % who if cause == "" else str(CAUSE_TEXTS.get(cause, OWN_SPLASH)) % who
	if cause == CAUSE_COLLISION:
		return RAMMED_BY % [who, make_unit_label(killer)]
	return KILLED_BY % [who, make_unit_label(killer)]


## Marks `unit` as hurt by `cause` (CAUSE_*); a later hit by a weapon clears it (apply_cause(unit, "")).
static func apply_cause(unit: Node, cause: String) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if cause != "":
		unit.set_meta(CAUSE_META, cause)
	elif unit.has_meta(CAUSE_META):
		unit.remove_meta(CAUSE_META)


## A vehicle: its pilot's name (a player's or bot's soldier inside), else its own (wingman / crew pilot / AI
## callsign), else its faction (an unnamed AI unit).
static func _make_vehicle_label(h: Herc) -> String:
	var vehicle := make_vehicle_name(h)
	var pilot := _make_pilot_name(h)
	if pilot == "":
		pilot = _make_unnamed_text(h)
	return "%s (%s)" % [pilot, vehicle]


static func _make_pilot_name(h: Herc) -> String:
	var battle := h.get_parent() as Battle
	var occ := h.get_node_or_null(VehicleOccupancy.NODE_NAME) as VehicleOccupancy
	if battle != null and battle.occupancy != null and occ != null and occ.has_pilot():
		var soldier := battle.occupancy.soldier_of(occ.pilot())
		if soldier != null:
			return str(soldier.display_name)
	var own := str(h.display_name)
	var vehicle := make_vehicle_name(h)
	if own == "" or own == vehicle or own == AI_PREFIX + vehicle:
		return ""
	return own


## An AI unit without a name: its faction or side ("Cybrid", "Imperial"), else "AI pilot"; an empty vehicle:
## "Unmanned".
static func _make_unnamed_text(h: Herc) -> String:
	var occ := h.get_node_or_null(VehicleOccupancy.NODE_NAME) as VehicleOccupancy
	if occ != null and not occ.has_pilot() and not occ.is_ai_piloted() and not h.has_meta("ai"):
		return UNMANNED
	var faction := str(h.def.get("faction", SIDE_NAMES.get(str(h.def.get("side", "")), "")))
	return faction if faction != "" else UNNAMED_AI


## Calls target.apply_hit(...) with `cause` named for a death it brings (no killer to credit).
static func apply_caused_hit(target: Object, hit: Array, cause: String) -> void:
	apply_cause(target as Node, cause)
	target.callv("apply_hit", hit)
	apply_cause(target as Node, "")
