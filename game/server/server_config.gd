class_name ServerConfig
extends RefCounted
## The settings of a dedicated server (--server): defaults, overridden by a JSON file (--config=<path>), overridden
## by command-line arguments (--key=value, "_" and "-" alike). deploy/server.json.example lists every key.

const DEFAULTS := {
	"name": "Siege Engine server",
	"port": Net.GAME_PORT,
	"bind": "*",
	"transport": Net.TRANSPORT_ENET,
	"max_players": Net.MAX_PLAYERS,
	"list_port": MatchListServer.DEFAULT_PORT,
	"password": "",
	"data_dir": "",
	"mode": "vs",
	"map": "",
	"game_mode": GameModes.DEFAULT,
	"bots": 0,
	"ai": 0,
	"max_bots": 0,   # cap on live AI soldiers + AI vehicles (BotBudget); 0 = no cap
	"frag_limit": MatchFlow.DEFAULT_FRAG_LIMIT,
	"time_limit_s": 0,
	"min_players": 1,
	"lobby_seconds": 20.0,
	"results_seconds": 20.0,
	"idle_abort_seconds": 60.0,
	"tick_hz": 0,   # 0: the game's NetProfile tick rate (ServerClock.DEFAULT_HZ until a battle starts)
	"max_catchup_steps": ServerClock.DEFAULT_MAX_CATCHUP_STEPS,
	"stats_seconds": 60.0,
	"master": "",         # a master server to list this server on (http://host:47710); empty = not listed
	"master_token": "",   # the master's auth_token, when it requires one
	# --- mode "extraction": one persistent raid on `map` (docs/SERVER_DEPLOY.md "Extraction servers")
	"relations": ExtractionFactions.DEFAULT_PRESET,   # the factions' relation preset (story, all_hostile, humans_allied)
	"raid_fast": 0,                 # 1: the short test timers of ExtractionRules (fast_timers)
	"raid_seed": 0,                 # the loot / squad seed of every world; 0 = a new one each time
	"raid_reset_minutes": 0,        # the world resets this long after it opened (new drop-ins pause until the last raider is out); 0 = never
	"raid_reset_grace_seconds": 300.0,   # raiders still in at the reset time get this long to extract before the world closes
	"raid_empty_seconds": 120.0,    # the world closes this long after the last raider left and nobody waits to drop in; 0 = it stays up
	"party_wait_seconds": 60.0,     # a party drops in together: its first built member waits this long for the rest to connect (those connected are always waited for)
	"results_hold_seconds": 5.0,    # an extracted / killed pilot sees his result this long before he leaves the raid
}
## The modes a dedicated server plays.
const MODES := ["vs", "coop", ExtractionRules.MODE]


## Defaults + the JSON file named by `--config=` + the other arguments.
static func load_from_args(args: PackedStringArray) -> Dictionary:
	return load_with(DEFAULTS, args)


## The same layering for any service's `defaults` (the master server uses it too).
static func load_with(defaults: Dictionary, args: PackedStringArray) -> Dictionary:
	var cfg := defaults.duplicate()
	var overrides := {}
	for a in args:
		if a.begins_with("--") and "=" in a:
			var kv := a.substr(2).split("=", true, 1)
			overrides[kv[0].replace("-", "_")] = kv[1]
	if overrides.has("config"):
		cfg.merge(read_json(str(overrides.config)), true)
	overrides.erase("config")
	for k in overrides:
		if cfg.has(k):
			cfg[k] = _coerce(overrides[k], cfg[k])
	return cfg


static func read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text()) if f else null
	if not data is Dictionary:
		push_error("server config %s is missing or not a JSON object" % path)
		return {}
	return data


static func _coerce(value: Variant, like: Variant) -> Variant:
	match typeof(like):
		TYPE_INT:
			return int(str(value))
		TYPE_FLOAT:
			return float(str(value))
	return str(value)


## The lobby settings (LobbySettings.make) of `cfg`; the map is matched by name or id against the map list.
static func make_settings(cfg: Dictionary) -> Dictionary:
	var mode := str(cfg.mode)
	var game_mode := str(cfg.game_mode)
	var s := LobbySettings.make({"mode": mode, "ai": int(cfg.ai), InfantryBots.CONFIG_KEY: int(cfg.bots),
		"game_mode": {"id": game_mode, "team_based": GameModes.is_team_based(game_mode)},
		"frag_limit": int(cfg.frag_limit), "world_idx": find_map_index(str(cfg.map)),
		"limits": {GameModes.TIME_LIMIT_KEY: int(cfg.time_limit_s)}, "relations": str(cfg.relations)})
	s["map"] = str(cfg.map)
	var entries := MapPicker.make_entries() if mode == ExtractionRules.MODE else []
	if int(s.world_idx) < entries.size():
		s["map"] = str(entries[int(s.world_idx)].name)   # the lobby and the lists name the map the way the host screen does
	s[BotBudget.CONFIG_KEY] = int(cfg.max_bots)
	return s


## Index of the first map entry whose name or id contains `wanted` (case-insensitive); 0 when none does.
static func find_map_index(wanted: String) -> int:
	if wanted == "":
		return 0
	var entries := MapPicker.make_entries()
	for i in entries.size():
		if wanted.to_lower() in str(entries[i].name).to_lower() or wanted == str((entries[i].config as Dictionary).get("map", "")):
			return i
	push_warning("server: no map matches '%s'; using the first" % wanted)
	return 0
