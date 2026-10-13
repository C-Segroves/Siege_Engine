class_name BattleOverlay
extends CanvasLayer
## The battle's 2D layer: the static cockpit picture, the placeholder HUD, the original cockpit
## instruments (CockpitDisplay, when the Herc has cockpit data), the Tab scoreboard and the chat's history
## (chat_log; BattleChat shows it in the ChatPanel on a layer above this one), the mission objectives panel. Every message goes to the chat as a system or radio
## line; the cockpit's own message line (and the plain HUD's) still shows the newest one. The missile camera
## (MissileCam) of the player's vehicle feeds the cockpit's MFD page and the MissileCamWindow.

const SCOREBOARD_POS := Vector2(300, 120)
const SCOREBOARD_FONT_SIZE := 18
const SCOREBOARD_OUTLINE := 5
const SCOREBOARD_HEADER := "%-22s %-12s %4s %5s %6s\n"
const SCOREBOARD_ROW := "%-22s %-12s %4d %5d %6d\n"
const INTRO_SECONDS := 8.0
const PILOTING_SECONDS := 7.0
const RADIO_MESSAGE_SECONDS := 6.0
const CONTROLS_HELP := "W/S throttle  A/D turn  mouse aim  LMB/RMB fire  T/C target  V view  Tab scores  Esc menu"

var cockpit_picture: TextureRect
var hud: HUD
var cockpit: CockpitDisplay     # original instruments (null for vehicles without cockpit data)
var scoreboard: Label
var chat_log := ChatLog.new()
## The translucent mission objectives side panel (build_objectives_panel).
var objectives: ObjectivesPanel
## The player's missile camera and its window (build_cockpit; null on foot).
var missile_cam: MissileCam
var missile_cam_window: MissileCamWindow
## The screen rects of the HUD in use and the chat (Battle: BattleChat.make_occupied_rects + its panel), which
## the missile cam window keeps clear of together with the objectives panel.
var occupied_provider := Callable()


func _init() -> void:
	cockpit_picture = _build_cockpit_picture()
	add_child(cockpit_picture)
	hud = HUD.new()
	add_child(hud)
	scoreboard = _build_scoreboard()
	add_child(scoreboard)


static func _build_cockpit_picture() -> TextureRect:
	var t := TextureRect.new()
	t.set_anchors_preset(Control.PRESET_FULL_RECT)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_SCALE
	t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.visible = false
	return t


