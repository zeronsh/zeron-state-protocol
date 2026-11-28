package zsp

import "base:runtime"
import "core:hash/xxhash"
import "core:slice"
import "core:sync"

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
	outbox:      Tree, // rows of this replica's own writing that no full replica is yet known to hold
	repair:      Tree, // rows whose shelf entries are to be sought out, where storage may answer "not yet"
	used:        Tree, // of a partial replica: each list it holds rows of, to when it was last watched: see retain.odin
	own:         bool, // its clients write here, and the outbox is kept
	unmarked:    bool, // a record was replayed that its clients did not write, or that says nothing of whose it is
	whole:       bool, // the outbox names all that this replica wrote and no full one is known to hold
	whole_kept:  bool, // as the last checkpoint says
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
	forgot:      u64, // cells ever forgotten, of which nothing is said in the log
	failed:      bool,

	// Recent changes, for tailing. See events.odin.
	events:      Ring,

	// Where reads may answer "not yet", the log past the checkpoint is replayed a record at a time: see lazy.odin.
	replaying:   bool,
	step_missed: int, // reads that missed before the step under way began
	remote:      ^Remote, // where it is kept in object storage: see remote.odin
	more:        bool, // work was left off for want of room, not of anything fetched: call node_retry again soon
	replay_at:   u64, // the next record, or where to look for it
	replay_tail: u64, // the end of the last sound record
	repair_at:   Key, // how far over the shelf repair_steps has gone
	repair_added: [dynamic]Id, // rows to be repaired that came along since it began
	evac:        Evacuation, // where storage may answer "not yet", of a segment, a step at a time
	evacuated:   [dynamic]u64, // whose living have all been moved, to be dropped at the next checkpoint
	dropped:     [dynamic]u64, // dropped, and their waste yet to be forgotten

	flight:      Flight,
}

// What the disk is making durable while the store goes on, where it can (Disk.log_sync_start): so that a host's loop
// is not held while it does. Nothing is counted on until the disk has said it is done: `synced`, and with it every
// acknowledgement, moves only then, and only as far as the log reached when that sync was begun.
Flight :: struct {
	log:        u64, // the token of the log sync under way, or 0
	log_upto:   u64, // the log's end when it was begun: what it makes durable
	again:      bool, // more was written since it began, and is to be made durable once it is done
	// A checkpoint under way: see store_checkpoint_start.
	step:       enum u8 {
		None,
		Durable, // its pages written, and waiting for them and the log as far as point.log to be durable
		Header, // its header written, and waiting for that to be durable
	},
	pages:      u64, // the token of the page sync under way, or 0
	point:      Header, // what its header says
	point_tail: Header_Tail,
	reuse:      [dynamic]Page_No, // given up by the trees it names, but not the last's: reusable once it is durable
	victims:    [dynamic]u64, // segments it evacuated, to be dropped once it is durable
}

// What may change in copies while a checkpoint is under way, at most: more, and a commit waits for it to be done.
FLIGHT_DIRTY :: 2 * CHECKPOINT_DIRTY

// Tokens for what is under way, never the same twice in a process, whichever store asks: so that what comes back for
// a store that is gone, or for a sync that was overtaken, is known for that and passed over.
@(private)
flight_tokens: u64 // atomic

@(private)
flight_token :: proc() -> u64 {
	return sync.atomic_add(&flight_tokens, 1) + 1
}

Header :: struct {
	magic:      [8]byte,
	generation: u64,
	log:        u64,
	clock:      u64,
	serial:     u64,
	forgot:     u64,
	shelf:      Page_No,
	cells:      Page_No,
	waste:      Page_No,
	outbox:     Page_No,
	repair:     Page_No,
	next:       Page_No,
	sum:        u64,
}
MAGIC :: [8]byte{'z', 's', 'p', '-', 't', 'r', 'e', '3'} // a store of another is made again from its log
HEADER_PAGES :: 2

