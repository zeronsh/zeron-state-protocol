package find

import "base:runtime"
import "core:math/bits"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../zsp"

// What is kept of a space so that questions about it are quick. Rows go by a number of their own here. A column
// that is compared is kept twice: by row, to be read, and by value, to be searched, ordered, counted and summed.
// One that is searched for words keeps, for every word, the texts it is in.
//
// It follows the store: by its recent changes when there are few, and by reading on in its log when there are
// many. It remembers how far it has read, and forgets nothing it needs to know by being deleted.

Index :: struct {
	using pager: Pager,
	n:          ^zsp.Node,
	scopes:     [dynamic]^Scope,
	generation: u64,
	upto:       u64, // the log has been read this far
	serial:     u64, // under this roster
	cursor:     u64, // into the node's recent changes
	tailing:    bool, // which are all that has happened since
	unsaved:    int, // rows gone over since it was last written
	blob:       [dynamic]u32, // pages the catalogue is in
	watchers:   [dynamic]Watcher,
}

Slots :: distinct [4]u64

@(private)
slots_add :: #force_inline proc(s: ^Slots, slot: zsp.Slot) {
	s[slot >> 6] |= 1 << (u64(slot) & 63)
}

@(private)
EVERY_SLOT :: Slots{max(u64), max(u64), max(u64), max(u64)}

// Told of every row gone over, before and after. Sets are of what rows are called here.
Watcher :: struct {
	data:   rawptr,
	before: proc(data: rawptr, s: ^Scope, row: u32),
	after:  proc(data: rawptr, s: ^Scope, row: u32, gone: bool),
	done:   proc(data: rawptr),
}

Scope :: struct {
	x:       ^Index,
	id:      zsp.Scope,
	next:    u32, // the number the next row will have
	ids:     Tree, // row id, number
	rows:    Tree, // number and most of the id
	columns: [dynamic]^Held,
	edits:   [2][dynamic]Edit, // of ids and rows
	all:     Set, // every row
}

Held :: struct {
	using column: Column, // the path is owned
	scope: ^Scope,
	built: bool, // every row is in it
	by_row: Tree, // number and value
	by_key: Tree, // value, number
	// For words: by_key is word, text; by_row is number, a hash of the text, and text; texts says whose each is.
	texts: Array, // how many words a text has, and one more than the row it is of
	alive: int, // texts that are of a row
	lexicon: Tree, // every word there has been
	next_text: u32,
	length: u64, // words in all the texts there are
	dead:   int, // texts that are gone, and whose words are yet to go
	edits:  [4][dynamic]Edit,
	asked:  u64, // when last of use
}

@(private)
BATCH :: 1 << 17 // edits gathered before they are made

@(private)
HEADERS :: 2
@(private)
MAGIC :: 0x7a73_7066_696e_6431

@(private)
Header :: struct {
	magic:      u64,
	generation: u64,
	upto:       u64,
	serial:     u64,
	next:       u32,
	blob:       u32, // the first page of the catalogue
	size:       u32,
	salt:       u32,
}

index_open :: proc(x: ^Index, n: ^zsp.Node, disk: Disk, key: zsp.Key32) {
	x.n = n
	pager_open(x, disk, key)
	best: Header
	for no in u32(0) ..< HEADERS {
		pg := page_get(x, no)
		h := (^Header)(&pg.data)^
		if !x.failed && h.magic == MAGIC && h.generation >= best.generation {
			best = h
		}
		x.failed = false // one that is not there, or cannot be read, is no header
		frame_free(x, no)
	}
	x.generation = best.generation
	if best.generation > 0 && catalogue_read(x, &best) {
		x.upto, x.serial, x.next = best.upto, best.serial, best.next
		free_find(x)
	} else {
		index_reset(x)
	}
}

// Forgets everything. It is made again as it is asked for.
@(private)
index_reset :: proc(x: ^Index) {
	for s in x.scopes {
		scope_free(s)
	}
	clear(&x.scopes)
	for frames in ([]^map[u32]^Frame{&x.open, &x.dirty}) {
		for _, f in frames {
			free(f)
		}
		clear(frames)
	}
	x.newest, x.oldest = nil, nil
	clear(&x.free)
	clear(&x.pending)
	set_destroy(&x.fresh)
	clear(&x.blob)
	x.next = HEADERS
	x.upto, x.serial, x.tailing, x.failed = 0, x.n.roster.serial, false, false
}

