class_name StoreService
extends RefCounted
## Buying and buying back (docs/design/lobby_loadout_economy.md section 2.6). Both change the profile in memory and
## return {ok, text, price}; the caller saves it.

const NOT_ENOUGH := "Not enough credits (%s needed)"


## Buys the unlock `id` at its first-purchase price. With `ctx` (the match the buyer is in) what that match gives free is not
## sold: medium and heavy armour are free in a match but bought in a raid (user answer O5).
static func apply_buy(profile: OperatorProfile, id: String, ctx: LoadoutContext = null) -> Dictionary:
	if not UnlockId.is_valid(id) or not StoreCatalog.is_known(id):
		return _make_result(false, "Not for sale", 0)
	var free := ctx.is_free(id) if ctx != null else FreeUnlocks.is_free_everywhere(id)
	if free or FreeUnlocks.is_stock_kind(UnlockId.kind_of(id)) or profile.unlocks.owned.has(id):
		return _make_result(false, "Already owned", 0)
	if profile.unlocks.is_lost(id):
		return _make_result(false, "Lost in a raid: buy it back", EconomyRules.rebuy_price())
	var price := StoreCatalog.make_unlock_price(id)
	if not profile.apply_spend(price):
		return _make_result(false, NOT_ENOUGH % EconomyRules.make_money_text(price), price)
	profile.unlocks.apply_add(id)
	return _make_result(true, "Bought %s for %s" % [SlotCheck.make_name(id), EconomyRules.make_money_text(price)], price)


## Buys back a lost unlock of an extraction death for the flat rebuy price.
static func apply_rebuy(profile: OperatorProfile, id: String) -> Dictionary:
	var price := EconomyRules.rebuy_price()
	if not profile.unlocks.is_lost(id):
		return _make_result(false, "Not lost", 0)
	if not EconomyRules.rebuy_kinds().has(UnlockId.kind_of(id)):
		return _make_result(false, "Cannot be bought back", 0)
	if not profile.apply_spend(price):
		return _make_result(false, NOT_ENOUGH % EconomyRules.make_money_text(price), price)
	profile.unlocks.apply_recover(id)
	profile.stats.bought_back = int(profile.stats.get("bought_back", 0)) + 1
	return _make_result(true, "Bought back %s for %s" % [SlotCheck.make_name(id), EconomyRules.make_money_text(price)], price)


static func _make_result(ok: bool, text: String, price: int) -> Dictionary:
	return {"ok": ok, "text": text, "price": price}
