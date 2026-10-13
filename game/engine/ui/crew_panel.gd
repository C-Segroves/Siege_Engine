class_name CrewPanel
extends VBoxContainer
## The Hangar screen's Crew tab, the same for every campaign (docs/formats/campaign_availability.md
## section 8): who flies each garage Herc, which of them go along as wingmen next mission (up to the
## mission's slots), the pilot roster with skill, missions and kills, the losses and the last mission's
## report. All rules are SquadRoster's; this only shows them.
##   CrewPanel.new(garage, wingman_slots, player_name)
##   changed()                  after every assignment / wingman change (the screen saves)

signal changed

const NO_SLOTS := "The missions of this campaign bring their own squadmates; no garage Herc flies as a wingman."
const NO_CREW := "No crew: this campaign has no pilot roster."
const SLOTS_TEXT := "Wingmen next mission: %d of %d slots."
const PLAYER_HERC := "%s  -  your Herc"
const WINGMAN := "Wingman"
const IN_FACTORY := "in the factory"
const LOSSES_TEXT := "Losses: %d  (%s)"
const NO_LOSSES := "Losses: none"

var garage: Garage
var slots := 0
var player_name := ""


func _init(p_garage: Garage, p_slots: int, p_player_name: String) -> void:
	garage = p_garage
	slots = p_slots
	player_name = p_player_name
	refresh()


## Rebuilds the panel from the garage.
func refresh() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	if garage.crew.is_empty():
		add_child(Widgets.paragraph(NO_CREW, "DimLabel"))
		return
	add_child(Widgets.section("Squad"))
	var squad := SquadRoster.make_squad(garage, slots)
	add_child(Widgets.paragraph(SLOTS_TEXT % [squad.size(), slots] if slots > 0 else NO_SLOTS, "DimLabel"))
	for i in garage.vehicles.size():
		add_child(_build_herc_row(i, squad.has(i)))
	add_child(Widgets.section("Pilots"))
	for p in garage.crew.pilots:
		add_child(Widgets.label(_make_roster_line(p)))
	add_child(Widgets.paragraph(_make_losses_text(), "DimLabel"))
	var report := make_report_text(garage.last_report)
	if report != "":
		add_child(Widgets.section("Last mission"))
		add_child(Widgets.paragraph(report, "DimLabel"))


## One garage Herc: its name, the pilot picker and the wingman box (the player's own Herc: his name).
func _build_herc_row(i: int, is_wingman: bool) -> Control:
	var e: Dictionary = garage.vehicles[i]
	var title := GaragePicker.make_entry_name(e)
	if i == garage.selected:
		return OptionRow.new(PLAYER_HERC % title, Widgets.label(player_name, "DimLabel"))
	var pilots: Array = [{}] + garage.crew.pilots
	var picker := Widgets.option_button(pilots.map(func(p): return SquadRoster.NO_PILOT if p.is_empty() else str(p.name)),
		maxi(0, pilots.find(SquadRoster.pilot_of(garage, i))))
	picker.item_selected.connect(func(k: int) -> void: _assign(i, str(pilots[k].get("id", ""))))
	var wing := Widgets.check_box(WINGMAN, is_wingman)
	wing.disabled = slots <= 0 or not SquadRoster.is_eligible(garage, i)
	wing.toggled.connect(func(_on: bool) -> void: _toggle_wingman(i))
	var row := OptionRow.new(title + ("" if Garage.is_ready(e) else "  (%s)" % IN_FACTORY), Widgets.row([picker, wing]))
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row


func _assign(i: int, pilot_id: String) -> void:
	SquadRoster.apply_assign(garage, i, pilot_id)
	_after_change()


func _toggle_wingman(i: int) -> void:
	SquadRoster.apply_toggle_wingman(garage, i, slots)
	_after_change()


func _after_change() -> void:
	refresh.call_deferred()
	changed.emit()


## "DUGGAN  -  skill 57, 3 missions, 2 kills  -  flies Lucky (Raptor)".
func _make_roster_line(p: Dictionary) -> String:
	var i := SquadRoster.herc_of_pilot(garage, str(p.id))
	var seat := "flies %s" % GaragePicker.make_entry_name(garage.vehicles[i]) if i >= 0 else "no Herc"
	return "%s  -  %s" % [Crew.make_pilot_label(p), seat]


func _make_losses_text() -> String:
	if garage.crew.losses() == 0:
		return NO_LOSSES
	return LOSSES_TEXT % [garage.crew.losses(), ", ".join(PackedStringArray(garage.crew.fallen.map(func(p): return str(p.name))))]


## "Salvage +42 t. Written off: Lucky. Killed: RIGGS (replaced by BRECKER)." ("" = nothing to say).
static func make_report_text(report: Dictionary) -> String:
	var parts: PackedStringArray = []
	if int(report.get("salvage_kg", 0)) > 0:
		parts.append("Salvage +%s." % GarageEconomy.make_tons_text(int(report.salvage_kg)))
	if not (report.get("written_off", []) as Array).is_empty():
		parts.append("Written off: %s." % ", ".join(PackedStringArray(report.written_off)))
	var killed: Array = report.get("killed", [])
	var replaced: Array = report.get("replaced", [])
	for k in killed.size():
		parts.append("Killed: %s (replaced by %s)." % [killed[k], replaced[k] if k < replaced.size() else "-"])
	return " ".join(parts)
