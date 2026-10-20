class_name SpawnWave
extends RefCounted
## One group to bring into the mission. `trigger` says when: "start", "region:<id>", "timer:<id>" or "script:<action>".
## `arrival` is the delay in seconds between the trigger and the group appearing; `repeat_every` > 0 brings `count` more
## each that many seconds after (extraction batches, arena respawns).

var group := ""
var trigger := "start"
var arrival := 0.0
var count := 1
var repeat_every := 0.0
## Where the group appears around the player: {distance (m), spread (rad), bearing (rad, from the player's heading)}, or empty
## to appear at its own place (the Earthsiege 2 region arrivals).
var placement := {}


static func make_wave(p_group: String, p_trigger := "start", p_count := 1, p_arrival := 0.0, p_repeat_every := 0.0) -> SpawnWave:
	var w := SpawnWave.new()
	w.group = p_group
	w.trigger = p_trigger
	w.count = p_count
	w.arrival = p_arrival
	w.repeat_every = p_repeat_every
	return w


## A wave that appears `distance` metres from the player, `bearing` radians off his heading, scattered by up to `spread` radians.
static func make_placed_wave(p_group: String, p_trigger: String, distance: float, spread: float, bearing: float) -> SpawnWave:
	var w := make_wave(p_group, p_trigger)
	w.placement = {"distance": distance, "spread": spread, "bearing": bearing}
	return w
