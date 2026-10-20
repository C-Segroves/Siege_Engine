extends RoutedScreen
## Options: the player's name and Operator Setup, control bindings (rebinding through the SiegeInput autoload when it is present),
## master / music volume, music device, Battledrome arena music set, CRT gamma of the original screens and the game-data folder. args: {"home": screen to return to}.
## A new binding that another action of the same context already uses (SiegeInput.find_conflicts)
## is not applied silently: a dialog offers Swap (the other action takes the old control), Clear
## (the other action loses it) or Cancel.

const INPUT_SINGLETON := "/root/SiegeInput"
## Actions shown when SiegeInput cannot list its own (docs/CODING_STANDARDS.md section 2 table).
const FALLBACK_ACTIONS := ["ui_accept", "ui_cancel", "menu_back", "menu_pause", "throttle_up",
	"throttle_down", "throttle_stop", "turn_left", "turn_right", "fire_group_1", "fire_group_2",
	"target_next", "target_nearest", "view_toggle", "command_map", "scoreboard", "look_up", "look_down", "orbit",
	"zoom_in", "zoom_out", "screenshot", "debug_toggle"]
const CAPTURE_TIMEOUT := 5.0              # seconds before a rebinding attempt is abandoned
const CAPTURE_AXIS_THRESHOLD := 0.6       # stick / trigger travel that counts as a binding
const PERCENT := 100.0
const GAMMA_STEP := 0.05
const CONFLICT_QUESTION := "%s is already bound to %s. Swap: %s gets %s instead. Clear: %s loses it."

var _home := ""
var _capture_action := ""
var _capture_button: Button
var _capture_timer: SceneTreeTimer
var _binding_buttons := {}               # action -> Button


func open(args: Dictionary) -> void:
	_home = str(args.get("home", ""))
	set_page_title("options")
	set_back("Back", router.back)
	_add_player_section()
	_add_audio_section()
	_add_display_section()
	content.add_child(ChatOptions.new())
	_add_data_section()
	_add_controls_section()


# ------------------------------------------------------------------ player

## The player's name, and the Operator Setup of his active character slot (armour, body, skin, Herc; OperatorProfile).
func _add_player_section() -> void:
	content.add_child(Widgets.section("Player"))
	content.add_child(NameRow.new())
	content.add_child(Widgets.button("Operator Setup...", _open_operator_setup))


func _open_operator_setup() -> void:
	var profile := OperatorProfile.load_for(Net.player_name)
	var ctx := LoadoutContext.make_for(GameOptionsModel.make_default_settings(GameOptionsModel.KIND_VERSUS), LoadoutContext.ROLE_PLAYER, profile.unlocks)
	OperatorSetup.open(self, ctx, profile.active_slot, profile)


# ------------------------------------------------------------------ audio

func _add_audio_section() -> void:
	content.add_child(Widgets.section("Audio"))
	content.add_child(_volume_row("Master volume", AudioSettings.MASTER_KEY))
	content.add_child(_volume_row("Music volume", AudioSettings.MUSIC_KEY))
	content.add_child(_music_device_row())
	content.add_child(_arena_music_row())
	content.add_child(_voices_row())


func _volume_row(text: String, key: String) -> OptionRow:
	var s := Widgets.slider(0, PERCENT, AudioSettings.level(key) * PERCENT, 5)
	s.value_changed.connect(func(v: float) -> void: AudioSettings.apply_level(key, v / PERCENT))
	return OptionRow.new(text, s).with_value_readout("%d %%")


## Earthsiege / Battledrome FM music as the original played it on a Sound Blaster or an AdLib card.
func _music_device_row() -> OptionRow:
	var labels := MusicLibrary.DEVICES.map(func(d: String) -> String: return MusicLibrary.DEVICE_LABELS[d])
	var o := Widgets.option_button(labels, MusicLibrary.DEVICES.find(MusicLibrary.device()))
	o.item_selected.connect(func(i: int) -> void: AudioSettings.apply_music_device(MusicLibrary.DEVICES[i]))
	return OptionRow.new("Music device", o)


## Battledrome arena music, the original's Preferences MUSIC TYPE (default VARIETY).
func _arena_music_row() -> OptionRow:
	var labels := MusicLibrary.ARENA_SETS.map(func(m: String) -> String: return MusicLibrary.ARENA_SET_LABELS[m])
	var o := Widgets.option_button(labels, MusicLibrary.ARENA_SETS.find(MusicLibrary.arena_set()))
	o.item_selected.connect(func(i: int) -> void: MusicLibrary.set_arena_set(MusicLibrary.ARENA_SETS[i]))
	return OptionRow.new("Battledrome arena music", o)


## Battledrome's announcer and Herc warning voice, the original's Preferences VOICES (default on).
func _voices_row() -> OptionRow:
	var c := Widgets.check_box("Arena announcer and the Herc's warning voice", AudioSettings.voices_on())
	c.toggled.connect(AudioSettings.apply_voices)
	return OptionRow.new("Battledrome voices", c)


