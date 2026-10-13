class_name TTMScene
extends RefCounted
## Dynamix TTM 4.14 interpreter (port of tools/shell.py TTMPlayer, extended; spec docs/formats/shell.md §7).
##
## A scene owns two 320x200 index layers — `bg` (background) and `scr` (screen) — and runs one or more
## scripts ("threads") concurrently on them, like the GO.EXE TTM manager does for a talking-head screen
## (commander + ambient staff + blinks). Each tick the screen is rebuilt from the background, then every
## thread draws its current frame. A frame's state ops (loads, FIX_RECT, fades, waits, jumps) run once when
## the frame is entered; drawing ops (DRAWBRUSH, RECTFILL, LINE, CALL_LABEL ...) are replayed every tick.
## Timing: 1 tick = 1/30 s; WAIT persists for following frames.

signal finished

const TICK := 1.0 / 30.0
const DRAW_OPS := ["DRAWBRUSH0", "DRAWBRUSH1", "DRAWBRUSH2", "DRAWBRUSH3", "RECTFILL", "RECT", "LINE",
	"CALL_LABEL", "PALETTE", "CALL_OFFSET", "CALL_START"]

var screen: ShellScreen        # palette / fades target (may be null for off-screen use)
var bg: Image
var scr: Image
var threads: Array = []
var done := false


class TTMThread:
	extends RefCounted
	var name := ""
	var dir := ""
	var frames: Array = []
	var labels := {}            # label id -> frame index
	var frame := -1             # current frame (being shown)
	var next := 0               # frame to enter when the timer expires
	var timer := 0.0
	var delay := TTMScene.TICK  # persistent WAIT
	var shapes := {}            # slot -> Array of frame images
	var slot := 0
	var fg := 0
	var stopped := false
	var driven := false         # frame index chosen from outside (talking-head sync)
	var main := true            # the scene finishes when all main threads have stopped
	var entered := {}           # frames already executed once (fix ops only run the first time)
	var hot_weights: Array = []
	var call_base := 0
	var pending_enter := false
	var extra := 0.0


func _init(p_screen: ShellScreen = null) -> void:
	screen = p_screen
	bg = ShellData.new_screen()
	scr = bg.duplicate()


## Adds a script. `main` threads decide when the scene is finished; ambient ones just play.
func add(script_name: String, main := true, driven := false) -> TTMThread:
	var j := ShellData.ttm(script_name)
	var t := TTMThread.new()
	t.main = main
	t.driven = driven
	if j.is_empty():
		push_warning("TTM not found: " + script_name)
		t.stopped = true
		threads.append(t)
		return t
	t.name = j.get("name", script_name)
	t.dir = j.get("dir", "")
	t.frames = j.frames
	for k in j.get("labels", {}):
		t.labels[int(k)] = int(j.labels[k])
	t.next = 0
	t.pending_enter = true
	threads.append(t)
	return t


func set_background(img: Image) -> void:
	if img:
		bg.copy_from(img)
		scr.copy_from(img)


## For driven threads (lip sync): show frame `i` from the next update on.
func drive(t: TTMThread, i: int) -> void:
	if t.frames.is_empty():
		return
	if t.frame < 0:
		# run the set-up frame (shape loads, fixed body parts) before the first sync frame
		t.pending_enter = false
		scr.copy_from(bg)
		_enter(t, 0)
		# frames that paint permanent parts (e.g. C0_SYNC's body, frame 25) are applied up front
		for k in range(1, t.frames.size()):
			for o in t.frames[k]:
				if o[0] == "FIX_RECT":
					scr.copy_from(bg)
					_enter(t, k)
					break
	i = clampi(i, 0, t.frames.size() - 1)
	if i != t.frame:
		t.next = i
		t.pending_enter = true


## Runs `t`'s set-up frame (shape loads, its WAIT) at once, so the first picture shown already has
## the thread's first drawn frame (a person who stays on screen after a talk must not appear without
## his head for the set-up wait).
func apply_setup_frame(t: TTMThread) -> void:
	if t.stopped or t.driven or t.frames.size() < 2:
		return
	update(0.0)
	if t.frame == 0:
		update(maxf(t.timer, 0.0))


func update(delta: float) -> void:
	# advance timers
	for t in threads:
		if t.stopped or t.driven or t.pending_enter:
			continue
		t.timer -= delta
		if t.timer <= 0.0:
			if t.next < 0 or t.next >= t.frames.size():
				t.stopped = true
			else:
				t.pending_enter = true
	scr.copy_from(bg)
	for t in threads:
		if t.pending_enter:
			t.pending_enter = false
			_enter(t, t.next)
		elif t.frame >= 0 and t.frame < t.frames.size():
			_run_ops(t, t.frames[t.frame], 0, 0, true, 0)
	if not done:
		var any_main := false
		var running := false
		for t in threads:
			if t.main:
				any_main = true
				if not t.stopped:
					running = true
		if any_main and not running:
			done = true
			finished.emit()


