extends SceneTree
## Builds the one theme of the app's own screens (library, launcher, lobby, briefings, options,
## hangar overlay) and saves it as res://engine/ui/siege_theme.tres, the project's default theme.
## Look modelled on the Tribes 2 front end (colours and shapes only, none of its textures): teal /
## cyan-green on a near-black background, translucent panels with thin bright borders, header bars,
## amber highlights and focus, rust for destructive actions.
##   godot --headless --path game --script res://engine/ui/siege_theme.gd
##
## Named variations: HeaderLabel, SectionLabel (a header bar), SubtitleLabel (the title bar's page name),
## DimLabel, StatusLabel, HangarCaption, PrimaryButton, DangerButton, ScreenBackground, ScreenBody,
## ContentPanel (the screen's scrolling column), TitleBar, FooterBar, ModalShade, ModalPanel, HudPanel
## (translucent in-battle side panels), HudTitle, HudLine, HudDoneLine, TightColumn. "Panel" (a built-in
## type, so not a variation) styles Panel nodes and plain PanelContainers as cards.
## Lobby / loadout kit: CreditsLabel, CardPanel, CardPanelSelected, BadgeNotAllowed, BadgeAtRisk, BadgeLost (labels
## with a coloured plate), TabButton (a toggle tab), ReadyDot / ReadyDotOff (a lit / dark status dot), Tooltip (the
## ItemTooltip plate).
## Constants (type "Siege"): margin, gap, label_width, button_width, row_height, font_size_*, narrow_width (the
## content width below which screens use their narrow layout).

const OUTPUT_PATH := "res://engine/ui/siege_theme.tres"

## Colours matched to Tribes 2's own shell profiles (base/scripts.vl2 gui/guiProfiles.cs; values only, no art):
##   $ShellColorBright 173 255 250, $ShellColorDark 130 190 185, $ShellColorVeryDark 0 117 133 (holo / opaque box
##   fill), ShellWindowProfile borderColor 3 124 134, ShellTextProfile fontColor 66 229 244, ShellLargeLabel /
##   ShellTextArray fontColor 60 180 180, fontColorHL 6 245 215, DisabledTextProfile 128 128 128,
##   ShellButtonProfile fontColor 8 19 6 / fontColorHL 25 68 56, memberListProfile 255 222 0 (the amber accent);
## and the shell bitmaps' dominant colours (sampled, not used): buttons 16 144 112, tab frame 16 160 128 at ~65 %
## alpha, fields 16 64 64 at ~40 %, selection bar 96 240 224.
const BACKGROUND := Color8(4, 12, 14)
const BACKGROUND_GLOW := Color8(0, 52, 60)
const STEEL_DARK := Color8(16, 64, 64, 120)
const STEEL := Color8(16, 72, 72, 150)
const STEEL_LIGHT := Color8(3, 124, 134)
const STEEL_BLUE := Color8(130, 190, 185)
const TEAL_BRIGHT := Color8(173, 255, 250)
const SHELL_VERY_DARK := Color8(0, 117, 133)
const HEADER_FILL := Color8(16, 160, 128, 166)
const BUTTON_FILL := Color8(16, 144, 112, 220)
const BUTTON_HOVER_FILL := Color8(32, 192, 144, 235)
const BUTTON_TEXT := Color8(8, 19, 6)
const BUTTON_TEXT_HL := Color8(25, 68, 56)
const SELECTION := Color8(96, 240, 224, 204)
const TEXT := Color8(66, 229, 244)
const TEXT_DIM := Color8(60, 180, 180)
const TEXT_HL := Color8(6, 245, 215)
const TEXT_DISABLED := Color8(128, 128, 128)
const AMBER := Color8(255, 222, 0)
const AMBER_DARK := Color8(120, 96, 8, 230)
const RUST := Color(0.50, 0.18, 0.10, 0.88)
const RUST_LIGHT := Color("e0683c")
const SHADE := Color(0.0, 0.02, 0.03, 0.62)
const HUD_FILL := Color8(16, 64, 64, 120)
const DONE := Color8(40, 247, 113)

const FONT_NAMES := ["Bahnschrift", "Segoe UI", "Arial", "sans-serif"]
const SIZES := {
	"margin": 28, "gap": 10, "label_width": 180, "button_width": 300, "row_height": 40,
	"font_size_small": 14, "font_size_body": 17, "font_size_section": 22, "font_size_header": 30,
	"narrow_width": 900,
}
const BORDER := 1
const FOCUS_BORDER := 2
const CORNER := 2
const BUTTON_PADDING := Vector2(14, 6)
const CHECK_ICON_SIZE := 20
const CHECK_FRAME := 2
const CHECK_INSET := 5


