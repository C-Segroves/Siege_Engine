class_name ShellMenu
extends RefCounted
## One DLG\MENU<n> dialog instance: layout from the exported DLG json, original panel art, DFN fonts,
## CORNERS.DBA bitmap buttons, STYLES.DAT colours. Draws into the 320x200 index frame buffer and turns
## mouse / keyboard input into activated controls (docs/formats/shell.md §4).

## DLG control types
const T_WINDOW := 0
const T_TEXT := 1
const T_EDIT := 2
const T_BUTTON := 3
const T_TEXT_R := 4
const T_TEXT_C := 5
const T_GADGET := 14
const T_LIST := 15
const T_GFX_LIST := 16
const T_ANIM_LIST := 17
const T_SEPARATOR := 18

## The one place the shell reads raw keys (docs/CODING_STANDARDS.md §2): the DLG files bind their
## buttons to DOS scan codes, so key events are translated through this adapter table
## (Godot keycode -> PC scan code). Everything else goes through the SiegeInput actions.
const SCANCODES := {
	KEY_ESCAPE: 1, KEY_SPACE: 57, KEY_ENTER: 28, KEY_KP_ENTER: 28, KEY_UP: 72, KEY_DOWN: 80, KEY_LEFT: 75,
	KEY_RIGHT: 77, KEY_PAGEUP: 73, KEY_PAGEDOWN: 81, KEY_KP_ADD: 78, KEY_KP_SUBTRACT: 74, KEY_EQUAL: 78,
	KEY_MINUS: 74, KEY_HOME: 71, KEY_END: 79, KEY_I: 23, KEY_E: 18, KEY_W: 17,
}
const SCAN_ESCAPE := 1
const SCAN_ENTER := 28
## set_items(): keep the current selection.
const KEEP_SELECTION := -2
## move_highlight(): weight of the sideways offset against the distance along the direction.
const SIDEWAYS_PENALTY := 2.0
const NAVIGABLE_TYPES := [T_BUTTON, T_EDIT, T_LIST, T_GFX_LIST]
## STYLES.DAT entries: MTButton states (ctor 0x1cde8 stores styles 0/1/2 with fonts active/pushed/inactive)
const STYLE_NORMAL := 0
const STYLE_PUSHED := 1
const STYLE_INACTIVE := 2
const STYLE_FIELD := 3
const STYLE_COUNT := 4

var id := 0
var data := {}
var title := ""
var window_rect := Rect2i()     # screen coords
var origin := Vector2i.ZERO
var panel: Image
var plain := false              # window flags 1: no panel / title
var controls: Array = []        # runtime control dictionaries
var hover := -1                 # control under the cursor / gamepad highlight
var pressed := -1
var focus := -1                 # focused edit box
var host: Object                # provides list_items(menu, ctl) and draw_gadget(menu, ctl, img) (optional)
var styles: Array[ShellStyle] = []   # STYLES.DAT entries (0 normal, 1 pushed, 2 inactive, 3 field)
var corners: Array = []
var _blink := 0.0


static func create(menu_id: int, p_host: Object = null) -> ShellMenu:
	var m := ShellMenu.new()
	m.id = menu_id
	m.host = p_host
	m.data = ShellData.dlg(menu_id)
	if m.data.is_empty():
		return null
	var w: Dictionary = m.data.window
	var r: Array = w.rect
	m.window_rect = Rect2i(int(r[0]), int(r[1]), int(r[2]) - int(r[0]), int(r[3]) - int(r[1]))
	m.origin = m.window_rect.position
	m.plain = int(w.flags) == 1
	m.title = str(w.label) if w.label != null else ""
	if not m.plain and m.data.get("panel") != null:
		var frames := ShellData.sheet(str(m.data.panel), "RES32")
		if not frames.is_empty():
			m.panel = frames[0]
	for k in STYLE_COUNT:
		m.styles.append(ShellStyle.load_style(k))
	m.corners = ShellData.sheet("CORNERS", "RES32")
	for c in m.data.controls:
		var sr: Array = c.screen_rect
		var ctl: Dictionary = c.duplicate(true)
		ctl["r"] = Rect2i(int(sr[0]), int(sr[1]), int(sr[2]) - int(sr[0]) + 1, int(sr[3]) - int(sr[1]) + 1)
		ctl["enabled"] = true
		ctl["visible"] = true
		ctl["items"] = []
		ctl["sel"] = -1
		ctl["top"] = 0
		ctl["text"] = ""
		if ctl.label == null:
			ctl.label = ""
		m.controls.append(ctl)
	return m


