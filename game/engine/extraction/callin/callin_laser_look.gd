class_name CallinLaserLook
extends RefCounted
## What the Targeting Laser looks and sounds like (Tribes 2 data when it is installed, plain otherwise). The beam takes the
## Tribes 2 laser rifle's beam block (gameplay/weapons_infantry.json: texture, colour, width) when the pack is there, else a
## plain red beam; the sounds are the Targeting Laser's own (TargetingLaserSwitchSound, TargetingLaserPaintSound) when they
## were extracted, else the default pack's lock cues. A missing sound is silent, never an error.

const PACK := "tribes2"
const BEAM_TEXTURE := "fx/textures/nonlingradient.png"
const BEAM_WIDTH := 0.145
const BEAM_COLOR := Color(1.0, 0.1, 0.1, 0.85)
const VALID_COLOR := Color(0.25, 1.0, 0.4)
const INVALID_COLOR := Color(1.0, 0.2, 0.15)
const SOUND_RAISE := ["tribes2:generic_switch", "target_select"]
const SOUND_PAINT := ["tribes2:targetinglaser_paint"]
const SOUND_CONFIRM := ["target_lock"]
const SOUND_CANCEL := ["target_unlock"]


## The colour of a painted spot: green when the call-in can land there, red when not.
static func make_validity_color(ok: bool) -> Color:
	return VALID_COLOR if ok else INVALID_COLOR


## The beam's material: the Tribes 2 beam bitmap when installed, else a plain glow.
static func make_beam_material() -> StandardMaterial3D:
	var tex: Texture2D = null
	if FileAccess.file_exists(Assets.path(BEAM_TEXTURE, PACK)):
		tex = FxLibrary.texture(BEAM_TEXTURE, PACK, "rgba", "")
	var m := FxMaterials.make_unshaded(BEAM_COLOR, tex, true)
	m.texture_repeat = true
	return m


## The first of `names` that is a sound ("" when none is).
static func pick_sound(names: Array) -> String:
	for n in names:
		if Sfx.stream(str(n)) != null:
			return str(n)
	return ""


static func play(names: Array) -> void:
	var picked := pick_sound(names)
	if picked != "":
		Sfx.play_ui(picked)


## True when the Tribes 2 beam bitmap is installed (the plain look is used otherwise).
static func is_beam_installed() -> bool:
	return FileAccess.file_exists(Assets.path(BEAM_TEXTURE, PACK))
