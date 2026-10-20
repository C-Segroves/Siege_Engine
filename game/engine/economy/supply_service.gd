class_name SupplyService
extends RefCounted
## Buying raid supplies (the physical stock of the kit: weapons, ammunition, gear, backpacks) with credits
## (docs/design/lobby_loadout_economy.md section 6.1, extraction extras). The lot goes to the stash, the price comes out
## of the operator's wallet. Both profiles change in memory and the caller saves them. Returns {ok, text, price}.


static func apply_buy(wallet: OperatorProfile, stash_owner: ExtractionProfile, id: String) -> Dictionary:
	if not StoreCatalog.SUPPLY_KINDS.has(ExtractionItems.kind_of(id)) or ExtractionShop.make_buy_price(id) <= 0:
		return {"ok": false, "text": "Not for sale", "price": 0}
	var price := ExtractionShop.make_buy_price(id)
	var units := ExtractionShop.make_buy_units(id)
	if not wallet.apply_spend(price):
		return {"ok": false, "text": StoreService.NOT_ENOUGH % EconomyRules.make_money_text(price), "price": price}
	stash_owner.stash.apply_add_unchecked(id, units)
	return {"ok": true, "text": "Bought %s for %s (to the stash)" % [ExtractionItems.make_stack_text(id, units), EconomyRules.make_money_text(price)], "price": price}
