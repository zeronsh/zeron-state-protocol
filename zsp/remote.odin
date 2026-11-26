package zsp

import "base:runtime"
import "core:hash/xxhash"
import "core:slice"

// A store in object storage, with the host's own storage as its cache: how a relay keeps a space that has no size.
//
// The log is written to the host's own storage, as any store's is, and is durable there. Once a stretch of it (an
// extent) is whole and durable it is put in object storage, and once the checkpoint is past it too, the host lets
// its own copy go. The trees are copy-on-write: at a checkpoint every changed page is put in object storage in one
// object, a pack, under numbers that say where it is (a page's number is its pack's generation << 20 | its slot),
// and no page is ever written twice. A small manifest in the host's own storage names the roots. A pack whose pages
// are all superseded is deleted; one that is mostly superseded has the rest copied on, by touching them, so that
// it soon is. Nothing is ever listed, and nothing is ever overwritten.
//
// Reads of what is not at hand answer "not yet" (see lazy.odin): the pages and stretches of log they wanted are
// fetched, several at a time and with their neighbours, and whatever waited for them is done again. The host's own
// storage keeps recently used pages and stretches too, so that a host woken from sleep has them at once.
//
// The host is a Remote_Host: synchronous calls on its own storage, and operations on object storage that it starts
// and answers with remote_done whenever they finish, in any order. Nothing is ever waited for.

PACK_SHIFT :: 20 // a pack holds at most 2^20 pages
TEMP_PAGES :: Page_No(1) << 62 // numbers for pages not yet in any pack
EXTENT :: #config(ZSP_EXTENT, min(SEGMENT / 4, 1 << 20)) // the log is put in object storage in pieces of this size
#assert(SEGMENT % EXTENT == 0 && EXTENT % LOG_BLOCK == 0)
LOG_BLOCK :: min(64 << 10, EXTENT) // a read of the log fetches at least this much
PAGE_RUN :: 16 // a read of a page fetches its neighbours in the pack too
HINT_SIZE :: 48
PACK_MAGIC :: 0x7a73_7070_6163_6b31 // "zsppack1", ending a pack
MANIFEST_MAGIC :: [8]byte{'z', 's', 'p', '-', 'm', 'a', 'n', '1'}
CHECKPOINT_HARD :: 4 * CHECKPOINT_DIRTY // changed pages past which writing waits for the checkpoint under way
REDELETE_AFTER :: #config(ZSP_REDELETE_AFTER, 60 * 60 * 1000) // milliseconds after which what was deleted is deleted again

Remote_Op_Kind :: enum u8 {
	Get_Pages, // number: pack; off, len: bytes of it
	Get_Log, // number: extent; off, len: bytes of it
	Get_Hints, // number: pack; off, len: its hints and what ends it
	Put_Pack, // number: pack; body
	Put_Extent, // number: extent; off, len: the log's bytes to put, from the host's own storage
	Delete, // objects
}

Remote_Object :: struct {
	number: u64,
	pack:   b64, // else an extent; as wide as the number, so that nothing lies between them
}

Remote_Op :: struct {
	id:      u32,
	kind:    Remote_Op_Kind,
	number:  u64,
	off:     u64,
	len:     u64,
	body:    []byte, // owned by the Remote
	objects: []Remote_Object, // owned by the Remote
}

Cached :: enum u8 {
	Page, // keyed by page number; a run of a pack's pages under the first
	Log, // keyed by offset
}

Remote_Host :: struct {
	data:           rawptr,
	// The host's own storage, synchronous. The log there holds what is not yet in object storage, or is past the
	// checkpoint; writes are durable once log_sync has said so.
	log_write:      proc(data: rawptr, off: u64, bytes: []byte) -> bool,
	log_read:       proc(data: rawptr, off: u64, into: []byte) -> bool,
	log_end:        proc(data: rawptr) -> u64,
	log_cut:        proc(data: rawptr, lo, hi: u64), // forget lo <= offset < hi
	log_sync:       proc(data: rawptr) -> bool,
	manifest_read:  proc(data: rawptr) -> []byte, // temporary memory; nil if there is none
	manifest_write: proc(data: rawptr, bytes: []byte) -> bool, // durable when it returns
	// A cache in it, which may keep what it is given or not, and let it go whenever it likes.
	cache_get:      proc(data: rawptr, kind: Cached, key: u64, into: []byte) -> bool, // all of into, or nothing
	cache_put:      proc(data: rawptr, kind: Cached, key: u64, bytes: []byte),
	cache_drop:     proc(data: rawptr, kind: Cached, lo, hi: u64),
	// Object storage, asynchronous: answered by remote_done, whenever, in any order.
	start:          proc(data: rawptr, op: ^Remote_Op),
	now:            proc(data: rawptr) -> u64, // milliseconds
}

// What it cost, for whoever measures.
Remote_Stats :: struct {
	gets, puts, deletes:       int, // operations started on object storage
	got, put:                  u64, // bytes
	checkpoints, extents:      int,
	fetched_pages, local_hits: int,
	relocated:                 int, // pages copied on out of packs mostly superseded
}

Redelete :: struct {
	object: Remote_Object,
	at:     u64, // milliseconds
}

@(private)
Cached_Page :: struct {
	pg:   ^Page,
	used: u64,
}

@(private)
Log_Block :: struct {
	bytes: []byte, // shorter than LOG_BLOCK where the object ends
	used:  u64,
}

@(private)
Inflight :: struct {
	op:        u32,
	gen:       u64,
	header:    Header,
	packs:     Page_No, // its root
	accounted: int, // of pending
	dead:      int, // of dead
	victims:   []u64, // segments dropped once it is durable
	deletes:   [dynamic]Remote_Object,
}

