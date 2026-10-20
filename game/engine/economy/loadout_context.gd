class_name LoadoutContext
extends RefCounted
## What a match lets an operator field and own (docs/design/lobby_loadout_economy.md section 2.6): the mode, the match's
## infantry game, the campaign availability, and where ownership comes from.
##   source "owned"   versus / co-op: every part must be an unlock (free or bought)
##   source "garage"  campaign: the campaign's availability decides, no store
##   source "stash"   extraction: look parts (armour, body, skin, vehicle) must be unlocks, the kit comes from stock
##   source "bot"     ownership ignored (a host editing a bot card, the host's validation of a roster)
## Losing an unlock on death and buying it back happens only where loss_on_death is true (extraction); elsewhere a
## lost unlock is usable and nothing is lost.

const SOURCE_OWNED := "owned"
const SOURCE_GARAGE := "garage"
const SOURCE_STASH := "stash"
const SOURCE_BOT := "bot"
const ROLE_PLAYER := "player"
const ROLE_BOT := "bot"
## Ownership checks per source; "look" = UnlockId.LOOK_KINDS only.
const CHECKED_ALL := "all"
const CHECKED_LOOK := "look"
const CHECKED_NONE := "none"
const CHECKED_BY_SOURCE := {SOURCE_OWNED: CHECKED_ALL, SOURCE_STASH: CHECKED_LOOK, SOURCE_GARAGE: CHECKED_NONE, SOURCE_BOT: CHECKED_NONE}

var mode_key := ""
var family := ""
var pack := ""
var source := SOURCE_OWNED
var availability := {}
var store_enabled := true
var loss_on_death := false
var unlocks := Unlocks.new()


## The context of a pilot in a match with `settings` (Net.settings): role "player" or "bot". `p_unlocks` are the
## pilot's own unlocks (none = only the free set).
static func make_for(settings: Dictionary, role := ROLE_PLAYER, p_unlocks: Unlocks = null) -> LoadoutContext:
	var c := LoadoutContext.new()
	var mode := str(settings.get("mode", ""))
	c.mode_key = EconomyRules.make_mode_key(settings)
	c.family = mode
	c.pack = str(settings.get("infantry_pack", ""))
	c.availability = settings.get("availability", {}) if settings.get("availability") is Dictionary else {}
	if p_unlocks != null:
		c.unlocks = p_unlocks
	if role == ROLE_BOT:
		c.source = SOURCE_BOT
		c.store_enabled = false
	elif mode == "campaign":
		c.source = SOURCE_GARAGE
		c.store_enabled = false
	elif mode == ExtractionRules.MODE:
		c.source = SOURCE_STASH
		c.loss_on_death = true
	return c


## Why `id` cannot be fielded in this match ("" = allowed): its game is not installed, the match's infantry game or
## the campaign availability excludes it. Ownership is separate (make_ownership_block).
func make_block_reason(id: String) -> String:
	var pack_id := UnlockId.pack_of(id)
	if pack_id != "" and not Assets.has_pack(pack_id):
		return "%s is not installed" % Packs.pack_name(pack_id)
	var ref := UnlockId.ref_of(id)
	match UnlockId.kind_of(id):
		"armor":
			if pack != "" and pack_id != pack:
				return "%s is not in this match's infantry game" % InfantryCatalog.armor(ref).get("name", ref)
		"vehicle":
			if not availability.is_empty() and not CampaignAvailability.is_vehicle_offered(availability, ref):
				return "Herc %s is not available in this mode" % str(Packs.vehicle(ref).get("name", ref))
		"herc_weapon":
			if not availability.is_empty() and CampaignAvailability.make_weapon_reason(availability, ref) == "":
				return "%s is not available in this mode" % str(Packs.weapon(ref).get("display_name", ref))
	return ""


## True when this match asks the operator to own parts of `kind`.
func is_ownership_checked(kind: String) -> bool:
	match CHECKED_BY_SOURCE.get(source, CHECKED_NONE):
		CHECKED_ALL:
			return true
		CHECKED_LOOK:
			return UnlockId.LOOK_KINDS.has(kind)
	return false


## True when the operator may use `id` here (with his own unlocks).
func is_usable(id: String) -> bool:
	return is_usable_with(id, unlocks)


## The same with another set of unlocks `owned`: ownership is not checked, he owns it (free items included), or it is
## lost where nothing is lost.
func is_usable_with(id: String, owned: Unlocks) -> bool:
	if not is_ownership_checked(UnlockId.kind_of(id)):
		return true
	if is_free(id) or owned.owned.has(id):
		return true
	return owned.is_lost(id) and not loss_on_death


## "" when `id` is owned (or ownership is not asked), else a short reason.
func make_ownership_block(id: String) -> String:
	return make_ownership_block_with(id, unlocks)


func make_ownership_block_with(id: String, owned: Unlocks) -> String:
	if is_usable_with(id, owned):
		return ""
	return "Lost in a raid" if owned.is_lost(id) else "Not owned"


## Free here: in a raid the rules decide which armours are free (O5); elsewhere weapons and ammunition are too (O2).
func is_free(id: String) -> bool:
	return FreeUnlocks.is_free_in_raid(id) if loss_on_death else FreeUnlocks.is_free_outside_raid(id)
