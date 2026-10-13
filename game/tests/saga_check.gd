extends Node
## Headless check: saga stages are playable and hand over es1 -> es2 -> starsiege (human/cybrid);
## every stage has a garage, and a won stage's garage joins the next stage's.

func _ready() -> void:
	for s in Saga.available_stages():
		print("stage ", s)
	var g := Saga.start_new()
	print("start: ", g.stage_name(), " mission ", g.campaign.current_mission() if g.campaign else null)
	for i in 2:
		g.advance()   # skip ahead as if the stage was won
		print("next: ", g.stage_name(), " needs_choice ", g.needs_choice())
		if g.needs_choice():
			for v in ["human", "cybrid"]:
				var copy := Saga.from_dict(g.to_dict())
				copy.choose(v)
				var m: Dictionary = copy.campaign.load_current({})
				print("  ", v, ": ", copy.stage_name(), " -> ", m.get("map", m.get("id", m.keys().slice(0, 6))))
		elif g.campaign:
			var m2: Dictionary = g.campaign.load_current({})
			print("  mission keys ", m2.keys().slice(0, 8))
		var rt := Saga.from_dict(g.to_dict())
		print("  save/restore ok: ", rt.stage == g.stage)
		if g.campaign:
			print("  garage: %d Hercs" % (g.campaign.garage as Garage).vehicles.size())
	_check_garage_carry()
	get_tree().quit()


func _check_garage_carry() -> void:
	var g := Saga.start_new()
	var es1_hercs: int = g.campaign.garage.vehicles.size()
	g.apply_carry(g.availability_context(), g.campaign.garage)
	g.advance()
	var es2: Garage = g.campaign.garage
	print("garage carry es1 -> es2: %d + %d Hercs -> %d  %s" % [es1_hercs, Es2Tech.make_start_garage().vehicles.size(),
		es2.vehicles.size(), "ok" if es2.vehicles.size() == es1_hercs + Es2Tech.make_start_garage().vehicles.size() else "FAIL"])
