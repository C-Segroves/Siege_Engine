class_name ScoreObjective
extends Objective
## Done when `team` has `limit` points (a frag limit, a score limit).
## `team` is whatever key the game scores by (a team number, a pilot's name). A game that scores in fractions or by name
## gives a `source` callable (key -> points as float) and the world's whole-number get_score is not asked.

var team: Variant = 0
var limit := 1.0
var source := Callable()


func _init(p_id := "", p_text := "", p_team: Variant = 0, p_limit := 1.0) -> void:
	super(p_id, p_text)
	team = p_team
	limit = p_limit


func _make_state(world: MissionWorld, _dt: float) -> State:
	var points: float = float(source.call(team)) if source.is_valid() else float(world.get_score(team))
	return State.DONE if points >= limit else state
