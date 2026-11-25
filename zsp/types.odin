/*
Package zsp is the Zeron State Protocol: a local-first replicated map of sealed cells.

It performs no I/O, starts no threads, and reads no clocks. Bytes go in, bytes come out.
See SPEC.md for the protocol this package implements.
*/
package zsp

import "base:intrinsics"

// The unit of sharing: one sealing key, one set of grants. A scope's number leads every row id and
// list tag within it, so a scope is a contiguous range of every index.
Scope :: distinct u32

// Row identity: scope (32 bits), creation time in seconds (32), entropy (64). New rows cluster.
Id :: distinct [2]u64

// Scope (32 bits), then an opaque tag (96) derived from the list's name with a key no relay sees.
// Tag zero is the scope's graveyard.
List :: distinct [2]u64

// A hybrid logical clock reading plus 64 bits of fresh entropy. Simultaneously a cell's version,
// its tie-break, and its AEAD nonce: never reused, not even by a forked virtual machine.
Stamp :: struct {
	time: u64, // 48 bits of milliseconds, 16 bits of counter
	salt: u64,
}

// Position of a row within a list, or of a cell within a row. Compared as a 40-byte big-endian string.
Key :: distinct [5]u64

// A multiset hash: two independent sums modulo 2^64. Addition commutes and inverts.
Print :: distinct [2]u64

Slot :: distinct u8

GRAVE :: Slot(0)
PLACE :: Slot(1) // ..= PLACE_LAST
PLACE_LAST :: Slot(15)
DATA :: Slot(16) // ..= 255

Kind :: enum u8 {
	Grave  = 1, // kills its row, permanently
	Place  = 2, // shelves its row in a list; replaces older cells in its slot
	Value  = 3, // replaces older cells in its slot
	Piece  = 4, // joins the set of pieces in its slot
	Bundle = 5, // a piece that replaces exactly the pieces it names
}

// One immutable write.
Cell :: struct {
	row:   Id,
	slot:  Slot,
	kind:  Kind,
	stamp: Stamp,
	body:  []byte, // clear prefix, then sealed bytes
}

KEY_MIN :: Key{}
KEY_MAX :: Key{max(u64), max(u64), max(u64), max(u64), max(u64)} // reserved: exclusive upper bound

MAX_CELL :: 1 << 20 // a body at rest and between devices
MAX_OPEN :: MAX_CELL - 128 // and before it is sealed, and perhaps signed

// A stamp further ahead of the clock than this is refused. Clocks follow stamps, so what one device's clock
// may be off by, every device's may; and it is how long a right may outlive its revocation.
LEAP_MS :: 15 * 60 * 1000
MAX_PLACES :: int(PLACE_LAST)

@(require_results)
stamp_less :: #force_inline proc "contextless" (a, b: Stamp) -> bool {
	return a.time < b.time || (a.time == b.time && a.salt < b.salt)
}

@(require_results)
key_cmp :: #force_inline proc "contextless" (a, b: ^Key) -> int {
	#unroll for i in 0 ..< 5 {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	return 0
}

@(require_results)
key_less :: #force_inline proc "contextless" (a, b: Key) -> bool {
	a, b := a, b
	return key_cmp(&a, &b) < 0
}

@(require_results)
place_key :: proc "contextless" (list: List, order: u64, row: Id) -> Key {
	return {list[0], list[1], order, row[0], row[1]}
}

@(require_results)
row_scope :: #force_inline proc "contextless" (row: Id) -> Scope {
	return Scope(row[0] >> 32)
}

// The least stamp time a cell of this row may have.
@(require_results)
row_born :: #force_inline proc "contextless" (row: Id) -> u64 {
	return (row[0] & 0xffff_ffff) * 1000 << 16
}

@(require_results)
list_scope :: #force_inline proc "contextless" (list: List) -> Scope {
	return Scope(list[0] >> 32)
}

@(require_results)
key_scope :: #force_inline proc "contextless" (key: Key) -> Scope {
	return Scope(key[0] >> 32)
}

@(require_results)
graveyard :: proc "contextless" (scope: Scope) -> List {
	return {u64(scope) << 32, 0}
}

@(require_results)
is_graveyard :: proc "contextless" (list: List) -> bool {
	return list[0] & 0xffff_ffff == 0 && list[1] == 0
}

@(require_results)
scope_lo :: proc "contextless" (scope: Scope) -> Key {
	return {u64(scope) << 32, 0, 0, 0, 0}
}

// Exclusive.
@(require_results)
scope_hi :: proc "contextless" (scope: Scope) -> Key {
	return {(u64(scope) + 1) << 32, 0, 0, 0, 0}
}

