class_name Tribes2Classes
extends RefCounted
## The Torque class hierarchy behind Tribes 2's script namespaces (lower case): a method call on an object
## looks for <namespace>::<method> along its name, its script class / superClass, then its engine class and
## that class's parents; a datablock's callbacks go along its name, its className field and its class
## (docs/formats/tribes2.md section 8). The engine classes are the ones the training missions use.

const PARENTS := {
	"player": "shapebase", "staticshape": "shapebase", "item": "shapebase", "turret": "staticshape",
	"vehicle": "shapebase", "hovervehicle": "vehicle", "flyingvehicle": "vehicle", "wheeledvehicle": "vehicle",
	"camera": "shapebase", "missionmarker": "shapebase", "waypoint": "missionmarker",
	"spawnsphere": "missionmarker", "shapebase": "gamebase", "trigger": "gamebase", "forcefieldbare": "gamebase",
	"projectile": "gamebase", "gamebase": "sceneobject", "sceneobject": "netobject", "interiorinstance": "sceneobject",
	"terrainblock": "sceneobject", "sky": "sceneobject", "tsstatic": "sceneobject", "audioemitter": "sceneobject",
	"waterblock": "sceneobject", "netobject": "simobject", "missionarea": "netobject",
	"aiconnection": "gameconnection", "gameconnection": "netconnection", "netconnection": "simgroup",
	"simgroup": "simset", "simset": "simobject", "aiobjectiveq": "simset", "scriptobject": "simobject",
	"aiobjective": "scriptobject", "actionmap": "simobject", "audiosource": "simobject",
	"itemdata": "shapebasedata", "staticshapedata": "shapebasedata", "playerdata": "shapebasedata",
	"vehicledata": "shapebasedata", "hovervehicledata": "vehicledata", "flyingvehicledata": "vehicledata",
	"wheeledvehicledata": "vehicledata", "turretdata": "staticshapedata", "sensordata": "simdatablock",
	"missionmarkerdata": "shapebasedata", "shapebasedata": "gamebasedata", "shapebaseimagedata": "gamebasedata",
	"triggerdata": "gamebasedata", "forcefieldbaredata": "gamebasedata", "projectiledata": "gamebasedata",
	"gamebasedata": "simdatablock", "simdatablock": "simobject", "audioprofile": "simdatablock",
	"audiodescription": "simdatablock", "particledata": "simdatablock", "particleemitterdata": "simdatablock",
}
const MAX_CHAIN := 32


## `cls` and its parents, lower case ("player" -> player, shapebase, gamebase, ...).
static func make_chain(cls: String) -> Array:
	var out := []
	var c := cls.to_lower()
	while c != "" and out.size() < MAX_CHAIN:
		out.append(c)
		c = String(PARENTS.get(c, "simobject" if c != "simobject" else ""))
	return out


## The namespaces a method call on `rec` (a TribesSimObjects record) searches, in order.
static func make_namespaces(rec: Dictionary, datablocks: Dictionary) -> Array:
	var out := []
	var obj_name := String(rec.get("name", "")).to_lower()
	if obj_name != "":
		out.append(obj_name)
	var fields: Dictionary = rec.get("fields", {})
	for f in ["class", "superclass"]:
		var v := DarkstarScript.to_str(fields.get(f, "")).to_lower()
		if v != "" and not v in out:
			out.append(v)
	if rec.get("is_datablock", false):
		var cn := String((datablocks.get(obj_name, {}).get("fields", {}) as Dictionary).get("classname", "")).to_lower()
		if cn != "" and not cn in out:
			out.append(cn)
	for c in make_chain(String(rec.get("class", ""))):
		if not c in out:
			out.append(c)
	return out


## The parent:: links of every engine class, and of a datablock (name -> className -> class).
static func link_classes(vm: DarkstarScript) -> void:
	for c in PARENTS:
		vm.namespace_parents[c] = PARENTS[c]


static func link_datablock(vm: DarkstarScript, key: String, record: Dictionary) -> void:
	var type := String(record.get("type", "")).to_lower()
	var cn := String((record.get("fields", {}) as Dictionary).get("classname", "")).to_lower()
	if cn != "" and cn != key:
		vm.namespace_parents[key] = cn
		if not vm.namespace_parents.has(cn):
			vm.namespace_parents[cn] = type
	elif type != "":
		vm.namespace_parents[key] = type