@(private)
Pack_GC :: struct {
	gen:     u64, // the pack being emptied, if any
	total:   u64, // its pages
	active:  bool,
	hints:   []byte, // owned
	slot:    int,
	asked:   bool,
}

Remote :: struct {
	host:          Remote_Host,
	store:         ^Store,
	missed:        int,
	unguarded:     int, // reads that missed outside any step: each a fault, and the store fails
	stats:         Remote_Stats,

	// As the manifest says.
	header:        Header,
	header_page:   Page,
	next_gen:      u64,
	uploaded:      u64, // the log before this is in object storage, or in segments dropped
	local_from:    u64, // the host's own storage holds the log from here on
	packs:         Tree, // generation -> {live pages, pages}
	packs_kept:    Page_No, // its root, as the manifest says
	kept_gen:      u64, // the latest pack the manifest names; those after it, before next_gen, were never made durable
	deletes:       [dynamic]Remote_Object, // named in the manifest until deleted
	// What was deleted is deleted again an hour later, as is what was put and never named: a put under way when a host
	// died may yet land, and the hour is longer than any put lives.
	redelete:      [dynamic]Redelete,

	// At hand.
	pages:         map[Page_No]Cached_Page,
	blocks:        map[u64]Log_Block,
	tick:          u64,
	rested:        u64, // the tick at the last rest
	page_budget:   int,
	block_budget:  int,

	// Being fetched, and wanted.
	next_op:       u32,
	ops:           map[u32]^Remote_Op,
	want_pages:    map[Page_No]struct{},
	want_blocks:   map[u64]struct{},
	getting_pages: map[u64]u32, // a run's first page -> op
	getting_blocks: map[u64]u32, // a block -> op
	ready:         [dynamic]^Remote_Op, // started by remote_ops

	// The checkpoint under way, if any, and the bookkeeping that precedes one.
	inflight:      Maybe(Inflight),
	flushing:      map[Page_No]^Page, // its pages, under their numbers
	want_checkpoint: bool,
	accounted:     int, // of the store's pending
	dead:          [dynamic]u64, // packs all superseded
	entry:         bool, // the next pack's entry is in packs

	uploading:     u32, // the op putting an extent
	upload_to:     u64, // where uploaded will be once it is done
	gc:            Pack_GC,
	gc_after:      u64, // no pack is chosen to be emptied until the one after this is durable
}

// Opens the remote side: what the manifest says, before store_open.
remote_open :: proc(r: ^Remote, host: Remote_Host, page_budget := 4096, block_budget := 256) -> bool {
	r.host = host
	r.page_budget, r.block_budget = page_budget, block_budget
	r.next_gen = 1
	if bytes := host.manifest_read(host.data); bytes != nil {
		remote_manifest_read(r, bytes) or_return
	}
	// Pages of a pack never made durable may have been cached by nobody, but are let go of all the same; and the pack,
	// should it have been put, is deleted, now and again a while later.
	host.cache_drop(host.data, .Page, (r.kept_gen + 1) << PACK_SHIFT, max(u64))
	for g in r.kept_gen + 1 ..< r.next_gen {
		append(&r.deletes, Remote_Object{g, true})
		remote_redelete(r, {g, true})
	}
	// What was being deleted is deleted.
	if len(r.deletes) > 0 {
		remote_delete(r, r.deletes[:])
	}
	return true
}

remote_close :: proc(r: ^Remote) {
	for _, c in r.pages {
		free(c.pg)
	}
	for _, b in r.blocks {
		delete(b.bytes)
	}
	for _, pg in r.flushing {
		free(pg)
	}
	for _, op in r.ops {
		remote_op_free(op)
	}
	if f, ok := r.inflight.?; ok {
		delete(f.victims)
		delete(f.deletes)
	}
	delete(r.pages)
	delete(r.blocks)
	delete(r.flushing)
	delete(r.ops)
	delete(r.want_pages)
	delete(r.want_blocks)
	delete(r.getting_pages)
	delete(r.getting_blocks)
	delete(r.ready)
	delete(r.deletes)
	delete(r.redelete)
	delete(r.dead)
	delete(r.gc.hints)
	r^ = {}
}

@(private)
remote_op_free :: proc(op: ^Remote_Op) {
	delete(op.body)
	delete(op.objects)
	free(op)
}

// The store's disk, which store_open is given. Set store.remote to the Remote first.
remote_disk :: proc(r: ^Remote) -> Disk {
	return {
		data = r,
		log_write = proc(data: rawptr, off: u64, bytes: []byte) -> bool {
			r := (^Remote)(data)
			return r.host.log_write(r.host.data, off, bytes)
		},
		log_read = remote_log_read,
		log_end = proc(data: rawptr) -> u64 {
			r := (^Remote)(data)
			return max(r.host.log_end(r.host.data), r.local_from)
		},
		log_drop = proc(data: rawptr, segment: u64) {
			unreachable() // the remote checkpoint drops what it drops itself
		},
		log_truncate = proc(data: rawptr, off: u64) {
			r := (^Remote)(data)
			assert(off >= r.local_from)
			r.host.log_cut(r.host.data, off, max(u64))
		},
		log_sync = proc(data: rawptr) -> bool {
			r := (^Remote)(data)
			return r.host.log_sync(r.host.data)
		},
		page = remote_page,
		page_write = proc(data: rawptr, no: Page_No, bytes: []byte) -> bool {
			return false // the remote checkpoint writes what it writes itself
		},
		page_sync = proc(data: rawptr) -> bool {return false},
		close = proc(data: rawptr) {},
		missed = proc(data: rawptr) -> int {
			return (^Remote)(data).missed
		},
	}
}

