#+build !js
package zsp

import "core:math/rand"
import "core:testing"

// Power lost at any point of what a store asks the disk, as disks lose it: whatever was written and not yet made
// durable may be there or not, each write on its own, the log's torn anywhere and a page's too; what a sync was asked
// for is durable once the disk said so, and perhaps before it did. Every acknowledged commit, which is to say every
// one the store counted as synced, must be there after, and the store sound: through syncs and checkpoints the store
// does not wait for (store_sync_start, store_checkpoint_start), answered in any order, and those it waits for.

POWER_SEEDS :: #config(ZSP_POWER_SEEDS, 40)

@(private = "file")
Power_Write :: struct {
	seq:   int,
	page:  bool,
	at:    u64, // the log offset, or the page number
	bytes: [dynamic]byte,
}

@(private = "file")
Power_Ask :: struct {
	token: u64,
	page:  bool,
	upto:  int, // writes before this are made durable by it
}

@(private = "file")
Power_Disk :: struct {
	seen:   Memory_Disk, // as the system shows it, which is what the store reads
	kept:   Memory_Disk, // durable, whatever happens
	writes: [dynamic]Power_Write, // since, not known durable
	seq:    int,
	asks:   [dynamic]Power_Ask, // under way
}

@(private = "file")
power_disk :: proc(p: ^Power_Disk) -> Disk {
	seen := memory_disk(&p.seen)
	return {
		data = p,
		log_write = proc(data: rawptr, off: u64, bytes: []byte) -> bool {
			p := (^Power_Disk)(data)
			power_note(p, false, off, bytes)
			return memory_disk(&p.seen).log_write(&p.seen, off, bytes)
		},
		log_read = proc(data: rawptr, off: u64, into: []byte) -> bool {
			p := (^Power_Disk)(data)
			return memory_disk(&p.seen).log_read(&p.seen, off, into)
		},
		log_end = proc(data: rawptr) -> u64 {
			return memory_disk_end(&(^Power_Disk)(data).seen)
		},
		// Taken as durable at once: so whatever the store forgets, it forgets for good, however soon after power goes.
		log_drop = proc(data: rawptr, segment: u64) {
			p := (^Power_Disk)(data)
			memory_disk(&p.seen).log_drop(&p.seen, segment)
			memory_disk(&p.kept).log_drop(&p.kept, segment)
			#reverse for w, i in p.writes {
				if !w.page && w.at / SEGMENT == segment {
					delete(w.bytes)
					ordered_remove(&p.writes, i)
				}
			}
		},
		log_truncate = proc(data: rawptr, off: u64) {
			p := (^Power_Disk)(data)
			memory_disk(&p.seen).log_truncate(&p.seen, off)
			memory_disk(&p.kept).log_truncate(&p.kept, off)
			#reverse for &w, i in p.writes {
				if w.page || w.at + u64(len(w.bytes)) <= off {
					continue
				}
				if w.at >= off {
					delete(w.bytes)
					ordered_remove(&p.writes, i)
				} else {
					resize(&w.bytes, int(off - w.at))
				}
			}
		},
		log_sync = proc(data: rawptr) -> bool {
			p := (^Power_Disk)(data)
			power_fold(p, false, p.seq)
			return true
		},
		page = seen.page,
		page_write = proc(data: rawptr, no: Page_No, bytes: []byte) -> bool {
			p := (^Power_Disk)(data)
			power_note(p, true, no, bytes)
			return memory_disk(&p.seen).page_write(&p.seen, no, bytes)
		},
		page_sync = proc(data: rawptr) -> bool {
			p := (^Power_Disk)(data)
			power_fold(p, true, p.seq)
			return true
		},
		close = proc(data: rawptr) {},
		log_sync_start = proc(data: rawptr, token: u64) -> bool {
			p := (^Power_Disk)(data)
			append(&p.asks, Power_Ask{token, false, p.seq})
			return true
		},
		page_sync_start = proc(data: rawptr, token: u64) -> bool {
			p := (^Power_Disk)(data)
			append(&p.asks, Power_Ask{token, true, p.seq})
			return true
		},
	}
}

@(private = "file")
power_note :: proc(p: ^Power_Disk, page: bool, at: u64, bytes: []byte) {
	w := Power_Write{seq = p.seq, page = page, at = at}
	append(&w.bytes, ..bytes)
	append(&p.writes, w)
	p.seq += 1
}

@(private = "file")
power_apply :: proc(m: ^Memory_Disk, w: ^Power_Write, n: int) {
	if n == 0 {
		return
	}
	if w.page {
		// A page torn keeps what was there before past where it tore.
		block: [size_of(Page)]byte
		if old := m.pages[w.at]; old != nil {
			copy(block[:], ([^]byte)(old)[:size_of(Page)])
		}
		copy(block[:], w.bytes[:n])
		memory_disk(m).page_write(m, w.at, block[:])
	} else {
		memory_disk(m).log_write(m, w.at, w.bytes[:n])
	}
}