static func _build_scoreboard() -> Label:
	var l := Label.new()
	l.position = SCOREBOARD_POS
	l.add_theme_font_size_override("font_size", SCOREBOARD_FONT_SIZE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", SCOREBOARD_OUTLINE)
	l.visible = false
	return l


## Adds the mission objectives side panel of `battle` (ObjectivesPanel).
func build_objectives_panel(battle: Battle) -> void:
	objectives = ObjectivesPanel.new(battle)
	objectives.occupied_provider = make_objectives_occupied_rects
	add_child(objectives)


## The match's objective (the rule that really ends it, BattleRules) plus the control summary,
## shown when the battle starts.
func show_intro(config: Dictionary) -> void:
	var text := "%s  %s" % [BattleRules.make_objective_text(config), CONTROLS_HELP]
	hud.message(text, INTRO_SECONDS)
	chat_log.add(ChatChannels.SYSTEM, "", text)


## Shows the Herc's cockpit: the original instruments if it has them, else the static picture.
func build_cockpit(h: Herc, battle: Node) -> void:
	hud.herc = h
	var ck: String = h.def.get("cockpit", "")
	var img: Image = Assets.load_image("cockpits/%s_0.png" % ck, h.def.get("pack", "es1")) if ck != "" else null
	cockpit_picture.texture = ImageTexture.create_from_image(img) if img else null
	if cockpit:
		cockpit.queue_free()
	hud.visible = true   # an original cockpit hides the HUD while it is up (CockpitDisplay)
	cockpit = CockpitDisplay.create(h, battle)
	if cockpit:
		add_child(cockpit)
		cockpit_picture.texture = null
	_build_missile_cam(h)
	if is_instance_valid(objectives):
		move_child(objectives, -1)   # drawn over the cockpit art (its window frame) and the missile cam window


## The missile camera of the player's vehicle `h` (none for a soldier), for the cockpit and the window.
func _build_missile_cam(h: Herc) -> void:
	for old in [missile_cam, missile_cam_window]:
		if is_instance_valid(old):
			old.queue_free()
	missile_cam = null
	missile_cam_window = null
	if h is Infantry:
		return
	missile_cam = MissileCam.new(h)
	add_child(missile_cam)
	missile_cam_window = MissileCamWindow.new(missile_cam)
	missile_cam_window.cockpit = cockpit
	missile_cam_window.occupied_provider = make_occupied_rects
	add_child(missile_cam_window)
	if cockpit:
		cockpit.missile_cam = missile_cam


## Screen rects the missile cam window must not cover: the HUD's / cockpit's and the chat's (occupied_provider)
## and the objectives panel while it shows.
func make_occupied_rects() -> Array:
	var rects: Array = occupied_provider.call() if occupied_provider.is_valid() else []
	if is_instance_valid(objectives) and objectives.visible and objectives.modulate.a > 0.0:
		rects.append(objectives.get_global_rect())
	return rects


## Screen rects (a screen of size `screen`) the objectives panel keeps clear of: the cockpit's instruments and
## panel (CockpitOccupancy) while it shows, else the plain HUD's meters and the soldier's bars; the chat panel
## and the missile cam window while they show.
func make_objectives_occupied_rects(screen: Vector2) -> Array:
	var rects: Array = []
	if is_instance_valid(cockpit) and cockpit.visible:
		rects = ChatPlacement.make_screen_rects(CockpitOccupancy.make_rects(cockpit), cockpit.canvas_size, screen)
	else:
		rects = HUD.make_occupied_rects(screen) + InfantryHud.make_occupied_rects(screen)
	var battle := get_parent() as Battle
	if battle != null and is_instance_valid(battle.chat) and battle.chat.panel != null:
		rects.append(battle.chat.panel.make_collapsed_rect())
	if is_instance_valid(missile_cam_window) and missile_cam_window.visible:
		rects.append(missile_cam_window.placed_rect)
	return rects


## The arrival message of the local player's body `h`: its seat in a vehicle (a passenger: the soldier in his
## seat; a gunner: the vehicle he guns), on foot, or the vehicle he drives (`herc_name`).
func announce_player(h: Herc, herc_name: String) -> void:
	var soldier := h as Infantry
	if soldier and soldier.stowed and soldier.seat != null and is_instance_valid(soldier.seat.vehicle):
		_announce(make_seat_text(soldier.seat.role, soldier.seat.vehicle, soldier))
	elif soldier:
		announce_on_foot(soldier)
	elif _is_local_gunner(h):
		_announce(make_seat_text(VehicleSeats.GUNNER, h, h))
	else:
		announce_vehicle(h, herc_name)


## "Gunner - Beowulf turret", "Passenger - Havoc", "Passenger - Havoc  (firing: Chaingun)" (an armed seat lists the
## soldier's own weapons; `body` is the controlled body: the vehicle for a gunner, the soldier for a passenger).
static func make_seat_text(role: String, vehicle: Herc, body: Herc) -> String:
	var name := str(vehicle.def.get("name", vehicle.vehicle_id))
	if role == VehicleSeats.GUNNER:
		return "Gunner - %s turret" % name
	var text := "Passenger - %s" % name
	if role == VehicleSeats.ARMED and not body.weapons.is_empty():
		text += "  (firing: %s)" % ", ".join(_make_weapon_names(body))
	return text


func _is_local_gunner(h: Herc) -> bool:
	var crew := TurretCrew.find(h)
	return crew != null and crew.gunner == multiplayer.get_unique_id()


static func _make_weapon_names(h: Herc) -> PackedStringArray:
	var names: PackedStringArray = []
	for w in h.weapons:
		names.append(str(w.def.get("display_name", w.weapon_name)))
	return names


## Tells the player which Herc they drive and with what weapons (career: the hangar's selection).
func announce_vehicle(h: Herc, herc_name: String) -> void:
	var armed := _make_weapon_names(h)
	_announce("You are piloting: %s  (%s)" % [herc_name.to_upper(), ", ".join(armed) if not armed.is_empty() else "unarmed"])


## Tells the player they are on foot, in which armour, and (armours that may pilot) how to board a vehicle.
func announce_on_foot(soldier: Infantry) -> void:
	_announce(make_on_foot_text(soldier))


## "On foot - Light Armor. E: board an empty vehicle" (no boarding hint for armours that can't pilot).
static func make_on_foot_text(soldier: Infantry) -> String:
	var text := "On foot - %s." % str(soldier.armor.get("name", "armour"))
	if bool(soldier.armor.get("can_pilot", false)):
		text += " %s: board an empty vehicle" % OccupancyHint.make_key_text()
	return text


func _announce(msg: String) -> void:
	hud.message(msg, PILOTING_SECONDS)
	chat_log.add(ChatChannels.SYSTEM, "", msg)
	if cockpit:
		# the cockpit message line shows the newest message: this one first, then the earlier ones
		for m in cockpit.messages:
			m[1] += PILOTING_SECONDS
			m[2] += PILOTING_SECONDS
		cockpit.show_message(msg, PILOTING_SECONDS)


func show_message(text: String, seconds: float) -> void:
	chat_log.add(ChatChannels.SYSTEM, "", text)
	_show_on_message_lines(text, seconds)


## A campaign radio line (RadioVoice: when its voice clip starts): the chat's radio channel with the speaker,
## and "SPEAKER: TEXT" on the cockpit's message line as the originals showed their radio. A voice-only line
## (no text: most Tribes 2 training lines) is only heard.
func show_radio(speaker: String, text: String) -> void:
	if text == "":
		return
	chat_log.add(ChatChannels.RADIO, speaker, text)
	_show_on_message_lines("%s: %s" % [speaker, text] if speaker != "" else text, RADIO_MESSAGE_SECONDS)


func _show_on_message_lines(text: String, seconds: float) -> void:
	hud.message(text, seconds)
	if cockpit:
		cockpit.show_message(text, seconds)


## Points the HUD at the live camera; the static cockpit picture only shows from inside.
func apply_view(camera: Camera3D, chasing: bool) -> void:
	hud.camera = camera
	cockpit_picture.visible = not chasing and cockpit_picture.texture != null


func set_scoreboard_visible(on: bool, vehicles: Dictionary) -> void:
	scoreboard.visible = on
	update_scoreboard(vehicles)


func update_scoreboard(vehicles: Dictionary) -> void:
	var rows := vehicles.values()
	rows.sort_custom(func(a, b): return a.kills > b.kills)
	var t := SCOREBOARD_HEADER % ["PILOT", "HERC", "TEAM", "KILLS", "DEATHS"]
	for h in rows:
		t += SCOREBOARD_ROW % [h.display_name.left(22), String(h.def.get("name", "")).left(12), h.team, h.kills, h.deaths]
	scoreboard.text = t
