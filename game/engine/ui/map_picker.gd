class_name MapPicker
extends OptionRow
## Labelled battlefield chooser ("Map"): the Earthsiege worlds (terrain x time of day; the es1 pack's maps), Battledrome arenas
## (when installed) and every pack map from MapBuilder.list_maps(). Each entry carries the battle
## config keys it sets ("world"/"zone", "arena" or "map").
##   selected_index() / select_index(i) / selected_name() / selected_config() / selected_entry()
##   map_changed(index)        the player (or select_index) picked another entry
##   MapPicker.config_at(i)    the config of entry i (the lobby stores only the index)
## An entry is {name, config, index}: "index" is the map's row of its pack's maps/_index.json (game modes, spawns;
## {"pack": ...} for the Earthsiege worlds and Battledrome arenas).

signal map_changed(index: int)

## Earthsiege worlds: name, world index (terrain * 6 + lighting * 2).
const WORLDS := [
	["Desert - day", 0], ["Desert - dusk", 2], ["Desert - night", 4],
	["Temperate - day", 6], ["Temperate - dusk", 8], ["Temperate - night", 10],
	["Ice - day", 12], ["Ice - dusk", 14], ["Ice - night", 16],
	["Urban - day", 18], ["Urban - dusk", 20], ["Urban - night", 22],
]
const WORLDS_PER_TERRAIN := 6
## The game whose maps head the list (and whose built-in worlds stand in when it has no map files).
const FIRST_PACK := "es1"
## ES1 mission zone ids per terrain (desert, temperate, ice, urban).
const ZONE_FOR_TERRAIN := [0, 1000, 1100, 1500]
## Battledrome arena sizes (ARENA.DAT order, size index = position + 1).
const ARENAS := ["MINI", "SMALL", "MED", "LARGE", "HUGE"]
const ARENA_DEFAULTS := {"obstacles": "SEVERAL", "turrets": "FEW", "lighting": "BRIGHT"}

var _options: OptionButton
var _entries: Array = []
var _shown: Array = []      # the entry indices the drop-down lists (all of them unless set_allowed narrowed it)


func _init(label_text := "World") -> void:
	super(label_text)
	_entries = make_entries()
	_options = Widgets.option_button([])
	set_control(_options)
	set_allowed(range(_entries.size()))
	_options.item_selected.connect(func(i: int) -> void: map_changed.emit(int(_shown[i])))


## The entry index of the selected map (not its row in a narrowed list), -1 when the list is empty.
func selected_index() -> int:
	return int(_shown[_options.selected]) if _options.selected >= 0 and _options.selected < _shown.size() else -1


## The entry indices the drop-down lists.
func shown_indices() -> Array:
	return _shown.duplicate()


## Selects entry `i` (an entry index); ignored when the list does not show it.
func select_index(i: int) -> void:
	var row := _shown.find(i)
	if row >= 0:
		_options.select(row)
		map_changed.emit(i)


## Narrows the drop-down to the entry indices `allowed` (the maps a game mode can be played on), keeping the selected map
## when it is still listed. Emits nothing.
func set_allowed(allowed: Array) -> void:
	var keep := selected_index()
	if allowed == _shown and _options.item_count == _shown.size():
		return
	_shown = allowed.duplicate()
	_options.clear()
	for i in _shown:
		_options.add_item(str(_entries[int(i)].name))
	_options.disabled = _shown.is_empty()
	if not _shown.is_empty():
		_options.select(maxi(_shown.find(keep), 0))


func selected_name() -> String:
	return str(_entries[selected_index()].name) if selected_index() >= 0 else ""


func selected_config() -> Dictionary:
	return config_at(selected_index())


## The selected entry {name, config, index}.
func selected_entry() -> Dictionary:
	return _entries[selected_index()] if selected_index() >= 0 else {}


static func config_at(i: int) -> Dictionary:
	var entries := make_entries()
	if i < 0 or i >= entries.size():
		push_error("MapPicker: no map entry %d" % i)
		return _world_config(WORLDS[0][1])
	return (entries[i].config as Dictionary).duplicate(true)


## Every entry in menu order, each named "<game> map - <map>": {name, config, index}. The Earthsiege worlds come
## first; they are the es1 pack's maps (with their game mode spawns) when it has them, else the built-in WORLDS
## (only with Earthsiege installed: they are built from its terrain).
static func make_entries() -> Array:
	var out := []
	var maps := MapBuilder.list_maps()
	var has_es1_maps := maps.any(func(m: Dictionary) -> bool: return m.pack == FIRST_PACK)
	if not has_es1_maps and Assets.has_pack(FIRST_PACK):   # the built-in worlds are Earthsiege's terrain
		for w in WORLDS:
			out.append({"name": "%s map - %s" % [Packs.pack_name(FIRST_PACK), w[0]], "config": _world_config(w[1]),
				"index": {"pack": FIRST_PACK}})
	var first := maps.filter(func(m: Dictionary) -> bool: return m.pack == FIRST_PACK)
	for m in first:
		out.append(_make_map_entry(m))
	if Assets.has_pack("bd"):
		for i in ARENAS.size():
			var arena := ARENA_DEFAULTS.duplicate()
			arena["size"] = i + 1
			out.append({"name": "Battledrome arena - %s" % ARENAS[i], "config": {"arena": arena, "respawn": true},
				"index": {"pack": "bd"}})
	for m in maps:
		if m.pack != FIRST_PACK:
			out.append(_make_map_entry(m))
	return out


static func _make_map_entry(m: Dictionary) -> Dictionary:
	return {"name": "%s map - %s" % [Packs.pack_name(m.pack), m.get("name", m.id)],
		"config": {"map": m.id, "respawn": true}, "index": m}


static func _world_config(world: int) -> Dictionary:
	return {"world": world, "zone": ZONE_FOR_TERRAIN[world / WORLDS_PER_TERRAIN]}
