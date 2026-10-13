class_name ExtractionShop
extends RefCounted
## Buying and selling between raids (docs/design/extraction.md section 5): the shop sells hand weapons, ammunition,
## gear, backpacks, armour (medium / heavy: light armour is free) and vehicle call-ins at ExtractionItems prices (rating-based, the remake's values) and buys
## anything back at the rules' sell fraction. Herc weapon salvage and valuables are only sold. Purchases go to the
## profile's stash; the caller saves the profile.

const BUY_CATEGORIES := ["weapon", "ammo", "gear", "pack", "armor", "callin"]


## What the shop offers of `category`, optionally only `pack`'s ("" = every game), cheapest first.
static func make_offers(category: String, pack := "") -> Array:
	if not BUY_CATEGORIES.has(category):
		return []
	var offers := ExtractionItems.items_of_kind(category, [pack] if pack != "" else []).filter(func(r: Dictionary) -> bool:
		return int(r.get("price", 0)) > 0)
	offers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa := make_buy_price(str(a.id))
		var pb := make_buy_price(str(b.id))
		return pa < pb or (pa == pb and str(a.id) < str(b.id)))
	return offers


## Units one Buy press gets: a full load of ammunition, else one.
static func make_buy_units(id: String) -> int:
	return int(ExtractionItems.item(id).get("stack", 1)) if ExtractionItems.kind_of(id) == "ammo" else 1


static func make_buy_price(id: String) -> int:
	return ExtractionItems.make_price(id, make_buy_units(id))


## Buys one lot of `id` into the stash; false when it is not for sale or the money does not reach.
static func apply_buy(profile: ExtractionProfile, id: String) -> bool:
	var price := make_buy_price(id)
	if not BUY_CATEGORIES.has(ExtractionItems.kind_of(id)) or price <= 0 or profile.money < price:
		return false
	profile.money -= price
	profile.stash.apply_add_unchecked(id, make_buy_units(id))
	return true


## Sells up to `units` of `id` from the stash; returns the credits earned.
static func apply_sell(profile: ExtractionProfile, id: String, units: int) -> int:
	var n := profile.stash.apply_take(id, units)
	var earned := ExtractionItems.make_sell_price(id, n)
	profile.money += earned
	return earned