@(private)
remote_miss :: proc(r: ^Remote) {
	r.missed += 1
	if r.store != nil && !r.store.pager.step {
		// Whatever read this would believe what stood in for it. Better to stop than to believe it.
		r.unguarded += 1
		r.store.failed = true
	}
}

// ---------------------------------------------------------------- pages

@(private)
remote_page :: proc(data: rawptr, no: Page_No) -> ^Page {
	r := (^Remote)(data)
	if no < HEADER_PAGES {
		return &r.header_page
	}
	if pg, ok := r.flushing[no]; ok {
		return pg
	}
	r.tick += 1
	if c, ok := &r.pages[no]; ok {
		c.used = r.tick
		return c.pg
	}
	pg := new(Page)
	if r.host.cache_get(r.host.data, .Page, no, ([^]byte)(pg)[:size_of(Page)]) && page_sound(pg, no) {
		r.pages[no] = {pg, r.tick}
		r.stats.local_hits += 1
		return pg
	}
	free(pg)
	r.want_pages[no] = {}
	remote_miss(r)
	return &EMPTY_PAGE
}

// Whether a page read back is the one that was written under that number.
@(private)
page_sound :: proc(pg: ^Page, no: Page_No) -> bool {
	if pg.number != no {
		return false
	}
	check := pg.check
	pg.check = 0
	sum := xxhash.XXH32(([^]byte)(pg)[:size_of(Page)])
	pg.check = check
	return sum == check
}

@(private)
page_seal :: proc(pg: ^Page, no: Page_No) {
	pg.number = no
	pg.check = 0
	pg.check = xxhash.XXH32(([^]byte)(pg)[:size_of(Page)])
}

// ---------------------------------------------------------------- the log

@(private)
remote_log_read :: proc(data: rawptr, off: u64, into: []byte) -> bool {
	r := (^Remote)(data)
	if len(into) == 0 {
		return true
	}
	end := off + u64(len(into))
	if off >= r.local_from {
		return r.host.log_read(r.host.data, off, into)
	}
	ok, missing := true, false
	if end > r.local_from && !r.host.log_read(r.host.data, r.local_from, into[r.local_from - off:]) {
		ok = false
	}
	for at := off; at < min(end, r.local_from); {
		b := at / LOG_BLOCK * LOG_BLOCK
		upto := min(end, r.local_from, b + LOG_BLOCK)
		block, have := remote_block(r, b)
		if !have {
			missing = true
		} else if u64(len(block)) < upto - b {
			ok = false // the object ends before: there is nothing there
		} else {
			copy(into[at - off:], block[at - b:upto - b])
		}
		at = upto
	}
	if missing {
		remote_miss(r)
		return false
	}
	return ok
}

@(private)
remote_block :: proc(r: ^Remote, b: u64) -> (bytes: []byte, ok: bool) {
	r.tick += 1
	if c, have := &r.blocks[b]; have {
		c.used = r.tick
		return c.bytes, true
	}
	// The host's own cache holds whole blocks only.
	buf := make([]byte, LOG_BLOCK)
	if r.host.cache_get(r.host.data, .Log, b, buf) {
		r.blocks[b] = {buf, r.tick}
		r.stats.local_hits += 1
		return buf, true
	}
	delete(buf)
	r.want_blocks[b] = {}
	return nil, false
}

// ---------------------------------------------------------------- fetching

// Starts fetching what steps have wanted, a run at a time, and whatever else is due: call after every burst.
remote_ops :: proc(r: ^Remote) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if len(r.want_pages) > 0 {
		runs := make([dynamic]u64, context.temp_allocator)
		for no in r.want_pages {
			first := no &~ (PAGE_RUN - 1) // the run it is in, of its pack
			if first not_in r.getting_pages && !slice.contains(runs[:], first) {
				append(&runs, first)
			}
		}
		clear(&r.want_pages)
		slice.sort(runs[:])
		for i := 0; i < len(runs); {
			// Adjacent runs of one pack, one read.
			j := i + 1
			for j < len(runs) && runs[j] == runs[j - 1] + PAGE_RUN && runs[j] >> PACK_SHIFT == runs[i] >> PACK_SHIFT && j - i < 32 {
				j += 1
			}
			first := runs[i]
			op := remote_op(r, .Get_Pages)
			op.number = first >> PACK_SHIFT
			op.off = (first & (1 << PACK_SHIFT - 1)) * PAGE_SIZE
			op.len = u64(j - i) * PAGE_RUN * PAGE_SIZE
			for k in i ..< j {
				r.getting_pages[runs[k]] = op.id
			}
			remote_start(r, op)
			i = j
		}
	}
	if len(r.want_blocks) > 0 {
		blocks := make([dynamic]u64, context.temp_allocator)
		for b in r.want_blocks {
			if b not_in r.getting_blocks {
				append(&blocks, b)
			}
		}
		clear(&r.want_blocks)
		slice.sort(blocks[:])
		for i := 0; i < len(blocks); {
			j := i + 1
			for j < len(blocks) && blocks[j] == blocks[j - 1] + LOG_BLOCK && blocks[j] / EXTENT == blocks[i] / EXTENT {
				j += 1
			}
			op := remote_op(r, .Get_Log)
			op.number = blocks[i] / EXTENT
			op.off = blocks[i] % EXTENT
			op.len = u64(j - i) * LOG_BLOCK
			for k in i ..< j {
				r.getting_blocks[blocks[k]] = op.id
			}
			remote_start(r, op)
			i = j
		}
	}
}

