package zsp

import "base:runtime"
import "core:hash/xxhash"
import "core:slice"

// The store keeps every cell exactly once, sealed, in an append-only log, and indexes the log with
// three trees in one page file:
//
//   shelf   (list, order, row)   -> fingerprint of the row
//   cells   (row, slot, stamp)   -> where the cell's body lies in the log
//   waste   (segment)            -> dead bytes in that segment
//
// The log is the write-ahead log: a commit is one append. Trees live in memory pages until a
// checkpoint, so the cost of indexing a thousand commits is the cost of indexing them once.

SEGMENT :: #config(ZSP_SEGMENT, 16 << 20)
RECORD_HEAD :: 8
ROLLED :: 0xffff_ffff_7a73_7021 // where a record would begin, says that the segment ends with this
MAX_RECORD :: SEGMENT / 2
CHECKPOINT_TAIL :: SEGMENT / 4 // log bytes replayed at worst on open
CHECKPOINT_DIRTY :: 1024 // pages held in memory at worst
BUFFER_KEEP :: 64 << 10

Store :: struct {
	using pager: Pager,
	shelf:       Tree,
	cells:       Tree,
	waste:       Tree,
	outbox:      Tree, // rows a partial replica has yet to place in a full one
	partial:     bool,
	stale:       ^[dynamic]Id, // when set, collects rows whose offered cells were dominated
	clock:       u64, // highest stamp time seen
	generation:  u64,

	// The log tail. buf[0] lies at buf_base; bytes before `flushed` are written.
	buf:         [dynamic]byte,
	buf_base:    u64,
	flushed:     int,
	checkpoint:  u64, // replay starts here
	synced:      u64, // durable up to here
	serial:      u64, // of the roster this was last held against
	serial_kept: u64,
	failed:      bool,

	// Recent changes, for tailing. See events.odin.
	events:      Ring,
}

Header :: struct {
	magic:      [8]byte,
	generation: u64,
	log:        u64,
	clock:      u64,
	serial:     u64,
	shelf:      u32,
	cells:      u32,
	waste:      u32,
	outbox:     u32,
	next:       u32,
	sum:        u64,
}
MAGIC :: [8]byte{'z', 's', 'p', '-', 't', 'r', 'e', '1'}
HEADER_PAGES :: 2

// Where a cell's body lies. Packed into a tree value.
@(private)
Place :: struct {
	off: u64,
	len: int,
	kind: Kind,
}

@(private)
place_pack :: proc(p: Place) -> Print {
	return {p.off, u64(p.len) << 8 | u64(p.kind)}
}

@(private)
place_unpack :: proc(v: Print) -> Place {
	return {v[0], int(v[1] >> 8), Kind(v[1] & 0xff)}
}

// Within a slot, cells that kill others sort before pieces, so one seek finds them all.
@(private)
cell_key :: proc(row: Id, slot: Slot, kind: Kind, stamp: Stamp) -> Key {
	piece := u64(1) if kind == .Piece else 0
	return {row[0], row[1], u64(slot) << 8 | piece, stamp.time, stamp.salt}
}

@(private)
cell_unkey :: proc(l: Leaf) -> (c: Cell, at: Place) {
	at = place_unpack(l.val)
	c.row = {l.key[0], l.key[1]}
	c.slot = Slot(l.key[2] >> 8)
	c.kind = at.kind
	c.stamp = {l.key[3], l.key[4]}
	return
}

@(require_results)
cell_print :: proc(c: ^Cell) -> (p: Print) {
	b: [34]byte = ---
	put_u64(b[0:], c.row[0])
	put_u64(b[8:], c.row[1])
	b[16] = byte(c.slot)
	b[17] = byte(c.kind)
	put_u64(b[18:], c.stamp.time)
	put_u64(b[26:], c.stamp.salt)
	h := sha256(b[:])
	return {get_u64(h[0:]), get_u64(h[8:])}
}

@(require_results)
store_open :: proc(s: ^Store, disk: Disk, ring := 256) -> bool {
	s.disk = disk
	ring_init(&s.events, ring)

	best := store_header(disk)
	s.generation = best.generation
	s.clock = best.clock
	s.serial, s.serial_kept = best.serial, best.serial
	s.checkpoint = best.log
	s.shelf.root, s.cells.root = best.shelf, best.cells
	s.waste.root, s.outbox.root = best.waste, best.outbox
	s.next = max(best.next, HEADER_PAGES)
	find_free(s)
	return replay(s)
}

