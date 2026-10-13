class_name CockpitEye
extends RefCounted
## Where a game puts the pilot's eye, when its data says so (docs/formats/cockpit.md section 9). Starsiege
## (tools/starsiege_hud.py EYE_RULES, Starsiege.exe 0x4a33c6 / 0x471520): the first of the shape nodes
## "cam", "camera", "cockpit", "head0" (Hercs; tanks and flyers: "cockpit", "head0") plus the vehicle's
## hercCpit / tankCpit / flyerCpit offset (x right, y forward, z up, metres) in that node's frame. In the
## first-person view the original shows the shape's cockpit interior objects ("cockpit", "cockpit1",
## "cockpit2": Seq07_cockpit / Seq01_cockpit, 0x481fc0) and hides the head; the remake shows those meshes to
## the cockpit camera. Other games: {} (BattleCameras.make_eye_position over the cockpit node).

const HERC_EYE_NODES := ["cam", "camera", "cockpit", "head0"]
const VEHICLE_EYE_NODES := ["cockpit", "head0"]
const INTERIOR_PREFIX := "cockpit"


## {node, position} of `h`'s original eye point, or {} when its game has none in the data.
static func make_mount(h: Herc) -> Dictionary:
	var cpit = h.def.get("ss_raw", {}).get("cpit") if h.def.get("ss_raw") is Dictionary else null
	if not (cpit is Array) or h.shape == null:
		return {}
	var names: Array = HERC_EYE_NODES if str(h.def.get("kind", "herc")) == "herc" else VEHICLE_EYE_NODES
	for want in names:
		var i := _find_node(h.shape, str(want))
		if i >= 0:
			return {"node": h.shape.nodes[i], "position": ShapeInstance.es_to_godot(cpit)}
	return {}


static func _find_node(s: ShapeInstance, want: String) -> int:
	var list: Array = s.shape.get("nodes", [])
	for i in mini(list.size(), s.nodes.size()):
		if str(list[i].get("name", "")).to_lower() == want:
			return i
	return -1


## The cockpit interior meshes of `h` (the pieces on its "cockpit*" nodes); [] for shapes without them.
static func make_interior_meshes(h: Herc) -> Array:
	if h.shape == null or make_mount(h).is_empty():
		return []
	var out := []
	var list: Array = h.shape.shape.get("nodes", [])
	for i in mini(list.size(), h.shape.nodes.size()):
		if str(list[i].get("name", "")).to_lower().begins_with(INTERIOR_PREFIX):
			for c in h.shape.nodes[i].get_children():
				if c is MeshInstance3D:
					out.append(c)
	return out
