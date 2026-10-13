class_name ChatRateLimiter
extends RefCounted
## The host's flood guard for player chat (BattleChat): at most `burst` lines per sender in any `window`
## seconds; lines over the limit are dropped and the sender is told.

const DEFAULT_BURST := 4
const DEFAULT_WINDOW := 5.0

var burst := DEFAULT_BURST
var window := DEFAULT_WINDOW
var _sent := {}          # sender -> Array of send times (seconds)


## True when `sender` may send a line at time `now` (seconds); counts the line when it may.
func try_take(sender: int, now: float) -> bool:
	var times: Array = _sent.get(sender, []).filter(func(t: float) -> bool: return now - t < window)
	var ok := times.size() < burst
	if ok:
		times.append(now)
	_sent[sender] = times
	return ok