@(require_results)
list_lo :: proc "contextless" (list: List) -> Key {
	return {list[0], list[1], 0, 0, 0}
}

// Exclusive upper bound of a list.
@(require_results)
list_hi :: proc "contextless" (list: List) -> Key {
	if list[1] == max(u64) {
		return {list[0] + 1, 0, 0, 0, 0} if list[0] != max(u64) else KEY_MAX
	}
	return {list[0], list[1] + 1, 0, 0, 0}
}

@(require_results)
key_next :: proc "contextless" (key: Key) -> (next: Key) {
	next = key
	#reverse for &v in next {
		v += 1
		if v != 0 {
			break
		}
	}
	return
}

@(require_results)
key_list :: proc "contextless" (key: Key) -> List {
	return {key[0], key[1]}
}

@(require_results)
key_row :: proc "contextless" (key: Key) -> Id {
	return {key[3], key[4]}
}

// Length of a cell body's unsealed prefix, or of as much of it as must be there to tell.
@(require_results)
clear_size :: proc "contextless" (kind: Kind, body: []byte) -> int {
	#partial switch kind {
	case .Place:
		return 24
	case .Bundle: // how many stamps, then the stamps, ascending
		if len(body) < 4 {
			return 4
		}
		n := get_u32(body)
		return 4 + int(n) * 16 if n <= MAX_CELL / 16 else max(int)
	}
	return 0
}

@(require_results)
cell_valid :: proc(c: ^Cell) -> bool {
	if len(c.body) > MAX_CELL || c.stamp.time >> 63 != 0 || len(c.body) < clear_size(c.kind, c.body) {
		return false
	}
	if scope := row_scope(c.row); scope == 0 || scope == max(Scope) {
		return false
	}
	// Nothing is older than its row. So whoever has lost the right to write, and can only pretend to have
	// written earlier, cannot touch what was made since.
	if c.stamp.time < row_born(c.row) {
		return false
	}
	switch c.kind {
	case .Grave:
		return c.slot == GRAVE
	case .Place:
		return c.slot >= PLACE && c.slot <= PLACE_LAST && list_scope(cell_list(c)) == row_scope(c.row) && !is_graveyard(cell_list(c))
	case .Value, .Piece:
		return c.slot >= DATA
	case .Bundle:
		if c.slot < DATA || get_u32(c.body) == 0 {
			return false
		}
		for i in 1 ..< int(get_u32(c.body)) {
			if !stamp_less(bundle_at(c.body, i - 1), bundle_at(c.body, i)) {
				return false
			}
		}
		// It absorbs what came before it, and so nothing absorbs it in turn.
		return stamp_less(bundle_at(c.body, int(get_u32(c.body)) - 1), c.stamp)
	}
	return false
}

@(require_results)
stamp_timely :: proc "contextless" (s: Stamp, now_ms: u64) -> bool {
	return s.time >> 16 <= now_ms + LEAP_MS
}

@(require_results)
cell_list :: proc(c: ^Cell) -> List {
	return {get_u64(c.body), get_u64(c.body[8:])}
}

@(require_results)
cell_order :: proc(c: ^Cell) -> u64 {
	return get_u64(c.body[16:])
}

// Everything in the cell's slot at or below this stamp, other than the cell itself, is dead.
@(require_results)
cell_floor :: proc(c: ^Cell) -> Stamp {
	switch c.kind {
	case .Grave, .Place, .Value:
		return c.stamp
	case .Piece, .Bundle:
	}
	return {}
}

@(require_results)
bundle_at :: proc "contextless" (body: []byte, i: int) -> Stamp {
	at := 4 + i * 16
	return {get_u64(body[at:]), get_u64(body[at + 8:])}
}

@(require_results)
bundle_has :: proc "contextless" (body: []byte, stamp: Stamp) -> bool {
	lo, hi := 0, int(get_u32(body))
	for lo < hi {
		mid := (lo + hi) / 2
		if stamp_less(bundle_at(body, mid), stamp) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < int(get_u32(body)) && bundle_at(body, lo) == stamp
}

@(require_results)
get_u64 :: #force_inline proc "contextless" (b: []byte) -> u64 {
	return u64(intrinsics.unaligned_load((^u64be)(raw_data(b))))
}

@(require_results)
get_u32 :: #force_inline proc "contextless" (b: []byte) -> u32 {
	return u32(intrinsics.unaligned_load((^u32be)(raw_data(b))))
}

put_u32 :: #force_inline proc "contextless" (b: []byte, v: u32) {
	intrinsics.unaligned_store((^u32be)(raw_data(b)), u32be(v))
}

put_u64 :: #force_inline proc "contextless" (b: []byte, v: u64) {
	intrinsics.unaligned_store((^u64be)(raw_data(b)), u64be(v))
}
