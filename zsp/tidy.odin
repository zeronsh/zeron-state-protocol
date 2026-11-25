package zsp

import "base:runtime"
import "core:slice"

// A text that has been written in a good deal is a good many pieces: each with its own seal to open, and its own
// signature to check, and room in the index. Whoever writes one more than so many has them put into a bundle; and bundles,
// once there are so many of a size, into one: so that however long a text is written, there are only ever a few, and
// what was written long ago has been written but a few times over.
//
// It may be done at any time and by anyone who could have written them, for a bundle kills what is in it and no more,
// and says the same.

@(private)
LOOSE :: #config(ZSP_LOOSE, 128) // pieces that are let be
@(private)
ALIKE :: #config(ZSP_ALIKE, 16) // of a size that are made one

@(private)
text_tidy :: proc(n: ^Node, c: Cell, as: []byte) {
	// Not every time; chance will do.
	if c.kind != .Piece || c.stamp.salt % u64(max(LOOSE / 8, 1)) != 0 || !node_may_write(n, row_scope(c.row)) {
		return
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	signed := .Signed in roster_scope(&n.roster, row_scope(c.row)).flags
	count := 0
	scan := row_scan(&n.store, c.row, c.slot, c.slot)
	for leaf in tree_next(&scan) {
		old, _ := cell_unkey(leaf)
		count += 1 if old.kind == .Piece else 0
	}
	if count < LOOSE {
		return
	}
	pieces := make([dynamic]Cell, context.temp_allocator)
	bundles := make([dynamic]Cell, context.temp_allocator)
	scan = row_scan(&n.store, c.row, c.slot, c.slot)
	for old in row_next(&n.store, &scan) {
		old := old
		if old.kind != .Piece && old.kind != .Bundle {
			continue
		}
		if signed {
			// What others wrote is theirs, and what was written here for someone is that someone's.
			me, _ := author_index(n.keys, &n.roster)
			r := Reader{buf = old.body, pos = clear_size(old.kind, old.body)}
			if read_varint(&r) != me {
				continue
			}
		}
		by: By
		if cell_open(n.keys, &n.roster, &old, &by) && (!signed || string(by.as) == string(as)) {
			append(&pieces if old.kind == .Piece else &bundles, old)
		}
	}
	if len(pieces) < LOOSE {
		return
	}
	slice.sort_by(pieces[:], proc(a, b: Cell) -> bool {return stamp_less(a.stamp, b.stamp)})
	slice.sort_by(bundles[:], proc(a, b: Cell) -> bool {return len(a.body) < len(b.body)})
	EACH :: 48 // more than a piece takes in a bundle, besides itself
	MOST :: min(MAX_OPEN, MAX_RECORD - 1024)
	size := EACH
	some := make([dynamic]Cell, context.temp_allocator)
	for p in pieces {
		if size + len(p.body) + EACH > MOST {
			break
		}
		size += len(p.body) + EACH
		append(&some, p)
	}
	// As many bundles of about that size as make it worth while, and then of what that comes to.
	rest := bundles[:]
	for {
		like, sum := 0, 0
		for like < len(rest) && len(rest[like].body) < 4 * size && size + sum + len(rest[like].body) + EACH <= MOST {
			sum += len(rest[like].body) + EACH
			like += 1
		}
		if like + 1 < ALIKE {
			break
		}
		append(&some, ..rest[:like])
		size += sum
		rest = rest[like:]
	}
	if len(some) < 2 {
		return
	}
	all := text_bundle(some[:], context.temp_allocator)
	// No later than need be: nothing has been written, and what is written meanwhile is not older than this.
	latest: u64
	for s in some {
		latest = max(latest, s.stamp.time)
	}
	salt: [8]byte
	node_random(n, salt[:])
	all.stamp = {latest + 1, get_u64(salt[:])}
	if cell_valid(&all) && cell_seal(n.keys, &n.roster, &all, 0, as) {
		node_commit(n, {all}, nil)
	}
}