// Forgets everything not yet flushed. Call store_flush, or store_checkpoint, first.
store_close :: proc(s: ^Store) {
	for _, pg in s.dirty {
		free(pg)
	}
	delete(s.dirty)
	delete(s.free)
	delete(s.pending)
	delete(s.buf)
	ring_destroy(&s.events)
	s.disk.close(s.disk.data)
	s^ = {}
}

@(private)
store_header :: proc(disk: Disk) -> (best: Header) {
	for i in u32(0) ..< HEADER_PAGES {
		pg := disk.page(disk.data, i)
		if pg == nil {
			continue
		}
		h := (^Header)(pg)^
		if h.magic == MAGIC && h.sum == header_sum(&h) && h.generation >= best.generation {
			best = h
		}
	}
	return
}

// Every cell written to the log from an offset on, living or dead, some perhaps twice. Flush first.
store_since :: proc(s: ^Store, from: u64, data: rawptr, each: proc(data: rawptr, c: ^Cell)) {
	Both :: struct {
		data: rawptr,
		each: proc(data: rawptr, c: ^Cell),
	}
	b := Both{data, each}
	log_scan(s.disk, from, &b, proc(data: rawptr, _: u64, body: []byte) {
		b := (^Both)(data)
		r := Reader{buf = body}
		row: Id
		for r.pos < len(r.buf) {
			c := read_cell(&r, row) or_break
			row = c.row
			b.each(b.data, &c)
		}
	})
}

// The latest stamp time a store has seen, without opening it.
@(require_results)
store_clock :: proc(disk: Disk) -> u64 {
	h := store_header(disk)
	log_scan(disk, h.log, &h.clock, proc(data: rawptr, _: u64, body: []byte) {
		clock := (^u64)(data)
		r := Reader{buf = body}
		row: Id
		for r.pos < len(r.buf) {
			c := read_cell(&r, row) or_break
			row = c.row
			clock^ = max(clock^, c.stamp.time)
		}
	})
	return h.clock
}

@(private)
header_sum :: proc(h: ^Header) -> u64 {
	b := ([^]byte)(h)[:offset_of(Header, sum)]
	return xxhash.XXH64(b)
}

// Everything the roots do not reach is free. Only branches are read.
@(private)
find_free :: proc(s: ^Store) {
	used := make([]bool, s.next, context.temp_allocator)
	for i in 0 ..< HEADER_PAGES {
		used[i] = true
	}
	mark :: proc(s: ^Store, used: []bool, no: u32, level: int) {
		used[no] = true
		if level == 0 {
			return
		}
		pg := page(s, no)
		for &e in pg.branch[:pg.count] {
			mark(s, used, e.child, level - 1)
		}
	}
	for t in ([]Tree{s.shelf, s.cells, s.waste, s.outbox}) {
		if t.root != 0 {
			mark(s, used, t.root, int(page(s, t.root).level))
		}
	}
	#reverse for u, i in used {
		if !u {
			append(&s.free, u32(i))
		}
	}
}

// Applies every record past the checkpoint. A damaged one is stepped over, whatever was damaged in it;
// only what follows the last good record, and so is torn or nothing, is cut off.
@(private)
replay :: proc(s: ^Store) -> bool {
	s.buf_base = max(u64) // nothing is buffered yet
	tail := log_scan(s.disk, s.checkpoint, s, proc(data: rawptr, pos: u64, body: []byte) {
		replay_record((^Store)(data), pos, body)
	})
	if tail < s.disk.log_end(s.disk.data) {
		s.disk.log_truncate(s.disk.data, tail)
	}
	ring_clear(&s.events)
	s.buf_base = tail
	// What was only found there may be in the system's keeping rather than the disk's: whoever wrote it died.
	s.synced = s.checkpoint
	return true
}

// Finds every sound record from an offset on. Returns the end of the last.
@(private)
log_scan :: proc(disk: Disk, from: u64, data: rawptr, each: proc(data: rawptr, pos: u64, body: []byte)) -> (tail: u64) {
	end := disk.log_end(disk.data)
	tail = from
	for at := from; at < end; at = (at / SEGMENT + 1) * SEGMENT {
		size := min(end, (at / SEGMENT + 1) * SEGMENT) - at
		// Only the last segment is known to reach this far; others end where their records do.
		part := make([]byte, size)
		defer delete(part)
		for !disk.log_read(disk.data, at, part[:size]) {
			size = log_size(disk, at, size)
			if size == 0 {
				break
			}
		}
		for pos := 0; pos < int(size); {
			n := record_at(part[pos:size])
			if n == 0 {
				pos += 1
				continue
			}
			each(data, at + u64(pos), part[pos + RECORD_HEAD:][:n])
			pos += RECORD_HEAD + n
			tail = at + u64(pos)
		}
	}
	return
}