func _init() -> void:
	var err := ResourceSaver.save(make_theme(), OUTPUT_PATH)
	print("siege_theme: saved %s (error %d)" % [OUTPUT_PATH, err])
	quit(0 if err == OK else 1)


## The complete theme (no side effects; `_init` saves it).
static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = _make_font()
	t.default_font_size = SIZES.font_size_body
	for k in SIZES:
		t.set_constant(k, "Siege", SIZES[k])
	_add_labels(t)
	_add_buttons(t)
	_add_panels(t)
	_add_inputs(t)
	_add_containers(t)
	_add_popups(t)
	_add_kit(t)
	return t


static func _make_font() -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(FONT_NAMES)
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return f


static func _box(fill: Color, border: Color, border_width := BORDER, padding := BUTTON_PADDING) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = border
	s.set_border_width_all(border_width)
	s.set_corner_radius_all(CORNER)
	s.content_margin_left = padding.x
	s.content_margin_right = padding.x
	s.content_margin_top = padding.y
	s.content_margin_bottom = padding.y
	return s


static func _focus_box() -> StyleBoxFlat:
	var s := _box(Color(0, 0, 0, 0), AMBER, FOCUS_BORDER)
	s.draw_center = false
	s.expand_margin_left = 2
	s.expand_margin_right = 2
	s.expand_margin_top = 2
	s.expand_margin_bottom = 2
	return s


static func _empty_box() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()


# ------------------------------------------------------------------ labels

static func _add_labels(t: Theme) -> void:
	t.set_color("font_color", "Label", TEXT)
	_label_variation(t, "HeaderLabel", AMBER, SIZES.font_size_header)
	_label_variation(t, "SectionLabel", TEAL_BRIGHT, SIZES.font_size_section)
	t.set_stylebox("normal", "SectionLabel", _make_header_bar())
	_label_variation(t, "SubtitleLabel", TEAL_BRIGHT, SIZES.font_size_section)
	_label_variation(t, "DimLabel", TEXT_DIM, SIZES.font_size_small)
	_label_variation(t, "StatusLabel", AMBER, SIZES.font_size_body)
	_label_variation(t, "HangarCaption", AMBER, SIZES.font_size_section)
	t.set_color("font_outline_color", "HangarCaption", Color(0, 0, 0, 0.9))
	t.set_constant("outline_size", "HangarCaption", 6)


## A Tribes 2 style header bar: translucent teal with a bright left edge and a thin underline.
static func _make_header_bar() -> StyleBoxFlat:
	var bar := _box(HEADER_FILL, TEAL_BRIGHT, 0, Vector2(12, 3))
	bar.border_width_left = 4
	bar.border_width_bottom = 1
	bar.set_corner_radius_all(0)
	return bar


static func _label_variation(t: Theme, name: String, color: Color, font_size: int) -> void:
	t.set_type_variation(name, "Label")
	t.set_color("font_color", name, color)
	t.set_font_size("font_size", name, font_size)


# ------------------------------------------------------------------ buttons

static func _add_buttons(t: Theme) -> void:
	for type in ["Button", "OptionButton", "CheckBox", "CheckButton", "MenuButton"]:
		_button_colors(t, type, TEXT)
		t.set_stylebox("focus", type, _focus_box())
	for raised in ["Button", "OptionButton", "MenuButton"]:
		_button_boxes(t, raised, BUTTON_FILL, TEAL_BRIGHT)
		_shell_button_text(t, raised)
	for flat in ["CheckBox", "CheckButton"]:
		t.set_color("font_pressed_color", flat, TEXT)
		for state in ["normal", "hover", "pressed", "disabled", "hover_pressed"]:
			t.set_stylebox(state, flat, _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0))
	_add_check_icons(t)
	_button_variation(t, "PrimaryButton", AMBER_DARK, AMBER)
	_button_variation(t, "DangerButton", RUST, RUST_LIGHT)


## Check boxes drawn for the dark panels: a bright teal frame, empty when off, an amber square when on.
static func _add_check_icons(t: Theme) -> void:
	var off := _make_check_icon(TEAL_BRIGHT, Color(0, 0, 0, 0))
	var on := _make_check_icon(TEAL_BRIGHT, AMBER)
	var off_dim := _make_check_icon(TEXT_DISABLED, Color(0, 0, 0, 0))
	var on_dim := _make_check_icon(TEXT_DISABLED, TEXT_DISABLED)
	for type in ["CheckBox", "CheckButton"]:
		for prefix in ["", "radio_"]:
			t.set_icon(prefix + "unchecked", type, off)
			t.set_icon(prefix + "checked", type, on)
			t.set_icon(prefix + "unchecked_disabled", type, off_dim)
			t.set_icon(prefix + "checked_disabled", type, on_dim)


