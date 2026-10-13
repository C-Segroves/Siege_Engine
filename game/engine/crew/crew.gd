class_name Crew
extends RefCounted
## A campaign's pilot roster (docs/formats/campaign_availability.md section 8), the same for every game:
## the original pilots (Earthsiege CAR/NAMES.DAT, Earthsiege 2 PILOTS.STR: twelve pilots, each with a
## chain of replacement names), their skill, missions, kills and whether they are still flying.
## A pilot killed in action is replaced by the next name of the slot's chain (VSHELL: dead pilots are
## counted - mission var 9 "Losses" - and replaced); the fallen are kept for the losses count.
##
##   pilots   [{id, slot, name, skill, missions, kills}]  one living pilot per roster slot
##   fallen   [same records]                              pilots killed in action
##
## Skill (0..1) drives the wingman's AI pilot. Remake approximation (the originals' pilot rating is not
## decoded): the original crew start seasoned, replacements as rookies; every mission and kill adds
## experience up to MAX_SKILL.

const VETERAN_SKILL := 0.55
const ROOKIE_SKILL := 0.45
const SKILL_PER_MISSION := 0.02
const SKILL_PER_KILL := 0.01
const MAX_SKILL := 0.9
## Display scale of skill ("skill 55").
const SKILL_SCALE := 100.0

var pilots: Array = []
var fallen: Array = []
var _names: Array = []          # name chain per slot (economy data)


## A fresh roster from `names` (one chain of names per slot).
static func make(names: Array) -> Crew:
	var c := Crew.new()
	c._names = names.duplicate(true)
	for slot in names.size():
		c.pilots.append(c._make_pilot(slot, 0, VETERAN_SKILL))
	return c


static func from_dict(d: Dictionary, names: Array) -> Crew:
	var c := Crew.new()
	c._names = names.duplicate(true)
	c.pilots = _make_records(d.get("pilots"))
	c.fallen = _make_records(d.get("fallen"))
	if c.pilots.is_empty() and c.fallen.is_empty():
		return make(names)
	return c


## Saved pilot records with their types restored (JSON numbers come back as floats).
static func _make_records(saved: Variant) -> Array:
	if not saved is Array:
		return []
	return (saved as Array).filter(func(p): return p is Dictionary).map(func(p): return {
		"id": str(p.get("id", "")), "slot": int(p.get("slot", 0)), "name": str(p.get("name", "")),
		"skill": float(p.get("skill", ROOKIE_SKILL)), "missions": int(p.get("missions", 0)), "kills": int(p.get("kills", 0))})


func to_dict() -> Dictionary:
	return {"pilots": pilots.duplicate(true), "fallen": fallen.duplicate(true)}


# ------------------------------------------------------------------ queries

func is_empty() -> bool:
	return pilots.is_empty()


## The living pilot `id` ({} when there is none).
func pilot(id: String) -> Dictionary:
	for p in pilots:
		if str(p.id) == id:
			return p
	return {}


## The living pilot of roster slot `slot` ({} when none).
func pilot_in_slot(slot: int) -> Dictionary:
	var i := _index_of(func(p): return int(p.slot) == slot)
	return pilots[i] if i >= 0 else {}


## Pilots killed in action so far.
func losses() -> int:
	return fallen.size()


## "DUGGAN  -  skill 57, 3 missions, 2 kills".
static func make_pilot_label(p: Dictionary) -> String:
	return "%s  -  skill %d, %d missions, %d kills" % [p.name, roundi(float(p.skill) * SKILL_SCALE),
		int(p.missions), int(p.kills)]


# ------------------------------------------------------------------ changes

## Counts a flown mission for pilot `id` (kills, experience); a pilot who died is replaced.
func apply_mission(id: String, kills: int, survived: bool) -> void:
	var p := pilot(id)
	if p.is_empty():
		return
	p.missions = int(p.missions) + 1
	p.kills = int(p.kills) + kills
	p.skill = minf(MAX_SKILL, float(p.skill) + SKILL_PER_MISSION + SKILL_PER_KILL * kills)
	if not survived:
		apply_death(id)


## Pilot `id` was killed: he joins the fallen and the next name of his slot takes the seat.
func apply_death(id: String) -> void:
	var i := _index_of(func(p): return str(p.id) == id)
	if i < 0:
		return
	var dead: Dictionary = pilots[i]
	fallen.append(dead.duplicate())
	pilots[i] = _make_pilot(int(dead.slot), _make_generation(int(dead.slot)), ROOKIE_SKILL)


## Takes over a finished saga stage's crew: the same slots keep their pilots and records (both games'
## rosters start with the same twelve names); a game without a roster (Starsiege) takes it whole.
func apply_merge(other: Crew) -> void:
	for p in other.pilots:
		var slot := int(p.slot)
		var i := _index_of(func(q): return int(q.slot) == slot)
		if i >= 0:
			pilots[i] = (p as Dictionary).duplicate()
		else:
			pilots.append((p as Dictionary).duplicate())
	for slot in other._names.size():
		if slot >= _names.size():
			_names.append(other._names[slot])
	fallen.append_array(other.fallen.duplicate(true))


## Index of the first living pilot `accepts` takes (-1 = none).
func _index_of(accepts: Callable) -> int:
	for i in pilots.size():
		if accepts.call(pilots[i]):
			return i
	return -1


## Generation of the next pilot in `slot` (fallen pilots of the slot + 1).
func _make_generation(slot: int) -> int:
	return fallen.filter(func(p): return int(p.slot) == slot).size()


func _make_pilot(slot: int, generation: int, skill: float) -> Dictionary:
	return {"id": "p%d_%d" % [slot, generation], "slot": slot, "name": _make_name(slot, generation),
		"skill": skill, "missions": 0, "kills": 0}


## The slot's chain of names; past its end the last name with a number ("BUTCHER 3").
func _make_name(slot: int, generation: int) -> String:
	var chain: Array = _names[slot] if slot < _names.size() else ["PILOT %d" % (slot + 1)]
	if generation < chain.size():
		return str(chain[generation])
	return "%s %d" % [str(chain[-1]), generation - chain.size() + 2]
