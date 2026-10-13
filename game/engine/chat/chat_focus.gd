class_name ChatFocus
## Whether the local player's chat is open (typing, the quick-chat menu or the full history): gameplay input
## handlers that run before the GUI (`_input`, e.g. CockpitDisplay's F-keys) ignore events while it is.
## BattleChat sets it; the chat's own controls take every key and button event while they have the focus.

static var open := false
