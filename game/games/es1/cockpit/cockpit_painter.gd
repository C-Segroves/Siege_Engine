class_name CockpitPainter
extends RefCounted
## Base of the cockpit's instrument painters (HUD, gauges, MFD, HDD): shared access to the display's
## state, its canvas, the game's skin (CockpitSkin) and the scene queries every instrument needs.

## Runtime HUD colours (Earthsiege 1 palette indices 0x30..0x3f).
const C_BLUE := 50
const C_RED := 53
const C_GREEN_D := 54
const C_GREEN := 55
const C_GREEN_B := 56
const C_YELLOW := 59
const C_WHITE := 60
const C_LIGHT_YELLOW := 0x38

var display: CockpitDisplay
var canvas: CockpitCanvas
var skin: CockpitSkin
var herc: Herc


func _init(p_display: CockpitDisplay, p_canvas: CockpitCanvas) -> void:
	display = p_display
	canvas = p_canvas
	skin = p_canvas.assets.skin
	herc = p_display.herc


func gauge(key: String) -> Dictionary:
	return display.gauges.get(key, {})


## String `i` of the game's label set `name` (CockpitSkin "strings"), or `fallback`.
func label(name: String, i: int, fallback := "") -> String:
	return canvas.assets.text_string(skin.group(name), i, fallback)


## The label set's own item (CockpitSkin "string_items"), e.g. "TARGET:" inside its group.
func item_label(name: String, fallback := "") -> String:
	return label(name, skin.item(name), fallback)


## Palette colour of skin value `key` in `section` (`fallback` index when the skin has none).
func skin_color(section: String, key: String, fallback: int) -> Color:
	return canvas.color(int(skin.value(section, key, fallback)))


func vehicles() -> Array:
	return RadarContacts.make_units(herc.get_tree()) if herc and herc.is_inside_tree() else []


func nav_points() -> Array:
	return herc.get_tree().get_nodes_in_group("nav_points")


## World yaw the cockpit looks along (HeadingFrame: chassis + torso twist, a flyer's nose without its bank).
func view_yaw() -> float:
	return HeadingFrame.make_heading(herc)


## True while the vehicle has a living target (a vehicle, soldier or targetable structure).
func has_live_target() -> bool:
	return TargetInfo.is_live(herc.target)


## Vehicle id without its pack ("es1:RAPTOR" -> "RAPTOR"); keys the PDG diagrams.
static func make_unit_key(v: Node) -> String:
	if v is Herc:
		var id: String = v.vehicle_id
		var i := id.find(":")
		return id.substr(i + 1) if i >= 0 else id
	return ""


## Wingmen: other living vehicles on the player's team, the radio's squad first in its slot order (so comm
## window k shows the wingman whose voice speaks from slot k), then the other allies.
func wingmen() -> Array:
	var wing := []
	for v in vehicles():
		if v != herc and v.alive and v.team == herc.team:
			wing.append(v)
	return WingmanRadio.make_squad_first(wing)


## Mission clock "MM:SS" (minutes wrap at 100).
func make_clock_text() -> String:
	var s := int(display.clock)
	return "%02d:%02d" % [(s / 60) % 100, s % 60]
