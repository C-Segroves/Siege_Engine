class_name NameRow
extends OptionRow
## The player's name (launcher menu, lobby, options): typing renames the player at once (Net.player_name) and
## saves it (PlayerProfile); `named` fires with the new name.

signal named(player_name: String)

var edit: LineEdit


func _init(label_text := "Your name") -> void:
	edit = Widgets.line_edit(Net.player_name, PlayerProfile.DEFAULT_NAME)
	edit.max_length = PlayerProfile.MAX_NAME_LENGTH
	super(label_text, edit)
	edit.text_changed.connect(_on_text_changed)
	edit.text_submitted.connect(func(_t: String) -> void: edit.release_focus())


func _on_text_changed(t: String) -> void:
	PlayerProfile.apply_name(t)
	named.emit(Net.player_name)
