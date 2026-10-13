class_name DarkstarLexer
extends RefCounted
## Tokenizer for Darkstar-family scripts: Starsiege / Tribes (Darkstar, 1998-99) and Tribes 2 (TorqueScript,
## 2001). Tokens are [type, value, line]:
## "s" string, "n" number, "l" %local / "g" $global (lower-case name, may contain ::),
## "i" identifier (may contain ::), "p" punctuation / operator, "e" end of input.
## Comments: // and # to end of line, /* ... */ (TorqueScript has no # comments: # is not a comment there).
##
## The TORQUE dialect adds the TorqueScript operators ($= !$= << >> %= &= |= ^= <<= >>=), hexadecimal numbers
## (0xff), and the string escapes \xHH and \c<colour> (colour codes are dropped: the remake shows plain text).

enum Dialect { DARKSTAR, TORQUE }

const OPS2 := ["==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "++", "--"]
const TORQUE_OPS3 := ["!$=", "<<=", ">>="]
const TORQUE_OPS2 := ["$=", "<<", ">>", "%=", "&=", "|=", "^="]
const WHITESPACE := [" ", "\t", "\r", "\f"]
## TorqueScript colour escapes: \c0 .. \c9 and the named \cr (reset), \cp (push), \co (pop).
const COLOUR_ESCAPES := "0123456789rpo"
const HEX_DIGITS := "0123456789abcdefABCDEF"

var dialect := Dialect.DARKSTAR
var _src := ""
var _n := 0
var _i := 0
var _line := 1
var _toks := []


static func tokenize(src: String, p_dialect := Dialect.DARKSTAR) -> Array:
	var lexer := new()
	lexer.dialect = p_dialect
	return lexer._run(src)


static func is_ident_char(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")


func _run(src: String) -> Array:
	_src = src
	_n = src.length()
	while _i < _n:
		_read_token()
	_toks.append(["e", "", _line])
	return _toks


func _at(k: int) -> String:
	return _src[k] if k < _n else ""


func _is_torque() -> bool:
	return dialect == Dialect.TORQUE


func _read_token() -> void:
	var c := _src[_i]
	if c == "\n":
		_line += 1
		_i += 1
	elif c in WHITESPACE:
		_i += 1
	elif c == "/" and _at(_i + 1) == "/" or (c == "#" and not _is_torque()):
		_skip_line_comment()
	elif c == "/" and _at(_i + 1) == "*":
		_skip_block_comment()
	elif c == "\"" or c == "'":
		_read_string(c)
	elif _is_torque() and c == "0" and (_at(_i + 1) == "x" or _at(_i + 1) == "X"):
		_read_hex_number()
	elif c.is_valid_int() or (c == "." and _i + 1 < _n and _src[_i + 1].is_valid_int()):
		_read_number()
	elif (c == "%" or c == "$") and _i + 1 < _n and (is_ident_char(_src[_i + 1]) or _src[_i + 1] == ":"):
		_read_variable(c)
	elif is_ident_char(c):
		_read_identifier()
	else:
		_read_operator(c)


func _read_operator(c: String) -> void:
	if _is_torque() and TORQUE_OPS3.has(_src.substr(_i, 3)):
		_push_op(3)
	elif _i + 1 < _n and (OPS2.has(_src.substr(_i, 2)) or (_is_torque() and TORQUE_OPS2.has(_src.substr(_i, 2)))):
		_push_op(2)
	else:
		_toks.append(["p", c, _line])
		_i += 1


func _push_op(length: int) -> void:
	_toks.append(["p", _src.substr(_i, length), _line])
	_i += length


func _skip_line_comment() -> void:
	while _i < _n and _src[_i] != "\n":
		_i += 1


func _skip_block_comment() -> void:
	var e := _src.find("*/", _i + 2)
	var stop := _n if e < 0 else e + 2
	_line += _src.substr(_i, stop - _i).count("\n")
	_i = stop


## Quoted string with \n, \t and \<char> escapes; the token carries the line it ends on.
func _read_string(quote: String) -> void:
	var s := ""
	_i += 1
	while _i < _n and _src[_i] != quote:
		var ch := _src[_i]
		if ch == "\\" and _i + 1 < _n:
			s += _read_escape()
			continue
		if ch == "\n":
			_line += 1
		s += ch
		_i += 1
	_i += 1
	_toks.append(["s", s, _line])


## The escape at _i (a backslash); advances past it.
func _read_escape() -> String:
	var e := _src[_i + 1]
	_i += 2
	match e:
		"n": return "\n"
		"t": return "\t"
	if not _is_torque():
		return e
	if e == "r":
		return "\r"
	if e == "c" and _i < _n and COLOUR_ESCAPES.contains(_src[_i]):
		_i += 1
		return ""
	if e == "x" and _i + 1 < _n and HEX_DIGITS.contains(_src[_i]) and HEX_DIGITS.contains(_src[_i + 1]):
		var code := _src.substr(_i, 2).hex_to_int()
		_i += 2
		return String.chr(code)
	return e


func _read_number() -> void:
	var j := _i
	while j < _n and (_src[j].is_valid_int() or _src[j] == "." or _is_exponent_at(j)):
		j += 2 if _src[j] == "e" or _src[j] == "E" else 1
	_toks.append(["n", DarkstarScript._clean(float(_src.substr(_i, j - _i))), _line])
	_i = j


func _read_hex_number() -> void:
	var j := _i + 2
	while j < _n and HEX_DIGITS.contains(_src[j]):
		j += 1
	_toks.append(["n", _src.substr(_i + 2, j - _i - 2).hex_to_int(), _line])
	_i = j


func _is_exponent_at(j: int) -> bool:
	return (_src[j] == "e" or _src[j] == "E") and j + 1 < _n and (_src[j + 1].is_valid_int() or _src[j + 1] == "-")


## %local / $global; names may contain "::" (a lone % is the modulo operator, handled as punctuation).
func _read_variable(sigil: String) -> void:
	var j := _i + 1
	while j < _n and (is_ident_char(_src[j]) or (_src[j] == ":" and j + 1 < _n and _src[j + 1] == ":")):
		j += 2 if _src[j] == ":" else 1
	_toks.append(["l" if sigil == "%" else "g", _src.substr(_i + 1, j - _i - 1).to_lower(), _line])
	_i = j


## An identifier (may contain "::"). TorqueScript: blanks after "::" are skipped (`parent:: onAIRespawn(...)`
## in Training3.cs / Training5.cs), and `switch$` is one word.
func _read_identifier() -> void:
	var text := ""
	var j := _i
	while j < _n:
		if is_ident_char(_src[j]):
			text += _src[j]
			j += 1
		elif _is_scope_at(j):
			text += "::"
			j += 2
		elif _is_torque() and _src.substr(j, 2) == "::" and _next_word_after_blanks(j + 2) > 0:
			text += "::"
			j = _next_word_after_blanks(j + 2)
		else:
			break
	if _is_torque() and text.to_lower() == "switch" and _at(j) == "$":
		text += "$"
		j += 1
	_toks.append(["i", text, _line])
	_i = j


## The index of the identifier character after the blanks from `j` on one line (-1 when none follows).
func _next_word_after_blanks(j: int) -> int:
	while j < _n and (_src[j] == " " or _src[j] == "\t"):
		j += 1
	return j if j < _n and is_ident_char(_src[j]) else -1


## "::" followed by an identifier character.
func _is_scope_at(j: int) -> bool:
	return _src[j] == ":" and j + 1 < _n and _src[j + 1] == ":" and j + 2 < _n and is_ident_char(_src[j + 2])