// The most that can be read from an offset, at most `size`.
@(private)
log_size :: proc(disk: Disk, at, size: u64) -> u64 {
	lo, hi := u64(0), size
	b: [1]byte
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if disk.log_read(disk.data, at + mid - 1, b[:]) {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// The size of the sound record that begins here, or zero.
@(private)
record_at :: proc(b: []byte) -> int {
	if len(b) <= RECORD_HEAD {
		return 0
	}
	n := int(get_u32(b))
	kind := b[RECORD_HEAD] // the first cell of a record always names its row
	if n == 0 || n > len(b) - RECORD_HEAD || kind < u8(min(Kind)) || kind > u8(max(Kind)) {
		return 0
	}
	return n if record_sum(b[RECORD_HEAD:][:n]) == get_u32(b[4:]) else 0
}

@(private)
replay_record :: proc(s: ^Store, pos: u64, body: []byte) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	r := Reader{buf = body}
	row: Id
	for r.pos < len(r.buf) {
		c := read_cell(&r, row) or_break
		row = c.row
		off := pos + RECORD_HEAD + u64(r.pos - len(c.body))
		if !apply(s, &c, off, 0, true) {
			waste_add(s, off, len(c.body))
		} else if s.partial {
			// Whether it was acknowledged is not recorded; offering it again is harmless.
			tree_put(s, &s.outbox, {c.row[0], c.row[1], 0, 0, 0}, {})
		}
	}
}

@(private)
record_sum :: proc(b: []byte) -> u32 {
	return u32(xxhash.XXH64(b))
}

@(require_results)
store_tail :: proc(s: ^Store) -> u64 {
	return s.buf_base + u64(len(s.buf))
}

// What a commit of these cells may come to. A caller passing on what it was sent must check.
@(require_results)
record_size :: proc(cells: []Cell) -> int {
	size := RECORD_HEAD
	for &c in cells {
		size += 48 + len(c.body)
	}
	return size
}

// Merges cells into the store and returns how many were news. The accepted ones become one atomic
// log record; stale ones cost nothing.
store_commit :: proc(s: ^Store, cells: []Cell, origin: u32 = 0) -> (accepted: int) {
	size := record_size(cells)
	assert(size <= MAX_RECORD)
	tail := store_tail(s)
	if tail % SEGMENT + u64(size) > SEGMENT {
		if !log_roll(s) {
			return 0
		}
	} else if len(s.buf) > BUFFER_KEEP && s.flushed == len(s.buf) {
		s.buf_base = tail
		clear(&s.buf)
		s.flushed = 0
	}

	start := len(s.buf)
	append(&s.buf, 0, 0, 0, 0, 0, 0, 0, 0)
	row: Id
	for &c in cells {
		at := len(s.buf)
		write_cell(&s.buf, &c, accepted > 0 && c.row == row)
		off := s.buf_base + u64(len(s.buf) - len(c.body))
		if apply(s, &c, off, origin, false) {
			accepted += 1
			row = c.row
		} else {
			resize(&s.buf, at)
		}
	}
	if accepted == 0 {
		resize(&s.buf, start)
		return
	}
	body := s.buf[start + RECORD_HEAD:]
	put_u32(s.buf[start:], u32(len(body)))
	put_u32(s.buf[start + 4:], record_sum(body))
	return
}

// Merges one cell into the trees. This is the whole CRDT.
@(private)
apply :: proc(s: ^Store, c: ^Cell, off: u64, origin: u32, replaying: bool) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	key := cell_key(c.row, c.slot, c.kind, c.stamp)
	if old, ok := tree_get(s, s.cells, key); ok {
		// Replay meets a cell again when a crash followed its evacuation from an old segment.
		if replaying {
			at := place_unpack(old)
			if at.off < off {
				waste_add(s, at.off, at.len)
				tree_put(s, &s.cells, key, place_pack({off, len(c.body), c.kind}))
				return true
			}
		}
		return false
	}
	if grave, ok := row_grave(s, c.row); ok && (c.kind != .Grave || !stamp_less(grave, c.stamp)) {
		stale_add(s, c.row)
		return false
	}

	if slot_refuses(s, c.row, c.slot, c.kind, c.stamp) {
		stale_add(s, c.row)
		return false
	}
	dead := make([dynamic]Leaf, context.temp_allocator)
	switch c.kind {
	case .Piece:
	case .Bundle:
		for i in 0 ..< int(get_u32(c.body)) {
			for kind in ([]Kind{.Piece, .Bundle}) {
				k := cell_key(c.row, c.slot, kind, bundle_at(c.body, i))
				if v, ok := tree_get(s, s.cells, k); ok && place_unpack(v).kind == kind {
					append(&dead, Leaf{k, v})
				}
			}
		}
	case .Grave, .Place, .Value:
		hi := Key{c.row[0], c.row[1], (u64(c.slot) + 1) << 8, 0, 0}
		if c.kind == .Grave {
			hi[2] = max(u64)
		}
		scan := tree_scan(s, s.cells, {c.row[0], c.row[1], u64(c.slot) << 8, 0, 0}, hi)
		for leaf in tree_next(&scan) {
			old, _ := cell_unkey(leaf)
			if c.kind == .Grave || stamp_less(old.stamp, c.stamp) {
				append(&dead, leaf)
			}
		}
	}

	before := row_places(s, c.row)
	print, shelved := Print{}, false
	if before.count > 0 {
		print, shelved = tree_get(s, s.shelf, before.keys[0])
	}
	if !shelved {
		print = row_print(s, c.row)
	}

	for leaf in dead {
		old, at := cell_unkey(leaf)
		print -= cell_print(&old)
		tree_delete(s, &s.cells, leaf.key)
		waste_add(s, at.off, at.len)
	}
	s.clock = max(s.clock, c.stamp.time)
	print += cell_print(c)
	tree_put(s, &s.cells, key, place_pack({off, len(c.body), c.kind}))

	after := before
	#partial switch c.kind {
	case .Grave:
		after = {count = 1}
		after.keys[0] = place_key(graveyard(row_scope(c.row)), c.stamp.time, c.row)
	case .Place:
		// The one placement that changed, recomputed from its own clear bytes.
		after = row_places(s, c.row)
	}
	for k in before.keys[:before.count] {
		if !slice.contains(after.keys[:after.count], k) {
			tree_delete(s, &s.shelf, k)
		}
	}
	for k in after.keys[:after.count] {
		tree_put(s, &s.shelf, k, print)
	}
	if !replaying {
		// Cells that arrived ahead of their row's first placement were invisible until now, and
		// whoever sent the placement may not have them.
		origin := origin
		if before.count == 0 && print != cell_print(c) {
			origin = 0
		}
		ring_push(&s.events, {c.row, c.slot, c.kind, c.stamp, origin}, &before, &after)
	}
	return true
}

