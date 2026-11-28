package zsp

import "base:runtime"

// Hex text, as keys and ids are written, to its bytes: false if it is not hex, of whole bytes. Of our own, as
// core:encoding/hex's decode says so by a bool in the release we build with and by an error in the next (dev-2026-11a),
// and code here builds with both.
hex_decode :: proc(text: []byte, allocator := context.allocator) -> (bytes: []byte, ok: bool) {
	if len(text) % 2 != 0 {
		return nil, false
	}
	digit :: proc(c: byte) -> (byte, bool) {
		switch c {
		case '0' ..= '9': return c - '0', true
		case 'a' ..= 'f': return c - 'a' + 10, true
		case 'A' ..= 'F': return c - 'A' + 10, true
		}
		return 0, false
	}
	out, err := make([]byte, len(text) / 2, allocator)
	if err != nil {
		return nil, false
	}
	for i in 0 ..< len(out) {
		hi, a := digit(text[2 * i])
		lo, b := digit(text[2 * i + 1])
		if !a || !b {
			runtime.delete(out, allocator)
			return nil, false
		}
		out[i] = hi << 4 | lo
	}
	return out, true
}