## Adds an extra text button (window-relative rect x1,y1,x2,y2) — used for the remake-only entries.
func add_button(label: String, cmd_id: int, rel: Rect2i, hotkey := 0) -> Dictionary:
	var ctl := {"index": controls.size() + 1, "type": T_BUTTON, "flags": 0, "hotkey": hotkey, "id": cmd_id,
		"label": label, "r": Rect2i(origin + rel.position, rel.size), "enabled": true, "visible": true,
		"items": [], "sel": -1, "top": 0, "text": "", "extra": true}
	controls.append(ctl)
	return ctl


## Adds an invisible click area (gadget) at screen rect `r`, e.g. the ARMAMENT hardpoint hotspots.
func add_gadget(cmd_id: int, r: Rect2i) -> Dictionary:
	var ctl := {"index": controls.size() + 1, "type": T_GADGET, "flags": 0, "hotkey": 0, "id": cmd_id,
		"label": "", "r": r, "enabled": true, "visible": true, "items": [], "sel": -1, "top": 0, "text": "", "extra": true}
	controls.append(ctl)
	return ctl


func find(cmd_id: int, type := -1) -> Dictionary:
	for c in controls:
		if int(c.id) == cmd_id and (type < 0 or int(c.type) == type):
			return c
	return {}


func first_list() -> Dictionary:
	for c in controls:
		if int(c.type) == T_LIST and int(c.flags) == 0:
			return c
	for c in controls:
		if int(c.type) in [T_LIST, T_GFX_LIST]:
			return c
	return {}


func set_items(cmd_id: int, items: Array, sel := KEEP_SELECTION) -> void:
	var c := find(cmd_id)
	if c.is_empty():
		return
	c.items = items
	if sel != KEEP_SELECTION:
		c.sel = sel
	elif c.sel >= items.size():
		c.sel = items.size() - 1
	if c.sel < 0 and not items.is_empty() and int(c.type) == T_LIST:
		c.sel = 0


func selected_item(cmd_id: int) -> String:
	var c := find(cmd_id)
	if c.is_empty() or c.sel < 0 or c.sel >= c.items.size():
		return ""
	return str(c.items[c.sel])


# ------------------------------------------------------------------ drawing

func font(n: String) -> ShellFont:
	return ShellData.font(n)


func draw(img: Image, delta := 0.0) -> void:
	_blink += delta
	if panel:
		ShellData.blit(img, panel, origin.x, origin.y)
	elif not plain:
		draw_box(img, Rect2i(window_rect.position, window_rect.size + Vector2i.ONE), STYLE_NORMAL)
	if title != "" and not plain:
		var f := font("TITLE")
		f.draw(img, origin.x + (window_rect.size.x - f.width(title)) / 2, origin.y + 4, title)
	for i in controls.size():
		var c: Dictionary = controls[i]
		if not c.visible:
			continue
		match int(c.type):
			T_BUTTON:
				ShellButton.draw(self, img, i, c)
			T_TEXT, T_TEXT_R, T_TEXT_C:
				var txt: String = c.text if c.text != "" else str(c.label)
				var j := 0 if int(c.type) == T_TEXT else (1 if int(c.type) == T_TEXT_R else 2)
				font("GRAY").draw_in(img, c.r, txt, j)
			T_EDIT:
				draw_frame(img, c.r, STYLE_FIELD)
				var ef := font("NM_GREEN")
				var tx: int = c.r.position.x + 3
				var ty: int = c.r.position.y + (c.r.size.y - ef.height) / 2 + 1
				var end_x := ef.draw(img, tx, ty, c.text)
				if focus == i and int(_blink * 3.0) % 2 == 0:
					ef.draw(img, end_x, ty, "_")
			T_LIST:
				_draw_list(img, c)
			T_SEPARATOR:
				var sr: Array = c.rect
				ShellData.line(img, int(sr[0]), int(sr[1]), int(sr[0]), int(sr[3]), 16)
			T_GADGET, T_GFX_LIST, T_ANIM_LIST:
				if host and host.has_method("draw_gadget"):
					host.draw_gadget(self, c, img)
				elif int(c.type) == T_GFX_LIST:
					_draw_list(img, c)


