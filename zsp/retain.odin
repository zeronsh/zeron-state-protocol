package zsp

import "core:slice"

// What a partial replica keeps of what it no longer watches, and for how long.
//
// A partial replica holds what its clients watch and ask about, and once they no longer do, it may let go of it, as
// though it had never come: whatever it lets go of is had again, as anything is, by watching it. It never lets go of
// what it wrote and no full replica is known to hold, of a row that any watch or question here covers, nor of one being
// typed in. So, by list, it keeps when each was last watched; a list nobody has watched for `Keep.age` is let go of, and
// when what is held comes to more than `Keep.bytes`, lists are let go of, those watched least lately first, until it
// comes to three quarters of that, what lies outside watched ranges of those being watched last of all.
//
// The work is done a step at a time, and only when there is any: at the start, when a checkpoint leaves more held than
// may be, and when the list watched least lately comes of age.

Keep :: struct {
	age:   u64, // milliseconds a list nobody watches is kept; 0 for ever
	bytes: u64, // that may be held, about: of cells, and what each costs to keep; 0 for no bound
}

// Here, by default: a month, and 256 MiB.
KEEP_DEFAULT :: Keep{30 * 24 * 3600 * 1000, 256 << 20}

// What may be said, beyond which it is as good as for ever, and no bound: so that nothing reckoned from it wraps.
KEEP_MOST :: Keep{100 * 366 * 24 * 3600 * 1000, 1 << 60}

// What a cell costs to keep beyond its body: its entry in a tree, and its head in the log, about.
CELL_COST :: 64

@(private)
RETAIN_STEP :: 4096 // cells gone over at a time

@(private)
Retain :: struct {
	due:     u64, // when next to look, in milliseconds; 0 for never
	running: bool,
	over:    bool, // what is held is more than may be: lists are let go of by age, oldest first
	cursor:  Key, // over the shelf, a list at a time
	lists:   [dynamic]Aged, // of a pass over what is too much, oldest first; owned
	at:      int, // of those, the one being let go of
	row_at:  Key, // and how far in it
	left:    u64, // what was held when it was last done, so that what is held and cannot go is not gone over again and again
	ended:   u64, // when it was last done
	forgot:  u64, // the store's count of what it forgot, as the pass began
}

@(private)
Aged :: struct {
	list: List,
	used: u64,
}

// How much a store holds, about, in bytes: what node_keep bounds.
@(require_results)
store_held :: proc(s: ^Store) -> u64 {
	sum := tree_range(s, s.cells, KEY_MIN, KEY_MAX)
	return sum.print[1] >> 8 + u64(sum.count) * CELL_COST
}

// Says what is kept, and looks again at once.
node_keep :: proc(n: ^Node, keep: Keep) {
	n.keep = {min(keep.age, KEEP_MOST.age), min(keep.bytes, KEEP_MOST.bytes)}
	n.retain.due = n.now if n.now > 0 else 1
}

// When there is next something to let go of, in milliseconds: 0 for never.
@(require_results)
node_retain_due :: proc(n: ^Node) -> u64 {
	switch {
	case !retaining(n):
		return 0
	case n.retain.running:
		return max(n.now, 1)
	}
	return n.retain.due
}

@(private)
retaining :: proc(n: ^Node) -> bool {
	return !n.full && n.own && !store_lazy(&n.store) && (n.keep.age > 0 || n.keep.bytes > 0)
}

// When a client here begins or ceases to watch a range: the lists in it were watched just now.
@(private)
used_stamp :: proc(n: ^Node, lo, hi: Key) {
	if !retaining(n) {
		return
	}
	MOST :: 4096 // lists a range may name, beyond which the rest are not stamped: they will be when they are let go of
	at := lo
	for _ in 0 ..< MOST {
		if !key_less(at, hi) {
			return
		}
		scan := tree_scan(n, n.shelf, at, hi)
		leaf, ok := tree_next(&scan)
		if !ok {
			return
		}
		list := key_list(leaf.key)
		used_now(n, list)
		at = list_hi(list)
	}
}

// A list was watched, or written in, just now; it is to be looked at again when that is long enough ago.
@(private)
used_now :: proc(n: ^Node, list: List) {
	tree_put(n, &n.used, {list[0], list[1], 0, 0, 0}, {n.now, 0})
	if n.keep.age > 0 && !n.retain.running && (n.retain.due == 0 || n.retain.due > n.now + n.keep.age) {
		n.retain.due = n.now + n.keep.age
	}
}

// Its clients wrote: where they put rows, they have used.
@(private)
used_written :: proc(n: ^Node, cells: []Cell) {
	if !retaining(n) {
		return
	}
	for c in cells {
		if c.kind == .Place && len(c.body) >= 16 {
			used_now(n, {get_u64(c.body), get_u64(c.body[8:])})
		}
	}
}

