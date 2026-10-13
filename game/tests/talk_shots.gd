extends Node
## Contact sheets of the ES1 shell's talking heads (playtest E4): General Gierling's transmission (G0) and the
## debriefing officer (D0), one cell every SAMPLE_SECONDS, to compare with the original sequences.
##   Godot --audio-driver Dummy --path game res://tests/talk_shots.tscn -- --out=../renders
## Writes <out>/fix_e_talk_G0.png and fix_e_talk_D0.png; prints the mouth tags shown per sample.

const SHELL_SCENE := "res://es1_shell.tscn"
const SAMPLE_SECONDS := 0.2
const SAMPLES := 30
const COLUMNS := 6
const SETTLE_SECONDS := 1.0

var _out := "../renders"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if not ShellData.available():
		print("talk_shots: SKIP (shell data not exported)")
		get_tree().quit(0)
		return
	var guard = preload("res://tests/saved_campaign_guard.gd").new()
	guard.back_up()
	var shell: EsShell = load(SHELL_SCENE).instantiate()
	add_child(shell)
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	shell.sequences.play_general_for_campaign(1)
	await _sheet(shell, "G0")
	shell.skip_requested = true
	shell.abort_requested = true
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	shell.skip_requested = false
	shell.abort_requested = false
	shell.sequences.play_debriefing(0, 0)
	await _sheet(shell, "D0")
	guard.restore()
	get_tree().quit(0)


func _sheet(shell: EsShell, speaker: String) -> void:
	var cells: Array[Image] = []
	for i in SAMPLES:
		await get_tree().create_timer(SAMPLE_SECONDS).timeout
		cells.append(shell.screen.snapshot())
	var w := cells[0].get_width()
	var h := cells[0].get_height()
	var rows := ceili(float(cells.size()) / COLUMNS)
	var sheet := Image.create(w * COLUMNS, h * rows, false, Image.FORMAT_RGB8)
	for i in cells.size():
		cells[i].convert(Image.FORMAT_RGB8)
		sheet.blit_rect(cells[i], Rect2i(0, 0, w, h), Vector2i(i % COLUMNS * w, i / COLUMNS * h))
	var path := _out.path_join("fix_e_talk_%s.png" % speaker)
	sheet.save_png(path)
	print("talk_shots: %s -> %s" % [speaker, path])
