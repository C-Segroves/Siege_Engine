extends RoutedScreen
## Results of the match just played (MatchResults.summary, see BattleSummary): headline and winner,
## the end message, the match time, a table of every pilot's kills / deaths / score, a won mission's
## salvage, then Continue (primary, also menu_back) and Rematch where the mode offers one.

const COLUMNS := ["PILOT", "VEHICLE", "TEAM", "KILLS", "DEATHS", "SCORE"]
const SECONDS_PER_MINUTE := 60
const CLIENT_WAIT := "The host can start a rematch; Continue returns to the lobby."


func open(_args: Dictionary) -> void:
	var s := _summary()
	set_page_title("results")
	focus_primary_first = true
	set_primary("Continue", (router as MatchResults).continue_to_front_end)
	content.add_child(Widgets.label(str(s.get("headline", "")), "HeaderLabel"))
	if str(s.get("text", "")) != "":
		content.add_child(Widgets.paragraph(str(s.text)))
	content.add_child(Widgets.label(make_details_text(s), "DimLabel"))
	content.add_child(Widgets.section("Pilots"))
	content.add_child(_build_pilot_table(s.get("pilots", [])))
	if bool(s.get("campaign", false)):
		_add_salvage(s.get("salvage", []))
	_add_rematch()


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event):
		get_viewport().set_input_as_handled()
		(router as MatchResults).continue_to_front_end()


func _summary() -> Dictionary:
	return (router as MatchResults).summary


## "Winner: X  -  time 3:07  -  enemies destroyed 4".
static func make_details_text(s: Dictionary) -> String:
	var parts: PackedStringArray = []
	if str(s.get("winner", "")) != "":
		parts.append("Winner: %s" % s.winner)
	parts.append("Time %s" % make_time_text(float(s.get("seconds", 0.0))))
	if int(s.get("enemies_destroyed", 0)) > 0:
		parts.append("Enemies destroyed: %d" % int(s.enemies_destroyed))
	return "  -  ".join(parts)


## 187.4 -> "3:07".
static func make_time_text(seconds: float) -> String:
	var whole := int(seconds)
	return "%d:%02d" % [whole / SECONDS_PER_MINUTE, whole % SECONDS_PER_MINUTE]


static func _build_pilot_table(pilots: Array) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = COLUMNS.size()
	for heading in COLUMNS:
		grid.add_child(Widgets.label(heading, "DimLabel"))
	for p in pilots:
		for cell in [p.name, p.vehicle, int(p.team) + 1, p.kills, p.deaths, p.score]:
			grid.add_child(Widgets.label(str(cell), "" if bool(p.get("player", false)) else "DimLabel"))
	return grid


func _add_salvage(names: Array) -> void:
	content.add_child(Widgets.section("Salvage recovered"))
	var text := ", ".join(PackedStringArray(names)) if not names.is_empty() else "none"
	content.add_child(Widgets.paragraph(text))


func _add_rematch() -> void:
	var results := router as MatchResults
	if results.can_rematch():
		content.add_child(Widgets.button("Rematch", results.rematch))
	elif bool(_summary().get("rematch", false)) and Net.is_online():
		content.add_child(Widgets.paragraph(CLIENT_WAIT, "DimLabel"))