index_close :: proc(x: ^Index) {
	for s in x.scopes {
		scope_free(s)
	}
	delete(x.scopes)
	delete(x.blob)
	delete(x.watchers)
	pager_close(x)
	x^ = {}
}

@(private)
scope_free :: proc(s: ^Scope) {
	for h in s.columns {
		held_free(h)
	}
	delete(s.columns)
	for e in s.edits {
		delete(e)
	}
	set_destroy(&s.all)
	free(s)
}

@(private)
held_free :: proc(h: ^Held) {
	for e in h.edits {
		delete(e)
	}
	delete(h.path)
	free(h)
}

@(private)
held_trees :: proc(h: ^Held) -> [4]^Tree {
	return {&h.by_row, &h.by_key, &h.texts.blocks, &h.lexicon}
}

// ---------------------------------------------------------------- resting

// Writes what is new, so that it need not be made again. The log must be durable so far.
index_save :: proc(x: ^Index) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if x.upto > x.n.synced {
		return false
	}
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&w, u64(len(x.scopes)))
	put_tree :: proc(w: ^[dynamic]byte, t: Tree) {
		zsp.write_varint(w, u64(t.root))
	}
	for s in x.scopes {
		zsp.write_varint(&w, u64(s.id))
		zsp.write_varint(&w, u64(s.next))
		put_tree(&w, s.ids)
		put_tree(&w, s.rows)
		zsp.write_varint(&w, u64(len(s.columns)))
		for h in s.columns {
			append(&w, u8(h.kind), u8(h.slot), 1 if h.built else 0)
			zsp.write_bytes(&w, transmute([]byte)h.path)
			zsp.write_varint(&w, h.list[0])
			zsp.write_varint(&w, h.list[1])
			for t in held_trees(h) {
				put_tree(&w, t^)
			}
			zsp.write_varint(&w, u64(h.next_text))
			zsp.write_varint(&w, h.length)
			zsp.write_varint(&w, u64(h.dead))
			zsp.write_varint(&w, u64(h.alive))
		}
	}
	for no in x.blob {
		page_drop(x, no)
	}
	clear(&x.blob)
	// From the last page to the first, each naming the next.
	ROOM :: LEAF_ROOM - 4
	next: u32
	for at := (len(w) + ROOM - 1) / ROOM - 1; at >= 0; at -= 1 {
		no, pg := page_new(x)
		(^u32)(&pg.data)^ = next
		copy(pg.data[4:], w[at * ROOM:])
		append(&x.blob, no)
		next = no
	}
	if !pager_write(x) || !x.disk.sync(x.disk.data) {
		x.failed = true
		return false
	}
	x.generation += 1
	h := Header{MAGIC, x.generation, x.upto, x.serial, x.next, next, u32(len(w)), 0}
	at := u32(x.generation % HEADERS)
	// Written as any page is, so that it too is sealed.
	f := new(Frame)
	f.no = at
	(^Header)(&f.page.data)^ = h
	frame_free(x, at)
	x.dirty[at] = f
	if !pager_write(x) || !x.disk.sync(x.disk.data) {
		x.failed = true
		return false
	}
	append(&x.free, ..x.pending[:])
	clear(&x.pending)
	set_destroy(&x.fresh)
	x.unsaved = 0
	return true
}