@(private)
stale_add :: proc(s: ^Store, row: Id) {
	if s.stale != nil {
		append(s.stale, row)
	}
}

// Whether a cell would be accepted, judged from its identity alone.
@(require_results)
store_news :: proc(s: ^Store, row: Id, slot: Slot, kind: Kind, stamp: Stamp) -> bool {
	if _, ok := tree_get(s, s.cells, cell_key(row, slot, kind, stamp)); ok {
		return false
	}
	if grave, ok := row_grave(s, row); ok && (kind != .Grave || !stamp_less(grave, stamp)) {
		return false
	}
	return !slot_refuses(s, row, slot, kind, stamp)
}

// Whether what a slot holds has already killed a stamp.
@(private)
slot_refuses :: proc(s: ^Store, row: Id, slot: Slot, kind: Kind, stamp: Stamp) -> bool {
	scan := tree_scan(s, s.cells, {row[0], row[1], u64(slot) << 8, 0, 0}, {row[0], row[1], u64(slot) << 8 | 1, 0, 0})
	for leaf in tree_next(&scan) {
		c, at := cell_unkey(leaf)
		if c.kind == .Bundle {
			if kind != .Piece && kind != .Bundle {
				continue // a bundle absorbs nothing else, whenever it comes
			}
			head := log_bytes(s, at.off, 4)
			if head == nil {
				continue
			}
			c.body = log_bytes(s, at.off, clear_size(.Bundle, head))
			if c.body != nil && bundle_has(c.body, stamp) {
				return true
			}
		} else if !stamp_less(cell_floor(&c), stamp) {
			return true
		}
	}
	return false
}

