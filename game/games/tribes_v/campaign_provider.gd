extends RefCounted
## Standalone campaign provider for Tribes: Vengeance (pack "tribes_v", tools/tv_import.py): the campaign maps in play
## order with their names, objective text and a dialogue excerpt, played on foot by TVMissionRuntime. It reuses the
## Aerial Assault campaign class (games/tribes_aa/campaign_provider.gd), which is parameterised by pack.

const AACampaignProvider := preload("res://games/tribes_aa/campaign_provider.gd")
const PACK := "tribes_v"
const TITLE := "Tribes: Vengeance"


static func start(_variant: String) -> Object:
	return AACampaignProvider.make_for(PACK, PACK, TITLE)


static func restore(d: Dictionary) -> Object:
	return AACampaignProvider.restore(d, PACK, PACK, TITLE)