@(private)
catalogue_read :: proc(x: ^Index, best: ^Header) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	bytes := make([dynamic]byte, context.temp_allocator)
	for no := best.blob; no != 0 && len(bytes) < int(best.size); {
		pg := page_get(x, no)
		if x.failed {
			return false
		}
		append(&x.blob, no)
		append(&bytes, ..pg.data[4:])
		no = (^u32)(&pg.data)^
	}
	if len(bytes) < int(best.size) {
		return false
	}
	r := zsp.Reader{buf = bytes[:best.size]}
	scopes := int(zsp.read_varint(&r))
	for _ in 0 ..< scopes {
		s := scope_make(x, zsp.Scope(zsp.read_varint(&r)))
		s.next = u32(zsp.read_varint(&r))
		s.ids.root = u32(zsp.read_varint(&r))
		s.rows.root = u32(zsp.read_varint(&r))
		columns := int(zsp.read_varint(&r))
		for _ in 0 ..< columns {
			h := new(Held)
			h.scope = s
			h.kind = Kind(zsp.read_u8(&r))
			h.slot = zsp.Slot(zsp.read_u8(&r))
			h.built = zsp.read_u8(&r) != 0
			h.path = strings.clone(string(zsp.read_bytes(&r)))
			h.list[0] = zsp.read_varint(&r)
			h.list[1] = zsp.read_varint(&r)
			held_shape(h)
			for t in held_trees(h) {
				t.root = u32(zsp.read_varint(&r))
			}
			h.next_text = u32(zsp.read_varint(&r))
			h.length = zsp.read_varint(&r)
			h.dead = int(zsp.read_varint(&r))
			h.alive = int(zsp.read_varint(&r))
			append(&s.columns, h)
			if r.bad {
				return false
			}
		}
		if tree_total(x, s.rows).count == int(s.next) {
			set_fill(&s.all, s.next)
		} else {
			rows_each(s, proc(s: ^Scope, row: u32) {
				set_add(&s.all, row)
			})
		}
	}
	return !r.bad && !x.failed
}

// Every page nothing leads to may be used. Only branches are read.
@(private)
free_find :: proc(x: ^Index) {
	used := make([]bool, x.next)
	defer delete(used)
	mark :: proc(x: ^Index, used: []bool, no: u32) {
		if no == 0 || int(no) >= len(used) {
			return
		}
		used[no] = true
		pg := page_get(x, no)
		if pg.level == 0 {
			return
		}
		level := pg.level
		below := make([]u32, int(pg.count))
		defer delete(below)
		for c, i in children(pg) {
			below[i] = c.child
		}
		for c in below {
			if level == 1 {
				used[min(int(c), len(used) - 1)] = true
			} else {
				mark(x, used, c)
			}
		}
	}
	for no in 0 ..< HEADERS {
		used[no] = true
	}
	for no in x.blob {
		used[no] = true
	}
	for s in x.scopes {
		mark(x, used, s.ids.root)
		mark(x, used, s.rows.root)
		for h in s.columns {
			for t in held_trees(h) {
				mark(x, used, t.root)
			}
			pages := make([dynamic]u32)
			defer delete(pages)
			array_pages(x, h.texts, &pages)
			for no in pages {
				used[min(int(no), len(used) - 1)] = true
			}
		}
	}
	#reverse for u, no in used {
		if !u {
			append(&x.free, u32(no))
		}
	}
}

// ---------------------------------------------------------------- scopes, rows and columns

@(private)
scope_make :: proc(x: ^Index, id: zsp.Scope) -> ^Scope {
	s := new(Scope)
	s.x, s.id = x, id
	append(&x.scopes, s)
	return s
}

@(require_results)
index_scope :: proc(x: ^Index, id: zsp.Scope) -> ^Scope {
	for s in x.scopes {
		if s.id == id {
			return s
		}
	}
	return nil
}

@(private)
id_key :: proc(id: zsp.Id) -> Key {
	return {id[0] << 32 | id[1] >> 32, id[1] << 32}
}

@(private)
row_key :: proc(row: u32, id: zsp.Id) -> Key {
	return {u64(row) << 32 | id[0] & 0xffff_ffff, id[1]}
}

// What a row goes by.
@(require_results)
row_number :: proc(s: ^Scope, id: zsp.Id) -> (row: u32, ok: bool) {
	if zsp.row_scope(id) != s.id {
		return
	}
	if s.ids.root == 0 {
		return
	}
	key := id_key(id)
	pg := page_get(s.x, s.ids.root)
	for pg.level > 0 {
		cs := children(pg)
		pg = page_get(s.x, cs[child_find(cs, key, max(u32))].child)
	}
	r := leaf_seek(pg, s.ids.width, key, 0)
	for reader_next(&r) {
		if r.key == key {
			return r.sub, true
		}
		if key_less(key, r.key) {
			return
		}
	}
	return
}