## Style box `s` (face, rings, corners) over the inclusive rect `r` (GO.EXE 0x44b86).
func draw_box(img: Image, r: Rect2i, s: int) -> void:
	styles[s].draw_box(img, r, corners)


## Rings and corners of style `s` without the face.
func draw_frame(img: Image, r: Rect2i, s: int) -> void:
	styles[s].draw_frame(img, r, corners)


func line_height() -> int:
	return font("NM_GREEN").height + 1


func visible_rows(c: Dictionary) -> int:
	return maxi(1, (c.r.size.y - 2) / line_height())


func _draw_list(img: Image, c: Dictionary) -> void:
	var items: Array = c.items
	if int(c.flags) == 1:      # single value field (e.g. MISSION PARAMS values, current pilot)
		var v := str(items[c.sel]) if c.sel >= 0 and c.sel < items.size() else (str(items[0]) if not items.is_empty() else "")
		font("NM_GREEN").draw_in(img, c.r, v, 2)
		return
	var lh := line_height()
	var rows := visible_rows(c)
	var y: int = c.r.position.y + 2
	for k in range(c.top, mini(items.size(), c.top + rows)):
		var f := font("NM_WHITE") if k == c.sel else font("NM_GREEN")
		if k == c.sel:
			ShellData.fill(img, Rect2i(c.r.position.x + 1, y - 1, c.r.size.x - 2, lh), 12)
		f.draw(img, c.r.position.x + 3, y, str(items[k]))
		y += lh


func scroll(c: Dictionary, d: int) -> void:
	if c.is_empty():
		return
	var n: int = c.items.size()
	if n == 0:
		return
	c.sel = clampi(c.sel + d, 0, n - 1)
	var rows := visible_rows(c)
	if c.sel < c.top:
		c.top = c.sel
	elif c.sel >= c.top + rows:
		c.top = c.sel - rows + 1


## Scrolls list `c` so its selection is visible.
func scroll_into_view(c: Dictionary) -> void:
	var rows := visible_rows(c)
	if c.sel < c.top:
		c.top = maxi(c.sel, 0)
	elif c.sel >= c.top + rows:
		c.top = c.sel - rows + 1
	c.top = clampi(c.top, 0, maxi(0, c.items.size() - rows))


# ------------------------------------------------------------------ input

func control_at(p: Vector2i) -> int:
	for i in range(controls.size() - 1, -1, -1):
		var c: Dictionary = controls[i]
		if c.visible and c.r.has_point(p) and int(c.type) in [T_BUTTON, T_EDIT, T_LIST, T_GADGET, T_GFX_LIST]:
			return i
	return -1


func mouse_move(p: Vector2i) -> void:
	hover = control_at(p)


## Returns the control that was clicked (lists/edit boxes act on press) or {}.
func mouse_down(p: Vector2i) -> Dictionary:
	var i := control_at(p)
	hover = i
	if i < 0:
		return {}
	var c: Dictionary = controls[i]
	match int(c.type):
		T_BUTTON:
			if c.enabled:
				pressed = i
		T_EDIT:
			focus = i
		T_LIST, T_GFX_LIST:
			if int(c.flags) == 1:
				if not c.items.is_empty():
					c.sel = (c.sel + 1) % c.items.size()
			else:
				var k: int = c.top + (p.y - c.r.position.y - 2) / line_height()
				if k >= 0 and k < c.items.size():
					c.sel = k
			return c
		T_GADGET:
			return c
	return {}