// What was written of a kind before `upto` is durable now.
@(private = "file")
power_fold :: proc(p: ^Power_Disk, page: bool, upto: int) {
	i := 0
	for i < len(p.writes) {
		w := &p.writes[i]
		if w.page == page && w.seq < upto {
			power_apply(&p.kept, w, len(w.bytes))
			delete(w.bytes)
			ordered_remove(&p.writes, i)
		} else {
			i += 1
		}
	}
}

// The disk says a sync it was asked for is done.
@(private = "file")
power_answer :: proc(p: ^Power_Disk, s: ^Store, i: int) -> bool {
	a := p.asks[i]
	ordered_remove(&p.asks, i)
	power_fold(p, a.page, a.upto)
	return store_disk_synced(s, a.token, true)
}

@(private = "file")
memory_disk_copy :: proc(from: ^Memory_Disk) -> (m: Memory_Disk) {
	for seg, b in from.log {
		c := make([dynamic]byte, len(b))
		copy(c[:], b[:])
		m.log[seg] = c
	}
	for no, pg in from.pages {
		c := new(Page)
		c^ = pg^
		m.pages[no] = c
	}
	return
}

// Power goes: what is left is what was durable, what syncs under way may have made so before anyone heard, and of the
// rest whatever the disk got to, a write at a time, each perhaps torn. Then it comes back, with nothing under way.
@(private = "file")
power_cut :: proc(p: ^Power_Disk) {
	for a in p.asks {
		if rand.int_max(2) == 0 {
			power_fold(p, a.page, a.upto) // done, though nobody heard
		}
	}
	image := memory_disk_copy(&p.kept)
	for &w in p.writes {
		switch rand.int_max(3) {
		case 0:
		case 1:
			power_apply(&image, &w, len(w.bytes))
		case:
			power_apply(&image, &w, rand.int_max(len(w.bytes) + 1))
		}
		delete(w.bytes)
	}
	clear(&p.writes)
	clear(&p.asks)
	memory_disk_destroy(&p.seen)
	memory_disk_destroy(&p.kept)
	p.seen = image
	p.kept = memory_disk_copy(&image)
}

@(private = "file")
power_destroy :: proc(p: ^Power_Disk) {
	for w in p.writes {
		delete(w.bytes)
	}
	delete(p.writes)
	delete(p.asks)
	memory_disk_destroy(&p.seen)
	memory_disk_destroy(&p.kept)
}

// What a cell's body is, by its stamp: so that what is read back can be held to what was written.
@(private = "file")
power_body :: proc(stamp: u64, size: int) -> []byte {
	b := make([]byte, size, context.temp_allocator)
	for &x, i in b {
		x = byte(stamp * 31 + u64(i) * 7)
	}
	return b
}

// Where a cut fell, so that a run is known to have cut at each.
@(private = "file")
Power_Point :: enum {
	Log_Sync, // a log sync begun, and not answered
	Pages_Written, // a checkpoint's pages written, not known durable
	Header_Written, // its header written, not known durable
	Evacuating, // under way with a segment evacuated, to be dropped
	Segment_Dropped, // just after a checkpoint dropped a segment
}