@(require_results)
row_id :: proc(s: ^Scope, row: u32) -> (id: zsp.Id, ok: bool) {
	e := tree_first(s.x, s.rows, {u64(row) << 32, 0}) or_return
	if u32(e.key.hi >> 32) != row {
		return
	}
	return {u64(s.id) << 32 | e.key.hi & 0xffff_ffff, e.key.lo}, true
}

@(private)
rows_each :: proc(s: ^Scope, each: proc(s: ^Scope, row: u32)) {
	Both :: struct {
		s:    ^Scope,
		each: proc(s: ^Scope, row: u32),
	}
	b := Both{s, each}
	tree_each(s.x, s.rows, KEY_MIN, KEY_MAX, &b, proc(data: rawptr, e: ^Entry) {
		b := (^Both)(data)
		b.each(b.s, u32(e.key.hi >> 32))
	})
}

// The first entry not less than a key.
@(require_results)
tree_first :: proc(p: ^Pager, t: Tree, key: Key, sub: u32 = 0) -> (e: Entry, ok: bool) {
	if t.root == 0 {
		return
	}
	pg := page_get(p, t.root)
	next: u32 // the leaf after, should this one have nothing
	for pg.level > 0 {
		cs := children(pg)
		at := child_find(cs, key, sub)
		if at + 1 < len(cs) {
			next = cs[at + 1].child
		}
		pg = page_get(p, cs[at].child)
	}
	r := leaf_seek(pg, t.width, key, sub)
	for reader_next(&r) {
		if !entry_less(r.key, r.sub, key, sub) {
			return r.at, true
		}
	}
	for next != 0 {
		pg = page_get(p, next)
		if pg.level == 0 {
			r = reader(pg, t.width)
			ok = reader_next(&r)
			return r.at, ok
		}
		next = children(pg)[0].child
	}
	return
}

@(private)
held_shape :: proc(h: ^Held) {
	if h.kind == .Words {
		h.by_key.width = .Byte
		h.texts.blocks.width = .Varint
		return
	}
	h.by_row.width = .Byte
	h.by_key.width = .Byte if h.kind == .Bytes || h.kind == .Fold else .None
	h.by_key.sums = h.kind == .Number
}

@(require_results)
index_column :: proc(x: ^Index, scope: zsp.Scope, c: ^Column) -> ^Held {
	s := index_scope(x, scope)
	if s == nil {
		return nil
	}
	for h in s.columns {
		if column_same(h, c) {
			return h
		}
	}
	return nil
}

// Makes a column for a scope, unless it is there, and everything it needs.
index_want :: proc(x: ^Index, scope: zsp.Scope, c: ^Column) -> ^Held {
	s := index_scope(x, scope)
	if s == nil {
		s = scope_make(x, scope)
		scope_fill(s)
	}
	for h in s.columns {
		if column_same(h, c) {
			return h
		}
	}
	h := new(Held)
	h.column = c^
	h.path = strings.clone(c.path)
	h.scope = s
	held_shape(h)
	append(&s.columns, h)
	held_fill(h)
	return h
}

index_drop :: proc(x: ^Index, h: ^Held) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	held_clear(h)
	for other, i in h.scope.columns {
		if other == h {
			unordered_remove(&h.scope.columns, i)
			break
		}
	}
	held_free(h)
}

@(private)
held_clear :: proc(h: ^Held) {
	array_clear(h.scope.x, &h.texts)
	for t, i in held_trees(h) {
		if i != 2 {
			tree_clear(h.scope.x, t)
		}
	}
}

// Numbers every row there is. The index must be level with the store.
@(private)
scope_fill :: proc(s: ^Scope) {
	bulk := new([2]Bulk)
	defer free(bulk)
	bulk_begin(&bulk[0], s.x, &s.ids)
	bulk_begin(&bulk[1], s.x, &s.rows)
	last: zsp.Id
	scan := zsp.tree_scan(&s.x.n.store, s.x.n.cells, {u64(s.id) << 32, 0, 0, 0, 0}, {(u64(s.id) + 1) << 32, 0, 0, 0, 0})
	for leaf in zsp.tree_next(&scan) {
		id := zsp.Id{leaf.key[0], leaf.key[1]}
		if id == last {
			continue
		}
		last = id
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if row_there(s, id) {
			row_admit(s, id)
			for &edits, i in s.edits {
				for x in edits {
					bulk_add(&bulk[i], x.entry)
				}
				clear(&edits)
			}
		}
	}
	for &b in bulk {
		bulk_end(&b)
	}
	index_relieve(s.x)
}