# ------------------------------------------------------------------ display

func _add_display_section() -> void:
	content.add_child(Widgets.section("Display"))
	content.add_child(_ui_scale_row())
	content.add_child(_gamma_row())
	var objectives := Widgets.check_box("Show the mission objectives panel in battle", DisplaySettings.objectives_panel_on())
	objectives.toggled.connect(DisplaySettings.apply_objectives_panel)
	content.add_child(OptionRow.new("Mission objectives panel", objectives))
	var missile_cam := Widgets.check_box("Show the missile camera window while your Earthsiege missile flies",
		DisplaySettings.missile_cam_window_on())
	missile_cam.tooltip_text = "A remake extra, on by default. The original games showed the missile camera only on " 		+ "the cockpit MFD's MISSILE CAM page (F6), which stays available; switch this off for the original look."

	missile_cam.toggled.connect(DisplaySettings.apply_missile_cam_window)
	content.add_child(OptionRow.new("Missile cam window", missile_cam))


## The whole UI's size (UiScale): Auto follows the window, or a fixed 75-200 %.
func _ui_scale_row() -> OptionRow:
	var items := ["Auto"]
	for p in UiScale.PERCENTS:
		items.append("%d%%" % p)
	var current := UiScale.percent()
	var b := Widgets.option_button(items, 0 if current == UiScale.AUTO else 1 + UiScale.PERCENTS.find(current))
	b.item_selected.connect(func(i: int) -> void: UiScale.apply_percent(UiScale.AUTO if i == 0 else int(UiScale.PERCENTS[i - 1])))
	return OptionRow.new("UI scale", b)


## Remake brightness of the original 8-bit screens (DisplaySettings): 1.0 = raw VGA palette.
func _gamma_row() -> OptionRow:
	var s := Widgets.slider(DisplaySettings.MIN_GAMMA, DisplaySettings.MAX_GAMMA, DisplaySettings.crt_gamma(), GAMMA_STEP)
	s.value_changed.connect(DisplaySettings.apply_crt_gamma)
	return OptionRow.new("Original screens: CRT gamma", s).with_value_readout("%.2f")


# ------------------------------------------------------------------ game data folder

func _add_data_section() -> void:
	content.add_child(Widgets.section("Game data"))
	var path := Widgets.paragraph(Assets.data_root, "DimLabel")
	var change := Widgets.small_button("Change folder...", _pick_data_folder)
	var reset := Widgets.small_button("Use default", _reset_data_folder)
	var row := OptionRow.new("Data folder", path)
	row.add_child(change)
	row.add_child(reset)
	if WebPlatform.is_active():
		path.text = WebPlatform.NO_DATA_FOLDER_TEXT
		change.disabled = true
		reset.disabled = true
	content.add_child(row)
	if router.make_screen_paths().has("versions"):
		content.add_child(Widgets.button("Tested game versions", func() -> void: router.go("versions")))


func _pick_data_folder() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	add_child(fd)
	fd.dir_selected.connect(func(dir: String) -> void: _apply_data_folder(dir))
	fd.popup_centered_ratio(0.7)


func _reset_data_folder() -> void:
	_apply_data_folder("")


## Points Assets at another data folder ("" = default) and reloads the catalog.
func _apply_data_folder(dir: String) -> void:
	if dir == "":
		Assets.settings.erase("data_dir")
	else:
		Assets.settings["data_dir"] = dir
	Assets.save_settings()
	Assets.refresh()
	Packs.reload()
	router.replace("options", {"home": _home})
	router.current.set_status("Game data folder: %s" % Assets.data_root)


# ------------------------------------------------------------------ controls

func _add_controls_section() -> void:
	var input := _input_singleton()
	content.add_child(Widgets.section("Controls"))
	if input == null:
		content.add_child(Widgets.paragraph("Rebinding is not available in this build (SiegeInput missing).", "DimLabel"))
	else:
		content.add_child(Widgets.paragraph("Select an action, then press the new key, mouse button or gamepad control. "
			+ "A new binding replaces the old one on the same device.", "DimLabel"))
		content.add_child(Widgets.row([Widgets.small_button("Reset all to defaults", _reset_bindings, Widgets.DANGER)]))
	content.add_child(_missile_pitch_row())
	for action in _action_names(input):
		if InputMap.has_action(action):
			content.add_child(_binding_row(action, input != null))


## Earthsiege EO missile steering: what "up" does (MissileSteering pitch setting, saved).
func _missile_pitch_row() -> OptionRow:
	var o := Widgets.option_button(MissileSteering.PITCH_LABELS, MissileSteering.PITCH_MODES.find(MissileSteering.pitch_mode()))
	o.item_selected.connect(func(i: int) -> void: MissileSteering.apply_pitch_mode(MissileSteering.PITCH_MODES[i]))
	return OptionRow.new("Missile steering pitch", o)


func _binding_row(action: String, rebindable: bool) -> OptionRow:
	var b := Widgets.small_button(BindingText.make_action_bindings(action), func() -> void: _start_capture(action))
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.disabled = not rebindable
	_binding_buttons[action] = b
	return OptionRow.new(BindingText.make_action_name(action), b)