// Lets go of what is to be let go of, as far as one step goes. True if there is more to do at once.
node_retain :: proc(n: ^Node) -> (more: bool) {
	r := &n.retain
	if !retaining(n) {
		retain_reset(r)
		return false
	}
	if !r.running {
		if r.due == 0 || n.now < r.due {
			return false
		}
		if len(n.sweep.plans) > 0 {
			r.due = n.now + 1000 // what a roster made unlawful is gone over first; then this
			return false
		}
		r.running, r.over, r.cursor, r.forgot = true, false, KEY_MIN, n.forgot
	}
	if !r.over {
		if retain_by_age(n) {
			return true
		}
		if n.keep.bytes == 0 || store_held(&n.store) <= n.keep.bytes {
			retain_done(n)
			return false
		}
		retain_collect(n)
		r.over = true
		return true
	}
	if retain_by_size(n) {
		return true
	}
	retain_done(n)
	return false
}

// A checkpoint was written: if what is held has grown past what may be, it is time to look.
@(private)
retain_grown :: proc(n: ^Node) {
	if !retaining(n) || n.retain.running || n.keep.bytes == 0 {
		return
	}
	if held := store_held(&n.store); held > n.keep.bytes && held > n.retain.left + n.keep.bytes / 8 {
		retain_soon(n)
	}
}

// A watch was let go of: what it held on to may go, if what is held is more than may be.
@(private)
retain_released :: proc(n: ^Node) {
	if retaining(n) && !n.retain.running && n.keep.bytes > 0 && store_held(&n.store) > n.keep.bytes {
		n.retain.left = 0
		retain_soon(n)
	}
}

// At once, but no more than once a second, however much is let go of by however many.
@(private)
retain_soon :: proc(n: ^Node) {
	at := max(n.now, n.retain.ended + 1000, 1)
	if n.retain.due == 0 || n.retain.due > at {
		n.retain.due = at
	}
}

// Looks again when the list watched least lately comes of age.
@(private)
retain_done :: proc(n: ^Node) {
	r := &n.retain
	if n.forgot != r.forgot {
		// Written down at once, so that what went stays gone however the node stops, and its room is had again.
		store_checkpoint(&n.store)
	}
	retain_reset(r)
	r.due, r.left, r.ended = 0, store_held(&n.store), n.now
	soonest := max(u64)
	empty := make([dynamic]Key, context.temp_allocator) // lists nothing is held of any more, as when all moved away
	scan := tree_scan(n, n.used, KEY_MIN, KEY_MAX)
	for leaf in tree_next(&scan) {
		list := key_list(leaf.key)
		if store_range(&n.store, list_lo(list), list_hi(list)).count == 0 {
			append(&empty, leaf.key)
		} else {
			soonest = min(soonest, leaf.val[0])
		}
	}
	for k in empty {
		tree_delete(n, &n.used, k)
	}
	if n.keep.age > 0 && soonest != max(u64) {
		r.due = max(soonest + n.keep.age, n.now + 1)
	}
}

@(private)
retain_reset :: proc(r: ^Retain) {
	delete(r.lists)
	r^ = {due = r.due, left = r.left, ended = r.ended}
}

// A step over the shelf, a list at a time, letting go of lists nobody has watched for long enough. True while there
// is more of the shelf to go over.
@(private)
retain_by_age :: proc(n: ^Node) -> bool {
	r := &n.retain
	cutoff := n.now - min(n.now, n.keep.age) if n.keep.age > 0 else 0
	seen := 0
	for seen < RETAIN_STEP {
		scan := tree_scan(n, n.shelf, r.cursor, KEY_MAX)
		leaf, ok := tree_next(&scan)
		if !ok {
			return false
		}
		list := key_list(leaf.key)
		used := list_used(n, list)
		if n.keep.age > 0 && used < cutoff {
			lo := r.cursor if key_list(r.cursor) == list else list_lo(list)
			at, done := retain_list(n, list, lo, used, &seen)
			if !done {
				r.cursor = at
				return true
			}
			// What could not be let go of is kept as though watched now: it will be looked at again in a while.
			if store_range(&n.store, list_lo(list), list_hi(list)).count > 0 {
				tree_put(n, &n.used, {list[0], list[1], 0, 0, 0}, {n.now, 0})
			} else {
				tree_delete(n, &n.used, {list[0], list[1], 0, 0, 0})
			}
		} else {
			seen += 1
		}
		r.cursor = list_hi(list)
		if r.cursor == KEY_MAX {
			return false
		}
	}
	return true
}

// When a list was last watched. One that has never been said to be, as one held before lists' ages were kept, is
// said to be now, and so is kept for as long as any.
@(private)
list_used :: proc(n: ^Node, list: List) -> u64 {
	if v, ok := tree_get(n, n.used, {list[0], list[1], 0, 0, 0}); ok {
		return v[0]
	}
	tree_put(n, &n.used, {list[0], list[1], 0, 0, 0}, {n.now, 0})
	return n.now
}