// Reads a column of every row. Its trees must be empty.
@(private)
held_fill :: proc(h: ^Held) {
	s := h.scope
	bulk := new([4]Bulk)
	defer free(bulk)
	for t, i in held_trees(h) {
		if i != 2 {
			bulk_begin(&bulk[i], s.x, t)
		}
	}
	c := cursor_make(s.x, s.rows, context.allocator)
	defer cursor_destroy(&c)
	cursor_seek(&c, KEY_MIN)
	for e in cursor_next(&c) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		row := Row{n = s.x.n, id = {u64(s.id) << 32 | e.key.hi & 0xffff_ffff, e.key.lo}}
		held_read(h, u32(e.key.hi >> 32), &row, fresh = true)
		for &edits, i in h.edits {
			if i == 2 {
				texts_make(h)
				index_relieve(s.x)
				continue
			}
			for x in edits {
				bulk_add(&bulk[i], x.entry)
			}
			clear(&edits)
		}
	}
	for &b, i in bulk {
		if i != 2 {
			bulk_end(&b)
		}
	}
	index_relieve(s.x)
	h.built = true
}

// A row is there to be found while it has a place, and is not in its grave.
@(private)
row_there :: proc(s: ^Scope, id: zsp.Id) -> bool {
	if _, dead := zsp.row_grave(&s.x.n.store, id); dead {
		return false
	}
	places := zsp.row_places(&s.x.n.store, id)
	return places.count > 0
}

@(private)
row_admit :: proc(s: ^Scope, id: zsp.Id) -> u32 {
	row := s.next
	s.next += 1
	append(&s.edits[0], Edit{entry = {key = id_key(id), sub = row}})
	append(&s.edits[1], Edit{entry = {key = row_key(row, id)}})
	set_add(&s.all, row)
	return row
}

// Goes over a row again, in so far as these slots can have changed it.
@(private)
row_reread :: proc(s: ^Scope, id: zsp.Id, slots: ^Slots) {
	row, known := row_number(s, id)
	there := row_there(s, id)
	if !there && !known {
		return
	}
	x := s.x
	if known {
		for w in x.watchers {
			w.before(w.data, s, row)
		}
	} else {
		row = row_admit(s, id)
	}
	r := Row{n = x.n, id = id}
	for h in s.columns {
		if !there {
			held_unread(h, row)
			continue
		}
		touched := !known
		for word, i in slots {
			for word := word; word != 0; word &= word - 1 {
				touched ||= column_reads(h, zsp.Slot(i << 6 + int(bits.trailing_zeros(word))))
			}
		}
		if touched {
			held_read(h, row, &r, fresh = !known)
		}
	}
	if !there {
		append(&s.edits[0], Edit{entry = {key = id_key(id), sub = row}, gone = true})
		append(&s.edits[1], Edit{entry = {key = row_key(row, id)}, gone = true})
		set_remove(&s.all, row)
	}
	x.unsaved += 1
	for w in x.watchers {
		w.after(w.data, s, row, !there)
	}
}

// ---------------------------------------------------------------- columns

// The values a column has for a row, from the index. Temporary memory.
@(require_results)
held_values :: proc(h: ^Held, row: u32) -> []Value {
	out := make([dynamic]Value, context.temp_allocator)
	if h.by_row.root == 0 {
		return nil
	}
	lo := by_row_split(row, KEY_MIN)
	pg := page_get(h.scope.x, h.by_row.root)
	for pg.level > 0 {
		cs := children(pg)
		pg = page_get(h.scope.x, cs[child_find(cs, lo.key, lo.sub)].child)
	}
	r := leaf_seek(pg, h.by_row.width, lo.key, lo.sub)
	for reader_next(&r) {
		if at := u32(r.key.hi >> 32); at == row {
			append(&out, Value{by_row_key(r.key, r.sub), r.val != 0})
		} else if at > row {
			return out[:]
		}
	}
	// Perhaps more of them in the next leaf.
	c := cursor_make(h.scope.x, h.by_row)
	cursor_seek(&c, lo.key, lo.sub)
	clear(&out)
	for e in cursor_next(&c) {
		if u32(e.key.hi >> 32) != row {
			break
		}
		append(&out, Value{by_row_key(e.key, e.sub), e.val != 0})
	}
	return out[:]
}