@(private)
remote_op :: proc(r: ^Remote, kind: Remote_Op_Kind) -> ^Remote_Op {
	r.next_op += 1
	if r.next_op == 0 {
		r.next_op = 1
	}
	op := new(Remote_Op)
	op.id, op.kind = r.next_op, kind
	r.ops[op.id] = op
	return op
}

@(private)
remote_start :: proc(r: ^Remote, op: ^Remote_Op) {
	switch op.kind {
	case .Get_Pages, .Get_Log, .Get_Hints:
		r.stats.gets += 1
	case .Put_Pack, .Put_Extent:
		r.stats.puts += 1
	case .Delete:
		r.stats.deletes += 1
	}
	r.host.start(r.host.data, op)
}

// An operation has finished. For a get, `bytes` is what was there (shorter where the object ends, nothing where
// there is none, which `absent` says); `ok` is false for a failure worth trying again.
remote_done :: proc(r: ^Remote, id: u32, ok: bool, absent := false, bytes: []byte = nil) {
	op, known := r.ops[id]
	if !known {
		return
	}
	delete_key(&r.ops, id)
	defer remote_op_free(op)
	s := r.store
	switch op.kind {
	case .Get_Pages:
		first := op.number << PACK_SHIFT | op.off / PAGE_SIZE
		for i in 0 ..< op.len / PAGE_SIZE / PAGE_RUN {
			delete_key(&r.getting_pages, first + i * PAGE_RUN)
		}
		if !ok {
			return // asked for again by whoever still wants it
		}
		got := 0
		for at := 0; at + PAGE_SIZE <= len(bytes); at += PAGE_SIZE {
			no := first + u64(at / PAGE_SIZE)
			if no in r.pages || no in r.flushing {
				continue
			}
			pg := new(Page)
			copy(([^]byte)(pg)[:size_of(Page)], bytes[at:])
			if !page_sound(pg, no) {
				free(pg) // past the last page, or not a page at all
				continue
			}
			r.tick += 1
			r.pages[no] = {pg, r.tick}
			got += 1
		}
		r.stats.fetched_pages += got
		r.stats.got += u64(len(bytes))
		if got > 0 {
			r.host.cache_put(r.host.data, .Page, first, bytes[:got * PAGE_SIZE])
		} else if absent && s != nil && !remote_deleted(r, {op.number, true}) {
			// A page that is named and not there: the store cannot be read. (Of a pack deleted since it was asked for,
			// it is no longer named: whatever asked for it will ask for something else.)
			s.failed = true
		}
	case .Get_Log:
		first := op.number * EXTENT + op.off
		for i in 0 ..< op.len / LOG_BLOCK {
			delete_key(&r.getting_blocks, first + i * LOG_BLOCK)
		}
		if !ok {
			return
		}
		r.stats.got += u64(len(bytes))
		for i in 0 ..< op.len / LOG_BLOCK {
			b := first + i * LOG_BLOCK
			lo := min(int(i * LOG_BLOCK), len(bytes))
			hi := min(lo + LOG_BLOCK, len(bytes))
			if b in r.blocks {
				continue
			}
			r.tick += 1
			r.blocks[b] = {slice.clone(bytes[lo:hi]), r.tick}
			if hi - lo == LOG_BLOCK {
				r.host.cache_put(r.host.data, .Log, b, bytes[lo:hi])
			}
		}
	case .Get_Hints:
		g := &r.gc
		if !g.active || g.gen != op.number || g.hints != nil {
			return
		}
		g.asked = false
		r.stats.got += u64(len(bytes))
		n := (len(bytes) - 16) / HINT_SIZE
		if ok && len(bytes) >= 16 && get_u64(bytes[len(bytes) - 8:]) == PACK_MAGIC && get_u64(bytes[len(bytes) - 16:]) == u64(n) && (len(bytes) - 16) % HINT_SIZE == 0 {
			g.hints = slice.clone(bytes[:n * HINT_SIZE])
		} else if !ok {
			return // asked again
		} else {
			g^ = {} // not what it should be: let it be
		}
	case .Put_Pack:
		if f, flying := r.inflight.?; flying && f.op == id {
			if ok {
				remote_commit(r)
			} else {
				// Again, under the same name: nothing names it yet.
				again := remote_op(r, .Put_Pack)
				again.number = op.number
				again.body, op.body = op.body, nil
				f.op = again.id
				r.inflight = f
				remote_start(r, again)
			}
		}
	case .Put_Extent:
		if r.uploading == id {
			r.uploading = 0
			if ok {
				r.uploaded = r.upload_to
				r.stats.extents += 1
			}
		}
	case .Delete:
		if !ok {
			remote_delete(r, op.objects)
			return
		}
		for o in op.objects {
			for d, i in r.deletes {
				if d == o {
					unordered_remove(&r.deletes, i)
					break
				}
			}
		}
	}
}

@(private)
remote_delete :: proc(r: ^Remote, objects: []Remote_Object) {
	for i := 0; i < len(objects); i += 1000 {
		op := remote_op(r, .Delete)
		op.objects = slice.clone(objects[i:min(i + 1000, len(objects))])
		remote_start(r, op)
	}
}

// ---------------------------------------------------------------- work

