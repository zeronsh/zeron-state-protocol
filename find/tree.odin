package find

import "base:runtime"
import "core:encoding/endian"
import "core:mem/virtual"
import "core:slice"
import "../zsp"

// One structure for everything: an ordered set of (key, sub), each with a value, in leaves that write each entry
// as its difference from the last. A posting is two bytes; a number in its place, five or so. Branches carry how
// many entries lie below, and what their keys come to when they are numbers, so any range is counted, summed
// and indexed into in logarithmic time.

Key :: struct {
	hi, lo: u64,
}

Entry :: struct {
	key: Key,
	sub: u32,
	val: u64,
}

// What an entry's value takes.
Width :: enum u8 {
	None,
	Byte,
	Varint,
}

Tree :: struct {
	root:  u32, // zero when empty
	width: Width,
	sums:  bool, // the keys are numbers
}

Edit :: struct {
	using entry: Entry,
	gone: bool,
}

Total :: struct {
	count: int,
	sum:   f64,
}

KEY_MIN :: Key{}
KEY_MAX :: Key{max(u64), max(u64)}

@(private)
LEAF_ROOM :: size_of(Page{}.data)
@(private)
RESTART :: 512 // bytes of a leaf between places reading can start
@(private)
ENTRY_MAX :: 2 + 16 + 5 + 10
@(private)
SAME_LONG :: 0xe0 // the key is the same, and a varint says how far on the sub is
@(private)
FRESH :: 0xe1 // plus how many leading bytes of the key are

@(private)
Child :: struct #packed {
	key:   Key,
	sub:   u32,
	child: u32,
	count: u32,
	sum:   f64,
}
@(private)
BRANCH_CAP :: LEAF_ROOM / size_of(Child)

@(require_results)
key_less :: #force_inline proc "contextless" (a, b: Key) -> bool {
	return a.hi < b.hi || (a.hi == b.hi && a.lo < b.lo)
}

@(require_results)
entry_less :: #force_inline proc "contextless" (ak: Key, as: u32, bk: Key, bs: u32) -> bool {
	return ak.hi < bk.hi || (ak.hi == bk.hi && (ak.lo < bk.lo || (ak.lo == bk.lo && as < bs)))
}

// The next key there can be. Zero after the last.
@(require_results)
key_next :: proc "contextless" (k: Key) -> Key {
	return {k.hi + (1 if k.lo == max(u64) else 0), k.lo + 1}
}

@(private)
children :: proc(pg: ^Page) -> []Child {
	return ([^]Child)(&pg.data)[:pg.count]
}

// ---------------------------------------------------------------- leaves

// A leaf is entries, then, from the end backwards, where each restart begins.
@(private)
Reader :: struct {
	pg:    ^Page,
	width: Width,
	pos:   int,
	stop:  int,
	using at: Entry,
}

@(private)
restart_at :: #force_inline proc(pg: ^Page, i: int) -> int {
	return int((^u16)(&pg.data[LEAF_ROOM - 2 * (i + 1)])^)
}

@(private)
reader :: proc(pg: ^Page, width: Width, block := 0) -> Reader {
	return {pg = pg, width = width, pos = restart_at(pg, block) if pg.count > 0 else 0, stop = int(pg.used)}
}

@(private)
reader_next :: #force_inline proc(r: ^Reader) -> bool #no_bounds_check {
	if r.pos >= r.stop {
		return false
	}
	d := &r.pg.data
	h := d[r.pos]
	r.pos += 1
	switch {
	case h < SAME_LONG:
		r.sub += u32(h) + 1
	case h == SAME_LONG:
		r.sub += u32(read_varint(d[:], &r.pos))
	case:
		shared, n := int(h - FRESH), int(d[r.pos])
		r.pos += 1
		r.key = key_join(r.key, shared, d[r.pos:], n)
		r.pos += n
		r.sub = u32(read_varint(d[:], &r.pos))
	}
	switch r.width {
	case .None:
	case .Byte:
		r.val = u64(d[r.pos])
		r.pos += 1
	case .Varint:
		r.val = read_varint(d[:], &r.pos)
	}
	return true
}

@(private)
read_varint :: #force_inline proc(d: []byte, pos: ^int) -> (v: u64) #no_bounds_check {
	shift: uint
	for {
		b := d[pos^]
		pos^ += 1
		v |= u64(b & 0x7f) << shift
		if b < 0x80 {
			return
		}
		shift += 7
	}
}

