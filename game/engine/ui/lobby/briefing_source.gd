class_name BriefingSource
extends RefCounted
## What the lobby's right pane shows (docs/design/lobby_loadout_economy.md section 5, Options A and B): the task list of
## goals (every mode with pay or a raid), or the campaign briefing (mission heading, text, objectives, the campaign's
## movies and talking heads, the mission map when there is one). The briefing of a campaign host comes from its Session;
## a co-op client reads the copy the host published in the lobby settings (MatchFlow.make_campaign_offer).

const KIND_GOALS := "goals"
const KIND_BRIEFING := "briefing"
const KIND_NONE := "none"


## Which pane `settings` call for: a campaign shows its briefing, a solo skirmish nothing, the rest the goals.
static func make_kind(settings: Dictionary) -> String:
	var mode := str(settings.get("mode", ""))
	if mode == "campaign":
		return KIND_BRIEFING
	if bool(settings.get("solo", false)) and mode != ExtractionRules.MODE:
		return KIND_NONE
	return KIND_GOALS


## {heading, text, objectives: [String], movies: [files], talks: [lines], map: Texture2D or null}. The host (and a single
## player) reads the running campaign; a client the host's offer.
static func make_briefing(settings: Dictionary) -> Dictionary:
	if Session.has_campaign():
		var texts := Session.briefing()
		return {"heading": MatchFlow.make_mission_heading(), "text": str(texts.get("briefing", "")),
			"objectives": _make_strings(texts.get("objectives", [])), "movies": make_movies(), "talks": make_talks(),
			"map": make_map_texture()}
	var offer: Dictionary = settings.get(MatchFlow.CAMPAIGN_OFFER, {}) if settings.get(MatchFlow.CAMPAIGN_OFFER) is Dictionary else {}
	var shown: Dictionary = offer.get("briefing", {}) if offer.get("briefing") is Dictionary else {}
	return {"heading": str(offer.get("heading", "")), "text": str(shown.get("text", "")),
		"objectives": _make_strings(shown.get("objectives", [])), "movies": [], "talks": [], "map": null}


## The campaign's briefing movies of the current mission (the leader's video), [] without a campaign or clips.
static func make_movies() -> Array:
	return CampaignPresentation.make_movies(Session.campaign, CampaignPresentation.MOMENT_BRIEFING, {"mission": Session.current_mission()})


static func make_talks() -> Array:
	return CampaignPresentation.make_talks(Session.campaign, CampaignPresentation.MOMENT_BRIEFING, {"mission": Session.current_mission()})


## The top-down picture of the mission's area. A lobby has no battle world to draw it from (CommandMapBackground needs
## one), so there is none yet: the pane leaves the map out until a mission carries a preview image.
static func make_map_texture() -> Texture2D:
	return null


static func _make_strings(list: Variant) -> Array:
	return (list as Array).map(func(x: Variant) -> String: return str(x)) if list is Array else []