// A row's number and a value make twenty bytes, which is a key and a sub.
@(private)
by_row_split :: proc(row: u32, k: Key) -> (e: Entry) {
	e.key = {u64(row) << 32 | k.hi >> 32, k.hi << 32 | k.lo >> 32}
	e.sub = u32(k.lo)
	return
}

@(private)
by_row_key :: proc(k: Key, sub: u32) -> Key {
	return {k.hi << 32 | k.lo >> 32, k.lo << 32 | u64(sub)}
}

@(private)
held_read :: proc(h: ^Held, row: u32, r: ^Row, fresh: bool) {
	if h.kind == .Words {
		words_read(h, row, r, fresh)
		return
	}
	now := row_values(r, h)
	was := held_values(h, row) if !fresh else nil
	for v in was {
		held_edit(h, row, v, gone = true)
	}
	for v in now {
		held_edit(h, row, v, gone = false)
	}
}

// An edit that undoes another in the same batch replaces it: see edits_settle.
@(private)
held_edit :: proc(h: ^Held, row: u32, v: Value, gone: bool) {
	e := by_row_split(row, v.key)
	e.val = 1 if v.long else 0
	append(&h.edits[0], Edit{entry = e, gone = gone})
	append(&h.edits[1], Edit{entry = {v.key, row, e.val if h.by_key.width == .Byte else 0}, gone = gone})
}

@(private)
held_unread :: proc(h: ^Held, row: u32) {
	if h.kind == .Words {
		text_bury(h, row)
		return
	}
	for v in held_values(h, row) {
		held_edit(h, row, v, gone = true)
	}
}

// The text of a row, as it is known here.
@(private)
held_text :: proc(h: ^Held, row: u32) -> (text: u32, ok: bool) {
	e := tree_first(h.scope.x, h.by_row, {u64(row) << 32, 0}) or_return
	return e.sub, e.key.hi >> 32 == u64(row)
}

@(private)
held_text_hash :: proc(h: ^Held, row: u32) -> (text: u32, hash: u64, ok: bool) {
	e := tree_first(h.scope.x, h.by_row, {u64(row) << 32, 0}) or_return
	return e.sub, e.key.lo, e.key.hi >> 32 == u64(row)
}

Text_Entry :: struct {
	row:    u32,
	length: u32,
}

@(require_results)
text_entry :: proc(h: ^Held, text: u32) -> (t: Text_Entry, ok: bool) {
	v := array_get(h.scope.x, h.texts, text)
	return {u32(v) - 1, u32(v >> 32)}, v != 0
}

@(private)
text_bury :: proc(h: ^Held, row: u32) {
	text, hash, ok := held_text_hash(h, row)
	if !ok {
		return
	}
	t, _ := text_entry(h, text)
	append(&h.edits[0], Edit{entry = {{u64(row) << 32, hash}, text, 0}, gone = true})
	append(&h.edits[2], Edit{entry = {key = {u64(text), 0}}, gone = true})
	h.dead += 1
	h.alive -= 1
	h.length -= min(h.length, u64(t.length))
}

