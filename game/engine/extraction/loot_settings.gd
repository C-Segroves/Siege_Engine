class_name LootSettings
## The loot window's setting, kept in user://settings.json (Assets.settings, key "loot"):
##   close_on_damage   the window closes at once when the looter is hit (off: the game runs on behind it and he is
##                     shot at while he picks)

const KEY := "loot"
const CLOSE_ON_DAMAGE := "close_on_damage"


static func make_close_on_damage() -> bool:
	var saved = Assets.settings.get(KEY, {})
	return saved is Dictionary and bool(saved.get(CLOSE_ON_DAMAGE, false))


static func apply_close_on_damage(on: bool) -> void:
	Assets.settings[KEY] = {CLOSE_ON_DAMAGE: on}
	Assets.save_settings()
