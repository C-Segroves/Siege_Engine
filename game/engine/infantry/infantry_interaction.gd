class_name InfantryInteraction
extends Node
## The one `interact` action of a soldier on foot (E, pad X; docs/CODING_STANDARDS.md section 2): it does the
## nearest thing in reach. Every system that offers something to do registers a provider:
##   item pickups      pick up a weapon, ammunition, a pack, a repair patch lying in the world (ItemPickups)
##   loot              loot a cache or bag (ExtractionDirector)
##   mission objects   touch a switch, take a mission item (the Tribes training runtime)
##   boarding          enter the vehicle whose hatch is in reach (OccupancyDirector; vehicle_enter_exit's pad B too)
## A provider is func(soldier: Infantry) -> Dictionary: {} when it has nothing in reach, else an offer
## {distance: float (metres), text: String ("pick up the Laser Rifle"), apply: Callable (no arguments; sends the
## request to the host where the host decides)}. The nearest offer wins.
## Child "Interaction" of the Battle (BattleInfantry builds it).

const NODE_NAME := "Interaction"

var battle: Node
var _providers: Array[Callable] = []


func _init(p_battle: Node) -> void:
	battle = p_battle
	name = NODE_NAME


## The battle's interaction node (null when the battle has none).
static func of(p_battle: Node) -> InfantryInteraction:
	return p_battle.get_node_or_null(NODE_NAME) as InfantryInteraction if p_battle else null


## Adds a provider (see the class comment).
func add_provider(provider: Callable) -> void:
	if not _providers.has(provider):
		_providers.append(provider)


func remove_provider(provider: Callable) -> void:
	_providers.erase(provider)


## The nearest offer any provider makes to `soldier` ({} when nothing is in reach or he cannot act).
func make_offer(soldier: Infantry) -> Dictionary:
	if soldier == null or not is_instance_valid(soldier) or not soldier.alive or soldier.stowed:
		return {}
	var best := {}
	for provider in _providers:
		if not provider.is_valid():
			continue
		var offer: Dictionary = provider.call(soldier)
		if not offer.is_empty() and (best.is_empty() or float(offer.distance) < float(best.distance)):
			best = offer
	return best


## "E: pick up the Laser Rifle" for the local soldier's nearest offer ("" when there is none).
func make_hint(soldier: Infantry) -> String:
	var offer := make_offer(soldier)
	return "" if offer.is_empty() else "%s: %s" % [make_key_text(), str(offer.text)]


## Does the local soldier's nearest offer; false when there was none.
func apply_interact(soldier: Infantry) -> bool:
	var offer := make_offer(soldier)
	if offer.is_empty():
		return false
	(offer.apply as Callable).call()
	return true


## The first control bound to interact ("E").
static func make_key_text() -> String:
	return BindingText.make_action_bindings("interact").get_slice(BindingText.SEPARATOR, 0)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact") or ChatFocus.open:
		return
	if battle.has_method("is_over") and battle.is_over():
		return
	apply_interact(_local_soldier())


func _local_soldier() -> Infantry:
	var occupancy = battle.get("occupancy")
	return occupancy.soldier_of(multiplayer.get_unique_id()) if occupancy else null
