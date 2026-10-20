class_name OperatorSetupLauncher
extends RefCounted
## Opens the Operator Setup loadout screen (OperatorSetup.open(parent, ctx, slot_index), docs/design/lobby_loadout_economy.md
## section 6) over the lobby. The screen is built in parallel with the lobby: while the class does not exist a stub sheet
## with the same entry and the same `closed` signal stands in, so the lobby and its tests do not wait for it.

const SETUP_CLASS := "OperatorSetup"
const STUB_TITLE := "OPERATOR SETUP"
const STUB_TEXT := "The Operator Setup screen is not part of this build yet. Your active slot stays as it is."


## True when the real Operator Setup screen exists in this build.
static func is_real() -> bool:
	return CatalogBridge.has_function(SETUP_CLASS, "open")


## Opens it over `host`; the returned node (the real OperatorSetup, else the stub sheet) emits `closed` (the real one with a
## changed flag).
static func open(host: Control, ctx: LoadoutContext, slot_index: int) -> Node:
	if is_real():
		return CatalogBridge.call_function(SETUP_CLASS, "open", [host, ctx, slot_index])
	var sheet := ModalSheet.open(host, STUB_TITLE)
	sheet.body.add_child(Widgets.paragraph(STUB_TEXT))
	sheet.set_back("Back")
	sheet.set_primary("Done", sheet.close)
	return sheet
