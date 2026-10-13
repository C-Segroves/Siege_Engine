extends RefCounted
## Destroys one of each kind of thing per pack for the death effect tests (death_fx_check, death_fx_sheet):
## a vehicle, a damage component (3Space packs), a structure, a turret, a soldier and a thrown grenade.
## Each case = {"label", "kind", "run": Callable(parent: Node3D, at: Vector3)}.

## Structure / turret shapes per pack (all exported by the importer) and the Starsiege record tag they carry.
const STRUCTURES := {"es1": "es1:BASES_0", "es2": "es2:BASES_0",
	"starsiege": "starsiege:htroopplanetdefense", "tribes": "tribes:generator", "tribes2": "tribes2:station_generator_large"}
const TURRETS := {"bd": "bd:TURRET", "tribes": "tribes:missileturret", "tribes2": "tribes2:turret_base_large"}
const SS_EXPLOSION_TAG := 351262
## Packs whose units carry 3Space damage components (Battledrome Hercs have none in the engine catalog).
const COMPONENT_PACKS := ["es1", "es2"]
const STRUCTURE_HP := 1000.0


## The death cases of `pack`.
static func make_cases(pack: String) -> Array:
	var cases := []
	var unit := make_vehicle_id(pack)
	if unit != "":
		cases.append({"label": "%s death" % unit, "kind": DeathFx.KIND_VEHICLE, "run": kill_vehicle.bind(unit)})
		if pack in COMPONENT_PACKS:
			cases.append({"label": "%s component" % unit, "kind": DeathFx.KIND_COMPONENT,
				"run": destroy_component.bind(unit)})
	if STRUCTURES.has(pack):
		cases.append({"label": "%s structure" % STRUCTURES[pack], "kind": DeathFx.KIND_STRUCTURE,
			"run": destroy_structure.bind(pack)})
	if TURRETS.has(pack):
		cases.append({"label": "%s turret" % TURRETS[pack], "kind": DeathFx.KIND_TURRET,
			"run": destroy_turret.bind(pack)})
	var armor := InfantryCatalog.light_armor_id(pack) if pack in ["tribes", "tribes2"] else ""
	if armor != "":
		cases.append({"label": "%s soldier" % armor, "kind": DeathFx.KIND_INFANTRY, "run": kill_soldier.bind(armor)})
		var grenade := make_grenade(pack)
		if not grenade.is_empty():
			cases.append({"label": "%s burst" % grenade.id, "kind": "burst", "run": burst_grenade.bind(grenade)})
	return cases


## A walking / driving unit of the pack (its first vehicle, ground units first).
static func make_vehicle_id(pack: String) -> String:
	var ids := []
	for id in Packs.vehicles:
		var v: Dictionary = Packs.vehicles[id]
		if str(v.get("pack", "")) == pack and str(v.get("category", "herc")) != "infantry":
			ids.append(str(id))
	ids.sort()
	for id in ids:
		if not Packs.vehicles[id].get("flyer", false):
			return id
	return ids[0] if not ids.is_empty() else ""


static func spawn_vehicle(parent: Node3D, id: String, at: Vector3) -> Herc:
	var h := Herc.new()
	h.vehicle_id = id
	parent.add_child(h)
	h.global_position = at
	return h


static func kill_vehicle(parent: Node3D, at: Vector3, id: String) -> void:
	var h := spawn_vehicle(parent, id, at)
	h._die(null)


## Destroys the unit's first non-cockpit component that is not a placeholder (its explosion only).
static func destroy_component(parent: Node3D, at: Vector3, id: String) -> void:
	var h := spawn_vehicle(parent, id, at)
	for i in range(h.components.size() - 1, -1, -1):
		var c: Dictionary = h.components[i]
		if not c.fatal and float(c.max) > HercDamage.PLACEHOLDER_HP:
			h.begin_damage_application()
			c.hp = 0.0
			h.play_component_destroyed(i)
			return


static func destroy_structure(parent: Node3D, at: Vector3, pack: String) -> void:
	var xf := Transform3D(Basis(), at)
	var s: Structure
	if pack == "starsiege":
		var ss := SSStructure.make(parent, STRUCTURES[pack], xf, Packs.default_palette(pack), 1, STRUCTURE_HP)
		ss.apply_damage_block({"hit_points": STRUCTURE_HP, "explosion_tag": SS_EXPLOSION_TAG}, 1.0)
		s = ss
	else:
		s = Structure.create(parent, STRUCTURES[pack], xf, Packs.default_palette(pack), 1, STRUCTURE_HP)
	s.destroy(null)


static func destroy_turret(parent: Node3D, at: Vector3, pack: String) -> void:
	var xf := Transform3D(Basis(), at)
	if pack == "bd":
		var t := ArenaTurret.create(parent, TURRETS[pack], xf, Packs.default_palette(pack), 1.0)
		t.apply_destroyed()
		return
	var s := Structure.create(parent, TURRETS[pack], xf, Packs.default_palette(pack), 1, STRUCTURE_HP)
	s.death_kind = DeathFx.KIND_TURRET
	s.destroy(null)


static func kill_soldier(parent: Node3D, at: Vector3, armor: String) -> void:
	var s := Infantry.new()
	s.armor_id = armor
	parent.add_child(s)
	s.global_position = at
	s._die(null)


static func make_grenade(pack: String) -> Dictionary:
	var gear = Assets.load_json("gameplay/infantry_gear.json", pack)
	for item in (gear.get("items", []) if gear is Dictionary else []):
		if str(item.get("kind", "")) == "grenade":
			return item
	return {}


static func burst_grenade(parent: Node3D, at: Vector3, item: Dictionary) -> void:
	ThrownItem.play_burst(parent, item, at)
