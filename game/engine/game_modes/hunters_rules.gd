class_name HuntersRules
extends GameModeRules
## Hunters and Team Hunters (Tribes 2 HuntersGame.cs, TeamHuntersGame.cs):
##   * everybody carries his own flag; a killed player drops all the flags he carried plus his own (Team Hunters: a
##     suicide or team kill drops only the carried ones), in denominations of 1, 2, 4 and 8 (make_drop_values);
##   * touching a dropped flag picks it up (its value); dropped flags fade after flag_life_s;
##   * touching the Nexus banks the flags carried: n flags score n(n+1)/2 (triangular), for the player or, in Team
##     Hunters, his team; greed_mode needs at least greed_min_flags to bank;
##   * kills score score_per_kill; the best score at the time limit wins (no score limit unless score_limit);
##   * hoard mode: no banking from hoard_start_min to hoard_start_min - hoard_duration_min minutes before the end
##     (only in games of at least HOARD_MIN_TIME_LIMIT_MIN minutes); a Nexus touch is answered once per
##     BANK_GUARD_SECONDS (Nexus::onCollision);
##   * camping (CampingDamage): camping_s inside the Nexus trigger warns, another half of it warns again, then the
##     camper takes camping_damage of his health every second until he leaves (request "damage");
##   * the player carrying more than hoarder_min flags is shown to everybody (the hoarder waypoint).

## make_drop_values: up to this many flags of each small denomination before larger ones are used.
const DENOMINATIONS := [1, 2, 4]
const MAX_PER_DENOMINATION := 5
const LARGEST_DENOMINATION := 8
const DROP_SPREAD_M := 2.5

## HuntersGame.cs: hoard mode is off in games shorter than this (minutes).
const HOARD_MIN_TIME_LIMIT_MIN := 6.0
const BANK_GUARD_SECONDS := 5.0
const CAMPING_TICK_SECONDS := 1.0

var carried := {}        # player key -> flags carried (not counting his own)
var _bank_guard := {}    # player key -> elapsed when the Nexus answers him again
var _camping := {}       # player key -> seconds inside the Nexus trigger
var _camping_tick := {}  # player key -> seconds to the next camping damage
var _next_id := 1


func _on_setup() -> void:
	for id in objects:
		_next_id = maxi(_next_id, int(id) + 1)


func apply_touch(player: Dictionary, object_id: int) -> void:
	var o: ModeObject = objects.get(object_id)
	if over or o == null or not bool(player.get("can_touch", true)) or not bool(player.get("alive", true)):
		return
	if o.kind == ModeObject.KIND_HUNTER_FLAG and o.state == ModeObject.DROPPED:
		carried[str(player.key)] = int(carried.get(str(player.key), 0)) + int(o.value)
		objects.erase(o.id)
		_changed()
	elif o.kind == ModeObject.KIND_NEXUS:
		_bank(player)


func _bank(player: Dictionary) -> void:
	var key := str(player.key)
	var n := int(carried.get(key, 0))
	if n <= 0 or elapsed < float(_bank_guard.get(key, 0.0)):
		return
	_bank_guard[key] = elapsed + BANK_GUARD_SECONDS
	if is_hoard_time():
		announce("Hoard mode: the Nexus takes no flags now.")
		return
	if bool(settings.get("greed_mode", false)) and n < int(_num("greed_min_flags", 8.0)):
		announce("%s needs %d flags to bank (greed mode)." % [key, int(_num("greed_min_flags", 8.0))])
		return
	var points := make_bank_points(n)
	carried[key] = 0
	if team_based:
		score.add_team(int(player.team), points)
	else:
		score.add_player(key, points)
	announce("%s banked %d flags for %d points." % [key, n, int(points)])
	_changed()
	if team_based:
		check_team_limit(int(player.team))
	else:
		check_player_limit(key)


## Triangular banking (HuntersGame.cs Nexus::onCollision): n flags -> n(n+1)/2 points.
static func make_bank_points(n: int) -> float:
	return n * (n + 1) / 2.0


func _on_kill(victim: Dictionary, killer: Dictionary) -> void:
	var key := str(victim.get("key", ""))
	var n := int(carried.get(key, 0))
	var feeding := team_based and (GameModeRules.is_suicide(victim, killer) or is_teamkill(victim, killer))
	if not feeding:
		n += 1                       # his own flag
	carried[key] = 0
	var values := make_drop_values(n)
	for i in values.size():
		_add_dropped(values[i], victim.pos + _make_offset(i, values.size()))
	if n >= 10:
		announce("%s dropped %d flags!" % [key, n])