Places :: struct {
	keys:  [MAX_PLACES]Key, // distinct
	count: int,
}

// Where the row is shelved.
@(require_results)
row_places :: proc(s: ^Store, row: Id) -> (p: Places) {
	if grave, ok := row_grave(s, row); ok {
		p.keys[0] = place_key(graveyard(row_scope(row)), grave.time, row)
		p.count = 1
		return
	}
	scan := tree_scan(s, s.cells, {row[0], row[1], u64(PLACE) << 8, 0, 0}, {row[0], row[1], u64(DATA) << 8, 0, 0})
	for leaf in tree_next(&scan) {
		c, at := cell_unkey(leaf)
		c.body = log_bytes(s, at.off, 24)
		if len(c.body) < 24 {
			continue
		}
		k := place_key(cell_list(&c), cell_order(&c), row)
		if !slice.contains(p.keys[:p.count], k) {
			p.keys[p.count] = k
			p.count += 1
		}
	}
	return
}

@(require_results)
row_grave :: proc(s: ^Store, row: Id) -> (stamp: Stamp, ok: bool) {
	scan := tree_scan(s, s.cells, {row[0], row[1], 0, 0, 0}, {row[0], row[1], u64(PLACE) << 8, 0, 0})
	leaf := tree_next(&scan) or_return
	return {leaf.key[3], leaf.key[4]}, true
}

@(private)
row_print :: proc(s: ^Store, row: Id) -> (p: Print) {
	scan := row_scan(s, row)
	for leaf in tree_next(&scan) {
		c, _ := cell_unkey(leaf)
		p += cell_print(&c)
	}
	return
}

// Walks a row's live cells without reading their bodies.
@(require_results)
row_scan :: proc(s: ^Store, row: Id, lo := GRAVE, hi := Slot(255)) -> Cursor {
	return tree_scan(
		s,
		s.cells,
		{row[0], row[1], u64(lo) << 8, 0, 0},
		{row[0], row[1], (u64(hi) + 1) << 8, 0, 0},
	)
}

// The next cell of a row_scan. The body is temporary memory.
@(require_results)
row_next :: proc(s: ^Store, scan: ^Cursor) -> (c: Cell, ok: bool) {
	leaf := tree_next(scan) or_return
	at: Place
	c, at = cell_unkey(leaf)
	c.body = log_bytes(s, at.off, at.len)
	return c, true
}

// One live cell by identity.
@(require_results)
store_cell :: proc(s: ^Store, row: Id, slot: Slot, kind: Kind, stamp: Stamp) -> (c: Cell, ok: bool) {
	v := tree_get(s, s.cells, cell_key(row, slot, kind, stamp)) or_return
	at := place_unpack(v)
	return {row, slot, kind, stamp, log_bytes(s, at.off, at.len)}, true
}

// Bytes of the log, from the tail buffer when they are recent. Valid until the next commit or
// temporary free.
@(private)
log_bytes :: proc(s: ^Store, off: u64, n: int) -> []byte {
	if off >= s.buf_base {
		return s.buf[off - s.buf_base:][:n]
	}
	b := make([]byte, n, context.temp_allocator)
	if !s.disk.log_read(s.disk.data, off, b) {
		s.failed = true
		return nil
	}
	return b
}

@(private)
waste_add :: proc(s: ^Store, off: u64, n: int) {
	k := Key{0, 0, 0, 0, off / SEGMENT}
	v, _ := tree_get(s, s.waste, k)
	tree_put(s, &s.waste, k, v + {u64(n + 36), 0})
}

// Goes on in a fresh segment, having marked where this one ends, so that it can be told from one cut short.
@(private)
log_roll :: proc(s: ^Store) -> bool {
	tail := store_tail(s)
	if SEGMENT - tail % SEGMENT >= RECORD_HEAD {
		mark: [RECORD_HEAD]byte
		put_u64(mark[:], ROLLED)
		append(&s.buf, ..mark[:])
	}
	store_flush(s) or_return
	s.buf_base = (tail / SEGMENT + 1) * SEGMENT
	clear(&s.buf)
	s.flushed = 0
	return true
}

// Hands buffered records to the disk. Cheap; call once per burst of work.
store_flush :: proc(s: ^Store) -> bool {
	if s.flushed < len(s.buf) {
		if !s.disk.log_write(s.disk.data, s.buf_base + u64(s.flushed), s.buf[s.flushed:]) {
			s.failed = true
			return false
		}
		s.flushed = len(s.buf)
	}
	return true
}

