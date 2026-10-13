class_name DuelRules
extends GameModeRules
## Battledrome challenge (docs/formats/battledrome.md section 8): a one-on-one arena fight that ends when a Herc
## reaches the agreed victory terms, the damage level (25 / 50 / 75 % damaged, crippled, destroyed) both pilots
## accepted; "victory_damage" 1.0 = destroyed. The pilot still standing wins.


func _on_kill(victim: Dictionary, killer: Dictionary) -> void:
	_finish_against(victim, killer)


func _on_tick(_delta: float) -> void:
	var terms := _num("victory_damage", 1.0)
	if terms >= 1.0:
		return
	for p in players.values():
		if bool(p.get("alive", true)) and 1.0 - float(p.get("integrity", 1.0)) >= terms:
			_finish_against(p, _make_opponent(p))
			return


func _make_opponent(loser: Dictionary) -> Dictionary:
	for p in players.values():
		if str(p.key) != str(loser.key):
			return p
	return {}


func _finish_against(loser: Dictionary, other: Dictionary) -> void:
	if other.is_empty() or GameModeRules.is_suicide(loser, other):
		other = _make_opponent(loser)
	if other.is_empty():
		finish("%s is out of the fight." % loser.get("key", "?"), "")
		return
	score.add_player(str(other.key), 1.0)
	finish("%s meets the victory terms against %s!" % [other.key, loser.get("key", "?")], str(other.key))
