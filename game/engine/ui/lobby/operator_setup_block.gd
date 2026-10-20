class_name OperatorSetupBlock
extends VBoxContainer
## The lobby's bottom left (docs/design/lobby_loadout_economy.md section 5): the pilot's name, his active character slot
## (its name and a one line summary), the credits, and the Operator Setup button that opens the loadout screen.
##   refresh(profile, settings)   shows the operator profile for the match
##   setup_requested               the button (or Enter on it) was pressed

signal setup_requested

const BUTTON_TEXT := "Operator Setup..."
const SLOT_LINE := "Slot %d  \"%s\""
const DEFAULT_LABEL := "Slot %d"

var name_row: NameRow
var credits: CreditsBadge
var setup_button: Button
var _slot_label: Label
var _summary: Label
var _detail: Label


func _init() -> void:
	add_child(Widgets.section("Operator setup"))
	name_row = NameRow.new()
	add_child(name_row)
	_slot_label = Widgets.label("", "HeaderLabel")
	add_child(_slot_label)
	_summary = Widgets.paragraph("", "DimLabel")
	add_child(_summary)
	var panel := PanelContainer.new()
	panel.theme_type_variation = "CardPanel"
	_detail = Widgets.paragraph("", "")
	panel.add_child(_detail)
	add_child(panel)
	credits = CreditsBadge.new()
	credits.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add_child(credits)
	setup_button = Widgets.button(BUTTON_TEXT, func() -> void: setup_requested.emit(), Widgets.PRIMARY)
	setup_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(setup_button)


func refresh(profile: OperatorProfile, settings: Dictionary) -> void:
	var slot := profile.make_active_slot()
	_slot_label.text = make_slot_text(slot)
	_summary.text = make_summary(slot, settings)
	_detail.text = "
".join(make_detail_lines(slot, settings))
	credits.set_credits(profile.credits)


## "Slot 1" while the slot keeps its default name, else "Slot 2  "Vanguard"".
static func make_slot_text(slot: CharacterSlot) -> String:
	if slot.label == DEFAULT_LABEL % (slot.index + 1):
		return slot.label
	return SLOT_LINE % [slot.index + 1, slot.label]


## "Medium / Raptor / 2 weapons" (a campaign: the garage decides, so the slot's soldier only).
static func make_summary(slot: CharacterSlot, settings: Dictionary) -> String:
	var parts: PackedStringArray = []
	if slot.armor != "":
		parts.append(LobbyCards.make_armor_text(slot.armor))
	if slot.vehicle != "" and str(settings.get("mode", "")) != "campaign":
		parts.append(str(Packs.vehicle(slot.vehicle).get("name", slot.vehicle)))
	parts.append("%d weapons" % (slot.infantry.weapons as Array).size())
	return " / ".join(parts)


## The slot spelled out for the room the left column has: soldier, his weapons, the vehicle and its weapons.
static func make_detail_lines(slot: CharacterSlot, settings: Dictionary) -> PackedStringArray:
	var lines: PackedStringArray = []
	if slot.armor != "":
		lines.append("Soldier: " + LobbyCards.make_armor_text(slot.armor))
		var weapons := LobbyCards.make_weapon_text(slot.infantry.weapons as Array)
		lines.append("Weapons: " + (weapons if weapons != "" else "none"))
	if slot.vehicle != "" and str(settings.get("mode", "")) != "campaign":
		lines.append("Vehicle: " + str(Packs.vehicle(slot.vehicle).get("name", slot.vehicle)))
		var guns := (slot.herc_loadout as Array).filter(func(w: Variant) -> bool: return str(w) != "")
		lines.append("Vehicle weapons: " + (LobbyCards.make_weapon_text(guns) if not guns.is_empty() else "none"))
	return lines