// The first `shared` bytes of a key, then others, then zeroes.
@(private)
key_join :: #force_inline proc(k: Key, shared: int, d: []byte, n: int) -> Key #no_bounds_check {
	rest: u128
	if n == 0 {
		rest = 0
	} else if len(d) >= 16 {
		rest = u128(endian.unchecked_get_u64be(d)) << 64 | u128(endian.unchecked_get_u64be(d[8:]))
		rest = rest >> uint(128 - 8 * n) << uint(128 - 8 * n)
	} else {
		for b, i in d[:n] {
			rest |= u128(b) << uint(120 - 8 * i)
		}
	}
	if shared > 0 {
		keep := ~u128(0) << uint(128 - 8 * shared)
		rest = (u128(k.hi) << 64 | u128(k.lo)) & keep | rest >> uint(8 * shared)
	}
	return {u64(rest >> 64), u64(rest)}
}

@(private)
Writer :: struct {
	p:     ^Pager,
	t:     ^Tree,
	out:   ^[dynamic]Child, // where finished leaves go
	pg:    ^Page,
	no:    u32,
	next_restart: int,
	last:  Entry,
	total: Total,
	laying: bool, // and so nothing else is being written
}

@(private)
write_varint :: #force_inline proc(d: []byte, pos: int, v: u64) -> int #no_bounds_check {
	v, pos := v, pos
	for v >= 0x80 {
		d[pos] = byte(v) | 0x80
		pos += 1
		v >>= 7
	}
	d[pos] = byte(v)
	return pos + 1
}

// Writes an entry after another, or at a restart after none.
@(private)
entry_write :: proc(d: []byte, pos: int, last, e: ^Entry, fresh: bool, width: Width) -> int #no_bounds_check {
	pos := pos
	if !fresh && e.key == last.key {
		step := e.sub - last.sub
		if step <= SAME_LONG {
			d[pos] = byte(step - 1)
			pos += 1
		} else {
			d[pos] = SAME_LONG
			pos = write_varint(d, pos + 1, u64(step))
		}
	} else {
		b, was: [16]byte = ---, ---
		zsp.put_u64(b[:], e.key.hi)
		zsp.put_u64(b[8:], e.key.lo)
		shared := 0
		if !fresh {
			zsp.put_u64(was[:], last.key.hi)
			zsp.put_u64(was[8:], last.key.lo)
			for shared < 15 && b[shared] == was[shared] {
				shared += 1
			}
		}
		end := 16
		for end > shared && b[end - 1] == 0 {
			end -= 1
		}
		d[pos], d[pos + 1] = byte(FRESH + shared), byte(end - shared)
		copy(d[pos + 2:], b[shared:end])
		pos = write_varint(d, pos + 2 + end - shared, u64(e.sub))
	}
	switch width {
	case .None:
	case .Byte:
		d[pos] = byte(e.val)
		pos += 1
	case .Varint:
		pos = write_varint(d, pos, e.val)
	}
	return pos
}

@(private)
writer_put :: proc(w: ^Writer, e: Entry) {
	e := e
	if w.pg != nil && int(w.pg.used) + ENTRY_MAX + 2 * (int(w.pg.count) + 1) > LEAF_ROOM {
		writer_end(w)
		if w.laying && len(w.p.dirty) > 2 * CACHE {
			pager_write(w.p)
		}
	}
	if w.pg == nil {
		w.no, w.pg = page_new(w.p)
		append(w.out, Child{key = e.key, sub = e.sub, child = w.no})
		w.next_restart = 0
		w.total = {}
	}
	pg := w.pg
	pos := int(pg.used)
	fresh := pos >= w.next_restart
	if fresh {
		(^u16)(&pg.data[LEAF_ROOM - 2 * (int(pg.count) + 1)])^ = u16(pos)
		pg.count += 1
		w.next_restart = pos + RESTART
	}
	pos = entry_write(pg.data[:], pos, &w.last, &e, fresh, w.t.width)
	pg.used = u16(pos)
	w.last = e
	w.total.count += 1
	if w.t.sums {
		w.total.sum += key_number(e.key)
	}
}

@(private)
writer_end :: proc(w: ^Writer) {
	if w.pg == nil {
		return
	}
	c := &w.out[len(w.out) - 1]
	c.count, c.sum = u32(w.total.count), w.total.sum
	w.pg = nil
}

// ---------------------------------------------------------------- changing

// Applies edits, which are in order and name each entry once.
tree_apply :: proc(p: ^Pager, t: ^Tree, edits: []Edit) {
	if len(edits) == 0 {
		return
	}
	if len(edits) <= FEW {
		for &e, i in edits {
			if !edit_place(p, t, &e) {
				edits_place(p, t, edits[i:i + 1])
			}
		}
		return
	}
	edits_place(p, t, edits)
}

@(private)
FEW :: 64