@(require_results)
store_unsynced :: proc(s: ^Store) -> bool {
	return s.synced != store_tail(s)
}

// Makes every commit so far durable.
store_sync :: proc(s: ^Store) -> bool {
	store_flush(s) or_return
	if s.synced != store_tail(s) {
		if !s.disk.log_sync(s.disk.data) {
			s.failed = true
			return false
		}
		s.synced = store_tail(s)
	}
	return true
}

@(require_results)
store_wants_checkpoint :: proc(s: ^Store) -> bool {
	return store_tail(s) - s.checkpoint > CHECKPOINT_TAIL || len(s.dirty) > CHECKPOINT_DIRTY
}

// Writes the trees, so that the log before this point need never be replayed.
store_checkpoint :: proc(s: ^Store) -> bool {
	if s.checkpoint == store_tail(s) && len(s.dirty) == 0 && s.serial == s.serial_kept {
		return true
	}
	victims := evacuate(s)
	store_sync(s) or_return
	if s.failed {
		return false
	}

	nos := slice.map_keys(s.dirty, context.temp_allocator) or_else nil
	slice.sort(nos)
	for no in nos {
		pg := s.dirty[no]
		if !s.disk.page_write(s.disk.data, no, ([^]byte)(pg)[:size_of(Page)]) {
			s.failed = true
			return false
		}
	}
	h := Header {
		magic      = MAGIC,
		generation = s.generation + 1,
		log        = store_tail(s),
		clock      = s.clock,
		serial     = s.serial,
		shelf      = s.shelf.root,
		cells      = s.cells.root,
		waste      = s.waste.root,
		outbox     = s.outbox.root,
		next       = s.next,
	}
	h.sum = header_sum(&h)
	block: [512]byte
	copy(block[:], ([^]byte)(&h)[:size_of(h)])
	ok := s.disk.page_sync(s.disk.data)
	ok = ok && s.disk.page_write(s.disk.data, u32(h.generation % HEADER_PAGES), block[:])
	ok = ok && s.disk.page_sync(s.disk.data)
	if !ok {
		s.failed = true
		return false
	}

	s.generation = h.generation
	s.checkpoint, s.serial_kept = h.log, h.serial
	for no in nos {
		free(s.dirty[no])
	}
	clear(&s.dirty)
	append(&s.free, ..s.pending[:])
	clear(&s.pending)
	for seg in victims {
		// Forgotten only now: after a crash before this point the segment is simply evacuated again.
		s.disk.log_drop(s.disk.data, seg)
		tree_delete(s, &s.waste, {0, 0, 0, 0, seg})
	}
	return true
}

// Copies the living out of the most wasteful segment, if any is at least half dead.
@(private)
evacuate :: proc(s: ^Store) -> []u64 {
	victims := make([dynamic]u64, context.temp_allocator)
	scan := tree_scan(s, s.waste, KEY_MIN, KEY_MAX)
	worst: u64
	for leaf in tree_next(&scan) {
		seg := leaf.key[4]
		if leaf.val[0] >= SEGMENT / 2 && seg != store_tail(s) / SEGMENT && leaf.val[0] > worst {
			worst = leaf.val[0]
			clear(&victims)
			append(&victims, seg)
		}
	}
	if len(victims) == 0 {
		return nil
	}
	seg := victims[0]
	base := seg * SEGMENT
	size := log_size(s.disk, base, SEGMENT)
	part := make([]byte, size)
	defer delete(part)
	if size > 0 && !s.disk.log_read(s.disk.data, base, part) {
		s.failed = true
		return nil
	}
	pos, whole := 0, false
	for pos < len(part) {
		n := record_at(part[pos:])
		if n == 0 {
			whole = len(part) - pos == RECORD_HEAD && get_u64(part[pos:]) == ROLLED
			break
		}
		if !relocate(s, base + u64(pos + RECORD_HEAD), part[pos + RECORD_HEAD:][:n]) {
			return nil
		}
		pos += RECORD_HEAD + n
	}
	if !whole && pos < SEGMENT - RECORD_HEAD {
		// Some of it is damaged, or missing. The rest may lie past the damage.
		for pos < len(part) {
			n := record_at(part[pos:])
			if n == 0 {
				pos += 1
				continue
			}
			if !relocate(s, base + u64(pos + RECORD_HEAD), part[pos + RECORD_HEAD:][:n]) {
				return nil
			}
			pos += RECORD_HEAD + n
		}
		// What was not found is gone from here. Not holding it is better than holding it unread: a replica that
		// does not have a cell is sent it again.
		lost := make([dynamic]Leaf, context.temp_allocator)
		all := tree_scan(s, s.cells, KEY_MIN, KEY_MAX)
		for leaf in tree_next(&all) {
			if place_unpack(leaf.val).off / SEGMENT == seg {
				append(&lost, leaf)
			}
		}
		forget(s, lost[:])
	}
	return victims[:]
}

