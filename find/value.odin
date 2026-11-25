package find

// Values as keys that sort as they do.

// A number, so that keys compare as numbers do; -0 is 0, and what is not a number comes last.
@(require_results)
number_key :: proc "contextless" (v: f64) -> Key {
	v := v
	if v == 0 {
		v = 0
	}
	bits := transmute(u64)v
	if v != v {
		return {max(u64), 0}
	}
	return {~bits if bits >> 63 != 0 else bits | 1 << 63, 0}
}

@(require_results)
key_number :: proc "contextless" (k: Key) -> f64 {
	bits := ~k.hi if k.hi >> 63 == 0 else k.hi & (1 << 63 - 1)
	return transmute(f64)bits
}