// Everything due that is not a fetch: checkpoints, extents, deletes, emptying packs. Returns whether some of it
// waits for what is being fetched. Call after the store's own work, outside any step.
remote_work :: proc(r: ^Remote) -> (waiting: bool) {
	s := r.store
	if s.failed {
		return false
	}
	if s.replaying {
		// A long replay, as of a store made again from a whole log, is checkpointed as it goes, where it has got to.
		if r.inflight == nil && len(s.dirty) > CHECKPOINT_DIRTY {
			if remote_account_steps(r) {
				return true
			}
			remote_begin(r)
		}
		return false
	}
	if r.inflight == nil && (r.want_checkpoint || store_wants_checkpoint(s) || len(r.dead) > 0) {
		if !store_sync(s) {
			return false
		}
		if remote_account_steps(r) {
			return true
		}
		remote_begin(r)
		r.want_checkpoint = false
	}
	remote_upload(r)
	remote_redeletes(r)
	if remote_gc_steps(r) {
		waiting = true
	}
	return
}

// Whether writing should wait: so much has changed while a checkpoint was under way that memory would run short.
@(require_results)
remote_full :: proc(r: ^Remote) -> bool {
	return r != nil && len(r.store.dirty) > CHECKPOINT_HARD
}

// Lets go of what is least lately used, past the budget. Call between bursts, never within a step. What was used
// or fetched since the last rest is kept whatever the budget: a step waiting for something reads again, each time it
// is tried, all it read before, and letting that go would have it wait forever.
remote_rest :: proc(r: ^Remote) {
	Use :: struct {
		key:  u64,
		used: u64,
	}
	by_use :: proc(a, b: Use) -> bool {return a.used < b.used}
	if len(r.pages) > r.page_budget {
		order := make([dynamic]Use, 0, len(r.pages), context.temp_allocator)
		for no, c in r.pages {
			if c.used < r.rested {
				append(&order, Use{no, c.used})
			}
		}
		slice.sort_by(order[:], by_use)
		for o in order[:min(len(order), len(r.pages) - r.page_budget * 3 / 4)] {
			free(r.pages[o.key].pg)
			delete_key(&r.pages, o.key)
		}
	}
	if len(r.blocks) > r.block_budget {
		order := make([dynamic]Use, 0, len(r.blocks), context.temp_allocator)
		for b, c in r.blocks {
			if c.used < r.rested {
				append(&order, Use{b, c.used})
			}
		}
		slice.sort_by(order[:], by_use)
		for o in order[:min(len(order), len(r.blocks) - r.block_budget * 3 / 4)] {
			delete(r.blocks[o.key].bytes)
			delete_key(&r.blocks, o.key)
		}
	}
	r.rested = r.tick
}

// ---------------------------------------------------------------- checkpoints

// The bookkeeping a checkpoint needs first, in steps: every page given up since the last counts against its pack,
// and the next pack has its entry.
@(private)
remote_account_steps :: proc(r: ^Remote) -> (waiting: bool) {
	s := r.store
	for r.accounted < len(s.pending) || !r.entry {
		accounted, dead, entry := r.accounted, len(r.dead), r.entry
		t := store_begin(s)
		remote_account(r)
		if store_missed(s, &t) {
			store_end(s, &t, false)
			r.accounted, r.entry = accounted, entry
			resize(&r.dead, dead)
			return true
		}
		store_end(s, &t, true)
	}
	return false
}

@(private)
remote_account :: proc(r: ^Remote) {
	s := r.store
	for r.accounted < len(s.pending) {
		no := s.pending[r.accounted]
		r.accounted += 1
		key := Key{0, 0, 0, 0, no >> PACK_SHIFT}
		v, ok := tree_get(s, r.packs, key)
		if !ok {
			if !step_doubtful(s) {
				s.failed = true // a page of no pack: the books do not balance
			}
			return
		}
		v[0] -= 1
		if v[0] == 0 {
			tree_delete(s, &r.packs, key)
			append(&r.dead, key[4])
		} else {
			tree_put(s, &r.packs, key, v)
		}
	}
	if !r.entry {
		tree_put(s, &r.packs, {0, 0, 0, 0, r.next_gen}, {})
		r.entry = true
	}
}