// After the header, in its block, and so written with it: what a store that is a device's, rather than a relay's, has
// come to keep since. One written before there was any is all zeroes, which its sum never is, and is read as nothing.
// (The header itself is also written into a relay's manifests, and so stays as it was.)
Header_Tail :: struct {
	flags: Tail_Flags,
	used:  Page_No,
	sum:   u64,
}
Tail_Flags :: bit_field u64 {
	whole: bool | 1, // the outbox is whole: see Store.whole
	_:     u64  | 63,
}

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

	best, tail := store_header(disk)
	s.generation = best.generation
	s.clock = best.clock
	s.serial, s.serial_kept = best.serial, best.serial
	s.forgot = best.forgot
	s.checkpoint = best.log
	s.shelf.root, s.cells.root = best.shelf, best.cells
	s.waste.root, s.outbox.root = best.waste, best.outbox
	s.repair.root = best.repair
	s.used.root = tail.used
	s.whole, s.whole_kept = tail.flags.whole, tail.flags.whole
	s.next = max(best.next, HEADER_PAGES)
	if s.remote != nil {
		s.next = TEMP_PAGES // pages are numbered for where they go only at a checkpoint
	}
	if store_lazy(s) {
		// Nothing may be read here that might not be at hand: what is free is never sought, and the log is
		// replayed by store_work, a record at a time, before anything else is done.
		s.buf_base = max(u64)
		s.replaying = true
		s.replay_at, s.replay_tail = s.checkpoint, s.checkpoint
		return true
	}
	find_free(s)
	replay(s) or_return
	if best.generation == 0 && s.own && !s.unmarked {
		// Never written down, and all that was written here, if anything, its own clients wrote and its outbox names: it
		// can have missed nothing.
		s.whole = true
	}
	return true
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
	delete(s.repair_added)
	delete(s.evacuated)
	delete(s.dropped)
	delete(s.flight.reuse)
	delete(s.flight.victims)
	delete(s.fresh)
	delete(s.retired)
	ring_destroy(&s.events)
	s.disk.close(s.disk.data)
	s^ = {}
}

@(private)
store_header :: proc(disk: Disk) -> (best: Header, tail: Header_Tail) {
	for i in Page_No(0) ..< HEADER_PAGES {
		pg := disk.page(disk.data, i)
		if pg == nil {
			continue
		}
		h := (^Header)(pg)^
		if h.magic == MAGIC && h.sum == header_sum(&h) && h.generation >= best.generation {
			best = h
			tail = (^Header_Tail)(rawptr(uintptr(pg) + size_of(Header)))^
			if tail.sum != tail_sum(&best, &tail) {
				tail = {}
			}
		}
	}
	return
}

// Every cell written to the log from an offset on, living or dead, some perhaps twice, for about so many bytes.
// Returns where to go on from. Flush first.
store_since :: proc(s: ^Store, from: u64, budget: int, data: rawptr, each: proc(data: rawptr, c: ^Cell)) -> u64 {
	WINDOW :: 1 << 20
	end := store_tail(s)
	at := from
	for at < end && at - from < u64(budget) {
		limit := min(end, (at / SEGMENT + 1) * SEGMENT)
		size := min(limit - at, WINDOW)
		for {
			got := size
			part := make([]byte, size)
			defer delete(part)
			if !s.disk.log_read(s.disk.data, at, part) {
				got = log_size(s.disk, at, size)
				if got > 0 && !s.disk.log_read(s.disk.data, at, part[:got]) {
					got = 0
				}
			}
			pos := 0
			for pos < int(got) {
				n := record_at(part[pos:got])
				if n == 0 {
					break
				}
				r := Reader{buf = part[pos + RECORD_HEAD:][:n]}
				row: Id
				for r.pos < len(r.buf) {
					c := read_cell(&r, row) or_break
					row = c.row
					each(data, &c)
				}
				pos += RECORD_HEAD + n
			}
			if pos > 0 {
				at += u64(pos)
				break
			}
			if got == size && size < limit - at {
				size = limit - at // a record that does not fit
				continue
			}
			// No record begins here: where one next does, or else in the next segment.
			next := limit
			for p in 1 ..< int(got) {
				if record_at(part[p:got]) > 0 {
					next = at + u64(p)
					break
				}
			}
			at = next
			break
		}
	}
	return min(at, end)
}

