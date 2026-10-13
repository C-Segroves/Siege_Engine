class_name TribesPowerGrid
extends RefCounted
## Which power groups of a Tribes map have power (docs/TRIBES_BASE_EQUIPMENT.md section 2). A map's
## "power_groups" are its mission's SimGroups ({name, parent index, provides_power}); every base object sits in
## one. A working generator powers its own group and every group below it, as both games do it:
##   Tribes 1  GameBase::generatePower (tribes.exe 0x41e19c -> 0x44417c) walks the generator's group and its
##             subgroups, counting power up or down on every shape; GameBase::isPowered = count > 0;
##   Tribes 2  SimGroup::powerInit / updatePowerCount (scripts/power.cs): a group's powerCount is its parent's
##             plus its own powering generators (Generator::isPowering: not disabled) and providesPower.

var _parents: Array[int] = []
var _provides: Array[bool] = []


## The grid of a loaded map.json (no groups: nothing is powered by a group).
static func make_for(map_data: Dictionary) -> TribesPowerGrid:
	var g := TribesPowerGrid.new()
	for entry in map_data.get("power_groups", []):
		g._parents.append(int((entry as Dictionary).get("parent", -1)))
		g._provides.append(bool((entry as Dictionary).get("provides_power", false)))
	return g


func group_count() -> int:
	return _parents.size()


## {group index: true} for every powered group, given the groups holding a working generator.
func make_powered_groups(source_groups: Array) -> Dictionary:
	var sources := {}
	for g in source_groups:
		sources[int(g)] = true
	for i in _provides.size():
		if _provides[i]:
			sources[i] = true
	var out := {}
	for i in _parents.size():
		if _has_source_above(i, sources):
			out[i] = true
	return out


func _has_source_above(group: int, sources: Dictionary) -> bool:
	var g := group
	var steps := 0
	while g >= 0 and g < _parents.size() and steps <= _parents.size():
		if sources.has(g):
			return true
		g = _parents[g]
		steps += 1
	return false