## A CHECK_ICON_SIZE square: a 2-pixel `frame`, a dark well and (when `fill` is opaque) a `fill` square inside.
static func _make_check_icon(frame: Color, fill: Color) -> ImageTexture:
	var n := CHECK_ICON_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(BACKGROUND)
	for i in n:
		for w in CHECK_FRAME:
			img.set_pixel(i, w, frame)
			img.set_pixel(i, n - 1 - w, frame)
			img.set_pixel(w, i, frame)
			img.set_pixel(n - 1 - w, i, frame)
	if fill.a > 0.0:
		img.fill_rect(Rect2i(CHECK_INSET, CHECK_INSET, n - CHECK_INSET * 2, n - CHECK_INSET * 2), fill)
	return ImageTexture.create_from_image(img)


## Tribes 2 shell buttons: dark text on the bright teal button (ShellButtonProfile fontColor / fontColorHL).
static func _shell_button_text(t: Theme, type: String) -> void:
	t.set_color("font_color", type, BUTTON_TEXT)
	t.set_color("font_focus_color", type, BUTTON_TEXT)
	for state in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(state, type, BUTTON_TEXT_HL)
	t.set_color("font_disabled_color", type, TEXT_DISABLED)


static func _button_colors(t: Theme, type: String, color: Color) -> void:
	t.set_color("font_color", type, color)
	t.set_color("font_hover_color", type, AMBER)
	t.set_color("font_focus_color", type, AMBER)
	t.set_color("font_pressed_color", type, AMBER)
	t.set_color("font_hover_pressed_color", type, AMBER)
	t.set_color("font_disabled_color", type, TEXT_DISABLED)


static func _button_boxes(t: Theme, type: String, fill: Color, border: Color) -> void:
	t.set_stylebox("normal", type, _box(fill, border))
	t.set_stylebox("hover", type, _box(BUTTON_HOVER_FILL if fill == BUTTON_FILL else fill.lightened(0.08), TEAL_BRIGHT))
	t.set_stylebox("pressed", type, _box(fill.darkened(0.2), AMBER))
	t.set_stylebox("hover_pressed", type, _box(fill.darkened(0.1), AMBER))
	t.set_stylebox("disabled", type, _box(Color8(72, 72, 72, 128), Color8(128, 128, 128, 128)))


static func _button_variation(t: Theme, name: String, fill: Color, border: Color) -> void:
	t.set_type_variation(name, "Button")
	_button_boxes(t, name, fill, border)
	_button_colors(t, name, Color.WHITE)


# ------------------------------------------------------------------ panels

static func _add_panels(t: Theme) -> void:
	var card := _box(STEEL_DARK, STEEL_LIGHT, BORDER, Vector2(16, 12))
	card.border_width_left = 3
	card.border_color = STEEL_BLUE
	# "Panel" is a built-in type, so it cannot be a variation: Panel nodes and plain
	# PanelContainers both draw the card; every other panel names its variation.
	t.set_stylebox("panel", "Panel", card)
	t.set_stylebox("panel", "PanelContainer", card)
	_panel_variation(t, "ScreenBackground", _make_background())
	var bar := _box(HEADER_FILL, TEAL_BRIGHT, 0, Vector2(SIZES.margin, 10))
	bar.border_width_bottom = 2
	_panel_variation(t, "TitleBar", bar)
	var footer := _box(STEEL_DARK, STEEL_BLUE, 0, Vector2(SIZES.margin, 10))
	footer.border_width_top = 1
	_panel_variation(t, "FooterBar", footer)
	_panel_variation(t, "ScreenBody", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, Vector2(SIZES.margin, SIZES.margin * 0.6)))
	_panel_variation(t, "ModalShade", _box(SHADE, SHADE, 0, Vector2.ZERO))
	var modal := _box(STEEL, TEAL_BRIGHT, BORDER, Vector2(24, 20))
	modal.border_width_top = 3
	_panel_variation(t, "ModalPanel", modal)
	_add_hud(t)