// The latest stamp time a store has seen, without opening it.
@(require_results)
store_clock :: proc(disk: Disk) -> u64 {
	h, _ := store_header(disk)
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

// Of the tail and the header it follows, so that it is never taken for another's; and never zero.
@(private)
tail_sum :: proc(h: ^Header, t: ^Header_Tail) -> u64 {
	b: [offset_of(Header_Tail, sum) + 8]byte
	copy(b[:], ([^]byte)(t)[:offset_of(Header_Tail, sum)])
	put_u64(b[offset_of(Header_Tail, sum):], h.sum)
	return xxhash.XXH64(b[:]) | 1
}

// Everything the roots do not reach is free. Only branches are read.
@(private)
find_free :: proc(s: ^Store) {
	used := make([]bool, s.next, context.temp_allocator)
	for i in 0 ..< HEADER_PAGES {
		used[i] = true
	}
	mark :: proc(s: ^Store, used: []bool, no: Page_No, level: int) {
		used[no] = true
		if level == 0 {
			return
		}
		pg := page(s, no)
		for &e in pg.branch[:pg.count] {
			mark(s, used, e.child, level - 1)
		}
	}
	for t in ([]Tree{s.shelf, s.cells, s.waste, s.outbox, s.repair, s.used}) {
		if t.root != 0 {
			mark(s, used, t.root, int(page(s, t.root).level))
		}
	}
	#reverse for u, i in used {
		if !u {
			append(&s.free, Page_No(i))
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
	// Compared as it is, unsigned: where int is 32 bits, as in WebAssembly, a length of 2^31 or more is negative.
	size := get_u32(b)
	kind := b[RECORD_HEAD] // the first cell of a record always names its row
	if size == 0 || u64(size) > u64(len(b) - RECORD_HEAD) || kind < u8(min(Kind)) || kind > u8(max(Kind)) {
		return 0
	}
	n := int(size)
	return n if record_sum(b[RECORD_HEAD:][:n]) == get_u32(b[4:]) else 0
}

// What a store's own clients wrote ends its record with this, where a cell would begin, as none can: so it is known again
// when the log is replayed after a crash, which is when the outbox may have lost what it had of it. Whatever reads a
// record without knowing of it stops there, as it would at anything that is not a cell, having read every cell before.
OWN_MARK :: u8(0)

@(private)
replay_record :: proc(s: ^Store, pos: u64, body: []byte) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	r := Reader{buf = body}
	row: Id
	applied := make([dynamic]Id, context.temp_allocator)
	own := false
	for r.pos < len(r.buf) {
		if r.pos == len(r.buf) - 1 && r.buf[r.pos] == OWN_MARK {
			own = true
			break
		}
		c := read_cell(&r, row) or_break
		row = c.row
		off := pos + RECORD_HEAD + u64(r.pos - len(c.body))
		if !apply(s, &c, off, 0, true) {
			waste_add(s, off, len(c.body))
		} else {
			append(&applied, c.row)
		}
	}
	s.unmarked ||= !own
	if own && s.own {
		// Its clients wrote it, after the outbox was last written down: whether a full replica has acknowledged it since
		// is not known, and so it is offered again. What came from peers is held as anything is, and may be let go of.
		for id in applied {
			tree_put(s, &s.outbox, {id[0], id[1], 0, 0, 0}, {})
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
	size := RECORD_HEAD + 1 // and, perhaps, OWN_MARK
	for &c in cells {
		size += 48 + len(c.body)
	}
	return size
}

// Merges cells into the store and returns how many were news. The accepted ones become one atomic
// log record; stale ones cost nothing.
store_commit :: proc(s: ^Store, cells: []Cell, origin: u32 = 0, own := false) -> (accepted: int) {
	if s.flight.step != .None && len(s.dirty) > FLIGHT_DIRTY {
		// What changed while a checkpoint is under way has come to as much as may be held: this waits for it.
		if !flight_land(s) {
			return 0
		}
	}
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
	if own {
		append(&s.buf, OWN_MARK)
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
		if step_doubtful(s) {
			// Not yet at hand, or asked for by something that was: zeroes stand in, and the step is undone.
			return b
		}
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

// Begins making every commit so far durable, where the disk can without waiting (Disk.log_sync_start); else makes it
// so now, as store_sync does. One is under way at a time: what is written meanwhile waits for the next, which begins
// as soon as that one is done. False if the store has failed.
store_sync_start :: proc(s: ^Store) -> bool {
	if s.disk.log_sync_start == nil || store_lazy(s) || s.remote != nil {
		return store_sync(s)
	}
	store_flush(s) or_return
	f := &s.flight
	switch {
	case s.failed:
		return false
	case s.synced == store_tail(s):
	case f.log != 0:
		f.again ||= f.log_upto != store_tail(s)
	case:
		f.log, f.log_upto, f.again = flight_token(), store_tail(s), false
		if !s.disk.log_sync_start(s.disk.data, f.log) {
			f.log = 0
			s.failed = true
			return false
		}
	}
	return true
}

// What the disk said of what it was making durable, by the token it was given. What the store no longer waits for is
// passed over. False if the store has failed.
store_disk_synced :: proc(s: ^Store, token: u64, ok: bool) -> bool {
	f := &s.flight
	switch {
	case token == 0:
		return !s.failed
	case token == f.log:
		f.log = 0
		if !ok {
			s.failed = true // and nothing it was to make durable is said to be
			return false
		}
		s.synced = max(s.synced, f.log_upto)
		if f.again {
			store_sync_start(s) or_return
		}
	case token == f.pages:
		f.pages = 0
		if !ok {
			s.failed = true
			return false
		}
	case:
		return !s.failed
	}
	return flight_advance(s)
}

// Whether the disk is making something durable for a store: what a store_disk_synced with this token would be heard.
@(require_results)
store_awaits :: proc(s: ^Store, token: u64) -> bool {
	return token != 0 && (token == s.flight.log || token == s.flight.pages)
}

// Whether the store is waiting for the disk.
@(require_results)
store_flying :: proc(s: ^Store) -> bool {
	return s.flight.log != 0 || s.flight.step != .None
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
	return store_tail(s) - s.checkpoint > CHECKPOINT_TAIL || len(s.dirty) > CHECKPOINT_DIRTY || s.serial != s.serial_kept || s.whole != s.whole_kept
}

// Writes the trees, so that the log before this point need never be replayed. A checkpoint under way without waiting
// (store_checkpoint_start) is finished first, waiting for it.
store_checkpoint :: proc(s: ^Store) -> bool {
	if s.remote != nil {
		// Made a step at a time, and put in object storage whenever it is: see remote_work.
		s.remote.want_checkpoint = true
		return !s.failed
	}
	flight_land(s) or_return
	if s.replaying || !checkpoint_wanted(s) {
		return true
	}
	// Where storage may answer "not yet", evacuation is a job of its own (evac_steps), done before.
	victims := s.evacuated[:] if store_lazy(s) else evacuate(s)
	store_sync(s) or_return
	if s.failed {
		return false
	}
	point_write(s, victims) or_return
	if !s.disk.page_sync(s.disk.data) || !point_header(s) || !s.disk.page_sync(s.disk.data) {
		s.failed = true
		return false
	}
	point_done(s)
	return true
}

// The same, where the disk can make what is written durable without the store waiting (Disk.log_sync_start and
// page_sync_start): the pages are written now, and the checkpoint goes on as the disk says each sync is done
// (store_disk_synced). Until it is done, the last one stands: whatever is changed meanwhile is changed in copies, for
// the next. One is under way at a time; else it is store_checkpoint. False if the store has failed.
//
// What the disk is asked, in order, each step only once the one before is durable:
//
//   1. the dirty pages, written to numbers the last durable checkpoint does not use; and the log, made durable as
//      far as the trees reach (its end now);
//   2. the header, naming those trees and that end, in the slot the last durable header is not in;
//   3. only then are the pages that checkpoint no longer uses reused, and segments it evacuated dropped.
//
// Power lost anywhere before 2 is durable leaves the last header standing, and everything it names, with the log it
// replays from: 1 wrote nothing it names, and dropped nothing. A header torn by it does not sum, and the other is read.
store_checkpoint_start :: proc(s: ^Store) -> bool {
	if s.disk.log_sync_start == nil || s.disk.page_sync_start == nil || s.remote != nil || store_lazy(s) {
		return store_checkpoint(s)
	}
	if s.flight.step != .None || s.replaying || !checkpoint_wanted(s) {
		return !s.failed
	}
	victims := evacuate(s)
	store_flush(s) or_return
	if s.failed {
		return false
	}
	point_write(s, victims) or_return
	f := &s.flight
	f.step = .Durable
	f.pages = flight_token()
	if !s.disk.page_sync_start(s.disk.data, f.pages) {
		f.pages = 0
		s.failed = true
		return false
	}
	store_sync_start(s) or_return // the log as far as the trees reach, or the next sync if one is under way already
	return flight_advance(s)
}

@(private)
checkpoint_wanted :: proc(s: ^Store) -> bool {
	return s.checkpoint != store_tail(s) || len(s.dirty) != 0 || s.serial != s.serial_kept || s.whole != s.whole_kept
}

// Writes the dirty pages, and holds what the header that names them will say: from now on the trees are changed in
// copies. The log must be flushed.
@(private)
point_write :: proc(s: ^Store, victims: []u64) -> bool {
	f := &s.flight
	nos := slice.map_keys(s.dirty, context.temp_allocator) or_else nil
	slice.sort(nos)
	for no in nos {
		pg := s.dirty[no]
		if !s.disk.page_write(s.disk.data, no, ([^]byte)(pg)[:size_of(Page)]) {
			s.failed = true
			return false
		}
	}
	f.point = Header {
		magic      = MAGIC,
		generation = s.generation + 1,
		log        = store_tail(s),
		clock      = s.clock,
		serial     = s.serial,
		forgot     = s.forgot,
		shelf      = s.shelf.root,
		cells      = s.cells.root,
		waste      = s.waste.root,
		outbox     = s.outbox.root,
		repair     = s.repair.root,
		next       = s.next,
	}
	f.point.sum = header_sum(&f.point)
	f.point_tail = Header_Tail{flags = {whole = s.whole}, used = s.used.root}
	f.point_tail.sum = tail_sum(&f.point, &f.point_tail)
	// Written, they are read from the disk from now on, and a change to one is made in a copy under another number: as
	// to any page the last durable checkpoint names. Those it no longer uses are reused only once this one is durable.
	for no in nos {
		free(s.dirty[no])
	}
	clear(&s.dirty)
	append(&f.reuse, ..s.pending[:])
	clear(&s.pending)
	clear(&f.victims)
	append(&f.victims, ..victims)
	return true
}

// Writes the header of the checkpoint under way, once all it names is durable.
@(private)
point_header :: proc(s: ^Store) -> bool {
	f := &s.flight
	block: [512]byte
	copy(block[:], ([^]byte)(&f.point)[:size_of(Header)])
	copy(block[size_of(Header):], ([^]byte)(&f.point_tail)[:size_of(Header_Tail)])
	return s.disk.page_write(s.disk.data, Page_No(f.point.generation % HEADER_PAGES), block[:])
}

// The checkpoint under way is durable, header and all: the store counts on it from now on.
@(private)
point_done :: proc(s: ^Store) {
	f := &s.flight
	s.generation = f.point.generation
	s.checkpoint, s.serial_kept = f.point.log, f.point.serial
	s.whole_kept = f.point_tail.flags.whole
	s.synced = max(s.synced, f.point.log) // as it was made durable before the header was written
	append(&s.free, ..f.reuse[:])
	clear(&f.reuse)
	for seg in f.victims {
		// Forgotten only now: after a crash before this point the segment is simply evacuated again.
		s.disk.log_drop(s.disk.data, seg)
		if store_lazy(s) {
			append(&s.dropped, seg) // and its waste is forgotten in a step: see store_work
		} else {
			tree_delete(s, &s.waste, {0, 0, 0, 0, seg})
		}
	}
	clear(&f.victims)
	clear(&s.evacuated)
	f.step = .None
}

// Takes the checkpoint under way a step further, as far as what the disk has said lets it.
@(private)
flight_advance :: proc(s: ^Store) -> bool {
	f := &s.flight
	if s.failed {
		return false
	}
	switch f.step {
	case .None:
	case .Durable:
		if f.pages != 0 || s.synced < f.point.log {
			break
		}
		if !point_header(s) {
			s.failed = true
			return false
		}
		f.step = .Header
		f.pages = flight_token()
		if !s.disk.page_sync_start(s.disk.data, f.pages) {
			f.pages = 0
			s.failed = true
			return false
		}
	case .Header:
		if f.pages == 0 {
			point_done(s)
		}
	}
	return true
}

// Finishes the checkpoint under way, if any, waiting for each sync it still wants: as when another is to be made at
// once, or what has changed since it began has come to more than may be held. What the disk then says of the syncs
// under way is passed over.
@(private)
flight_land :: proc(s: ^Store) -> bool {
	f := &s.flight
	switch f.step {
	case .None:
		return !s.failed
	case .Durable:
		f.pages = 0
		if !store_sync(s) || !s.disk.page_sync(s.disk.data) || !point_header(s) || !s.disk.page_sync(s.disk.data) {
			s.failed = true
			return false
		}
	case .Header:
		f.pages = 0
		if !s.disk.page_sync(s.disk.data) {
			s.failed = true
			return false
		}
	}
	point_done(s)
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

// Loses rows, as when where their cells lay cannot be read: to see what is made of that.
store_lose :: proc(s: ^Store, rows: []Id) {
	lost := make([dynamic]Leaf, context.temp_allocator)
	for row in rows {
		scan := tree_scan(s, s.cells, {row[0], row[1], 0, 0, 0}, {row[0], row[1], max(u64), max(u64), max(u64)})
		for leaf in tree_next(&scan) {
			append(&lost, leaf)
		}
	}
	forget(s, lost[:])
}

// Unholds cells, as though they had never come. Unless `read`, where they lay is not read: it may be unreadable.
@(private)
forget :: proc(s: ^Store, lost: []Leaf, read := false) {
	if len(lost) == 0 {
		return
	}
	s.forgot += u64(len(lost))
	rows := make(map[Id]bool, context.temp_allocator) // to whether its places are in doubt
	doubt := false
	for leaf in lost {
		c, _ := cell_unkey(leaf)
		shelved := c.kind == .Place || c.kind == .Grave
		rows[c.row] = rows[c.row] || shelved
		doubt ||= shelved
	}
	// Where they can be read, a row's places are those it is shelved at, and are unshelved by name.
	was := make(map[Id]Places, context.temp_allocator)
	if read && doubt {
		for row, shelved in rows {
			if shelved {
				was[row] = row_places(s, row)
			}
		}
	}
	for leaf in lost {
		_, at := cell_unkey(leaf)
		tree_delete(s, &s.cells, leaf.key)
		waste_add(s, at.off, at.len)
	}
	if read {
		for _, &places in was {
			for k in places.keys[:places.count] {
				tree_delete(s, &s.shelf, k)
			}
		}
	} else if doubt && store_lazy(s) {
		// Every entry of the row must be sought, and the shelf may be more than can be had at once: see repair_steps.
		for row, shelved in rows {
			if shelved {
				tree_put(s, &s.repair, {row[0], row[1], 0, 0, 0}, {})
				append(&s.repair_added, row)
			}
		}
	} else if doubt {
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
