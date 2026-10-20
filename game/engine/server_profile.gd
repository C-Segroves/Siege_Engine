class_name ServerProfile
extends RefCounted
## The dedicated server's build profile: a collision-only world. The simulation needs hitboxes, terrain and
## structure collision, markers and cell states, not what the player sees, so the shared builders ask
## `is_collision_only()` at their few choke points (ShapeInstance materials and textures, MapTerrain meshes
## and textures) and skip the render-only work. One switch, no flag arguments: the dedicated server turns it
## on before it builds a world (DedicatedServer.start); a run that wants the full world leaves it off.

static var _collision_only := false


static func is_collision_only() -> bool:
	return _collision_only


static func set_collision_only(on: bool) -> void:
	_collision_only = on


## Switches a client-only node (HUD, plates, input views) off on a dedicated server: it keeps existing, so calls into it
## (show a message, add a chat line) still work, but it no longer processes, draws or handles input every frame.
static func apply_client_only(node: Node) -> void:
	if _collision_only:
		node.process_mode = Node.PROCESS_MODE_DISABLED
