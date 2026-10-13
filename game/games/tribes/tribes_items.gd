class_name TribesItems
extends RefCounted
## What the mission scripts' item names mean for the remake's soldier (docs/formats/tribes.md section 8):
##   weapon  an item whose image (Tribes ItemData imageType, Tribes 2 image) is a catalogued infantry weapon's
##           image (weapons_infantry.json "source" names it) -> that weapon ("DiscLauncher" -> tribes:DISC_LAUNCHER);
##   ammo    an item that is a weapon image's ammunition (ammoType / ammo) -> rounds of that weapon;
##   gear    a hand item or backpack of infantry_gear.json with the same name ("RepairKit" -> REPAIR_KIT);
##   armour  Tribes 2 setArmor("Light") / Tribes armour items ("lightArmor") -> the pack's armour of that size;
##   vehicle a vehicle datablock (hercs.json "datablock") -> that vehicle.
## The script inventory ({lower item: count}) is kept per player object; apply_to() makes the soldier carry it.

const ARMOR_WORDS := {"light": "LIGHT", "medium": "MEDIUM", "heavy": "HEAVY", "larmor": "LIGHT", "marmor": "MEDIUM",
	"harmor": "HEAVY"}
const IMAGE_FIELDS := ["image", "imagetype"]
const WEAPONS_FILE := "gameplay/weapons_infantry.json"
## infantry_gear.json "kind" of grenades (the soldier throws his grenade_id).
const GRENADE_KIND := "grenade"
const AMMO_FIELDS := ["ammo", "ammotype"]

var pack := ""
var _weapon_of_image := {}      # lower image name -> weapon id
var _weapon_of_item := {}       # lower item name -> weapon id
var _weapon_of_ammo := {}       # lower ammo item -> weapon id
var _gear_of_name := {}         # normalized name -> gear id
var _vehicle_of_datablock := {} # lower datablock -> vehicle id
var _image_pattern := RegEx.create_from_string("(\\w+Image)\\b")


func _init(p_pack: String, datablocks: Dictionary) -> void:
	pack = p_pack
	_index_weapons()
	_index_items(datablocks)
	_index_gear()
	_index_vehicles()


## weapons_infantry.json: each record's "source" names the original image ("ItemImageData BlasterImage -> ...").
func _index_weapons() -> void:
	var j = Assets.load_json(WEAPONS_FILE, pack)
	var records: Array = j.get("weapons", []) if j is Dictionary else []
	for w in records:
		var m := _image_pattern.search(String(w.get("source", "")).replace("ItemImageData", ""))
		if m and String(w.get("name", "")) != "":
			_weapon_of_image[m.get_string(1).to_lower()] = "%s:%s" % [pack, w.name]


func _index_items(datablocks: Dictionary) -> void:
	for key in datablocks:
		var fields: Dictionary = datablocks[key].get("fields", {})
		for f in IMAGE_FIELDS:
			var image := String(fields.get(f, "")).to_lower()
			if _weapon_of_image.has(image):
				_weapon_of_item[key] = _weapon_of_image[image]
		if _weapon_of_image.has(key):
			for f in AMMO_FIELDS:
				var ammo := String(fields.get(f, "")).to_lower()
				if ammo != "":
					_weapon_of_ammo[ammo] = _weapon_of_image[key]


func _index_gear() -> void:
	var j = Assets.load_json("gameplay/infantry_gear.json", pack)
	if not (j is Dictionary):
		return
	for list in ["items", "packs"]:
		for g in j.get(list, []):
			var id := String(g.get("id", ""))
			_gear_of_name[make_normal_name(id.get_slice(":", 1))] = id


func _index_vehicles() -> void:
	var j = Assets.load_json("gameplay/hercs.json", pack)
	if not (j is Dictionary):
		return
	for key in j:
		var db := String(j[key].get("datablock", "")).to_lower()
		if db != "":
			_vehicle_of_datablock[db] = "%s:%s" % [pack, key]


## "REPAIR_KIT" / "RepairKit" / "repairkit" -> "REPAIRKIT".
static func make_normal_name(s: String) -> String:
	return s.replace("_", "").replace(" ", "").to_upper()


func weapon_of(item: String) -> String:
	return String(_weapon_of_item.get(item.to_lower(), ""))


func ammo_weapon_of(item: String) -> String:
	return String(_weapon_of_ammo.get(item.to_lower(), ""))


func gear_of(item: String) -> String:
	return String(_gear_of_name.get(make_normal_name(item), ""))


func vehicle_of(datablock: String) -> String:
	return String(_vehicle_of_datablock.get(datablock.to_lower(), ""))


## The armour id an armour name / item means ("" when it names none).
func armor_of(armor_name: String) -> String:
	var key := armor_name.to_lower()
	for word in ARMOR_WORDS:
		if key.begins_with(word):
			return "%s:%s" % [pack, ARMOR_WORDS[word]]
	return ""


## Makes `soldier` carry the script inventory `inv` ({lower item: count}): the weapons in the order they were
## given (the armour's limit and allowed weapons apply), their rounds, the hand items and the backpack.
func apply_to(soldier: Infantry, inv: Dictionary) -> void:
	if soldier == null or not is_instance_valid(soldier):
		return
	var loadout := []
	for item in inv:
		var wid := weapon_of(item)
		if wid != "" and int(inv[item]) > 0 and not loadout.has(wid):
			loadout.append(wid)
	if loadout != soldier.make_loadout():
		var slot_weapon := soldier.current_weapon().weapon_id if soldier.current_weapon() else ""
		soldier.equip(loadout)
		if loadout.has(slot_weapon):
			soldier.apply_weapon_slot(soldier.make_loadout().find(slot_weapon))
	_apply_rounds(soldier, inv)
	_apply_gear(soldier, inv)


func _apply_rounds(soldier: Infantry, inv: Dictionary) -> void:
	for item in inv:
		var wid := ammo_weapon_of(item)
		if wid == "":
			continue
		for w in soldier.weapons:
			if w.weapon_id == wid and w.ammo_max > 0:
				w.ammo = clampi(int(inv[item]), 0, w.ammo_max)


func _apply_gear(soldier: Infantry, inv: Dictionary) -> void:
	for item in inv:
		var gid := gear_of(item)
		if gid == "":
			continue
		var record := InfantryGear.pack(gid)
		if not record.is_empty():
			if int(inv[item]) > 0:
				soldier.kit.pack_id = gid
			elif soldier.kit.pack_id == gid:
				soldier.kit.pack_id = ""
			continue
		soldier.kit.counts[gid] = int(inv[item])
		if InfantryGear.item(gid).get("kind", "") == GRENADE_KIND and int(inv[item]) > 0:
			soldier.kit.grenade_id = gid
