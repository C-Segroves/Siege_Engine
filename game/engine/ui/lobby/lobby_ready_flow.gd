class_name LobbyReadyFlow
extends RefCounted
## The disallowed-items warning before ready-up (docs/design/lobby_loadout_economy.md section 5.3): Ready (or the host's
## Start) first looks at what the active slot may not field here. Nothing wrong: go. Otherwise a dialog lists the parts
## that will be left off ("Ready anyway": the match uses CharacterSlot.make_resolved) or opens Operator Setup.

const MESSAGE := "These parts are not allowed here and will be left off:"
const GO_TEXT := "Ready anyway"
const SETUP_TEXT := "Open Operator Setup"


static func make_message(blocks: Array) -> String:
	return MESSAGE + "\n- " + "\n- ".join(PackedStringArray(LobbyAnnouncer.make_block_lines(blocks)))


## Calls `on_go` at once when `blocks` is empty, else asks first. Returns the dialog (null when none was needed).
static func ask(host: Control, blocks: Array, on_go: Callable, on_setup: Callable, go_text := GO_TEXT) -> ConfirmDialog:
	if blocks.is_empty():
		on_go.call()
		return null
	var dialog := ConfirmDialog.ask(host, make_message(blocks), on_go, go_text)
	dialog.add_choice(SETUP_TEXT, on_setup)
	return dialog