@(private)
words_read :: proc(h: ^Held, row: u32, r: ^Row, fresh: bool) {
	bytes: []byte
	have: bool
	if h.path == "" {
		bytes, have = row_slot(r, h.slot)
	} else if raw, there := row_slot(r, h.slot); there {
		all := make([dynamic]byte, context.temp_allocator)
		json_each(raw, h.path, proc(data: rawptr, kind: Json, raw: []byte, _: ^Column) {
			if kind == .String {
				all := (^[dynamic]byte)(data)
				append(all, ..json_unescape(raw))
				append(all, '\n')
			}
		}, &all, nil)
		bytes, have = all[:], len(all) > 0
	}
	hash := bytes_hash(bytes)
	if !fresh {
		if _, old, ok := held_text_hash(h, row); ok {
			if have && old == hash {
				return
			}
			text_bury(h, row)
		}
	}
	if !have {
		return
	}
	// Each word once, and how often.
	Seen :: struct {
		key:  Key,
		long: bool,
	}
	all := make([dynamic]Seen, context.temp_allocator)
	it := words(bytes)
	for w in words_next(&it) {
		w := w
		k, long := bytes_key(w.bytes[:w.len])
		append(&all, Seen{k, long})
	}
	if len(all) == 0 {
		return
	}
	slice.sort_by(all[:], proc(a, b: Seen) -> bool {return key_less(a.key, b.key)})
	text := h.next_text
	h.next_text += 1
	for i := 0; i < len(all); {
		j := i
		for j < len(all) && all[j].key == all[i].key {
			j += 1
		}
		append(&h.edits[1], Edit{entry = {all[i].key, text, u64(min(j - i, 255))}})
		if !fresh {
			if _, known := tree_get(h.scope.x, h.lexicon, all[i].key, 0); !known {
				append(&h.edits[3], Edit{entry = {key = all[i].key}})
			}
		} else {
			append(&h.edits[3], Edit{entry = {key = all[i].key}})
		}
		i = j
	}
	h.length += u64(len(all))
	append(&h.edits[0], Edit{entry = {{u64(row) << 32, hash}, text, 0}})
	append(&h.edits[2], Edit{entry = {{u64(text), u64(len(all)) << 32 | u64(row + 1)}, 0, 0}})
	h.alive += 1
}

@(private)
bytes_hash :: proc(s: []byte) -> u64 {
	h := zsp.sha256(s)
	return zsp.get_u64(h[:])
}

// ---------------------------------------------------------------- making edits

// Puts edits in order. Of several to one entry the last stands.
@(private)
edits_settle :: proc(edits: []Edit) -> []Edit {
	ordered := true
	for i in 1 ..< len(edits) {
		if !entry_less(edits[i - 1].key, edits[i - 1].sub, edits[i].key, edits[i].sub) {
			ordered = false
			break
		}
	}
	if ordered {
		return edits
	}
	edits_sort(edits)
	n := 0
	for e, i in edits {
		if i + 1 < len(edits) && edits[i + 1].key == e.key && edits[i + 1].sub == e.sub {
			continue
		}
		edits[n] = e
		n += 1
	}
	return edits[:n]
}

// Stable, and fast where much is in order already: runs are found, and merged two by two.
@(private)
edits_sort :: proc(edits: []Edit) {
	less :: #force_inline proc(a, b: ^Edit) -> bool {
		return entry_less(a.key, a.sub, b.key, b.sub)
	}
	SMALL :: 24
	n := len(edits)
	for at := 0; at < n; at += SMALL {
		run := edits[at:min(at + SMALL, n)]
		for i in 1 ..< len(run) {
			e := run[i]
			j := i
			for j > 0 && less(&e, &run[j - 1]) {
				run[j] = run[j - 1]
				j -= 1
			}
			run[j] = e
		}
	}
	// Not from the heap when it is much: that would be kept.
	arena: virtual.Arena
	mapped := n > 4096 && virtual.arena_init_static(&arena, uint(n + 64) * size_of(Edit), 1 << 16) == nil
	spare := make([]Edit, n, virtual.arena_allocator(&arena) if mapped else context.allocator)
	defer if mapped {
		virtual.arena_destroy(&arena)
	} else {
		delete(spare)
	}
	from, to := edits, spare
	for width := SMALL; width < n; width *= 2 {
		for at := 0; at < n; at += 2 * width {
			mid, end := min(at + width, n), min(at + 2 * width, n)
			if mid == end || !less(&from[mid], &from[mid - 1]) {
				copy(to[at:end], from[at:end])
				continue
			}
			a, b := at, mid
			for k in at ..< end {
				if b == end || (a < mid && !less(&from[b], &from[a])) {
					to[k] = from[a]
					a += 1
				} else {
					to[k] = from[b]
					b += 1
				}
			}
		}
		from, to = to, from
	}
	if raw_data(from) != raw_data(edits) {
		copy(edits, from)
	}
}

@(private)
edits_make :: proc(x: ^Index, t: ^Tree, edits: ^[dynamic]Edit) {
	all := edits_settle(edits[:])
	for at := 0; at < len(all); at += 1024 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		tree_apply(x, t, all[at:min(at + 1024, len(all))])
		index_relieve(x)
	}
	clear(edits)
}

