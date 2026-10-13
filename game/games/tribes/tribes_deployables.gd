class_name TribesDeployables
extends Node
## The deploy packs of a Tribes battle (child "Deployables" of the Battle; docs/TRIBES_BASE_EQUIPMENT.md,
## Deployables): pack use with a deploy pack on (InfantryGearDirector.apply_pack_toggle) places the pack's object
## where the soldier aims, by the pack's own rules (TribesDeployRules). The host decides; every peer builds the
## object (a TribesBaseObject: a remote turret, sensor, jammer, camera or inventory / ammo station) through the
## base (TribesBase.add_deployed). Deployed objects power themselves, as the originals' do (Tribes 1
## DeployableTurret::onPower does nothing, Tribes 2 deployables setSelfPowered). The pack is used up after its last
## use (Tribes 2 sensor packs carry maxSensors).
## In an extraction raid deploying follows the same rules (the squad limit is the original team limit); the objects
## belong to the deployer's team and the used-up pack leaves his raid inventory.

const NODE_NAME := "Deployables"
const META_FROM := "deployed_from"
const META_USES := "deploy_uses_left"
const MESSAGE_SECONDS := 3.0
## Extraction inventory item id of a worn pack (ExtractionItems: "pack/<gear pack id>").
const EXTRACTION_PACK_PREFIX := "pack/"

var battle: Node
var _next_id := 0


static func build_for(p_battle: Node) -> TribesDeployables:
	var d := TribesDeployables.new()
	d.battle = p_battle
	d.name = NODE_NAME
	p_battle.add_child(d)
	return d


static func of(p_battle: Node) -> TribesDeployables:
	return p_battle.get_node_or_null(NODE_NAME) as TribesDeployables if p_battle else null


## True when gear pack `pack_id` deploys something (infantry_gear.json effect "deploy").
static func is_deploy_pack(pack_id: String) -> bool:
	return pack_id != "" and str(InfantryGear.pack(pack_id).get("effect", "")) == "deploy"


## The rules of `pack_id` ({} when its game has none).
static func rules_of(pack_id: String) -> Dictionary:
	var pack := pack_id.get_slice(":", 0)
	return TribesBase.load_specs(pack).get("deployables", {}).get(pack_id, {})


## Host: `peer`'s soldier deploys his pack (or is told why he can't).
func apply_deploy(peer: int, soldier: Infantry) -> void:
	var rules := rules_of(soldier.kit.pack_id)
	var base := TribesBase.of(battle)
	if rules.is_empty() or base == null:
		return
	# a destroyed deployable leaves the team's count (Sensor / Turret ::onDestroyed $TeamItemCount--)
	var placed := base.objects.filter(func(o: TribesBaseObject) -> bool: return o.has_meta(META_FROM) and o.alive)
	var result: Dictionary = TribesDeployRules.make(rules).make_placement(soldier, placed, make_team_size())
	if str(result.error) != "":
		_tell(peer, str(result.error))
		return
	var record := {"shape": str(result.place.get("shape", "")), "spec": str(result.place.get("spec", result.place.deployed)),
		"datablock": str(result.place.deployed), "team": soldier.team, "from": str(rules.item), "id": _next_id}
	_next_id += 1
	_spawn_deployed(record, result.xf)
	if Net.is_online():
		_spawn_deployed.rpc(record, result.xf)
	_tell(peer, "%s deployed" % str(InfantryGear.pack(soldier.kit.pack_id).get("name", rules.item)))
	_use_pack(peer, soldier, int(rules.get("uses", 1)))


## Players of the bigger team (Tribes 2 turret limits: countTurretsAllowed).
func make_team_size() -> int:
	var counts := {}
	for v in battle.get("vehicles").values():
		if is_instance_valid(v) and v is Infantry and not (v as Infantry).has_meta("ai"):
			counts[v.team] = int(counts.get(v.team, 0)) + 1
	var best := 0
	for t in counts:
		best = maxi(best, int(counts[t]))
	return best


@rpc("authority", "call_remote", "reliable")
func _spawn_deployed(record: Dictionary, xf: Transform3D) -> void:
	var base := TribesBase.of(battle)
	if base:
		base.add_deployed(record, xf)


func _use_pack(peer: int, soldier: Infantry, uses: int) -> void:
	var worn: Array = soldier.get_meta(META_USES, [soldier.kit.pack_id, uses])
	var left := (int(worn[1]) if str(worn[0]) == soldier.kit.pack_id else uses) - 1   # a new pack starts full
	soldier.set_meta(META_USES, [soldier.kit.pack_id, left])
	if left > 0:
		return
	soldier.remove_meta(META_USES)
	_take_extraction_item(peer, soldier.kit.pack_id)
	_spend_pack(soldier.net_id)
	if Net.is_online():
		_spend_pack.rpc(soldier.net_id)


## Extraction raid: the worn pack is an inventory item ("pack/<id>", agent F's ExtractionInventory); deploying uses
## one up.
func _take_extraction_item(peer: int, pack_id: String) -> void:
	var raid = battle.get("extraction")
	if raid == null or not (raid.get("inventories") is Dictionary) or not raid.inventories.has(peer):
		return
	raid.inventories[peer].apply_take(EXTRACTION_PACK_PREFIX + pack_id, 1)
	raid.send_inventory(peer)


@rpc("authority", "call_remote", "reliable")
func _spend_pack(net_id: int) -> void:
	var s := battle.get("vehicles").get(net_id) as Infantry
	if s:
		s.kit.pack_id = ""
		s.kit.pack_active = false


func _tell(peer: int, text: String) -> void:
	if peer == multiplayer.get_unique_id():
		_show_message(text)
	elif Net.is_online():
		_show_message.rpc_id(peer, text)


@rpc("authority", "call_remote", "reliable")
func _show_message(text: String) -> void:
	if battle.has_method("fx"):
		battle.fx("message", [text, MESSAGE_SECONDS])
