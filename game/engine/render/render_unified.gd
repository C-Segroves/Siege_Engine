class_name RenderUnified
extends RefCounted
## The `render_unified` setting (docs/RENDER_UNIFICATION.md): shapes draw through the one shared material
## (UnifiedMaterial) instead of each game's own shaders. ON by default since the phase 7 switch. Turn it off with the
## settings.json key "render_unified": false, or the environment variable SIEGE_RENDER_UNIFIED=0 (=1 forces it on).

## Test / tool override: null = follow the setting.
static var force = null


static func enabled() -> bool:
	if force != null:
		return bool(force)
	var env := OS.get_environment("SIEGE_RENDER_UNIFIED")
	if env == "1":
		return true
	if env == "0":
		return false
	return bool(Assets.settings.get("render_unified", true))