func _enter(t: TTMThread, i: int) -> void:
	t.frame = i
	t.next = i + 1
	t.extra = 0.0
	var first: bool = not t.entered.has(i)
	t.entered[i] = true
	var res := _run_ops(t, t.frames[i], 0, 0, false, 0, first)
	t.timer = (res if res >= 0.0 else t.delay) + t.extra
	if t.next >= t.frames.size() and not t.driven:
		# last frame: stop after its delay
		t.next = -1


## Runs a frame's ops. replay = only drawing ops. Returns this frame's explicit delay or -1.
func _run_ops(t: TTMThread, ops: Array, dx: int, dy: int, replay: bool, depth: int, first := true) -> float:
	var frame_delay := -1.0
	for o in ops:
		var op: String = o[0]
		var a: Array = o[1]
		if replay and not DRAW_OPS.has(op):
			continue
		match op:
			"DRAWBRUSH0", "DRAWBRUSH1", "DRAWBRUSH2", "DRAWBRUSH3":
				var sh: Array = t.shapes.get(int(a[3]), [])
				var fr := int(a[2])
				if fr >= 0 and fr < sh.size():
					ShellData.blit(scr, sh[fr], int(a[0]) + dx, int(a[1]) + dy, int(op.right(1)))
			"PALETTE":
				t.fg = int(a[0])
			"RECTFILL":
				ShellData.fill(scr, Rect2i(int(a[0]) + dx, int(a[1]) + dy, int(a[2]), int(a[3])), t.fg)
			"RECT":
				var x := int(a[0]) + dx
				var y := int(a[1]) + dy
				var w := int(a[2])
				var h := int(a[3])
				ShellData.line(scr, x, y, x + w - 1, y, t.fg)
				ShellData.line(scr, x, y + h - 1, x + w - 1, y + h - 1, t.fg)
				ShellData.line(scr, x, y, x, y + h - 1, t.fg)
				ShellData.line(scr, x + w - 1, y, x + w - 1, y + h - 1, t.fg)
			"LINE":
				ShellData.line(scr, int(a[0]) + dx, int(a[1]) + dy, int(a[2]) + dx, int(a[3]) + dy, t.fg)
			"CALL_LABEL":
				var fi: int = t.labels.get(int(a[2]), -1)
				if fi >= 0 and depth < 8:
					_run_ops(t, t.frames[fi], dx + int(a[0]), dy + int(a[1]), true, depth + 1)
			"CALL_START":
				t.call_base = t.labels.get(int(a[0]), 0)
			"CALL_OFFSET":
				var fi2: int = t.call_base + int(a[2])
				if fi2 >= 0 and fi2 < t.frames.size() and depth < 8:
					_run_ops(t, t.frames[fi2], dx + int(a[0]), dy + int(a[1]), true, depth + 1)
			"FIX_RECT":
				if first:
					var r := Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3])).abs()
					r = r.intersection(Rect2i(0, 0, 320, 200))
					if r.size.x > 0 and r.size.y > 0:
						bg.blit_rect(scr, r, r.position)
			"FIXBACK":
				if first:
					bg.copy_from(scr)
			"SHAPESELECT":
				t.slot = int(a[0])
			"SHAPELOAD":
				t.shapes[t.slot] = ShellData.sheet(String(a[0]), t.dir)
			"FREESHAPE":
				t.shapes.erase(t.slot)
			"SCRNLOAD":
				var img := ShellData.background(String(a[0]), t.dir)
				if img:
					bg.copy_from(img)
					scr.copy_from(img)
			"PALLOAD":
				if screen:
					screen.set_palette(ShellData.palette(String(a[0]), t.dir))
			"FADE_IN", "FADE_OUT":
				if screen:
					t.extra += screen.fade(op == "FADE_IN", int(a[0]), int(a[1]), int(a[2]), int(a[3]))
			"WAIT":
				t.delay = maxf(int(a[0]), 1) * TICK
				frame_delay = t.delay
			"RANDOM_WAIT":
				frame_delay = randi_range(int(a[0]), maxi(int(a[0]), int(a[1]))) * TICK
			"JUMP_LABEL":
				t.next = t.labels.get(int(a[0]), t.next)
			"ENDLABEL":
				if not t.driven:
					t.next = -1
			"HOTSPOT":
				if t.hot_weights.is_empty():
					t.hot_weights = a.duplicate()
				else:
					t.next = _pick(t, t.hot_weights, a)
					t.hot_weights = []
			_:
				pass   # GLABEL/LLABEL (markers), sound, fonts, GET/PUT: not needed for playback
	return frame_delay


func _pick(t: TTMThread, weights: Array, labels: Array) -> int:
	var total := 0
	for w in weights:
		total += maxi(int(w), 0)
	if total <= 0:
		return t.next
	var r := randi() % total
	for k in weights.size():
		r -= maxi(int(weights[k]), 0)
		if r < 0:
			var lab := int(labels[k]) if k < labels.size() else -1
			return t.labels.get(lab, t.next)
	return t.next
