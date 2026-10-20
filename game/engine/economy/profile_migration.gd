class_name ProfileMigration
extends RefCounted
## Brings what older versions stored into a new OperatorProfile, once each (recorded in `migrated`), without losing
## anything and without editing the old files (docs/design/lobby_loadout_economy.md section 2.4):
##   loadout_presets   the saved Herc / infantry presets fill slots 1..3 (preset n -> slot n; the presets stay on disk)
##   player_settings   the armour, body, skin and Herc skin chosen in Options -> slot 1, when it got no preset
##   extraction_v2     the extraction profile's money -> credits; the paid armours in its stash and its call-in tokens
##                     -> armour and vehicle unlocks (the old file keeps them until the extraction code stops using it)
## Everything migrated is owned, even where today's price would be higher.

const PRESETS := "loadout_presets"
## The old preset files (one per player: {"herc": [{name, vehicle, loadout}], "infantry": [{name, armor, body, skin}]}).
const PRESETS_FOLDER := "loadout_presets"
const KIND_HERC := "herc"
const KIND_INFANTRY := "infantry"
const SETTINGS := "player_settings"
const EXTRACTION := "extraction_v2"
const STEPS := [PRESETS, SETTINGS, EXTRACTION]


static func apply_all(p: OperatorProfile) -> void:
	for step in STEPS:
		if p.migrated.has(step):
			continue
		match step:
			PRESETS:
				_apply_presets(p)
			SETTINGS:
				_apply_settings(p)
			EXTRACTION:
				_apply_extraction(p)
		p.migrated.append(step)


## The file of `player`'s old presets.
static func make_presets_path(player: String) -> String:
	var slug := ""
	for ch in player.to_lower():
		slug += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	return UserStore.path(PRESETS_FOLDER).path_join("%s.json" % (slug if slug != "" else "pilot"))


## Every old preset of `kind` (KIND_HERC / KIND_INFANTRY) `player` saved, in saving order; the file is only read.
static func list_old_presets(player: String, kind: String) -> Array:
	var path := make_presets_path(player)
	if not FileAccess.file_exists(path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return ((parsed as Dictionary).get(kind, []) as Array).duplicate(true) if parsed is Dictionary else []


static func _apply_presets(p: OperatorProfile) -> void:
	var herc := list_old_presets(p.pilot, KIND_HERC)
	var infantry := list_old_presets(p.pilot, KIND_INFANTRY)
	for i in mini(p.slots.size(), maxi(herc.size(), infantry.size())):
		var slot: CharacterSlot = p.slots[i]
		if i < infantry.size():
			_apply_look(p, slot, infantry[i])
		if i < herc.size():
			_apply_herc(p, slot, herc[i])
		var named := str((herc[i] if i < herc.size() else infantry[i]).get("name", ""))
		if named != "":
			slot.label = named.left(CharacterSlot.MAX_LABEL)


static func _apply_settings(p: OperatorProfile) -> void:
	var slot: CharacterSlot = p.slots[0]
	var infantry := list_old_presets(p.pilot, KIND_INFANTRY)
	if infantry.is_empty() and PlayerProfile.load_value(PlayerProfile.ARMOR_KEY) != "":
		_apply_look(p, slot, {"armor": PlayerProfile.load_value(PlayerProfile.ARMOR_KEY),
			"body": PlayerProfile.load_value(PlayerProfile.BODY_KEY), "skin": PlayerProfile.load_value(PlayerProfile.SKIN_KEY)})
	var skin := PlayerProfile.load_herc_skin(slot.vehicle) if slot.vehicle != "" else ""
	if skin != "" and slot.herc_skin == "":
		slot.herc_skin = skin
		p.unlocks.apply_add(UnlockId.make("herc_skin", UnlockId.make_skin_ref(SkinCatalog.make_vehicle_shape(slot.vehicle), skin)))


static func _apply_extraction(p: OperatorProfile) -> void:
	var d := SaveGames.read_profile(ExtractionProfile.make_id(p.pilot))
	if d.is_empty():
		return
	p.credits = int(d.get("money", p.credits))   # JSON numbers come back as floats
	for stack in d.get("stash", []):
		var id := str(stack[0])
		match ExtractionItems.kind_of(id):
			"armor":
				p.unlocks.apply_add(UnlockId.make("armor", ExtractionItems.ref_of(id)))
			"callin":
				p.unlocks.apply_add(UnlockId.make("vehicle", ExtractionItems.ref_of(id)))
	var worn := str((d.get("kit", {}) as Dictionary).get("armor", "")) if d.get("kit") is Dictionary else ""
	if worn != "":
		p.unlocks.apply_add(UnlockId.make("armor", worn))


## Puts a saved infantry look {armor, body, skin} on `slot` and owns it.
static func _apply_look(p: OperatorProfile, slot: CharacterSlot, look: Dictionary) -> void:
	var armor := str(look.get("armor", ""))
	if armor == "":
		return
	slot.apply_armor_defaults(armor)
	slot.body = str(look.get("body", ""))
	slot.skin = str(look.get("skin", ""))
	p.unlocks.apply_add(UnlockId.make("armor", armor))
	var shown := slot.body if slot.body != "" else PlayerProfile.make_default_body(armor)
	if slot.body != "":
		p.unlocks.apply_add(UnlockId.make("body", slot.body))
	if slot.skin != "":
		p.unlocks.apply_add(UnlockId.make("skin", UnlockId.make_skin_ref(shown, slot.skin)))


## Puts a saved Herc build {vehicle, loadout} on `slot` and owns it.
static func _apply_herc(p: OperatorProfile, slot: CharacterSlot, build: Dictionary) -> void:
	var vehicle := str(build.get("vehicle", ""))
	if vehicle == "":
		return
	slot.apply_vehicle_defaults(vehicle)
	slot.herc_loadout = CharacterSlot.make_strings(build.get("loadout", []))
	p.unlocks.apply_add(UnlockId.make("vehicle", vehicle))
	for w in slot.herc_loadout:
		if w != "":
			p.unlocks.apply_add(UnlockId.make("herc_weapon", w))
