class_name QuickChat
## The canned messages of the gamepad quick-chat menu (chat_quick), Tribes' chat menu idea: categories of short
## lines, each said to the team or to everybody. The lines come from the installed Tribes data
## (gameplay/quick_chat.json, extracted from the original chat menu script at import by
## tools/export_tribes_quickchat.py); without it the remake's own short list below is used.
## A menu is [{name, items: [{label, text, team}]}].

const DATA_FILE := "gameplay/quick_chat.json"
const DATA_PACKS := ["tribes", "tribes2"]
## The remake's own lines (not from any original game).
const OWN_MENU := [
	{"name": "Team", "items": [
		{"label": "Attack", "text": "Attack my target!", "team": true},
		{"label": "Cover me", "text": "Cover me!", "team": true},
		{"label": "Regroup", "text": "Regroup on me.", "team": true},
		{"label": "Need help", "text": "I need help here!", "team": true},
		{"label": "Need repairs", "text": "I need repairs.", "team": true},
		{"label": "Defend", "text": "Defend the base!", "team": true}]},
	{"name": "Replies", "items": [
		{"label": "Yes", "text": "Yes.", "team": true},
		{"label": "No", "text": "No.", "team": true},
		{"label": "Thanks", "text": "Thanks!", "team": true},
		{"label": "Sorry", "text": "Sorry!", "team": true}]},
	{"name": "Everybody", "items": [
		{"label": "Good game", "text": "Good game!", "team": false},
		{"label": "Nice shot", "text": "Nice shot!", "team": false},
		{"label": "Oops", "text": "Oops!", "team": false}]},
]


## The quick-chat menu: the first installed pack's extracted one, else OWN_MENU.
static func load_menu() -> Array:
	for pack in DATA_PACKS:
		var menu := load_pack_menu(pack)
		if not menu.is_empty():
			return menu
	return OWN_MENU


## `pack`'s extracted menu ([] when it has none or it is unreadable).
static func load_pack_menu(pack: String) -> Array:
	if not FileAccess.file_exists(Assets.path(DATA_FILE, pack)):
		return []
	var j = Assets.load_json(DATA_FILE, pack)
	if not (j is Dictionary) or not (j.get("menu") is Array):
		push_error("QuickChat: %s:%s unreadable" % [pack, DATA_FILE])
		return []
	return (j.menu as Array).filter(func(c): return c is Dictionary and not (c.get("items", []) as Array).is_empty())
