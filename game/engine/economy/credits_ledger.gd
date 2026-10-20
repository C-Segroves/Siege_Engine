class_name CreditsLedger
extends RefCounted
## What a match pays (docs/design/lobby_loadout_economy.md sections 2.5 and 7.2): the host turns a pilot's match stats
## into an award {total, lines: [{text, amount}]} from the mode's earn row (EconomyRules). Pure: nothing is paid here,
## OperatorProfile.apply_award does that on the owner's machine.
## stats: {seconds, kills, bot_kills, vehicle_kills, assists, objectives, won, extracted_value}. Bot kills pay
## bot_kill_factor of a kill. A match shorter than min_match_s pays nothing. The rate part is capped (cap 0 = no cap),
## a pilot who left early gets left_early_factor of it; goals are paid on top. Extraction pays what the raid carried
## out (extracted_value: loot, money, task rewards) plus on_extract when he got out; its tasks are in that value.

const SECONDS_PER_MINUTE := 60


static func make_award(mode_key: String, stats: Dictionary, goals_done: Array, left_early: bool) -> Dictionary:
	var row := EconomyRules.make_earn_row(mode_key)
	var is_raid := mode_key == EconomyRules.EXTRACTION_KEY
	var lines := []
	if is_raid:
		_add_raid_lines(lines, row, stats)
	elif _is_paid(row) and float(stats.get("seconds", 0.0)) >= float(EconomyRules.earn().get("min_match_s", 0)):
		_add_rate_lines(lines, row, stats, left_early)
		_add_goal_lines(lines, goals_done)
	return {"total": maxi(_sum(lines), 0), "lines": lines}


## True when the mode pays anything per match (solo modes do not).
static func _is_paid(row: Dictionary) -> bool:
	return ["per_minute", "per_kill", "per_vehicle_kill", "per_assist", "per_objective", "win_bonus", "loss_bonus"].any(
		func(key: String) -> bool: return int(row.get(key, 0)) > 0)


static func _add_raid_lines(lines: Array, row: Dictionary, stats: Dictionary) -> void:
	_add_line(lines, "Carried out", int(stats.get("extracted_value", 0)))
	if bool(stats.get("won", false)):
		_add_line(lines, "Extraction bonus", int(row.get("on_extract", 0)))


static func _add_rate_lines(lines: Array, row: Dictionary, stats: Dictionary, left_early: bool) -> void:
	var rate_lines := []
	var minutes := int(float(stats.get("seconds", 0.0)) / SECONDS_PER_MINUTE)
	_add_count_line(rate_lines, "Time", minutes, int(row.get("per_minute", 0)), "min")
	_add_count_line(rate_lines, "Kills", int(stats.get("kills", 0)), int(row.get("per_kill", 0)), "")
	var bot_rate := int(round(float(row.get("per_kill", 0)) * float(EconomyRules.earn().get("bot_kill_factor", 1.0))))
	_add_count_line(rate_lines, "Bot kills", int(stats.get("bot_kills", 0)), bot_rate, "")
	_add_count_line(rate_lines, "Vehicle kills", int(stats.get("vehicle_kills", 0)), int(row.get("per_vehicle_kill", 0)), "")
	_add_count_line(rate_lines, "Assists", int(stats.get("assists", 0)), int(row.get("per_assist", 0)), "")
	_add_count_line(rate_lines, "Objectives", int(stats.get("objectives", 0)), int(row.get("per_objective", 0)), "")
	_add_line(rate_lines, "Victory" if bool(stats.get("won", false)) else "Defeat",
		int(row.get("win_bonus" if bool(stats.get("won", false)) else "loss_bonus", 0)))
	var cap := int(row.get("cap", 0))
	if cap > 0 and _sum(rate_lines) > cap:
		_add_line(rate_lines, "Match cap", cap - _sum(rate_lines))
	if left_early:
		var factor := float(EconomyRules.earn().get("left_early_factor", 1.0))
		_add_line(rate_lines, "Left early (x%s)" % str(factor), int(round(_sum(rate_lines) * factor)) - _sum(rate_lines))
	lines.append_array(rate_lines)


static func _add_goal_lines(lines: Array, goals_done: Array) -> void:
	for g in goals_done:
		_add_line(lines, "Goal: %s" % str(g.get("text", g.get("id", "?"))), int(g.get("reward", 0)))


static func _add_count_line(lines: Array, label: String, count: int, rate: int, unit: String) -> void:
	if count > 0 and rate > 0:
		_add_line(lines, "%s %d%s x %d" % [label, count, " " + unit if unit != "" else "", rate], count * rate)


static func _add_line(lines: Array, text: String, amount: int) -> void:
	if amount != 0:
		lines.append({"text": text, "amount": amount})


static func _sum(lines: Array) -> int:
	var total := 0
	for l in lines:
		total += int(l.amount)
	return total