// Renumbers what has changed into the next pack, and puts it. Reads nothing that may not be at hand.
@(private)
remote_begin :: proc(r: ^Remote) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	s := r.store
	gen := r.next_gen
	// The generation is spent before anything is put under it: a put that lands late lands on nothing named.
	r.next_gen = gen + 1
	if !remote_manifest_write(r, r.header, r.packs_kept, r.kept_gen, r.deletes[:]) {
		s.failed = true
		return
	}

	Node :: struct {
		no:    Page_No,
		tree:  u8,
		level: u16,
		low:   Key,
	}
	nodes := make([dynamic]Node, context.temp_allocator)
	roots := [?]^Tree{&s.shelf, &s.cells, &s.waste, &s.outbox, &s.repair, &r.packs}
	for t, ti in roots {
		if t.root == 0 || t.root not_in s.dirty {
			continue
		}
		start := len(nodes)
		append(&nodes, Node{t.root, u8(ti), s.dirty[t.root].level, KEY_MIN})
		for i := start; i < len(nodes); i += 1 {
			pg := s.dirty[nodes[i].no]
			if pg.level == 0 {
				continue
			}
			for e, j in pg.branch[:pg.count] {
				if child, ok := s.dirty[e.child]; ok {
					append(&nodes, Node{e.child, u8(ti), child.level, nodes[i].low if j == 0 else e.key})
				}
			}
		}
	}
	assert(len(nodes) == len(s.dirty), "a changed page that no tree reaches")
	// Branches first, then leaves, each in the order of their keys: neighbours in a tree are neighbours in the pack.
	slice.sort_by(nodes[:], proc(a, b: Node) -> bool {
		if a.level != b.level {
			return a.level > b.level
		}
		if a.tree != b.tree {
			return a.tree < b.tree
		}
		return key_less(a.low, b.low)
	})
	n := len(nodes)
	assert(n < 1 << PACK_SHIFT)
	// The pack's own entry, which is among its pages: every page in it lives, until superseded.
	{
		key := Key{0, 0, 0, 0, gen}
		pg := page(s, r.packs.root)
		for pg.level > 0 {
			pg = page(s, pg.branch[branch_find(pg, &key)].child)
		}
		i := leaf_find(pg, &key)
		assert(i < int(pg.count) && pg.leaf[i].key == key)
		pg.leaf[i].val = {u64(n), u64(n)}
		// Sums above it change with it.
		remote_resum(s, r.packs.root, &key)
	}
	renumber := make(map[Page_No]Page_No, n, context.temp_allocator)
	for node, slot in nodes {
		renumber[node.no] = gen << PACK_SHIFT | Page_No(slot)
	}
	for node in nodes {
		pg := s.dirty[node.no]
		if pg.level > 0 {
			for &e in pg.branch[:pg.count] {
				if to, ok := renumber[e.child]; ok {
					e.child = to
				}
			}
		}
	}
	for t in roots {
		if to, ok := renumber[t.root]; ok {
			t.root = to
		}
	}
	body := make([]byte, n * PAGE_SIZE + n * HINT_SIZE + 16)
	for node, slot in nodes {
		no := gen << PACK_SHIFT | Page_No(slot)
		pg := s.dirty[node.no]
		page_seal(pg, no)
		copy(body[slot * PAGE_SIZE:], ([^]byte)(pg)[:size_of(Page)])
		h := body[n * PAGE_SIZE + slot * HINT_SIZE:]
		h[0], h[1] = node.tree, u8(node.level)
		for k, i in node.low {
			put_u64(h[8 + i * 8:], k)
		}
		r.flushing[no] = pg
	}
	put_u64(body[len(body) - 16:], u64(n))
	put_u64(body[len(body) - 8:], PACK_MAGIC)
	clear(&s.dirty)

	h := Header {
		magic      = MAGIC,
		generation = s.generation + 1,
		log        = s.replay_at if s.replaying else store_tail(s),
		clock      = s.clock,
		serial     = s.serial,
		forgot     = s.forgot,
		shelf      = s.shelf.root,
		cells      = s.cells.root,
		waste      = s.waste.root,
		outbox     = s.outbox.root,
		repair     = s.repair.root,
	}
	h.sum = header_sum(&h)
	f := Inflight {
		gen       = gen,
		header    = h,
		packs     = r.packs.root,
		accounted = r.accounted,
		dead      = len(r.dead),
		victims   = slice.clone(s.evacuated[:]),
	}
	// What this checkpoint lets go of is named in its manifest until it is gone.
	append(&f.deletes, ..r.deletes[:])
	for g in r.dead {
		append(&f.deletes, Remote_Object{number = g, pack = true})
	}
	for seg in s.evacuated {
		for e := seg * SEGMENT / EXTENT; e < (seg + 1) * SEGMENT / EXTENT; e += 1 {
			append(&f.deletes, Remote_Object{number = e})
		}
	}
	op := remote_op(r, .Put_Pack)
	op.number = gen
	op.body = body
	f.op = op.id
	r.inflight = f
	r.stats.checkpoints += 1
	r.stats.put += u64(len(body))
	remote_start(r, op)
}

// Puts right the sums on the way down to a key, after a value beneath changed in place.
@(private)
remote_resum :: proc(p: ^Pager, no: Page_No, key: ^Key) {
	pg := page(p, no)
	if pg.level == 0 {
		return
	}
	i := branch_find(pg, key)
	remote_resum(p, pg.branch[i].child, key)
	pg.branch[i] = branch_of(pg.branch[i].key, pg.branch[i].child, page(p, pg.branch[i].child))
}

// The pack is in object storage: the manifest names it, and what it superseded can go.
@(private)
remote_commit :: proc(r: ^Remote) {
	s := r.store
	f := r.inflight.?
	r.inflight = nil
	defer delete(f.victims)
	defer delete(f.deletes)
	local_from := max(r.local_from, min(r.uploaded, f.header.log))
	r.local_from, local_from = local_from, r.local_from
	if !remote_manifest_write(r, f.header, f.packs, f.gen, f.deletes[:]) {
		r.local_from = local_from
		s.failed = true
		return
	}
	r.header = f.header
	r.packs_kept, r.kept_gen = f.packs, f.gen
	remote_header_page(r)
	s.checkpoint = f.header.log
	s.generation = f.header.generation
	s.serial_kept = f.header.serial
	// Its pages are at hand, and kept by the host too, in runs.
	first := f.gen << PACK_SHIFT
	run := make([dynamic]byte, context.temp_allocator)
	at := first
	for no := first; ; no += 1 {
		pg, ok := r.flushing[no]
		if ok {
			r.tick += 1
			r.pages[no] = {pg, r.tick}
			delete_key(&r.flushing, no)
			append(&run, ..([^]byte)(pg)[:size_of(Page)])
			resize(&run, len(run) + PAGE_SIZE - size_of(Page))
		}
		if !ok || len(run) >= 512 * PAGE_SIZE {
			if len(run) > 0 {
				r.host.cache_put(r.host.data, .Page, at, run[:])
				clear(&run)
			}
			at = no + 1
		}
		if !ok {
			break
		}
	}
	remove_range(&s.pending, 0, f.accounted)
	r.accounted -= f.accounted
	for g in r.dead[:f.dead] {
		r.host.cache_drop(r.host.data, .Page, g << PACK_SHIFT, (g + 1) << PACK_SHIFT)
	}
	remove_range(&r.dead, 0, f.dead)
	r.entry = false
	for seg in f.victims {
		r.host.log_cut(r.host.data, seg * SEGMENT, (seg + 1) * SEGMENT)
		r.host.cache_drop(r.host.data, .Log, seg * SEGMENT, (seg + 1) * SEGMENT)
		append(&s.dropped, seg) // and its waste forgotten in a step: see store_work
		for b := seg * SEGMENT; b < (seg + 1) * SEGMENT; b += LOG_BLOCK {
			if c, have := r.blocks[b]; have {
				delete(c.bytes)
				delete_key(&r.blocks, b)
			}
		}
		for x, i in s.evacuated {
			if x == seg {
				ordered_remove(&s.evacuated, i)
				break
			}
		}
	}
	// The host's own copy of the log is let go where object storage has it and the checkpoint is past it.
	if r.local_from > local_from {
		r.host.log_cut(r.host.data, local_from, r.local_from)
	}
	// Deleted now, and again a while later, should a put that was under way land after.
	clear(&r.deletes)
	append(&r.deletes, ..f.deletes[:])
	for o in f.deletes {
		remote_redelete(r, o)
	}
	if len(r.deletes) > 0 {
		remote_delete(r, r.deletes[:])
	}
}