// Every list held, and when each was last watched, oldest first.
@(private)
retain_collect :: proc(n: ^Node) {
	r := &n.retain
	clear(&r.lists)
	at := KEY_MIN
	for {
		scan := tree_scan(n, n.shelf, at, KEY_MAX)
		leaf, ok := tree_next(&scan)
		if !ok {
			break
		}
		list := key_list(leaf.key)
		append(&r.lists, Aged{list, list_used(n, list)})
		at = list_hi(list)
		if at == KEY_MAX {
			break
		}
	}
	slice.sort_by(r.lists[:], proc(a, b: Aged) -> bool {return a.used < b.used})
	r.at = 0
	if len(r.lists) > 0 {
		r.row_at = list_lo(r.lists[0].list)
	}
}

// A step of letting go of lists, oldest first, until what is held comes to three quarters of what may be. True while
// there is more to do.
@(private)
retain_by_size :: proc(n: ^Node) -> bool {
	r := &n.retain
	seen := 0
	for r.at < len(r.lists) && seen < RETAIN_STEP {
		if store_held(&n.store) <= n.keep.bytes / 4 * 3 {
			return false
		}
		a := r.lists[r.at]
		at, done := retain_list(n, a.list, r.row_at, a.used, &seen)
		if !done {
			r.row_at = at
			return true
		}
		if store_range(&n.store, list_lo(a.list), list_hi(a.list)).count == 0 {
			tree_delete(n, &n.used, {a.list[0], a.list[1], 0, 0, 0})
		}
		r.at += 1
		if r.at < len(r.lists) {
			r.row_at = list_lo(r.lists[r.at].list)
		}
	}
	return r.at < len(r.lists)
}

// Lets go of the rows of a list from a key on that may be let go of, for as long as `seen` allows. Returns where it got
// to, and whether it got to the end.
@(private)
retain_list :: proc(n: ^Node, list: List, lo: Key, used: u64, seen: ^int) -> (at: Key, done: bool) {
	hi := list_hi(list)
	held := retain_held(n, list)
	gone := make([dynamic]Id, context.temp_allocator)
	at, done = hi, true
	scan := tree_scan(n, n.shelf, lo, hi)
	for leaf in tree_next(&scan) {
		if seen^ >= RETAIN_STEP {
			at, done = leaf.key, false
			break
		}
		seen^ += 1
		row := key_row(leaf.key)
		if held_by_none(n, row, leaf.key, held[:], used) {
			append(&gone, row)
		}
	}
	lost := make([dynamic]Leaf, context.temp_allocator)
	for row in gone {
		cells := row_scan(&n.store, row)
		for leaf in tree_next(&cells) {
			append(&lost, leaf)
		}
	}
	forget(&n.store, lost[:], read = true)
	return
}

// The ranges in a list that something here watches, or asks about.
@(private)
retain_held :: proc(n: ^Node, list: List) -> [dynamic][2]Key {
	lo, hi := list_lo(list), list_hi(list)
	held := make([dynamic][2]Key, context.temp_allocator)
	add :: proc(held: ^[dynamic][2]Key, w: Watch, lo, hi: Key) {
		if w.data && key_less(w.lo, hi) && key_less(lo, w.hi) {
			append(held, [2]Key{w.lo, w.hi})
		}
	}
	for &it in n.interests {
		add(&held, it.watch, lo, hi)
	}
	for s in n.sessions {
		for w in s.watches {
			add(&held, w, lo, hi)
		}
	}
	return held
}

// Whether nothing holds on to a row: not the outbox, not a watch, not one typing, not a question; nor another list it is
// in, watched since this one was.
@(private)
held_by_none :: proc(n: ^Node, row: Id, here: Key, held: [][2]Key, used: u64) -> bool {
	if _, mine := tree_get(n, n.outbox, {row[0], row[1], 0, 0, 0}); mine {
		return false
	}
	for x in n.typing {
		if x.row == row {
			return false
		}
	}
	places := row_places(&n.store, row)
	for k in places.keys[:places.count] {
		k := k
		for h in held {
			h := h
			if key_cmp(&h[0], &k) <= 0 && key_cmp(&k, &h[1]) < 0 {
				return false
			}
		}
		if key_list(k) != key_list(here) {
			for &it in n.interests {
				if it.watch.data && range_has(&it.watch, k) {
					return false
				}
			}
			for s in n.sessions {
				for &w in s.watches {
					if w.data && range_has(&w, k) {
						return false
					}
				}
			}
			// One never said to have been watched is as one watched now, as list_used says, whichever is gone over first.
			other := key_list(k)
			if v, ok := tree_get(n, n.used, {other[0], other[1], 0, 0, 0}); !ok || v[0] > used {
				return false
			}
		}
	}
	if q := &n.host.questions; q.shows != nil {
		for s in n.sessions {
			if s.role == .Open && q.shows(q.data, s, row) {
				return false
			}
		}
	}
	return true
}