## Near-black with a soft teal glow towards the top left (a generated gradient, no game texture).
static func _make_background() -> StyleBoxTexture:
	var g := Gradient.new()
	g.set_color(0, BACKGROUND_GLOW)
	g.set_color(1, BACKGROUND)
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.15, 0.0)
	tex.fill_to = Vector2(1.1, 1.2)
	tex.width = 256
	tex.height = 256
	var box := StyleBoxTexture.new()
	box.texture = tex
	return box


## Translucent in-battle side panels (the mission objectives): HudPanel, HudTitle, HudLine, HudDoneLine.
static func _add_hud(t: Theme) -> void:
	var panel := _box(HUD_FILL, STEEL_BLUE, BORDER, Vector2(12, 8))
	panel.border_width_top = 3
	_panel_variation(t, "HudPanel", panel)
	_label_variation(t, "HudTitle", TEAL_BRIGHT, SIZES.font_size_body)
	_label_variation(t, "HudLine", TEXT, SIZES.font_size_small)
	_label_variation(t, "HudDoneLine", DONE, SIZES.font_size_small)
	for name in ["HudTitle", "HudLine", "HudDoneLine"]:
		t.set_color("font_outline_color", name, Color(0, 0, 0, 0.85))
		t.set_constant("outline_size", name, 3)


static func _panel_variation(t: Theme, name: String, box: StyleBox) -> void:
	t.set_type_variation(name, "PanelContainer")
	t.set_stylebox("panel", name, box)


# ------------------------------------------------------------------ inputs

static func _add_inputs(t: Theme) -> void:
	t.set_stylebox("normal", "LineEdit", _box(BACKGROUND, STEEL_LIGHT))
	t.set_stylebox("focus", "LineEdit", _focus_box())
	t.set_stylebox("read_only", "LineEdit", _box(STEEL_DARK, STEEL_DARK))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("caret_color", "LineEdit", AMBER)
	t.set_color("selection_color", "LineEdit", STEEL_BLUE)
	t.set_color("font_placeholder_color", "LineEdit", TEXT_DIM)
	_add_slider(t)
	_add_progress(t)


static func _add_slider(t: Theme) -> void:
	var track := _box(BACKGROUND, STEEL_LIGHT, BORDER, Vector2(0, 3))
	t.set_stylebox("slider", "HSlider", track)
	var fill := _box(STEEL_BLUE, STEEL_BLUE, 0, Vector2(0, 3))
	t.set_stylebox("grabber_area", "HSlider", fill)
	var fill_hot := _box(AMBER, AMBER, 0, Vector2(0, 3))
	t.set_stylebox("grabber_area_highlight", "HSlider", fill_hot)
	t.set_stylebox("focus", "HSlider", _focus_box())


static func _add_progress(t: Theme) -> void:
	t.set_stylebox("background", "ProgressBar", _box(BACKGROUND, STEEL_LIGHT, BORDER, Vector2(0, 2)))
	t.set_stylebox("fill", "ProgressBar", _box(AMBER_DARK, AMBER, BORDER, Vector2(0, 2)))
	t.set_color("font_color", "ProgressBar", TEXT)


# ------------------------------------------------------------------ containers and popups

static func _add_containers(t: Theme) -> void:
	t.set_constant("separation", "VBoxContainer", SIZES.gap)
	t.set_constant("separation", "HBoxContainer", SIZES.gap)
	t.set_type_variation("TightColumn", "VBoxContainer")
	t.set_constant("separation", "TightColumn", 0)
	t.set_constant("h_separation", "GridContainer", SIZES.gap)
	t.set_constant("v_separation", "GridContainer", SIZES.gap / 2)
	t.set_constant("h_separation", "HFlowContainer", SIZES.gap)
	t.set_constant("v_separation", "HFlowContainer", SIZES.gap)
	t.set_stylebox("panel", "ScrollContainer", _empty_box())
	t.set_stylebox("focus", "ScrollContainer", _empty_box())
	t.set_type_variation("ContentPanel", "ScrollContainer")
	t.set_stylebox("panel", "ContentPanel", _box(STEEL_DARK, STEEL_LIGHT, BORDER, Vector2(16, 12)))
	t.set_stylebox("scroll", "VScrollBar", _box(STEEL_DARK, STEEL_DARK, 0, Vector2(4, 0)))
	t.set_stylebox("grabber", "VScrollBar", _box(STEEL_LIGHT, STEEL_LIGHT, 0, Vector2(4, 0)))
	t.set_stylebox("grabber_highlight", "VScrollBar", _box(STEEL_BLUE, STEEL_BLUE, 0, Vector2(4, 0)))
	t.set_stylebox("grabber_pressed", "VScrollBar", _box(AMBER, AMBER, 0, Vector2(4, 0)))


