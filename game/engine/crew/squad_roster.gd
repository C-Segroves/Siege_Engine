class_name SquadRoster
extends RefCounted
## Who flies the garage's Hercs (docs/formats/campaign_availability.md section 8), the same in every
## game: crew pilots are assigned to Hercs (Earthsiege CREW screen 1610, Earthsiege 2 squad), and up to
## a mission's wingman slots of them fly as the player's wingmen with their Herc, loadout, condition and
## skill. The selected Herc is the player's own; its pilot sits that mission out.
##
## Wingman slots: Earthsiege 2 missions fix them (MSN group 0's Hercs besides the player); Earthsiege
## gives the squad up to three (the HDD's three wingman windows); Starsiege missions bring their own
## squadmates (none from the garage). The provider says how many (wingman_slots()).

## Shown for a Herc nobody flies.
const NO_PILOT := "(no pilot)"


## The crew pilot assigned to Herc `i` ({} when none, or when he was killed).
static func pilot_of(g: Garage, i: int) -> Dictionary:
	return g.crew.pilot(str(g.vehicles[i].get("pilot_id", ""))) if i >= 0 and i < g.vehicles.size() else {}


## Index of the Herc pilot `pilot_id` flies (-1 = none).
static func herc_of_pilot(g: Garage, pilot_id: String) -> int:
	for i in g.vehicles.size():
		if pilot_id != "" and str(g.vehicles[i].get("pilot_id", "")) == pilot_id:
			return i
	return -1


## Herc `i` is a possible wingman: built, not the player's own and flown by a living pilot.
static func is_eligible(g: Garage, i: int) -> bool:
	return i != g.selected and Garage.is_ready(g.vehicles[i]) and not pilot_of(g, i).is_empty()


## The wingmen for the next mission (Herc indices, at most `limit`): the chosen ones still eligible,
## or the first eligible Hercs while the player has not chosen.
static func make_squad(g: Garage, limit: int) -> Array:
	var out: Array = []
	var candidates: Array = range(g.vehicles.size()) if g.squad_auto else g.squad.map(func(uid): return g.find_uid(int(uid)))
	for i in candidates:
		if out.size() < limit and int(i) >= 0 and is_eligible(g, int(i)):
			out.append(int(i))
	return out


## Battle entries for the wingmen: [{vehicle, loadout, name, skill, garage}] (pilot's name and skill).
static func make_squad_config(g: Garage, limit: int) -> Array:
	var out: Array = []
	for i in make_squad(g, limit):
		var e: Dictionary = g.vehicles[i]
		var p := pilot_of(g, i)
		out.append({"vehicle": str(e.vehicle), "loadout": (e.loadout as Array).duplicate(), "name": str(p.name),
			"skill": float(p.skill), "garage": Garage.make_battle_tag(e)})
	return out


static func is_wingman(g: Garage, i: int, limit: int) -> bool:
	return make_squad(g, limit).has(i)


# ------------------------------------------------------------------ changes

## Seats pilot `pilot_id` in Herc `i` ("" = leave it empty); he leaves any other Herc.
static func apply_assign(g: Garage, i: int, pilot_id: String) -> void:
	if i < 0 or i >= g.vehicles.size():
		return
	var other := herc_of_pilot(g, pilot_id)
	if other >= 0:
		g.vehicles[other].pilot_id = ""
	g.vehicles[i].pilot_id = pilot_id


## Adds Herc `i` to the wingmen (while there is a slot) or takes it out; from now on the player's
## choice counts instead of the automatic one.
static func apply_toggle_wingman(g: Garage, i: int, limit: int) -> void:
	var chosen := make_squad(g, limit).map(func(k): return int(g.vehicles[k].uid))
	var uid := int(g.vehicles[i].uid)
	if chosen.has(uid):
		chosen.erase(uid)
	elif is_eligible(g, i) and chosen.size() < limit:
		chosen.append(uid)
	g.squad = chosen
	g.squad_auto = false


## The wingman slots as Herc indices, -1 for a free slot: [2, -1, 5] (always `limit` entries).
static func make_slots(g: Garage, limit: int) -> Array:
	var out: Array = []
	if g.squad_auto:
		out = make_squad(g, limit)
	else:
		for k in mini(limit, g.squad.size()):
			var i := g.find_uid(int(g.squad[k]))
			out.append(i if i >= 0 and is_eligible(g, i) else -1)
	while out.size() < limit:
		out.append(-1)
	return out


## Puts Herc `herc_i` (-1 = nobody) into wingman slot `slot`; it leaves any other slot, and a Herc taken by the
## slot's old occupant frees it. The player's choice counts from now on.
static func apply_slot(g: Garage, slot: int, limit: int, herc_i: int) -> void:
	var slots := make_slots(g, limit)
	if slot < 0 or slot >= slots.size():
		return
	if herc_i >= 0 and not is_eligible(g, herc_i):
		return
	var at := slots.find(herc_i)
	if herc_i >= 0 and at >= 0:
		slots[at] = -1
	slots[slot] = herc_i
	var uids: Array = []
	for i in slots:
		uids.append(int(g.vehicles[i].uid) if int(i) >= 0 else -1)
	g.squad = uids
	g.squad_auto = false


## Hercs a wingman slot can take: eligible ones (built, flown by a living pilot, not the player's own).
static func make_slot_candidates(g: Garage) -> Array:
	var out: Array = []
	for i in g.vehicles.size():
		if is_eligible(g, i):
			out.append(i)
	return out


## Living pilots without a Herc take the Hercs nobody flies (not the player's own), in roster order:
## the start of a campaign and replacements after losses.
static func apply_auto_assign(g: Garage) -> void:
	for i in g.vehicles.size():
		if i == g.selected or not pilot_of(g, i).is_empty():
			continue
		var free := g.crew.pilots.filter(func(p): return herc_of_pilot(g, str(p.id)) < 0)
		if free.is_empty():
			return
		g.vehicles[i].pilot_id = str(free[0].id)


## "DUGGAN" / "(no pilot)" for Herc `i`; the player's own Herc shows `player_name`.
static func make_pilot_name(g: Garage, i: int, player_name: String) -> String:
	if i == g.selected:
		return player_name
	var p := pilot_of(g, i)
	return str(p.name) if not p.is_empty() else NO_PILOT
