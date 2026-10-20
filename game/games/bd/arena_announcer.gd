class_name ArenaAnnouncer
extends RefCounted
## Battledrome's end-of-round announcer (SIM.EXE referee state machine 0x13b74, docs/formats/battledrome.md
## section 8): when the victory terms are met, ENDRND1 plays; 2.048 s later AREAN01; 2.048 s after that AREAN11
## when this machine's own pilot won, else AREAN12; 3.072 s later the sim ends.  Ids and delays come from the
## user's SIM.EXE (BdVoices).  Every peer plays it for its own pilot (the original decides by [0x954ac], always
## the machine's own Herc).


## [[seconds after the end, Sfx voice name], ...] for a pilot who won (`won`) or lost; [] without Battledrome.
## The voices are a FIFO list of the announcer: each keeps the radio busy for its delay, the next starts after it.
static func make_end_sequence(won: bool) -> Array:
	var e: Dictionary = BdVoices.table().get("end_of_round", {})
	if e.is_empty():
		return []
	var voices: Array = e.get("voices", []).duplicate()
	voices.append(e.get("winner_voice" if won else "loser_voice", ""))
	var delays: Array = e.get("delays_s", [])
	var list: Array[MissionMessage] = []
	for i in voices.size():
		var delay := float(delays[i]) if i < delays.size() else 0.0
		list.append(MissionMessage.make_voice_only(MissionVoice.make_voice(BdVoices.sound_name(String(voices[i])), delay)))
	var starts := MissionAnnouncer.make_start_times(list)
	var out := []
	for i in list.size():
		out.append([starts[i], list[i].voice.id])
	return out


## Plays the end-of-round voices for this peer's pilot (unless Battledrome voices are switched off).
static func play_end_of_round(won: bool) -> void:
	if not AudioSettings.voices_on():
		return
	for step in make_end_sequence(won):
		Sfx.play_voice_after(String(step[1]), float(step[0]))


## True when `winner` (as Battle.end_match names it: a pilot, or a team in a team match) is this peer's pilot.
static func is_local_winner(battle: Battle, winner: String) -> bool:
	var p := battle.player
	if p == null or not is_instance_valid(p) or winner == "":
		return false
	if BattleRules.plays_in_teams(battle.config):
		return MapTeams.make_team_name(p.team, battle.config) == winner
	return p.display_name == winner


## Whether a battle is fought in a Battledrome arena (the announcer's place).
static func is_arena(config: Dictionary) -> bool:
	return config.has("arena") and not config.has("map")
