class_name BoundsTint
extends Control
## The red tint and the warning while the local player is outside the combat area: a screen-reading post-process rect (the
## HudLayout FULL zone's "bounds_tint") with a gentle pulse, and "RETURN TO THE COMBAT AREA" with the seconds to the first damage
## where the rule damages. Off inside, dead, and in a support craft: BattleBounds.is_out_of_area decides, as for the damage.

const SHADER := preload("res://engine/shaders/bounds_tint.gdshader")
const TEXT_COLOR := Color(1.0, 0.85, 0.8)
const OUTLINE_COLOR := Color(0.3, 0.0, 0.0)
const FONT_SIZE := 30
const SUB_FONT_SIZE := 18

var battle: Battle
var rect: ColorRect
var warning: Label
var countdown: Label
var _material := ShaderMaterial.new()
## Whether the tint is on, its strength, and the seconds spent outside (tests read them).
var is_on := false
var amount := 0.0
var outside_seconds := 0.0


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "BoundsTint"
	ServerProfile.apply_client_only(self)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_material.shader = SHADER
	rect = ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = _material
	rect.visible = false
	add_child(rect)
	warning = _make_label(FONT_SIZE, str(BoundsVisual.data().get("warning_text", "")))
	countdown = _make_label(SUB_FONT_SIZE, "")


func _make_label(font_size: int, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", TEXT_COLOR)
	l.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	l.add_theme_constant_override("outline_size", 6)
	l.visible = false
	add_child(l)
	return l


## True when the local player is outside the area by the rule that damages him (the same test as the damage).
func is_player_outside() -> bool:
	var p := battle.player
	return p != null and is_instance_valid(p) and p.alive and battle.bounds.is_out_of_area(p)


func _process(delta: float) -> void:
	size = get_viewport_rect().size
	is_on = is_player_outside()
	outside_seconds = outside_seconds + delta if is_on else 0.0
	var layout := HudLayout.of(self)
	layout.declare(&"bounds_tint", Vector2.ONE if is_on else Vector2.ZERO)
	layout.declare(&"bounds_warning", Vector2(HudLayout.ELEMENTS[&"bounds_warning"].max) if is_on else Vector2.ZERO)
	var left := make_seconds_to_damage()
	rect.visible = is_on
	warning.visible = is_on
	countdown.visible = is_on and left >= 0
	if not is_on:
		amount = 0.0
		return
	var pulse := 0.0
	if not BoundsVisual.is_reduced_motion():
		pulse = sin(outside_seconds * TAU * BoundsVisual.value("pulse_hz")) * BoundsVisual.value("pulse_depth")
	amount = clampf(BoundsVisual.value("tint_alpha") * (1.0 + pulse) + 0.25, 0.0, 1.0)
	_material.set_shader_parameter("amount", amount)
	_place(layout.rect_of(&"bounds_warning"), left)


func _place(r: Rect2, left: int) -> void:
	warning.position = r.position
	warning.size = Vector2(r.size.x, r.size.y * 0.6)
	countdown.position = r.position + Vector2(0.0, r.size.y * 0.6)
	countdown.size = Vector2(r.size.x, r.size.y * 0.4)
	if left >= 0:
		countdown.text = str(BoundsVisual.data().get("countdown_text", "%d")) % left


## Whole seconds until the first out-of-area damage while it is still ahead; -1 when the rule does not damage or it began.
func make_seconds_to_damage() -> int:
	if battle.bounds.area_rule != BattleBounds.AREA_DAMAGE:
		return -1
	var left := BattleBounds.DAMAGE_DELAY - outside_seconds
	return int(ceil(left)) if left > 0.0 else -1