// Whether something was deleted lately: named to be deleted, or to be deleted again.
@(private)
remote_deleted :: proc(r: ^Remote, o: Remote_Object) -> bool {
	if slice.contains(r.deletes[:], o) {
		return true
	}
	for d in r.redelete {
		if d.object == o {
			return true
		}
	}
	return false
}

@(private)
remote_redelete :: proc(r: ^Remote, o: Remote_Object) {
	for d in r.redelete {
		if d.object == o {
			return
		}
	}
	append(&r.redelete, Redelete{o, r.host.now(r.host.data) + REDELETE_AFTER})
}

// What is due to be deleted again is deleted, and named until it is.
@(private)
remote_redeletes :: proc(r: ^Remote) {
	now := r.host.now(r.host.data)
	due := make([dynamic]Remote_Object, context.temp_allocator)
	#reverse for d, i in r.redelete {
		if d.at <= now {
			if !slice.contains(r.deletes[:], d.object) {
				append(&r.deletes, d.object)
				append(&due, d.object)
			}
			unordered_remove(&r.redelete, i)
		}
	}
	if len(due) > 0 {
		remote_delete(r, due[:])
	}
}

// ---------------------------------------------------------------- the log, to object storage

// Puts the next extent of the log in object storage, if it is whole and durable.
@(private)
remote_upload :: proc(r: ^Remote) {
	s := r.store
	for r.uploading == 0 {
		e := r.uploaded
		seg := e / SEGMENT
		seg_end := (seg + 1) * SEGMENT
		ext_end := min((e / EXTENT + 1) * EXTENT, seg_end)
		if s.synced >= ext_end {
			// Whole, unless the segment ended before it: then as much of it as there is.
			n := log_size(remote_disk(r), e, ext_end - e) if s.synced >= seg_end else ext_end - e
			if n == 0 {
				r.uploaded = seg_end if s.synced >= seg_end else ext_end
				continue
			}
			op := remote_op(r, .Put_Extent)
			op.number = e / EXTENT
			op.off, op.len = e, n
			r.uploading = op.id
			r.upload_to = ext_end if n == ext_end - e else seg_end
			r.stats.put += n
			remote_start(r, op)
			return
		}
		if s.synced >= seg_end {
			// The segment ended before this extent began.
			n := log_size(remote_disk(r), e, seg_end - e)
			if n == 0 {
				r.uploaded = seg_end
				continue
			}
			op := remote_op(r, .Put_Extent)
			op.number = e / EXTENT
			op.off, op.len = e, n
			r.uploading = op.id
			r.upload_to = seg_end
			r.stats.put += n
			remote_start(r, op)
		}
		return
	}
}

// ---------------------------------------------------------------- emptying packs

GC_STEP :: 64 // pages touched in a step
GC_LIVE :: 2 // a pack is emptied once fewer than one in this many of its pages live
GC_HOT :: 4 // the latest packs are let be: their pages are still changing

// Copies on what still lives in a pack mostly superseded, so that it is soon wholly superseded and deleted.
@(private)
remote_gc_steps :: proc(r: ^Remote) -> (waiting: bool) {
	s := r.store
	g := &r.gc
	if !g.active {
		if r.inflight != nil || len(s.dirty) > CHECKPOINT_DIRTY / 2 || r.kept_gen < r.gc_after {
			return false // when there is room in the next checkpoint, and what was last copied on is durable
		}
		t := store_begin(s)
		gen, total, found := remote_gc_victim(r)
		if store_missed(s, &t) {
			store_end(s, &t, false)
			return true
		}
		store_end(s, &t, true)
		if !found {
			return false
		}
		g^ = {gen = gen, active = true, total = total}
	}
	if g.hints == nil {
		if !g.asked {
			g.asked = true
			op := remote_op(r, .Get_Hints)
			op.number = g.gen
			op.off, op.len = g.total * PAGE_SIZE, g.total * HINT_SIZE + 16
			remote_start(r, op)
		}
		return true
	}
	n := len(g.hints) / HINT_SIZE
	for g.slot < n {
		if len(s.dirty) > CHECKPOINT_DIRTY {
			return false // the rest after the next checkpoint
		}
		slot := g.slot
		t := store_begin(s)
		for i in slot ..< min(slot + GC_STEP, n) {
			h := g.hints[i * HINT_SIZE:]
			key: Key
			for &k, j in key {
				k = get_u64(h[8 + j * 8:])
			}
			roots := [?]^Tree{&s.shelf, &s.cells, &s.waste, &s.outbox, &s.repair, &r.packs}
			if int(h[0]) < len(roots) {
				remote_touch(s, roots[h[0]], key, u16(h[1]), g.gen << PACK_SHIFT | Page_No(i))
			}
		}
		if store_missed(s, &t) {
			store_end(s, &t, false)
			return true
		}
		store_end(s, &t, true)
		g.slot = min(slot + GC_STEP, n)
	}
	delete(g.hints)
	g^ = {}
	// What was copied on goes into the next checkpoint, which is then due; and until it is durable the books are not
	// yet what they will be, so nothing else is chosen.
	r.want_checkpoint = true
	r.gc_after = r.next_gen
	return false
}