// Unholds cells, as though they had never come. Where they lay is not read: it may be unreadable.
@(private)
forget :: proc(s: ^Store, lost: []Leaf) {
	if len(lost) == 0 {
		return
	}
	rows := make(map[Id]bool, context.temp_allocator) // to whether its places are in doubt
	doubt := false
	for leaf in lost {
		c, at := cell_unkey(leaf)
		tree_delete(s, &s.cells, leaf.key)
		waste_add(s, at.off, at.len)
		shelved := c.kind == .Place || c.kind == .Grave
		rows[c.row] = rows[c.row] || shelved
		doubt ||= shelved
	}
	if doubt {
		old := make([dynamic]Key, context.temp_allocator)
		scan := tree_scan(s, s.shelf, KEY_MIN, KEY_MAX)
		for entry in tree_next(&scan) {
			if rows[key_row(entry.key)] {
				append(&old, entry.key)
			}
		}
		for k in old {
			tree_delete(s, &s.shelf, k)
		}
	}
	for row in rows {
		places, print := row_places(s, row), row_print(s, row)
		for k in places.keys[:places.count] {
			tree_put(s, &s.shelf, k, print)
		}
	}
}

// Puts another body in place of a held cell's, its identity unchanged. False when the log cannot take it.
@(private)
store_replace :: proc(s: ^Store, c: ^Cell) -> bool {
	key := cell_key(c.row, c.slot, c.kind, c.stamp)
	old := tree_get(s, s.cells, key) or_return
	tail := store_tail(s)
	if tail % SEGMENT + u64(record_size({c^})) > SEGMENT {
		log_roll(s) or_return
	}
	start := len(s.buf)
	append(&s.buf, 0, 0, 0, 0, 0, 0, 0, 0)
	write_cell(&s.buf, c, false)
	out := s.buf[start + RECORD_HEAD:]
	put_u32(s.buf[start:], u32(len(out)))
	put_u32(s.buf[start + 4:], record_sum(out))
	at := place_unpack(old)
	waste_add(s, at.off, at.len)
	tree_put(s, &s.cells, key, place_pack({s.buf_base + u64(len(s.buf) - len(c.body)), len(c.body), c.kind}))
	return true
}

@(private)
relocate :: proc(s: ^Store, base: u64, body: []byte) -> bool {
	tail := store_tail(s)
	if tail % SEGMENT + u64(len(body) * 2 + RECORD_HEAD) > SEGMENT {
		log_roll(s) or_return
	}
	start := len(s.buf)
	append(&s.buf, 0, 0, 0, 0, 0, 0, 0, 0)
	r := Reader{buf = body}
	row, wrote: Id
	for r.pos < len(r.buf) {
		c := read_cell(&r, row) or_break
		row = c.row
		key := cell_key(c.row, c.slot, c.kind, c.stamp)
		v := tree_get(s, s.cells, key) or_continue
		if place_unpack(v).off != base + u64(r.pos - len(c.body)) {
			continue
		}
		write_cell(&s.buf, &c, wrote == c.row)
		wrote = c.row
		off := s.buf_base + u64(len(s.buf) - len(c.body))
		tree_put(s, &s.cells, key, place_pack({off, len(c.body), c.kind}))
	}
	if len(s.buf) == start + RECORD_HEAD {
		resize(&s.buf, start)
		return true
	}
	out := s.buf[start + RECORD_HEAD:]
	put_u32(s.buf[start:], u32(len(out)))
	put_u32(s.buf[start + 4:], record_sum(out))
	return true
}

// Rows currently shelved in lo <= key < hi.
@(require_results)
store_range :: proc(s: ^Store, lo, hi: Key) -> Sum {
	return tree_range(s, s.shelf, lo, hi)
}