@(test)
power_cuts_lose_nothing_acknowledged :: proc(t: ^testing.T) {
	hit: [Power_Point]int
	cuts := 0
	for seed in 0 ..< u64(POWER_SEEDS) {
		state := seeded(seed + 7000)
		context.random_generator = rand.default_random_generator(&state)
		p: Power_Disk
		defer power_destroy(&p)
		s: Store
		testing.expect(t, store_open(&s, power_disk(&p)))
		size := max(SEGMENT / 256, 64)
		ROWS :: 60
		stamp := u64(1)
		// Of each row's value, the stamp written last, and where the log then ended: acknowledged once synced past it.
		Wrote :: struct {
			stamp: u64,
			end:   u64,
		}
		wrote: map[u64][dynamic]Wrote
		defer {
			for _, w in wrote {
				delete(w)
			}
			delete(wrote)
		}
		dropped := false
		for round in 0 ..< 3000 {
			switch r := rand.int_max(100); {
			case r < 45:
				n := u64(rand.int_max(ROWS)) + 1
				cells := make([dynamic]Cell, context.temp_allocator)
				if n not_in wrote {
					body := make([]byte, 24, context.temp_allocator)
					put_u64(body, 1 << 32)
					put_u64(body[8:], 1)
					put_u64(body[16:], n)
					append(&cells, Cell{row = {1 << 32, n}, slot = PLACE, kind = .Place, stamp = {stamp, 0}, body = body})
					stamp += 1
				}
				append(&cells, Cell{row = {1 << 32, n}, slot = 16, kind = .Value, stamp = {stamp, 0}, body = power_body(stamp, size)})
				if store_commit(&s, cells[:]) == len(cells) {
					if n not_in wrote {
						wrote[n] = {}
					}
					append(&wrote[n], Wrote{stamp, store_tail(&s)})
				}
				stamp += 1
			case r < 52:
				store_flush(&s)
			case r < 62:
				testing.expect(t, store_sync_start(&s))
			case r < 70:
				testing.expect(t, store_checkpoint_start(&s))
			case r < 71:
				testing.expect(t, store_checkpoint(&s))
			case r < 72:
				testing.expect(t, store_sync(&s))
			case r < 96:
				if len(p.asks) > 0 {
					victims := len(s.flight.victims) > 0 && s.flight.step == .Header
					testing.expect(t, power_answer(&p, &s, rand.int_max(len(p.asks))))
					dropped ||= victims && s.flight.step == .None
				}
			case:
				f := &s.flight
				if f.log != 0 {hit[.Log_Sync] += 1}
				if f.step == .Durable && f.pages != 0 {hit[.Pages_Written] += 1}
				if f.step == .Header {hit[.Header_Written] += 1}
				if f.step != .None && len(f.victims) > 0 {hit[.Evacuating] += 1}
				if dropped {hit[.Segment_Dropped] += 1}
				dropped = false
				cuts += 1
				synced := s.synced
				store_close(&s)
				power_cut(&p)
				testing.expect(t, store_open(&s, power_disk(&p)))
				testing.expectf(t, !s.failed, "seed %d round %d: the store opens again", seed, round)
				check_shelf(t, &s)
				for n, &w in wrote {
					// The latest acknowledged, or any later.
					want := u64(0)
					for x in w {
						if x.end <= synced {
							want = x.stamp
						}
					}
					scan := row_scan(&s, {1 << 32, n}, 16, 16)
					got := u64(0)
					for c in row_next(&s, &scan) {
						got = max(got, c.stamp.time)
						if string(c.body) != string(power_body(c.stamp.time, size)) {
							testing.expectf(t, false, "seed %d round %d: row %d's value of %d reads back otherwise", seed, round, n, c.stamp.time)
						}
					}
					testing.expectf(t, got >= want, "seed %d round %d: row %d holds %d, not %d, which was acknowledged", seed, round, n, got, want)
					// From now on, what is there is what there is: nothing later than it was ever acknowledged.
					clear(&w)
					if got > 0 {
						append(&w, Wrote{got, 0})
					}
				}
				if t.error_count > 0 {
					return
				}
			}
			free_all(context.temp_allocator)
		}
		store_close(&s)
	}
	for n, point in hit {
		testing.expectf(t, n > 0, "power never went with %v: %v", point, hit)
	}
	testing.expect(t, cuts > 0)
}

