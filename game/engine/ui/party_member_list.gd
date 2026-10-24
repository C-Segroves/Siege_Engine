class_name PartyMemberList
extends VBoxContainer
## The members of the party, one row each: name, leader mark, ready state, the operator summary line (armour, kit, credits),
## and the leader's Remove button. Rows are built when the members change and only their texts are updated while the same
## members stay (a poll every second must not take the focus away).
##   refresh(view)       view: PartyClient.view
## `kick_requested(member_id)` is the leader's Remove.

signal kick_requested(member_id: int)

const READY_TEXT := "READY"
const NOT_READY_TEXT := "not ready"
const AWAY_TEXT := "away on a raid"
const LEADER_TEXT := "LEADER"

var _key := ""
var _rows := {}   # member id -> {name: Label, state: Label, summary: Label}


func _init() -> void:
	add_child(Widgets.section("Members"))


## Shows the view's members; the Remove buttons appear for the leader only.
func refresh(view: Dictionary) -> void:
	var members: Array = view.get("members", [])
	var i_lead := int(view.get("leader", -1)) == int(view.get("you", -2))
	var key := _make_key(members, i_lead)
	if key != _key:
		_rebuild(members, i_lead, int(view.get("you", -2)))
		_key = key
	for m: Dictionary in members:
		var row: Dictionary = _rows.get(int(m.id), {})
		if row.is_empty():
			continue
		(row.state as Label).text = make_state_text(m)
		(row.summary as Label).text = str(m.summary)


static func make_state_text(member: Dictionary) -> String:
	if bool(member.in_raid):
		return AWAY_TEXT
	return READY_TEXT if bool(member.ready) else NOT_READY_TEXT


func _make_key(members: Array, i_lead: bool) -> String:
	return "%s|%s" % [i_lead, ",".join(PackedStringArray(members.map(func(m: Dictionary) -> String: return "%d:%s:%s" % [m.id, m.name, m.leader])))]


func _rebuild(members: Array, i_lead: bool, my_id: int) -> void:
	for c in get_children().slice(1):
		c.queue_free()
	_rows.clear()
	for m: Dictionary in members:
		add_child(_make_row(m, i_lead, my_id))


func _make_row(m: Dictionary, i_lead: bool, my_id: int) -> Control:
	var box := VBoxContainer.new()
	var head := HBoxContainer.new()
	var title := "%s%s%s" % [m.name, "  (you)" if int(m.id) == my_id else "", "  -  " + LEADER_TEXT if bool(m.leader) else ""]
	var name_label := Widgets.label(title, "HeaderLabel" if bool(m.leader) else "")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)
	var state := Widgets.label(make_state_text(m), "StatusLabel")
	head.add_child(state)
	if i_lead and int(m.id) != my_id:
		var id := int(m.id)
		head.add_child(Widgets.small_button("Remove", func() -> void: kick_requested.emit(id), Widgets.DANGER))
	box.add_child(head)
	var summary := Widgets.label(str(m.summary), "DimLabel")
	summary.clip_text = true
	box.add_child(summary)
	_rows[int(m.id)] = {"name": name_label, "state": state, "summary": summary}
	return box
