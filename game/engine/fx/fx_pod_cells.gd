class_name FxPodCells
extends RefCounted
## Battledrome pods have no muzzle flash: a shot steps the hardpoint's baked pod cells through their firing
## states, one per frame time, then back to idle (render prep SIM 0x7904; weapon fx `pod_cell_states`,
## docs/formats/weapon_fx.md section 4). Damaged / destroyed pods keep their damage state.


## Plays the firing states of the weapon on hardpoint `mount_index` of `vehicle` (a Herc with a ShapeInstance).
static func play(vehicle: Node3D, def: Dictionary, mount_index: int) -> void:
	var states = FxLibrary.weapon_fx(def).get("pod_cell_states")
	var shape: ShapeInstance = vehicle.get("shape")
	var vdef: Dictionary = vehicle.get("def") if vehicle.get("def") is Dictionary else {}
	if not (states is Dictionary) or shape == null or str(vdef.get("pack", "")) != FxLibrary.weapon_pack(def):
		return
	var guns: Array = vdef.get("guns", [])
	if mount_index < 0 or mount_index >= guns.size():
		return
	var cells: Array = guns[mount_index].get("pod_cells", [])
	var idle := int(states.get("idle", 0))
	var live := cells.filter(func(ci): return shape.get_cell_state(int(ci)) == idle)
	if live.is_empty():
		return
	var firing: Array = states.get("firing", [])
	var ours := [idle] + firing.map(func(f): return int(f))
	var tw := vehicle.create_tween()
	for state in firing:
		tw.tween_callback(_apply_state.bind(shape, live, int(state), ours))
		tw.tween_interval(float(states.get("frame_time", 0.1)))
	tw.tween_callback(_apply_state.bind(shape, live, idle, ours))


## Sets `state` on the cells still showing one of `ours` (a pod damaged meanwhile keeps its damage state).
static func _apply_state(shape: ShapeInstance, cells: Array, state: int, ours: Array) -> void:
	if not is_instance_valid(shape):
		return
	for ci in cells:
		if shape.get_cell_state(int(ci)) in ours:
			shape.set_cell_state(int(ci), state)
