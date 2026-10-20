extends Node
## Headless check of Classic campaigns (CampaignAvailability "classic"): an Earthsiege classic campaign offers its
## released weapons, similar Battledrome weapons and basic infantry kit, nothing from Earthsiege 2, Starsiege or
## Tribes; an Earthsiege 2 classic campaign also allows Earthsiege weapons; Session keeps the flag in the save.
##   godot --headless --audio-driver Dummy --path game res://tests/classic_check.tscn

var _failures := 0


func _ready() -> void:
	_check_es1()
	_check_es2()
	_check_session_flag()
	_check_shell_career()
	print("classic_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


static func _packs_of(offers: Array) -> Dictionary:
	var out := {}
	for o in offers:
		var p := str(o.weapon.pack)
		out[p] = int(out.get(p, 0)) + 1
	return out


func _check_es1() -> void:
	print("ES1 classic, first mission:")
	var ctx := Es1Tech.make_context(0, true, Es1Tech.make_start_armory())
	var open_packs := _packs_of(CampaignAvailability.offered_weapons(ctx))
	ctx["classic"] = true
	var offers := CampaignAvailability.offered_weapons(ctx)
	var packs := _packs_of(offers)
	print("    open: ", open_packs, "  classic: ", packs)
	_expect(not offers.is_empty(), "weapons are offered")
	for p in packs:
		_expect(["es1", "bd"].has(p), "pack %s allowed in an ES1 classic campaign" % p)
	for o in offers:
		var released: bool = (ctx.unlocked_weapons as Array).has(CampaignAvailability.base_weapon(str(o.weapon.id)))
		if str(o.weapon.pack) == "es1":
			_expect(released or o.reason == CampaignAvailability.REASON_STOCK, "es1 %s is released or stocked" % o.weapon.id)
		elif not str(o.reason).begins_with("similar to"):
			_expect(false, "%s offered for the wrong reason: %s" % [o.weapon.id, o.reason])
	_expect(packs.has("bd"), "look-alike Battledrome weapons are offered")
	_expect(CampaignAvailability.make_weapon_reason(ctx, "bd:BLASTER1") == "", "BD blaster has no ES1 look-alike")
	_expect(CampaignAvailability.make_weapon_reason(ctx, "es1:PBEAM") == "", "unreleased PBEAM stays locked")
	var later := ["es2", "starsiege", "tribes", "tribes2"]
	for p in later:
		_expect(not packs.has(p), "no %s weapons" % p)
	var ss := Packs.weapons.keys().filter(func(id): return str(Packs.weapons[id].pack) == "starsiege")
	if not ss.is_empty():
		var open_ctx := Es1Tech.make_context(0, true, {})
		var leaked := ss.filter(func(id): return CampaignAvailability.make_weapon_reason(open_ctx, str(id)) != "")
		print("    non-classic Starsiege weapons offered at ES1 start: ", leaked.size(), " of ", ss.size())


func _check_es2() -> void:
	print("ES2 classic:")
	var ctx := CampaignAvailability.make_context("es2")
	ctx["classic"] = true
	ctx.unlocked_weapons = []
	var packs := _packs_of(CampaignAvailability.offered_weapons(ctx))
	print("    ", packs)
	_expect(packs.has("es1"), "ES1 weapons allowed in an ES2 classic campaign")
	_expect(not packs.has("starsiege") and not packs.has("tribes"), "no Starsiege / Tribes weapons")
	var ss := CampaignAvailability.make_context("starsiege")
	ss["classic"] = true
	var ss_packs := _packs_of(CampaignAvailability.offered_weapons(ss))
	_expect(ss_packs.has("es2") and ss_packs.has("bd") and not ss_packs.has("tribes"), "Starsiege classic: ES2 and BD in, Tribes out")


func _check_session_flag() -> void:
	print("Session save:")
	Session.start_stage_campaign("es1")
	Session.classic = true
	var d := Session.make_save_dict()
	_expect(bool(d.get("classic", false)) and bool(d.meta.get("classic", false)), "save and meta carry classic")
	Session.classic = false
	Session.apply_save_dict(d)
	_expect(Session.classic and bool(Session.availability_context().get("classic", false)), "load restores classic")
	Session.start_stage_campaign("es1")
	_expect(not Session.classic, "a plain start is not classic")
	Session.clear_campaign()


func _check_shell_career() -> void:
	print("ES1 shell career:")
	var career := {"name": "CLASSICPILOT", "campaign": 0, "slot": 0, "missions": 0, "kills": 0,
		"next_mission": ShellCareers.FIRST_MISSION, "classic": true}
	var d := ShellCareers.make_save(career, SaveGames.KIND_AUTOSAVE, "t")
	_expect(bool(d.meta.get("classic", false)), "career save meta carries classic")
	_expect(bool(ShellCareers.make_career(d).get("classic", false)), "career restored from its save is classic")
	var ctx := MissionLaunch.campaign_for(career).availability_context()
	ctx["classic"] = bool(career.get("classic", false))
	var packs := _packs_of(CampaignAvailability.offered_weapons(ctx))
	_expect(not packs.has("starsiege") and not packs.has("es2"), "shell career offers no later-game weapons")
