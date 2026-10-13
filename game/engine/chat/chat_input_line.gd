class_name ChatInputLine
extends LineEdit
## The chat's text input (ChatPanel). Sending, cancelling, scrolling and switching the channel are chat actions
## the panel handles before the GUI; every other key goes into the text, capped at ChatLog.MAX_TEXT_LENGTH.


func _init() -> void:
	max_length = ChatLog.MAX_TEXT_LENGTH
	context_menu_enabled = false
	caret_blink = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