// What is changed while a checkpoint is under way is changed in copies, and so held in memory: never more than so much,
// for a commit beyond it waits for the checkpoint to be done. And what the checkpoint then made is sound.
@(test)
checkpoint_under_way_holds_only_so_much :: proc(t: ^testing.T) {
	state := seeded(77)
	context.random_generator = rand.default_random_generator(&state)
	p: Power_Disk
	defer power_destroy(&p)
	s: Store
	testing.expect(t, store_open(&s, power_disk(&p)))
	commit :: proc(s: ^Store) {
		c := random_cell(1 << 30, 1_000_000)
		c.kind, c.slot = .Value, 16
		store_commit(s, {c})
	}
	for _ in 0 ..< 20_000 {
		commit(&s)
		free_all(context.temp_allocator)
	}
	testing.expect(t, store_checkpoint(&s)) // all of it clean, on the disk
	commit(&s)
	testing.expect(t, store_checkpoint_start(&s) && s.flight.step == .Durable)
	most, landed := 0, false
	for _ in 0 ..< 100_000 {
		commit(&s) // and nothing the disk was asked is answered
		most = max(most, len(s.dirty))
		if s.flight.step == .None {
			landed = true
			break
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, landed, "a checkpoint under way held %d pages, and went on holding more", most)
	testing.expectf(t, most <= FLIGHT_DIRTY + 32, "%d pages held, of %d", most, FLIGHT_DIRTY)
	testing.expect(t, store_sync(&s))
	want := census(&s)
	store_close(&s)
	power_cut(&p)
	testing.expect(t, store_open(&s, power_disk(&p)))
	check_shelf(t, &s)
	testing.expect(t, census(&s) == want && !s.failed)
	store_close(&s)
}

// A checkpoint under way that storage failed under is not finished, however it is asked to be: no header is written,
// nothing more counted on, and nothing dropped.
@(test)
a_failed_store_finishes_no_checkpoint :: proc(t: ^testing.T) {
	for step in 0 ..< 2 {
		p: Power_Disk
		defer power_destroy(&p)
		s: Store
		testing.expect(t, store_open(&s, power_disk(&p)))
		body := [4]byte{1, 2, 3, 4}
		store_commit(&s, {{row = {1 << 32, 1}, slot = 16, kind = .Value, stamp = {1, 0}, body = body[:]}})
		testing.expect(t, store_checkpoint_start(&s) && s.flight.step == .Durable)
		if step == 1 {
			for s.flight.step == .Durable && len(p.asks) > 0 {
				testing.expect(t, power_answer(&p, &s, 0))
			}
			testing.expect(t, s.flight.step == .Header)
		}
		writes := p.seq
		generation, synced := s.generation, s.synced
		s.failed = true
		testing.expect(t, !store_checkpoint(&s))
		testing.expect(t, p.seq == writes && s.generation == generation && s.synced == synced, "nothing more written or counted on")
		store_close(&s)
	}
}

// A header the process wrote, and was killed before it was made durable, is what a store opening again reads; power lost
// after would fall back to the one before it. So before anything that one names is reused, what was read is made
// durable: else the next checkpoint writes over pages the header fallen back to names, and what it held is gone (once
// the log that would have rebuilt it is dropped, which is why the power sims found it only with small segments).
@(test)
a_header_read_is_made_durable_before_its_last_pages_are_reused :: proc(t: ^testing.T) {
	p: Power_Disk
	defer power_destroy(&p)
	s: Store
	testing.expect(t, store_open(&s, power_disk(&p)))
	put :: proc(s: ^Store, stamp: u64) {
		for n in u64(1) ..= 200 {
			store_commit(s, {{row = {1 << 32, n}, slot = 16, kind = .Value, stamp = {stamp + n, 0}, body = power_body(stamp + n, 64)}})
		}
	}
	put(&s, 0)
	testing.expect(t, store_checkpoint(&s)) // durable
	// Each header, with the pages as they were when it was written: what it names must be so still, if it is the one read.
	snaps: [2]Memory_Disk
	defer for &m in snaps {
		memory_disk_destroy(&m)
	}
	snaps[s.generation % HEADER_PAGES] = memory_disk_copy(&p.kept)
	// The next, made without waiting, as far as its header written and asked to be made durable.
	put(&s, 1000)
	testing.expect(t, store_checkpoint_start(&s))
	for s.flight.step == .Durable && len(p.asks) > 0 {
		testing.expect(t, power_answer(&p, &s, 0))
	}
	testing.expect(t, s.flight.step == .Header && len(p.asks) == 1)
	snaps[(s.generation + 1) % HEADER_PAGES] = memory_disk_copy(&p.seen)
	// Killed: the system keeps all it was given, the disk only what was synced; nothing asked is done.
	store_close(&s)
	clear(&p.asks)
	testing.expect(t, store_open(&s, power_disk(&p)))
	put(&s, 2000)
	testing.expect(t, store_checkpoint_start(&s)) // its pages written, perhaps over what it read as free
	store_close(&s)
	// Power lost, as it may be: every page written lands but a header not made durable.
	#reverse for w, i in p.writes {
		if w.page && w.at < HEADER_PAGES {
			delete(w.bytes)
			ordered_remove(&p.writes, i)
		}
	}
	power_fold(&p, true, p.seq)
	best, _ := store_header(memory_disk(&p.kept))
	snap := &snaps[best.generation % HEADER_PAGES]
	testing.expect(t, best.generation > 0)
	walk :: proc(t: ^testing.T, snap: ^Memory_Disk, now: ^Memory_Disk, no: Page_No) {
		if no == 0 {
			return
		}
		was, is := snap.pages[no], now.pages[no]
		testing.expectf(t, was != nil && is != nil && was^ == is^, "page %d, named by the header read, was written over", no)
		if was != nil && was.level > 0 {
			for &e in was.branch[:was.count] {
				walk(t, snap, now, e.child)
			}
		}
	}
	h, tail := store_header(memory_disk(snap))
	testing.expect(t, h.generation == best.generation)
	for root in ([]Page_No{h.shelf, h.cells, h.waste, h.outbox, h.repair, tail.used}) {
		walk(t, snap, &p.kept, root)
	}
	// And back, from what power left: sound.
	power_cut(&p)
	testing.expect(t, store_open(&s, power_disk(&p)))
	check_shelf(t, &s)
	store_close(&s)
}
