class_name FailRule
extends RefCounted
## A rule that rules on the mission each rules tick. It returns a MissionVerdict, or null while it has nothing to say, and
## never ends the mission itself (the MissionEnder does). Rules live in engine/mission/fail_rules/; the original timings
## (4.9 s grace, 8 s death debrief) are passed in by the game adapters.

var code := 0
var text := ""
## Callable() -> int. When valid it gives the end code at verdict time, for a code that depends on the state of the
## mission (a damage level); `code` is the fixed one otherwise.
var code_source := Callable()


func _init(p_code := 0, p_text := "") -> void:
	code = p_code
	text = p_text


func make_verdict(_world: MissionWorld, _dt: float) -> MissionVerdict:
	return null


## The end code a verdict of this rule carries now.
func get_code() -> int:
	return int(code_source.call()) if code_source.is_valid() else code


## The first verdict of `rules`, in their order (the order of a game end check), or null.
static func make_first_verdict(rules: Array, world: MissionWorld, dt: float) -> MissionVerdict:
	for r in rules:
		var v: MissionVerdict = (r as FailRule).make_verdict(world, dt)
		if v != null:
			return v
	return null