## Returns the activated button or {}.
func mouse_up(p: Vector2i) -> Dictionary:
	var i := pressed
	pressed = -1
	if i >= 0 and control_at(p) == i:
		return controls[i]
	return {}


## The button bound to the key of `ev` through the scan-code adapter table, or {}.
func hotkey_for_key(ev: InputEventKey) -> Dictionary:
	return hotkey_for_scan(SCANCODES.get(ev.keycode, -1))


## The enabled, visible button whose DLG hotkey is scan code `sc`, or {}.
func hotkey_for_scan(sc: int) -> Dictionary:
	if sc < 0:
		return {}
	for c in controls:
		if int(c.type) == T_BUTTON and int(c.hotkey) == sc and c.enabled and c.visible:
			return c
	return {}


# ------------------------------------------------------------------ keyboard / gamepad highlight

## The highlighted control ({} if none or not usable).
func highlighted() -> Dictionary:
	if hover < 0 or hover >= controls.size():
		return {}
	var c: Dictionary = controls[hover]
	return c if _is_navigable(c) else {}


## The highlighted control if it is a list, else {}.
func highlighted_list() -> Dictionary:
	var c := highlighted()
	return c if not c.is_empty() and int(c.type) in [T_LIST, T_GFX_LIST] else {}


## Acts on the highlighted list / edit box like a click on it; returns the control or {}.
func press_highlighted() -> Dictionary:
	var c := highlighted()
	if c.is_empty():
		return {}
	match int(c.type):
		T_EDIT:
			focus = hover
			return {}
		T_LIST, T_GFX_LIST:
			if int(c.flags) == 1 and not c.items.is_empty():
				c.sel = (c.sel + 1) % c.items.size()
	return c


func _is_navigable(c: Dictionary) -> bool:
	var r: Rect2i = c.r
	return c.visible and c.enabled and int(c.type) in NAVIGABLE_TYPES and r.size.x > 0 and r.size.y > 0


## Moves the highlight to the nearest usable control in direction `dir` (the first one if none
## is highlighted).
func move_highlight(dir: Vector2i) -> void:
	var from := highlighted()
	if from.is_empty():
		hover = _first_navigable()
		return
	var origin := Vector2(from.r.get_center())
	var best := -1
	var best_score := INF
	for i in controls.size():
		var c: Dictionary = controls[i]
		if i == hover or not _is_navigable(c):
			continue
		var to := Vector2(c.r.get_center()) - origin
		var along := to.dot(Vector2(dir))
		if along <= 0.0:
			continue
		var score := along + absf(to.cross(Vector2(dir))) * SIDEWAYS_PENALTY
		if score < best_score:
			best_score = score
			best = i
	if best >= 0:
		hover = best


func _first_navigable() -> int:
	var best := -1
	for i in controls.size():
		var c: Dictionary = controls[i]
		if _is_navigable(c) and int(c.type) == T_BUTTON and (best < 0 or _reads_before(c.r, controls[best].r)):
			best = i
	return best


## Reading order: top to bottom, then left to right.
static func _reads_before(a: Rect2i, b: Rect2i) -> bool:
	return a.position.y < b.position.y or (a.position.y == b.position.y and a.position.x < b.position.x)


## Text entry for the focused edit box (typed characters are text, not bindings). Returns true
## when consumed.
func text_input(ev: InputEventKey) -> bool:
	if focus < 0:
		return false
	var c: Dictionary = controls[focus]
	if ev.keycode == KEY_BACKSPACE:
		c.text = c.text.substr(0, maxi(0, c.text.length() - 1))
		return true
	if ev.unicode >= 32 and ev.unicode < 127:
		var t: String = c.text + char(ev.unicode).to_upper()
		if font("NM_GREEN").width(t) < c.r.size.x - 10:
			c.text = t
		return true
	return false
