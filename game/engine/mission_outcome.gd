class_name MissionOutcome
extends RefCounted
## The result of a mission battle, one shape for every game and for an abort: what Battle hands its result screen,
## Session.last_result keeps, the campaigns record and saves / LAN messages carry (a plain Dictionary):
##   success       the mission counts as won
##   aborted       the player left it (BattleExit): failed, nothing recorded as flown
##   code          the game's own end code (Earthsiege debriefing code, Earthsiege 2 status, Starsiege /
##                 Tribes 1 / 6, ABORT_CODE)
##   vars          the mission variables after the battle (campaign branching)
##   text          the debriefing text
##   pilot_killed  the local player's vehicle was destroyed (the campaigns replay instead of recording)
## Salvage fields (BattleSalvage) are merged in by Battle.

const ABORT_CODE := -1
const HEADLINES := {"success": "MISSION SUCCESSFUL", "failure": "MISSION FAILED", "aborted": "MISSION ABORTED"}


## A mission that ended by its own rules (MissionRuntime.mission_over).
static func make_ended(success: bool, code: int, vars: PackedInt32Array, text: String, pilot_killed: bool) -> Dictionary:
	return {"success": success, "aborted": false, "code": code, "vars": vars, "text": text, "pilot_killed": pilot_killed}


## A mission the player aborted.
static func make_aborted(vars: PackedInt32Array, text: String) -> Dictionary:
	return {"success": false, "aborted": true, "code": ABORT_CODE, "vars": vars, "text": text, "pilot_killed": false,
		"salvage": []}


## The headline of mission result `r` (debriefing and results screens).
static func make_headline(r: Dictionary) -> String:
	if bool(r.get("aborted", false)):
		return HEADLINES.aborted
	return HEADLINES.success if bool(r.get("success", false)) else HEADLINES.failure
