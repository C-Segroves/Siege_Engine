extends RefCounted
## Test helper: keeps the player's own files untouched by a test run. back_up() switches the whole user store
## (UserStore: saves, extraction profiles, careers, settings.json, input.json, content.json) to a test store of this
## process (user://test_store/<pid>, seeded with copies of the player's settings files); restore() deletes it and
## switches back. Nothing of the player's is ever written, and test processes running at the same time never see each
## other's files. (Earlier versions backed the files up and wrote them back, which raced between test processes.)

## Kept for the callers' older signatures.
const FILES := ["es1_careers.json", "es1_careers.moved.json", "settings.json"]


## `_slot` is ignored (the whole store is isolated); kept for the callers' older signature.
func _init(_slot := "") -> void:
	pass


var _made_store := false


## Isolates the store (a test scene already runs in one: UserStore.TEST_SCENES; then nothing changes).
func back_up() -> void:
	if UserStore.is_test_store():
		return
	UserStore.apply_test_store()
	_made_store = true
	Assets.reload_settings()


## Deletes the test store back_up made (one the process started with stays until the process ends).
func restore() -> void:
	if not _made_store:
		return
	UserStore.clear_test_store()
	_made_store = false
	Assets.reload_settings()