// A page that may be written to, perhaps under another number.
@(private)
page_own :: proc(p: ^Pager, no: u32) -> (u32, ^Page) {
	if f, ok := p.dirty[no]; ok {
		return no, &f.page
	}
	copied := page_get(p, no)^
	page_drop(p, no)
	fresh, pg := page_new(p)
	pg^ = copied
	return fresh, pg
}

// Makes one edit where it belongs, rewriting no more than the few hundred bytes around it. False, and nothing
// done, when there is no room, or a leaf would be left with nothing.
@(private)
edit_place :: proc(p: ^Pager, t: ^Tree, e: ^Edit) -> bool {
	if t.root == 0 {
		return false
	}
	path: [8]struct {
		no: u32,
		at: int,
	}
	depth := 0
	no := t.root
	pg := page_get(p, no)
	for pg.level > 0 {
		cs := children(pg)
		at := child_find(cs, e.key, e.sub)
		path[depth] = {no, at}
		depth += 1
		no = cs[at].child
		pg = page_get(p, no)
	}
	if pg.count == 0 {
		return false
	}

	// The block it belongs in, written again with it.
	lo, hi := 1, int(pg.count)
	for lo < hi {
		mid := (lo + hi) / 2
		r := reader(pg, t.width, mid)
		reader_next(&r)
		if entry_less(e.key, e.sub, r.key, r.sub) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	block := lo - 1
	r := reader(pg, t.width, block)
	if block + 1 < int(pg.count) {
		r.stop = restart_at(pg, block + 1)
	}
	from, stop := r.pos, r.stop
	out: [3 * RESTART]byte = ---
	pos, n := 0, 0
	last: Entry
	delta := 0
	done := false
	put :: #force_inline proc(out: []byte, pos, n: ^int, last, e: ^Entry, width: Width) {
		pos^ = entry_write(out, pos^, last, e, n^ == 0, width)
		last^ = e^
		n^ += 1
	}
	for reader_next(&r) {
		if pos > 2 * RESTART {
			return false
		}
		if !done && !entry_less(r.key, r.sub, e.key, e.sub) {
			done = true
			same := r.key == e.key && r.sub == e.sub
			if !e.gone {
				put(out[:], &pos, &n, &last, &e.entry, t.width)
				delta += 1
			}
			if same {
				delta -= 1
				continue
			}
		}
		put(out[:], &pos, &n, &last, &r.at, t.width)
	}
	if !done && !e.gone {
		put(out[:], &pos, &n, &last, &e.entry, t.width)
		delta += 1
	}
	grown := pos - (stop - from)
	if n == 0 || pos > 2 * RESTART || int(pg.used) + grown + 2 * int(pg.count) > LEAF_ROOM {
		return false
	}

	no, pg = page_own(p, no)
	copy(pg.data[stop + grown:], pg.data[stop:pg.used])
	copy(pg.data[from:], out[:pos])
	for i in block + 1 ..< int(pg.count) {
		at := (^u16)(&pg.data[LEAF_ROOM - 2 * (i + 1)])
		at^ = u16(int(at^) + grown)
	}
	pg.used = u16(int(pg.used) + grown)
	sum: f64
	if t.sums {
		all := reader(pg, t.width)
		for reader_next(&all) {
			sum += key_number(all.key)
		}
	}
	#reverse for step in path[:depth] {
		up, over := page_own(p, step.no)
		c := &children(over)[step.at]
		c.child, c.count = no, u32(int(c.count) + delta)
		if t.sums {
			c.sum = sum
			sum = 0
			for x in children(over) {
				sum += x.sum
			}
		}
		no = up
	}
	t.root = no
	return true
}

@(private)
edits_place :: proc(p: ^Pager, t: ^Tree, edits: []Edit) {
	top := make([dynamic]Child, context.temp_allocator)
	if t.root == 0 {
		w := Writer{p = p, t = t, out = &top}
		for e in edits {
			if !e.gone {
				writer_put(&w, e.entry)
			}
		}
		writer_end(&w)
		tree_grow(p, t, &top, 1)
		return
	}
	level := int(page_get(p, t.root).level)
	node_apply(p, t, t.root, edits, &top)
	tree_grow(p, t, &top, level + 1)
}

// Puts branches over nodes until there is one.
@(private)
tree_grow :: proc(p: ^Pager, t: ^Tree, nodes: ^[dynamic]Child, level: int) {
	nodes, level := nodes[:], level
	for len(nodes) > 1 {
		up := make([dynamic]Child, context.temp_allocator)
		branch_write(p, nodes, level, &up)
		nodes = up[:]
		level += 1
	}
	t.root = 0
	if len(nodes) == 0 {
		return
	}
	t.root = nodes[0].child
	// A branch over a single child says nothing.
	for {
		pg := page_get(p, t.root)
		if pg.level == 0 || pg.count != 1 {
			return
		}
		only := children(pg)[0].child
		page_drop(p, t.root)
		t.root = only
	}
}

