class_name LobbyAnnouncer
extends RefCounted
## What the local pilot tells the lobby about himself (docs/design/lobby_loadout_economy.md sections 3 and 7.1): the build
## of his active character slot as the match will use it (the legacy roster keys the battle reads plus the compact
## "slot" snapshot), his raid kit in a raid, and the goals he picked. Pure `make_*` queries build the fields; `announce`
## sends them in one message (Net.set_my_infos).

const GOALS_KEY := "goals"


## The loadout context of the pilot `profile` in a match with `settings`.
static func make_context(settings: Dictionary, profile: OperatorProfile) -> LoadoutContext:
	var ctx := LoadoutContext.make_for(settings, LoadoutContext.ROLE_PLAYER, profile.unlocks)
	if ctx.source == LoadoutContext.SOURCE_GARAGE and Session.has_campaign():
		ctx.availability = Session.availability_context()   # the campaign decides what may be built and armed
	if ctx.source == LoadoutContext.SOURCE_STASH:
		ctx.apply_raid_kit(ExtractionProfile.load_for(profile.pilot).kit)
	return ctx


## The roster keys of the active slot's build for the match, plus the raid kit in an extraction raid.
static func make_fields(settings: Dictionary, profile: OperatorProfile) -> Dictionary:
	var ctx := make_context(settings, profile)
	var fields := profile.make_active_slot().make_roster_fields(ctx)
	if ExtractionRules.is_extraction(settings):
		fields["kit"] = ExtractionProfile.load_for(profile.pilot).make_kit_dict()
	return fields


## What the active slot forbids or lacks in this match: [{part, id, text}] (the ready-up warning).
static func make_blocks(settings: Dictionary, profile: OperatorProfile) -> Array:
	return profile.make_active_slot().make_blocks(make_context(settings, profile))


## The warning's lines, one per part.
static func make_block_lines(blocks: Array) -> Array:
	return blocks.map(func(b: Dictionary) -> String: return str(b.text))


## Sends the build to the lobby (a campaign pilot's Herc is the garage's: LobbyScreen announces that itself).
static func announce(settings: Dictionary, profile: OperatorProfile) -> void:
	Net.set_my_infos(make_fields(settings, profile))


## Sends the picked goal ids.
static func announce_goals(ids: Array) -> void:
	Net.set_my_info(GOALS_KEY, ids.duplicate())
