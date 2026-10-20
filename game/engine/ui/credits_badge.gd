class_name CreditsBadge
extends PanelContainer
## The wallet readout "CR 1,240" shown on the lobby, Operator Setup and the results screens. It takes plain
## numbers (set_credits) or a Callable returning the balance (bind_source + refresh), never the economy classes.
## Display only: it never takes focus or mouse input, so it cannot trap keyboard or gamepad navigation.
##   var badge := CreditsBadge.new(); badge.set_credits(1240)

const PREFIX := "CR "
const GROUP_SIZE := 3

var credits := 0
var _label: Label
var _source := Callable()


func _init(p_credits := 0) -> void:
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Widgets.label("", "CreditsLabel")
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	set_credits(p_credits)


## "CR 1,240" (negative balances keep their sign).
static func make_text(amount: int) -> String:
	var digits := str(absi(amount))
	var out := ""
	while digits.length() > GROUP_SIZE:
		out = "," + digits.substr(digits.length() - GROUP_SIZE) + out
		digits = digits.substr(0, digits.length() - GROUP_SIZE)
	return PREFIX + ("-" if amount < 0 else "") + digits + out


func set_credits(amount: int) -> void:
	credits = amount
	_label.text = make_text(amount)


## `source` returns the current balance as an int; refresh() reads it again.
func bind_source(source: Callable) -> void:
	_source = source
	refresh()


func refresh() -> void:
	if _source.is_valid():
		set_credits(int(_source.call()))


func text() -> String:
	return _label.text