@(private)
branch_write :: proc(p: ^Pager, nodes: []Child, level: int, out: ^[dynamic]Child) {
	pages := (len(nodes) + BRANCH_CAP - 1) / BRANCH_CAP
	at := 0
	for i in 0 ..< pages {
		n := (len(nodes) - at + pages - i - 1) / (pages - i)
		no, pg := page_new(p)
		pg.level, pg.count = u16(level), u16(n)
		copy(children(pg), nodes[at:][:n])
		c := Child{key = nodes[at].key, sub = nodes[at].sub, child = no}
		for x in nodes[at:][:n] {
			c.count += x.count
			c.sum += x.sum
		}
		append(out, c)
		at += n
	}
}

@(private)
node_apply :: proc(p: ^Pager, t: ^Tree, no: u32, edits: []Edit, out: ^[dynamic]Child) {
	pg := page_get(p, no)
	if pg.level == 0 {
		leaf_apply(p, t, no, edits, out)
		return
	}
	level := int(pg.level)
	old := make([]Child, int(pg.count), context.temp_allocator)
	copy(old, children(pg))
	page_drop(p, no)
	nodes := make([dynamic]Child, 0, len(old) + 4, context.temp_allocator)
	at := 0
	for c, i in old {
		end := len(edits)
		if i + 1 < len(old) {
			// Up to where the next child begins.
			lo, hi := at, len(edits)
			for lo < hi {
				mid := (lo + hi) / 2
				if entry_less(edits[mid].key, edits[mid].sub, old[i + 1].key, old[i + 1].sub) {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			end = lo
		}
		if end == at {
			append(&nodes, c)
			continue
		}
		before := len(nodes)
		node_apply(p, t, c.child, edits[at:end], &nodes)
		at = end
		if before > 0 && before < len(nodes) {
			node_join(p, t, &nodes, before)
		}
	}
	if len(nodes) > 0 {
		branch_write(p, nodes[:], level, out)
	}
}

// Two small neighbours become one.
@(private)
node_join :: proc(p: ^Pager, t: ^Tree, nodes: ^[dynamic]Child, i: int) {
	a, b := nodes[i - 1], nodes[i]
	pa, pb := page_get(p, a.child), page_get(p, b.child)
	if pa.level != pb.level {
		return
	}
	joined := make([dynamic]Child, context.temp_allocator)
	if pa.level > 0 {
		if int(pa.count) + int(pb.count) > BRANCH_CAP / 2 {
			return
		}
		all := make([dynamic]Child, context.temp_allocator)
		append(&all, ..children(pa))
		append(&all, ..children(pb))
		level := int(pa.level)
		branch_write(p, all[:], level, &joined)
	} else {
		if int(pa.used) + int(pb.used) > LEAF_ROOM / 2 {
			return
		}
		w := Writer{p = p, t = t, out = &joined}
		for c in ([2]u32{a.child, b.child}) {
			copied := new_clone(page_get(p, c)^, context.temp_allocator)
			r := reader(copied, t.width)
			for reader_next(&r) {
				writer_put(&w, r.at)
			}
		}
		writer_end(&w)
	}
	page_drop(p, a.child)
	page_drop(p, b.child)
	nodes[i - 1] = joined[0]
	if len(joined) > 1 {
		nodes[i] = joined[1]
	} else {
		ordered_remove(nodes, i)
	}
}

@(private)
leaf_apply :: proc(p: ^Pager, t: ^Tree, no: u32, edits: []Edit, out: ^[dynamic]Child) {
	old := new_clone(page_get(p, no)^, context.temp_allocator)
	page_drop(p, no)
	w := Writer{p = p, t = t, out = out}
	r := reader(old, t.width)
	have := reader_next(&r)
	for e in edits {
		for have && entry_less(r.key, r.sub, e.key, e.sub) {
			writer_put(&w, r.at)
			have = reader_next(&r)
		}
		if have && r.key == e.key && r.sub == e.sub {
			have = reader_next(&r)
		}
		if !e.gone {
			writer_put(&w, e.entry)
		}
	}
	for have {
		writer_put(&w, r.at)
		have = reader_next(&r)
	}
	writer_end(&w)
}

// Gives up every page.
tree_clear :: proc(p: ^Pager, t: ^Tree) {
	drop :: proc(p: ^Pager, no: u32) {
		pg := page_get(p, no)
		if pg.level > 0 {
			below := make([]u32, int(pg.count), context.temp_allocator)
			for c, i in children(pg) {
				below[i] = c.child
			}
			for c in below {
				drop(p, c)
			}
		}
		page_drop(p, no)
	}
	if t.root != 0 {
		drop(p, t.root)
	}
	t.root = 0
}

// ---------------------------------------------------------------- asking

// The child that would hold an entry.
@(private)
child_find :: proc(cs: []Child, key: Key, sub: u32) -> int #no_bounds_check {
	lo, hi := 1, len(cs)
	for lo < hi {
		mid := (lo + hi) / 2
		if entry_less(key, sub, cs[mid].key, cs[mid].sub) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo - 1
}

// A reader of a leaf, at the last restart not past an entry.
@(private)
leaf_seek :: proc(pg: ^Page, width: Width, key: Key, sub: u32) -> Reader {
	lo, hi := 1, int(pg.count)
	for lo < hi {
		mid := (lo + hi) / 2
		r := reader(pg, width, mid)
		reader_next(&r)
		if entry_less(key, sub, r.key, r.sub) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return reader(pg, width, max(lo - 1, 0))
}

@(require_results)
tree_get :: proc(p: ^Pager, t: Tree, key: Key, sub: u32) -> (val: u64, ok: bool) {
	if t.root == 0 {
		return
	}
	pg := page_get(p, t.root)
	for pg.level > 0 {
		cs := children(pg)
		pg = page_get(p, cs[child_find(cs, key, sub)].child)
	}
	r := leaf_seek(pg, t.width, key, sub)
	for reader_next(&r) {
		if !entry_less(r.key, r.sub, key, sub) {
			return r.val, r.key == key && r.sub == sub
		}
	}
	return
}

// What lies before an entry.
@(require_results)
tree_before :: proc(p: ^Pager, t: Tree, key: Key, sub: u32) -> (s: Total) {
	if t.root == 0 {
		return
	}
	pg := page_get(p, t.root)
	for pg.level > 0 {
		cs := children(pg)
		at := child_find(cs, key, sub)
		for c in cs[:at] {
			s.count += int(c.count)
			s.sum += c.sum
		}
		pg = page_get(p, cs[at].child)
	}
	r := reader(pg, t.width)
	for reader_next(&r) && entry_less(r.key, r.sub, key, sub) {
		s.count += 1
		if t.sums {
			s.sum += key_number(r.key)
		}
	}
	return
}

@(require_results)
tree_total :: proc(p: ^Pager, t: Tree) -> (s: Total) {
	if t.root == 0 {
		return
	}
	pg := page_get(p, t.root)
	if pg.level > 0 {
		for c in children(pg) {
			s.count += int(c.count)
			s.sum += c.sum
		}
		return
	}
	r := reader(pg, t.width)
	for reader_next(&r) {
		s.count += 1
		if t.sums {
			s.sum += key_number(r.key)
		}
	}
	return
}

// Entries of keys from `lo` up to, and not including, `hi`; where `hi` is KEY_MAX, including it.
@(require_results)
tree_between :: proc(p: ^Pager, t: Tree, lo, hi: Key) -> (s: Total) {
	a := tree_before(p, t, lo, 0)
	s = tree_total(p, t) if hi == KEY_MAX else tree_before(p, t, hi, 0)
	return {max(s.count - a.count, 0), s.sum - a.sum}
}

// Walks entries in either direction.
Cursor :: struct {
	p:     ^Pager,
	t:     Tree,
	path:  [8]struct {
		no: u32,
		at: int,
	},
	depth: int, // of the leaf in the path
	block: int,
	items: [dynamic]Entry, // the block's
	at:    int, // the next going forward
	done:  bool,
}

cursor_make :: proc(p: ^Pager, t: Tree, allocator := context.temp_allocator) -> (c: Cursor) {
	c.p, c.t = p, t
	c.items = make([dynamic]Entry, allocator)
	return
}

cursor_destroy :: proc(c: ^Cursor) {
	delete(c.items)
	c^ = {}
}

// Stands before the first entry not less than this one.
cursor_seek :: proc(c: ^Cursor, key: Key, sub: u32 = 0) {
	clear(&c.items)
	c.at, c.depth = 0, 0
	c.done = c.t.root == 0
	if c.done {
		return
	}
	no := c.t.root
	for {
		pg := page_get(c.p, no)
		if pg.level == 0 {
			c.path[c.depth] = {no, 0}
			lo, hi := 1, int(pg.count)
			for lo < hi {
				mid := (lo + hi) / 2
				r := reader(pg, c.t.width, mid)
				reader_next(&r)
				if entry_less(r.key, r.sub, key, sub) {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			cursor_block(c, max(lo - 1, 0))
			break
		}
		cs := children(pg)
		at := child_find(cs, key, sub)
		c.path[c.depth] = {no, at}
		c.depth += 1
		no = cs[at].child
	}
	lo, hi := 0, len(c.items)
	for lo < hi {
		mid := (lo + hi) / 2
		if entry_less(c.items[mid].key, c.items[mid].sub, key, sub) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	c.at = lo
}

@(private)
cursor_block :: proc(c: ^Cursor, block: int) {
	pg := page_get(c.p, c.path[c.depth].no)
	c.block = block
	clear(&c.items)
	if pg.count == 0 {
		return
	}
	r := reader(pg, c.t.width, block)
	if block + 1 < int(pg.count) {
		r.stop = restart_at(pg, block + 1)
	}
	for reader_next(&r) {
		append(&c.items, r.at)
	}
}

@(require_results)
cursor_next :: proc(c: ^Cursor) -> (e: Entry, ok: bool) {
	for !c.done {
		if c.at < len(c.items) {
			c.at += 1
			return c.items[c.at - 1], true
		}
		if !cursor_step(c, 1) {
			c.at = len(c.items)
			return
		}
		c.at = 0
	}
	return
}

@(require_results)
cursor_prev :: proc(c: ^Cursor) -> (e: Entry, ok: bool) {
	for !c.done {
		if c.at > 0 {
			c.at -= 1
			return c.items[c.at], true
		}
		if !cursor_step(c, -1) {
			c.at = 0
			return
		}
		c.at = len(c.items)
	}
	return
}

// The block after this one, or before it. False, and nothing moved, when there is none.
@(private)
cursor_step :: proc(c: ^Cursor, way: int) -> bool {
	pg := page_get(c.p, c.path[c.depth].no)
	if b := c.block + way; b >= 0 && b < int(pg.count) {
		cursor_block(c, b)
		return true
	}
	d := c.depth - 1
	for d >= 0 {
		up := page_get(c.p, c.path[d].no)
		if at := c.path[d].at + way; at >= 0 && at < int(up.count) {
			c.path[d].at = at
			break
		}
		d -= 1
	}
	if d < 0 {
		return false
	}
	for d < c.depth {
		up := page_get(c.p, c.path[d].no)
		below := children(up)[c.path[d].at].child
		d += 1
		c.path[d] = {below, 0}
		if d < c.depth && way < 0 {
			c.path[d].at = int(page_get(c.p, below).count) - 1
		}
	}
	leaf := page_get(c.p, c.path[c.depth].no)
	cursor_block(c, 0 if way > 0 else max(int(leaf.count) - 1, 0))
	return true
}

// Every entry of keys from `lo` up to, and not including, `hi`, as fast as they can be read.
tree_each :: proc(p: ^Pager, t: Tree, lo, hi: Key, data: rawptr, each: proc(data: rawptr, e: ^Entry)) {
	walk :: proc(p: ^Pager, t: ^Tree, no: u32, lo, hi: Key, data: rawptr, each: proc(data: rawptr, e: ^Entry)) {
		pg := page_get(p, no)
		if pg.level > 0 {
			cs := make([]Child, int(pg.count), context.temp_allocator)
			copy(cs, children(pg))
			for c, i in cs {
				if !key_less(c.key, hi) && hi != KEY_MAX {
					return
				}
				if i + 1 < len(cs) && key_less(cs[i + 1].key, lo) {
					continue
				}
				walk(p, t, c.child, lo, hi, data, each)
			}
			return
		}
		r := leaf_seek(pg, t.width, lo, 0)
		for reader_next(&r) {
			if key_less(r.key, lo) {
				continue
			}
			if !key_less(r.key, hi) && hi != KEY_MAX {
				return
			}
			each(data, &r.at)
		}
	}
	t := t
	if t.root != 0 {
		walk(p, &t, t.root, lo, hi, data, each)
	}
}

// The subs of every entry of keys from `lo` up to, and not including, `hi`.
tree_subs :: proc(p: ^Pager, t: Tree, lo, hi: Key, out: ^Set) {
	// `within`: all of this node lies between them, and its keys need not be made out.
	walk :: proc(p: ^Pager, t: ^Tree, no: u32, lo, hi: Key, within: bool, out: ^Set) {
		pg := page_get(p, no)
		if pg.level > 0 {
			cs := make([]Child, int(pg.count), context.temp_allocator)
			copy(cs, children(pg))
			for c, i in cs {
				if within {
					walk(p, t, c.child, lo, hi, true, out)
					continue
				}
				if !key_less(c.key, hi) && hi != KEY_MAX {
					return
				}
				last := i + 1 == len(cs)
				if !last && key_less(cs[i + 1].key, lo) {
					continue
				}
				inner := i > 0 && !key_less(c.key, lo) && !last && (hi == KEY_MAX || key_less(cs[i + 1].key, hi))
				walk(p, t, c.child, lo, hi, inner || (lo == KEY_MIN && hi == KEY_MAX), out)
			}
			return
		}
		if within || (lo == KEY_MIN && hi == KEY_MAX) {
			leaf_subs(pg, t.width, out)
			return
		}
		r := leaf_seek(pg, t.width, lo, 0)
		key: Key
		inside, begun := false, false
		for reader_next(&r) {
			if !begun || r.key != key {
				key, begun = r.key, true
				if !key_less(key, hi) && hi != KEY_MAX {
					return
				}
				inside = !key_less(key, lo)
			}
			if inside {
				set_put(out, r.sub)
			}
		}
	}
	t := t
	if t.root != 0 {
		walk(p, &t, t.root, lo, hi, false, out)
		set_settle(out)
	}
}

// Every sub in a leaf, and nothing else of it.
@(private)
leaf_subs :: proc(pg: ^Page, width: Width, out: ^Set) #no_bounds_check {
	d := pg.data[:]
	pos, stop := 0, int(pg.used)
	sub: u32
	for pos < stop {
		h := d[pos]
		pos += 1
		switch {
		case h < SAME_LONG:
			sub += u32(h) + 1
		case h == SAME_LONG:
			sub += u32(read_varint(d, &pos))
		case:
			pos += 1 + int(d[pos])
			sub = u32(read_varint(d, &pos))
		}
		switch width {
		case .None:
		case .Byte:
			pos += 1
		case .Varint:
			_ = read_varint(d, &pos)
		}
		set_put(out, sub)
	}
}

// ---------------------------------------------------------------- making a tree of much at once

// Entries are gathered, put in order, and laid down as trees of their own, which are then read side by side into
// one. Nothing is written over and over, however many there are.
Bulk :: struct {
	p:     ^Pager,
	t:     ^Tree,
	edits: [dynamic]Edit,
	runs:  [dynamic]Tree,
	arena: virtual.Arena,
	merging: Merging,
}

@(private)
RUN :: 1 << 15
@(private)
RUNS :: 48 // read side by side

bulk_begin :: proc(b: ^Bulk, p: ^Pager, t: ^Tree) {
	b.p, b.t = p, t
	if virtual.arena_init_static(&b.arena, (RUN + 64) * size_of(Edit), 1 << 16) == nil {
		b.edits = make([dynamic]Edit, 0, RUN, virtual.arena_allocator(&b.arena))
	}
}

bulk_add :: #force_inline proc(b: ^Bulk, e: Entry) {
	if len(b.edits) == RUN {
		bulk_run(b)
	}
	append(&b.edits, Edit{entry = e})
}

@(private)
bulk_run :: proc(b: ^Bulk) {
	if len(b.edits) == 0 {
		return
	}
	run := Tree{width = b.t.width, sums = b.t.sums}
	l: Laying
	laying_begin(&l, b.p)
	for e in edits_settle(b.edits[:]) {
		laying_put(&l, &run, e.entry)
	}
	laying_end(&l, &run)
	append(&b.runs, run)
	clear(&b.edits)
}

// Goes on putting it all together, for about so many entries. True once it is done, and the tree, which must have
// been empty, is whole.
bulk_end :: proc(b: ^Bulk, budget := max(int)) -> bool {
	if b.merging.p == nil {
		bulk_run(b)
		b.edits = {}
		if b.arena.curr_block != nil {
			virtual.arena_destroy(&b.arena)
		}
	}
	left := budget
	for {
		if b.merging.p != nil {
			if !merging_step(&b.merging, &left) {
				return false
			}
			append(&b.runs, b.merging.out)
			b.merging = {}
		}
		if len(b.runs) <= 1 {
			break
		}
		// The first so many, which are the smallest, for what they come to goes to the end.
		n := min(RUNS, len(b.runs))
		merging_begin(&b.merging, b.p, b.runs[:n])
		remove_range(&b.runs, 0, n)
	}
	if len(b.runs) == 1 {
		b.t.root = b.runs[0].root
	}
	delete(b.runs)
	b^ = {}
	return true
}

// Gives it up.
bulk_abandon :: proc(b: ^Bulk) {
	if b.arena.curr_block != nil {
		virtual.arena_destroy(&b.arena)
	}
	if b.merging.p != nil {
		for &r in b.merging.from {
			run_end(&r)
		}
		delete(b.merging.from)
		delete(b.merging.heap)
		delete(b.merging.l.leaves)
	}
	// What was laid down is found to be nobody's when the index is next opened.
	delete(b.runs)
	b^ = {}
}

@(private)
Merging :: struct {
	p:    ^Pager,
	out:  Tree,
	l:    Laying,
	from: []Run_Reader,
	heap: [dynamic]int,
	last: Entry,
	begun: bool,
}

@(private)
run_less :: #force_inline proc(a, b: ^Run_Reader) -> bool {
	return entry_less(a.at.key, a.at.sub, b.at.key, b.at.sub)
}

@(private)
heap_sift :: proc(heap: []int, from: []Run_Reader, at: int) {
	at := at
	for {
		kid := 2 * at + 1
		if kid >= len(heap) {
			return
		}
		if kid + 1 < len(heap) && run_less(&from[heap[kid + 1]], &from[heap[kid]]) {
			kid += 1
		}
		if !run_less(&from[heap[kid]], &from[heap[at]]) {
			return
		}
		heap[at], heap[kid] = heap[kid], heap[at]
		at = kid
	}
}

@(private)
merging_begin :: proc(m: ^Merging, p: ^Pager, runs: []Tree) {
	m.p = p
	m.out = {width = runs[0].width, sums = runs[0].sums}
	laying_begin(&m.l, p)
	m.from = make([]Run_Reader, len(runs))
	for &r, i in m.from {
		run_begin(&r, p, runs[i])
		if run_next(&r) {
			append(&m.heap, i)
		}
	}
	for i := len(m.heap) / 2 - 1; i >= 0; i -= 1 {
		heap_sift(m.heap[:], m.from, i)
	}
}

@(private)
merging_step :: proc(m: ^Merging, left: ^int) -> bool {
	for len(m.heap) > 0 {
		if left^ <= 0 {
			writer_end(&m.l.w) // a page is not held on to while others are written
			return false
		}
		left^ -= 1
		r := &m.from[m.heap[0]]
		// One that is in several is the same in all.
		if !m.begun || r.at.key != m.last.key || r.at.sub != m.last.sub {
			laying_put(&m.l, &m.out, r.at)
			m.last, m.begun = r.at, true
		}
		if !run_next(r) {
			m.heap[0] = m.heap[len(m.heap) - 1]
			pop(&m.heap)
		}
		heap_sift(m.heap[:], m.from, 0)
	}
	laying_end(&m.l, &m.out)
	for &r in m.from {
		run_end(&r)
	}
	delete(m.from)
	delete(m.heap)
	return true
}

// Reads a tree from end to end, giving up its pages behind it.
@(private)
Run_Reader :: struct {
	p:      ^Pager,
	width:  Width,
	leaves: [dynamic]u32, // yet to be read, last first
	page:   ^Page,
	no:     u32,
	r:      Reader,
	at:     Entry,
}

@(private)
run_begin :: proc(r: ^Run_Reader, p: ^Pager, t: Tree) {
	r.p, r.width = p, t.width
	gather :: proc(r: ^Run_Reader, no: u32) {
		pg := page_get(r.p, no)
		if pg.level == 0 {
			append(&r.leaves, no)
			return
		}
		below := make([]u32, int(pg.count))
		defer delete(below)
		for c, i in children(pg) {
			below[i] = c.child
		}
		for c in below {
			gather(r, c)
		}
		page_drop(r.p, no)
	}
	if t.root != 0 {
		gather(r, t.root)
	}
	slice.reverse(r.leaves[:])
	r.page = new(Page)
}

@(private)
run_next :: proc(r: ^Run_Reader) -> bool {
	for !reader_next(&r.r) {
		if r.no != 0 {
			page_drop(r.p, r.no)
			r.no = 0
		}
		if len(r.leaves) == 0 {
			return false
		}
		r.no = pop(&r.leaves)
		r.page^ = page_get(r.p, r.no)^
		r.r = reader(r.page, r.width)
	}
	r.at = r.r.at
	return true
}

@(private)
run_end :: proc(r: ^Run_Reader) {
	delete(r.leaves)
	free(r.page)
}

// Lays a tree down from entries in order.
@(private)
Laying :: struct {
	w:      Writer,
	leaves: [dynamic]Child,
}

@(private)
laying_begin :: proc(l: ^Laying, p: ^Pager) {
	l.w = Writer{p = p, laying = true}
}

@(private)
laying_put :: #force_inline proc(l: ^Laying, t: ^Tree, e: Entry) {
	l.w.out, l.w.t = &l.leaves, t
	writer_put(&l.w, e)
}

@(private)
laying_end :: proc(l: ^Laying, t: ^Tree) {
	writer_end(&l.w)
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	tree_grow(l.w.p, t, &l.leaves, 1)
	delete(l.leaves)
	l^ = {}
}
