class_name CockpitWeapons
extends CockpitPainter
## The weapon slots (one per hardpoint, docs/formats/cockpit.md 3.1 / 8.3): status LED, weapon name, and
## a charge bar (guns, beams) or the ammo count (missiles, grenades), placed by the layout's templates.

const DEFAULT_LABEL := [0, 0, 38, 7]
const DEFAULT_VALUE := [40, 0, 58, 7]
const DEFAULT_BAR := [40, 1, 58, 6]
## Earthsiege 1 draws the name 4 px right of the slot (past its 2 px LED); Earthsiege 2 templates place it.
const DEFAULT_NAME_DX := 4.0


func draw() -> void:
	var slots: Array = display.layout.get("weapon_slots", [])
	var gs: Array = display.layout.get("gun_slots", [])
	for w in herc.weapons:
		var si: int = int(gs[w.mount_index]) if w.mount_index < gs.size() else w.mount_index
		if si >= 0 and si < slots.size():
			_draw_weapon(w, CockpitCanvas.rect_of(slots[si]))


func _draw_weapon(w: Weapon, sr: Rect2) -> void:
	var tpl: Dictionary = display.layout.get("weapon_templates", {})
	if w.kind == "ecm" and skin.frame("weapons", "ecm_button") >= 0:
		_draw_ecm(tpl.get("ecm", {}), sr)
		return
	var counted: bool = w.kind in ["missile", "grenade"]
	var t: Dictionary = tpl.get("ammo_text" if counted else "charge_bar", {})
	var o := sr.position
	var sel: bool = w.trigger and herc.alive
	var ready: bool = w.ready_to_fire()
	_draw_led(t, o, sel, ready)
	var lr := CockpitCanvas.rect_of(t.get("label", DEFAULT_LABEL))
	var dx: float = DEFAULT_NAME_DX if not t.has("led") else 0.0
	canvas.text(skin.font("weapons", "font_selected" if sel else "font"), o.x + lr.position.x + dx, o.y + lr.position.y,
		make_short_name(w.weapon_name), Rect2(o + lr.position, lr.size))
	if counted:
		_draw_ammo_count(w, CockpitCanvas.rect_of(t.get("value", DEFAULT_VALUE)), o)
	else:
		_draw_charge_bar(w, CockpitCanvas.rect_of(t.get("bar", DEFAULT_BAR)), o, ready)
	_draw_slot_frame(t, o, sel)


func _draw_ecm(e: Dictionary, sr: Rect2) -> void:
	var o := sr.position
	var br := CockpitCanvas.rect_of(e.get("button", [0, 0, 9, 7]))
	canvas.blit(canvas.dba(skin.dba("weapons"), skin.frame("weapons", "ecm_button")),
		o.x + br.position.x, o.y + br.position.y, Rect2(o + br.position, br.size))
	var lab: Array = e.get("label", [11, 0, 59, 7])
	canvas.text(skin.font("weapons", "ecm_font"), o.x + float(lab[0]), o.y + float(lab[1]), label("ecm", 0, "ECM"), sr)


## Earthsiege 1: selected / ready / charging LED at the slot origin; Earthsiege 2 (template "led"): ready /
## charging LED (WeaponSelectGadget 0x4426c0).
func _draw_led(t: Dictionary, o: Vector2, sel: bool, ready: bool) -> void:
	var led := skin.frame("weapons", "led_ready") if ready else skin.frame("weapons", "led_charging")
	if sel and skin.frame("weapons", "led_selected") >= 0:
		led = skin.frame("weapons", "led_selected")
	var at: Array = t.get("led", [0, 0])
	canvas.blit(canvas.dba(skin.dba("weapons"), led), o.x + float(at[0]), o.y + float(at[1]))


## Earthsiege 2: the slot's outline (selected / other) around it.
func _draw_slot_frame(t: Dictionary, o: Vector2, sel: bool) -> void:
	if not t.has("frame"):
		return
	var f := skin.frame("weapons", "frame_selected" if sel else "frame_idle")
	canvas.blit(canvas.dba(skin.dba("weapons"), f), o.x + float(t.frame[0]), o.y + float(t.frame[1]))


## "LAS200" -> "LAS 200" like the original weapon labels.
static func make_short_name(n: String) -> String:
	for i in n.length():
		if n[i] >= "0" and n[i] <= "9":
			return (n.substr(0, i) + " " + n.substr(i)).replace("_", " ") if i > 0 else n
	return n.replace("_", " ")


func _draw_ammo_count(w: Weapon, vr: Rect2, o: Vector2) -> void:
	vr.position += o
	var txt := str(maxi(w.ammo, 0)) if w.ammo >= 0 else "--"
	var f := skin.font("weapons", "value_font")
	canvas.text(skin.font("weapons", "value_font_empty") if w.ammo == 0 else f,
		vr.end.x - canvas.text_width(f, txt), vr.position.y, txt, vr)


func _draw_charge_bar(w: Weapon, b: Rect2, o: Vector2, ready: bool) -> void:
	b.position += o
	var px := roundf(make_charge(w) * (b.size.x - 2.0))
	var col := canvas.color(skin.frame("weapons", "bar_ready" if ready else "bar_charging"))
	canvas.fill(Rect2(b.position.x, b.position.y + 1, px, b.size.y - 2), col)
	canvas.blit(canvas.dba(skin.dba("weapons"), skin.frame("weapons", "bar_marker")), b.position.x + px,
		b.position.y - 1, Rect2(b.position.x, b.position.y - 1, b.size.x, b.size.y + 2))


## 0..1 fill of a weapon's bar: ammo left, reload progress, and for beams the capacitor charge.
func make_charge(w: Weapon) -> float:
	var f := 1.0
	if w.ammo_max > 0:
		f = float(w.ammo) / float(w.ammo_max)
	elif w.refire > 0.0:
		f = 1.0 - w.cooldown / w.refire
	if w.kind == "beam" and w.min_charge > 0:
		f = minf(f, herc.capacitor / float(w.min_charge))
	return clampf(f, 0.0, 1.0)