@(private)
remote_gc_victim :: proc(r: ^Remote) -> (gen, total: u64, ok: bool) {
	scan := tree_scan(r.store, r.packs, KEY_MIN, KEY_MAX)
	best := f64(1)
	for leaf in tree_next(&scan) {
		g, live, pages := leaf.key[4], leaf.val[0], leaf.val[1]
		if g + GC_HOT >= r.next_gen || pages == 0 || live * GC_LIVE >= pages {
			continue
		}
		if ratio := f64(live) / f64(pages); ratio < best {
			best, gen, total, ok = ratio, g, pages, true
		}
	}
	return
}

// Copies on the page at a level on the way to a key, if it is the one named: it and the way to it change.
@(private)
remote_touch :: proc(s: ^Store, t: ^Tree, key: Key, level: u16, target: Page_No) {
	key := key
	if t.root == 0 {
		return
	}
	no, found := touch(s, t.root, &key, level, target)
	if found {
		t.root = no
		s.remote.stats.relocated += 1
	}
}

@(private)
touch :: proc(p: ^Pager, no: Page_No, key: ^Key, level: u16, target: Page_No) -> (Page_No, bool) {
	pg := page(p, no)
	if pg.level == level {
		if no != target {
			return no, false
		}
		mine, _ := page_own(p, no)
		return mine, true
	}
	if pg.level < level || pg.count == 0 {
		return no, false
	}
	i := branch_find(pg, key)
	child, found := touch(p, pg.branch[i].child, key, level, target)
	if !found {
		return no, false
	}
	mine, own := page_own(p, no)
	own.branch[i].child = child
	return mine, true
}

// ---------------------------------------------------------------- the manifest

@(private)
remote_manifest_write :: proc(r: ^Remote, h: Header, packs: Page_No, kept_gen: u64, deletes: []Remote_Object) -> bool {
	w := make([dynamic]byte, context.temp_allocator)
	magic := MANIFEST_MAGIC
	append(&w, ..magic[:])
	h := h
	append(&w, ..([^]byte)(&h)[:size_of(Header)])
	write_u64(&w, r.next_gen)
	write_u64(&w, kept_gen)
	write_u64(&w, r.uploaded)
	write_u64(&w, r.local_from)
	write_u64(&w, packs)
	write_u64(&w, u64(len(deletes)))
	for d in deletes {
		write_u8(&w, 1 if d.pack else 0)
		write_u64(&w, d.number)
	}
	write_u64(&w, u64(len(r.redelete)))
	for d in r.redelete {
		write_u8(&w, 1 if d.object.pack else 0)
		write_u64(&w, d.object.number)
		write_u64(&w, d.at)
	}
	write_u64(&w, xxhash.XXH64(w[:]))
	return r.host.manifest_write(r.host.data, w[:])
}

@(private)
remote_manifest_read :: proc(r: ^Remote, bytes: []byte) -> bool {
	if len(bytes) < 8 + size_of(Header) + 48 || xxhash.XXH64(bytes[:len(bytes) - 8]) != get_u64(bytes[len(bytes) - 8:]) {
		return false
	}
	rd := Reader{buf = bytes[:len(bytes) - 8]}
	magic := MANIFEST_MAGIC
	if string(read_take(&rd, 8)) != string(magic[:]) {
		return false
	}
	copy(([^]byte)(&r.header)[:size_of(Header)], read_take(&rd, size_of(Header)))
	r.next_gen = read_u64(&rd)
	r.kept_gen = read_u64(&rd)
	r.uploaded = read_u64(&rd)
	r.local_from = read_u64(&rd)
	r.packs.root = read_u64(&rd)
	r.packs_kept = r.packs.root
	n := read_u64(&rd)
	for _ in 0 ..< n {
		pack := read_u8(&rd) == 1
		append(&r.deletes, Remote_Object{read_u64(&rd), b64(pack)})
		if rd.bad {
			return false
		}
	}
	n = read_u64(&rd)
	for _ in 0 ..< n {
		pack := read_u8(&rd) == 1
		number := read_u64(&rd)
		append(&r.redelete, Redelete{{number, b64(pack)}, read_u64(&rd)})
		if rd.bad {
			return false
		}
	}
	remote_header_page(r)
	return !rd.bad
}

@(private)
remote_header_page :: proc(r: ^Remote) {
	r.header_page = {}
	copy(([^]byte)(&r.header_page)[:size_of(Page)], ([^]byte)(&r.header)[:size_of(Header)])
}