@(private)
texts_make :: proc(h: ^Held) {
	for e in h.edits[2] {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		array_set(h.scope.x, &h.texts, u32(e.key.hi), 0 if e.gone else e.key.lo)
	}
	clear(&h.edits[2])
}

@(private)
held_flush :: proc(h: ^Held) {
	for t, i in held_trees(h) {
		if i != 2 {
			edits_make(h.scope.x, t, &h.edits[i])
		}
	}
	texts_make(h)
	if h.dead > 4096 && h.dead > h.alive {
		words_renew(h)
	}
	index_relieve(h.scope.x)
}

// Reads every text again, leaving out the words of those that are gone.
@(private)
words_renew :: proc(h: ^Held) {
	{
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		held_clear(h)
	}
	h.next_text, h.length, h.dead, h.alive, h.built = 0, 0, 0, 0, false
	held_fill(h)
}

@(private)
scope_flush :: proc(s: ^Scope) {
	edits_make(s.x, &s.ids, &s.edits[0])
	edits_make(s.x, &s.rows, &s.edits[1])
	for h in s.columns {
		held_flush(h)
	}
	index_relieve(s.x)
}

// Lets go of pages made and not yet written, when there are many. They are written where nothing committed
// points, so it does not matter what becomes of them.
@(private)
index_relieve :: proc(x: ^Index) {
	if len(x.dirty) > 2 * CACHE {
		pager_write(x)
	}
}

// ---------------------------------------------------------------- following the store

// Brings the index level with the store. Costs nothing when nothing has happened.
index_follow :: proc(x: ^Index) {
	n := x.n
	if len(x.scopes) == 0 {
		// Nothing is kept, so there is nothing to bring up.
		x.upto, x.serial = zsp.store_tail(&n.store), n.roster.serial
		x.cursor, x.tailing = n.events.next, true
		return
	}
	if x.serial != n.roster.serial {
		index_check(x)
		x.serial = n.roster.serial
	}
	if x.tailing && x.cursor == n.events.next {
		return
	}
	Dirty :: struct {
		x:    ^Index,
		rows: map[zsp.Id]Slots,
	}
	d := Dirty{x = x}
	defer delete(d.rows)
	flush :: proc(d: ^Dirty) {
		for id, slots in d.rows {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			slots := slots
			if s := index_scope(d.x, zsp.row_scope(id)); s != nil {
				row_reread(s, id, &slots)
			}
		}
		clear(&d.rows)
		for s in d.x.scopes {
			scope_flush(s)
		}
		for w in d.x.watchers {
			w.done(w.data)
		}
	}
	tail := zsp.store_tail(&n.store)
	if x.tailing && x.cursor >= n.events.first {
		for i in x.cursor ..< n.events.next {
			c := zsp.ring_at(&n.events, i)
			slots := d.rows[c.row]
			slots_add(&slots, c.slot)
			d.rows[c.row] = slots
		}
	} else {
		// More than is remembered: what the log says, in pieces.
		zsp.store_flush(&n.store)
		zsp.store_since(&n.store, x.upto, &d, proc(data: rawptr, c: ^zsp.Cell) {
			d := (^Dirty)(data)
			slots := d.rows[c.row]
			slots_add(&slots, c.slot)
			d.rows[c.row] = slots
			if len(d.rows) >= 1 << 14 {
				flush(d)
			}
		})
	}
	flush(&d)
	x.upto, x.cursor, x.tailing = tail, n.events.next, true
}

// Looks for rows the store no longer has without having said so, as when a roster made them unlawful.
@(private)
index_check :: proc(x: ^Index) {
	for s in x.scopes {
		gone: [dynamic]zsp.Id
		defer delete(gone)
		c := cursor_make(x, s.rows, context.allocator)
		defer cursor_destroy(&c)
		cursor_seek(&c, KEY_MIN)
		for e in cursor_next(&c) {
			append(&gone, zsp.Id{u64(s.id) << 32 | e.key.hi & 0xffff_ffff, e.key.lo})
		}
		every := EVERY_SLOT
		for id in gone {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			row_reread(s, id, &every)
			if len(s.edits[1]) > BATCH {
				scope_flush(s)
			}
		}
		scope_flush(s)
	}
}