func _input_singleton() -> Node:
	return get_node_or_null(INPUT_SINGLETON)


func _action_names(input: Node) -> Array:
	if input != null and input.has_method("action_names"):
		return input.call("action_names")
	return FALLBACK_ACTIONS


func _reset_bindings() -> void:
	ConfirmDialog.ask(self, "Reset every control to its default binding?", func() -> void:
		_input_singleton().call("reset_defaults")
		_refresh_binding_texts()
		set_status("Controls reset to defaults."), "Reset", Widgets.DANGER)


func _refresh_binding_texts() -> void:
	for action in _binding_buttons:
		(_binding_buttons[action] as Button).text = BindingText.make_action_bindings(action)


# ------------------------------------------------------------------ capturing a new binding

func _start_capture(action: String) -> void:
	_capture_action = action
	_capture_button = _binding_buttons[action]
	_capture_button.text = "press a key / button ..."
	set_status("Rebinding %s: press the new control (or wait %d s to cancel)." % [
		BindingText.make_action_name(action), int(CAPTURE_TIMEOUT)])
	_capture_timer = get_tree().create_timer(CAPTURE_TIMEOUT)
	_capture_timer.timeout.connect(_on_capture_timeout.bind(_capture_timer))


func _on_capture_timeout(timer: SceneTreeTimer) -> void:
	if timer == _capture_timer and _capture_action != "":
		_end_capture()
		set_status("Rebinding cancelled.")


func _input(event: InputEvent) -> void:
	if _capture_action == "" or not _is_bindable(event):
		return
	get_viewport().set_input_as_handled()
	var action := _make_capture_target(_capture_action, event)
	var binding := _make_binding(event)
	_end_capture()
	var conflicts: Array = _input_singleton().call("find_conflicts", action, binding)
	if conflicts.is_empty():
		_input_singleton().call("rebind", action, binding)
		_report_bound(action, binding)
	else:
		_ask_conflict(action, binding, conflicts)


func _report_bound(action: String, binding: InputEvent) -> void:
	_refresh_binding_texts()
	set_status("%s bound to %s." % [BindingText.make_action_name(action), BindingText.make_event_text(binding)])


## Swap / Clear / Cancel when `binding` already belongs to `conflicts` (actions of the same context).
func _ask_conflict(action: String, binding: InputEvent, conflicts: Array) -> void:
	var control_name := BindingText.make_event_text(binding)
	var others := ", ".join(PackedStringArray(conflicts.map(BindingText.make_action_name)))
	var first := BindingText.make_action_name(str(conflicts[0]))
	var previous := _make_device_binding_text(action, binding)
	set_status("%s is already used by %s." % [control_name, others])
	var question := CONFLICT_QUESTION % [control_name, others, first, previous, others]
	var dialog := ConfirmDialog.ask(self, question, func() -> void:
		_input_singleton().call("rebind_swapping", action, binding, conflicts)
		_report_bound(action, binding), "Swap")
	dialog.add_choice("Clear", func() -> void:
		_input_singleton().call("rebind_clearing", action, binding, conflicts)
		_report_bound(action, binding), Widgets.DANGER)


## What `action` is bound to now on `binding`'s device ("nothing" when unbound there).
func _make_device_binding_text(action: String, binding: InputEvent) -> String:
	var input := _input_singleton()
	var device: int = input.call("device_of", binding)
	for ev in InputMap.action_get_events(action):
		if int(input.call("device_of", ev)) == device:
			return BindingText.make_event_text(ev)
	return "nothing"


func _end_capture() -> void:
	_capture_action = ""
	_capture_timer = null
	_refresh_binding_texts()


## A pad button pressed for a held action (inventory_toggle: hold pad X) rebinds its tap action, which carries
## the hold (SiegeInput HELD_ACTIONS); any other control binds `action` itself.
static func _make_capture_target(action: String, event: InputEvent) -> String:
	var held := BindingText.make_held_actions()
	if held.has(action) and event is InputEventJoypadButton:
		return str(held[action][0])
	return action


static func _is_bindable(event: InputEvent) -> bool:
	if event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton:
		return event.is_pressed() and not event.is_echo()
	if event is InputEventJoypadMotion:
		return absf((event as InputEventJoypadMotion).axis_value) >= CAPTURE_AXIS_THRESHOLD
	return false


## A device-independent copy of the pressed event (any keyboard / gamepad, full axis direction).
static func _make_binding(event: InputEvent) -> InputEvent:
	var copy := event.duplicate() as InputEvent
	copy.device = -1
	if copy is InputEventJoypadMotion:
		var m := copy as InputEventJoypadMotion
		m.axis_value = signf(m.axis_value)
	if copy is InputEventMouseButton:
		(copy as InputEventMouseButton).position = Vector2.ZERO
		(copy as InputEventMouseButton).global_position = Vector2.ZERO
	return copy