## Flag denominations for `n` flags: up to 5 of 1, then of 2, then of 4, the rest in 8s (HuntersGame.cs throwFlags).
static func make_drop_values(n: int) -> Array:
	var out := []
	var left := n
	for v in DENOMINATIONS:
		var k := 0
		while left >= v and k < MAX_PER_DENOMINATION:
			out.append(v)
			left -= v
			k += 1
	while left >= LARGEST_DENOMINATION:
		out.append(LARGEST_DENOMINATION)
		left -= LARGEST_DENOMINATION
	for v in [4, 2, 1]:
		while left >= v:
			out.append(v)
			left -= v
	return out


static func _make_offset(i: int, count: int) -> Vector3:
	var a := TAU * i / maxi(count, 1)
	return Vector3(cos(a), 0.5, sin(a)) * DROP_SPREAD_M


func _add_dropped(value: int, at: Vector3) -> void:
	var o := ModeObject.new()
	o.id = _next_id
	_next_id += 1
	o.kind = ModeObject.KIND_HUNTER_FLAG
	o.value = value
	o.home = at
	o.pos = at
	o.state = ModeObject.DROPPED
	o.timer = _num("flag_life_s", 60.0)
	objects[o.id] = o


## True during the hoard period (hoard_mode).
func is_hoard_time() -> bool:
	var limit := _num("time_limit_s", 0.0)
	if not bool(settings.get("hoard_mode", false)) or limit < HOARD_MIN_TIME_LIMIT_MIN * SECONDS_PER_MINUTE:
		return false
	var left := (limit - elapsed) / SECONDS_PER_MINUTE
	var start := _num("hoard_start_min", 5.0)
	return left <= start and left > start - _num("hoard_duration_min", 3.0)


func _apply_camping(delta: float) -> void:
	var limit := _num("camping_s", 0.0)
	var zones := objects_of(ModeObject.KIND_NEXUS_ZONE)
	if limit <= 0.0 or zones.is_empty():
		return
	for p in players.values():
		var key := str(p.key)
		if not bool(p.get("alive", true)) or not zones.any(func(z: ModeObject) -> bool: return z.is_touched_at(p.pos, 0.0)):
			_camping.erase(key)
			continue
		var before := float(_camping.get(key, 0.0))
		var now := before + delta
		_camping[key] = now
		if before < limit and now >= limit:
			announce("%s: you are camping near the Nexus." % make_label(key))
		if before < limit * 1.5 and now >= limit * 1.5:
			announce("%s: no camping near the Nexus." % make_label(key))
		if now >= limit * 2.0:
			_camping_tick[key] = float(_camping_tick.get(key, 0.0)) - delta
			if float(_camping_tick[key]) <= 0.0:
				_camping_tick[key] = CAMPING_TICK_SECONDS
				requests.append({"kind": "damage", "id": int(p.id), "share": _num("camping_damage", 0.075)})


## The player carrying the most flags when above hoarder_min ("" none).
func make_hoarder_key() -> String:
	var best := ""
	var most := int(_num("hoarder_min", 0.0))
	if most <= 0:
		return ""
	for k in carried:
		if int(carried[k]) > most:
			most = int(carried[k])
			best = str(k)
	return best


func _on_tick(delta: float) -> void:
	_apply_camping(delta)
	for o in objects_of(ModeObject.KIND_HUNTER_FLAG):
		o.timer -= delta
		if o.timer <= 0.0:
			objects.erase(o.id)
			_changed()


func make_extra_state() -> Dictionary:
	return {"carried": carried.duplicate(), "next_id": _next_id}


func apply_extra_state(d: Dictionary) -> void:
	carried = d.get("carried", {}).duplicate()
	_next_id = int(d.get("next_id", _next_id))


func make_hud_lines(viewer: Dictionary) -> PackedStringArray:
	var lines := super(viewer)
	if not viewer.is_empty():
		lines.append("Flags carried: %d" % int(carried.get(str(viewer.key), 0)))
	var hoarder := make_hoarder_key()
	if hoarder != "":
		lines.append("Flag hoarder: %s (%d flags)" % [hoarder, int(carried[hoarder])])
	if is_hoard_time():
		lines.append("Hoard mode: no banking")
	return lines