static func _add_popups(t: Theme) -> void:
	t.set_stylebox("panel", "PopupMenu", _box(Color8(4, 30, 34, 240), TEAL_BRIGHT, BORDER, Vector2(4, 4)))
	t.set_stylebox("hover", "PopupMenu", _box(SELECTION, TEAL_BRIGHT, BORDER, Vector2(4, 2)))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", BUTTON_TEXT)
	t.set_color("font_separator_color", "PopupMenu", STEEL_BLUE.lightened(0.35))
	t.set_color("font_disabled_color", "PopupMenu", TEXT_DISABLED)
	t.set_stylebox("panel", "TooltipPanel", _box(STEEL_DARK, AMBER, BORDER, Vector2(8, 4)))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_stylebox("panel", "AcceptDialog", _box(STEEL, STEEL_BLUE, BORDER, Vector2(16, 12)))
	t.set_stylebox("embedded_border", "Window", _box(STEEL, STEEL_BLUE, BORDER, Vector2(0, 28)))
	t.set_color("title_color", "Window", AMBER)


# ------------------------------------------------------------------ lobby / loadout kit

const BADGE_RED := Color8(150, 40, 30, 230)
const BADGE_AMBER := Color8(150, 110, 0, 230)
const BADGE_GREY := Color8(70, 80, 80, 230)
const READY_DOT_SIZE := 14
const TAB_PADDING := Vector2(18, 8)


## Credits readout, selectable cards, state badges, slot / pane tabs, the ready dot and the tooltip plate.
static func _add_kit(t: Theme) -> void:
	_label_variation(t, "CreditsLabel", AMBER, SIZES.font_size_section)
	_add_cards(t)
	_add_badges(t)
	_add_tab_button(t)
	_add_ready_dots(t)
	_panel_variation(t, "Tooltip", _box(Color8(4, 30, 34, 240), AMBER, BORDER, Vector2(12, 8)))


static func _add_cards(t: Theme) -> void:
	var card := _box(STEEL_DARK, STEEL_LIGHT, BORDER, Vector2(16, 12))
	card.border_width_left = 3
	card.border_color = STEEL_BLUE
	_panel_variation(t, "CardPanel", card)
	var selected := _box(STEEL, AMBER, FOCUS_BORDER, Vector2(16, 12))
	selected.border_width_left = 4
	_panel_variation(t, "CardPanelSelected", selected)


## A small coloured plate behind a Label: not allowed (red), at risk (amber), lost (grey).
static func _add_badges(t: Theme) -> void:
	var badges := {"BadgeNotAllowed": BADGE_RED, "BadgeAtRisk": BADGE_AMBER, "BadgeLost": BADGE_GREY}
	for name in badges:
		_label_variation(t, name, Color.WHITE, SIZES.font_size_small)
		t.set_stylebox("normal", name, _box(badges[name], badges[name].lightened(0.3), BORDER, Vector2(6, 1)))


## A toggle tab: dim when off, bright with an amber underline when it is the selected tab.
static func _add_tab_button(t: Theme) -> void:
	t.set_type_variation("TabButton", "Button")
	var off := _box(STEEL_DARK, STEEL_LIGHT, BORDER, TAB_PADDING)
	t.set_stylebox("normal", "TabButton", off)
	t.set_stylebox("hover", "TabButton", _box(STEEL, TEAL_BRIGHT, BORDER, TAB_PADDING))
	var on := _box(BUTTON_FILL, TEAL_BRIGHT, BORDER, TAB_PADDING)
	on.border_width_bottom = FOCUS_BORDER + 1
	on.border_color = AMBER
	t.set_stylebox("pressed", "TabButton", on)
	t.set_stylebox("hover_pressed", "TabButton", on)
	t.set_color("font_color", "TabButton", TEXT)
	for state in ["font_hover_color", "font_focus_color"]:
		t.set_color(state, "TabButton", AMBER)
	for state in ["font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(state, "TabButton", BUTTON_TEXT)


## A round status dot (PanelContainer): lit green for ready, dark teal for not ready.
static func _add_ready_dots(t: Theme) -> void:
	for entry in [["ReadyDot", DONE], ["ReadyDotOff", STEEL_DARK]]:
		var dot := _box(entry[1], entry[1].lightened(0.3), BORDER, Vector2.ZERO)
		dot.set_corner_radius_all(READY_DOT_SIZE / 2)
		_panel_variation(t, entry[0], dot)
