extends LauncherScreen
## The training missions of Tribes or Tribes 2 (args "pack"; TribesMissionRuntime.list_missions): pick one, read
## its briefing, start it. The player starts on foot in the mission's armour; the match ends on the results
## screen as every battle does.

const PACK_TITLES := {"tribes": "Tribes training", "tribes2": "Tribes 2 training"}

var _pack := ""
var _missions: Array = []
var _picker: OptionButton
var _briefing: Label


func open(args: Dictionary) -> void:
	var pack := str(args.get("pack", "tribes"))
	_pack = pack
	set_page_title(str(PACK_TITLES.get(pack, "training")).to_lower())
	set_back("Back", router.back)
	_missions = TribesMissionRuntime.list_missions(pack)
	content.add_child(Widgets.label(str(PACK_TITLES.get(pack, "Training")), "HeaderLabel"))
	if _missions.is_empty():
		content.add_child(Widgets.paragraph("No training missions installed - import the disc again.", "DimLabel"))
		return
	set_primary("Start training", _start)
	_picker = Widgets.option_button(_missions.map(func(e: Dictionary) -> String:
		return "%d. %s" % [int(e.get("order", 0)), str(e.get("name", e.get("id", "")))]))
	_picker.item_selected.connect(_show_briefing)
	content.add_child(OptionRow.new("Mission", _picker))
	content.add_child(Widgets.section("Briefing"))
	_briefing = Widgets.paragraph("")
	content.add_child(_briefing)
	_show_briefing(0)


func _show_briefing(i: int) -> void:
	_briefing.text = str(_missions[i].get("briefing", ""))


func _start() -> void:
	var e: Dictionary = _missions[_picker.selected]
	var mission_name := "%s:%s" % [_pack, str(e.get("id", ""))]
	launcher().start_battle({"mode": "mission", "mission_name": mission_name, "respawn": false,
		"roster": MatchFlow.make_solo_roster(str(e.get("armor", "")), [])})
