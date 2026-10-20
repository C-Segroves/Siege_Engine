class_name TeamsSheet
extends ModalSheet
## "Adjust teams": the existing TeamList (columns of teams, pilots and bots; the host moves anyone, Assign all, Shuffle)
## in a sheet over the lobby. It forwards the list's signals; the lobby refreshes it when the roster changes.

signal team_chosen(peer: int, team: int)
signal member_team_chosen(key: String, team: int)
signal assign_all_requested
signal shuffle_requested

var list: TeamList
var scroll: ScrollContainer


static func show_over(host: Control) -> TeamsSheet:
	var sheet := TeamsSheet.new()
	sheet.set_title("ADJUST TEAMS")
	sheet._return_focus = host.get_viewport().gui_get_focus_owner()
	host.add_child(sheet)
	sheet._build()
	return sheet


func _build() -> void:
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	body.add_child(scroll)
	list = TeamList.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.team_chosen.connect(func(peer: int, team: int) -> void: team_chosen.emit(peer, team))
	list.member_team_chosen.connect(func(key: String, team: int) -> void: member_team_chosen.emit(key, team))
	list.assign_all_requested.connect(func() -> void: assign_all_requested.emit())
	list.shuffle_requested.connect(func() -> void: shuffle_requested.emit())
	scroll.add_child(list)
	set_back("Back")
	set_primary("Done", close)


func refresh(settings: Dictionary, roster: Dictionary, my_id: int, is_host: bool) -> void:
	list.refresh(settings, roster, my_id, is_host)
