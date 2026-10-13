class_name MissionRng
extends RefCounted
## Shell random(n) policy of tools/mission.py Rng: seed < 0 -> always 0, else CPython's
## Mersenne Twister (MT19937) seeded like random.Random(seed) (init_by_array) and randrange(n)
## (getrandbits rejection sampling), so equal seeds give the same missions as the Python tools.

const N := 624
const M := 397
const MATRIX_A := 0x9908b0df
const UPPER_MASK := 0x80000000
const LOWER_MASK := 0x7fffffff
const WORD_MASK := 0xffffffff
## CPython's init_by_array seed for init_genrand.
const INIT_SEED := 19650218

var enabled := false
var mt := PackedInt64Array()
var mti := N + 1


func _init(seed := -1) -> void:
	if seed < 0:
		return
	enabled = true
	var key := []
	var n := seed
	while n > 0:
		key.append(n & WORD_MASK)
		n = n >> 32
	if key.is_empty():
		key.append(0)
	_init_by_array(key)


## random(n): 0 for n <= 0 (no state consumed), else randrange(n).
func call_n(n: int) -> int:
	if n <= 0 or not enabled:
		return 0
	var k := 0
	var t := n
	while t > 0:
		k += 1
		t >>= 1
	var r := getrandbits(k)
	while r >= n:
		r = getrandbits(k)
	return r


func getrandbits(k: int) -> int:
	return genrand_uint32() >> (32 - k)


func _init_genrand(s: int) -> void:
	mt.resize(N)
	mt[0] = s & WORD_MASK
	for i in range(1, N):
		mt[i] = (1812433253 * (mt[i - 1] ^ (mt[i - 1] >> 30)) + i) & WORD_MASK
	mti = N


func _init_by_array(key: Array) -> void:
	_init_genrand(INIT_SEED)
	var i := 1
	var j := 0
	var kl := key.size()
	var k: int = N if N > kl else kl
	while k > 0:
		var p: int = mt[i - 1]
		mt[i] = ((mt[i] ^ (((p ^ (p >> 30)) * 1664525) & WORD_MASK)) + key[j] + j) & WORD_MASK
		i += 1
		j += 1
		if i >= N:
			mt[0] = mt[N - 1]
			i = 1
		if j >= kl:
			j = 0
		k -= 1
	k = N - 1
	while k > 0:
		var p: int = mt[i - 1]
		mt[i] = ((mt[i] ^ (((p ^ (p >> 30)) * 1566083941) & WORD_MASK)) - i) & WORD_MASK
		i += 1
		if i >= N:
			mt[0] = mt[N - 1]
			i = 1
		k -= 1
	mt[0] = UPPER_MASK


func genrand_uint32() -> int:
	if mti >= N:
		_twist()
	var y: int = mt[mti]
	mti += 1
	y ^= (y >> 11)
	y ^= (y << 7) & 0x9d2c5680
	y ^= (y << 15) & 0xefc60000
	y ^= (y >> 18)
	return y & WORD_MASK


## Regenerates the N state words.
func _twist() -> void:
	for kk in N:
		var y: int = (mt[kk] & UPPER_MASK) | (mt[(kk + 1) % N] & LOWER_MASK)
		mt[kk] = mt[(kk + M) % N] ^ (y >> 1) ^ (MATRIX_A if (y & 1) else 0)
	mti = 0
