class_name TribesItemModels
extends RefCounted
## Draws the Item objects of a training mission's script world (TribesSimObjects records of class Item) with their
## datablock's model (gameplay/items.json, TribesPickups.make_item_model), where the record says they are, hidden
## while the item is carried or hidden (Item::hide). The script runtime keeps deciding pickups (TribesContacts ->
## <datablock>::onCollision); this only shows them. The model is kept in the record as "model".

var rt: TribesMissionRuntime
var grants: TribesItemGrants


func _init(runtime: TribesMissionRuntime) -> void:
	rt = runtime
	grants = TribesItemGrants.new(rt.pack)


## Builds the models of new items and shows / hides / moves every item's model as its record says.
func update() -> void:
	for id in rt.sim.objects:
		var rec: Dictionary = rt.sim.objects[id]
		if String(rec.class).to_lower() != "item" or rec.get("is_datablock", false):
			continue
		var shown: bool = not rec.get("hidden", false) and not rec.get("deleted", false)
		var model = rec.get("model")
		if model == null and shown:
			model = _build(rec)
		if model is Node3D and is_instance_valid(model):
			(model as Node3D).visible = shown
			(model as Node3D).global_position = rt.sim.position_of(id)


## The display name of item `id` ("a sniper rifle"; the datablock's name when the catalog has none).
func make_item_name(id: int) -> String:
	var db := String(rt.sim.get_record(id).get("datablock", ""))
	return str(grants.record(db).get("name", db))


func _build(rec: Dictionary) -> Node3D:
	var model := TribesPickups.make_item_model(grants, String(rec.get("datablock", "")))
	rec["model"] = model if model else false
	if model:
		model.name = "Item%d" % int(rec.id)
		rt.battle.add_child(model)
	return model
