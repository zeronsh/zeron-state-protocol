#+build !js
package zsp

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"

// A disk that holds everything but hands over only what has been fetched, as a cache over object storage does: a page
// or a block of the log that is not at hand is "not yet" until the host, here the test, brings it. The log past the
// checkpoint is always at hand, as the host keeps it in its own storage. Reading what is not at hand anywhere but in
// a step is a fault: whatever stood in for it would be believed.
@(private)
Slow_Disk :: struct {
	m:       Memory_Disk,
	store:   ^Store,
	missed:  int,
	all:     bool, // everything at hand, for looking at what is there
	stingy:  bool, // what is written is not kept at hand either
	pages:   map[Page_No]struct{}, // at hand
	blocks:  map[u64]struct{},
	want_pages:  map[Page_No]struct{},
	want_blocks: map[u64]struct{},
	unguarded: int, // reads of what was not at hand, outside any step
}

SLOW_BLOCK :: 4096

@(private)
slow_disk :: proc(d: ^Slow_Disk) -> Disk {
	inner := memory_disk(&d.m)
	return {
		data = d,
		log_write = proc(data: rawptr, off: u64, bytes: []byte) -> bool {
			d := (^Slow_Disk)(data)
			return memory_disk(&d.m).log_write(&d.m, off, bytes)
		},
		log_read = proc(data: rawptr, off: u64, into: []byte) -> bool {
			d := (^Slow_Disk)(data)
			if !memory_disk(&d.m).log_read(&d.m, off, into) {
				return false // never: not "not yet"
			}
			if d.all || len(into) == 0 || d.store == nil || off >= d.store.checkpoint {
				return true
			}
			here := true
			for b in off / SLOW_BLOCK ..= (off + u64(len(into)) - 1) / SLOW_BLOCK {
				if b not_in d.blocks {
					d.want_blocks[b] = {}
					here = false
				}
			}
			if !here {
				slow_miss(d)
			}
			return here
		},
		log_end = inner.log_end,
		log_drop = proc(data: rawptr, segment: u64) {
			d := (^Slow_Disk)(data)
			memory_disk(&d.m).log_drop(&d.m, segment)
		},
		log_truncate = proc(data: rawptr, off: u64) {
			d := (^Slow_Disk)(data)
			memory_disk(&d.m).log_truncate(&d.m, off)
		},
		log_sync = proc(data: rawptr) -> bool {
			d := (^Slow_Disk)(data)
			return memory_disk(&d.m).log_sync(&d.m)
		},
		page = proc(data: rawptr, no: Page_No) -> ^Page {
			d := (^Slow_Disk)(data)
			pg := d.m.pages[no]
			if pg == nil {
				return nil
			}
			if d.all || no in d.pages || no < HEADER_PAGES {
				return pg
			}
			d.want_pages[no] = {}
			slow_miss(d)
			return &EMPTY_PAGE
		},
		page_write = proc(data: rawptr, no: Page_No, bytes: []byte) -> bool {
			d := (^Slow_Disk)(data)
			if !d.stingy {
				d.pages[no] = {} // just written: at hand
			}
			return memory_disk(&d.m).page_write(&d.m, no, bytes)
		},
		page_sync = proc(data: rawptr) -> bool {
			d := (^Slow_Disk)(data)
			return memory_disk(&d.m).page_sync(&d.m)
		},
		close = proc(data: rawptr) {},
		missed = proc(data: rawptr) -> int {
			return (^Slow_Disk)(data).missed
		},
	}
}

@(private)
slow_miss :: proc(d: ^Slow_Disk) {
	d.missed += 1
	if d.store != nil && !d.store.pager.step {
		d.unguarded += 1
	}
}

// The host brings some of what was asked for, or all of it. Returns how much it brought. (Keys are gone over in
// order: a map's own order differs from run to run, and a seed must say everything.)
@(private)
slow_fetch :: proc(d: ^Slow_Disk, all := false) -> (brought: int) {
	pages := sorted_keys(d.want_pages)
	for no in pages {
		if all || rand.int_max(2) == 0 {
			d.pages[no] = {}
			delete_key(&d.want_pages, no)
			brought += 1
		}
	}
	blocks := sorted_keys(d.want_blocks)
	for b in blocks {
		if all || rand.int_max(2) == 0 {
			d.blocks[b] = {}
			delete_key(&d.want_blocks, b)
			brought += 1
		}
	}
	return
}

@(private)
sorted_keys :: proc(m: map[$K]$V) -> []K {
	keys := make([]K, len(m), context.temp_allocator)
	i := 0
	for k in m {
		keys[i] = k
		i += 1
	}
	slice.sort(keys)
	return keys
}

// The cache lets some of it go.
@(private)
slow_evict :: proc(d: ^Slow_Disk, chance: int) {
	for no in sorted_keys(d.pages) {
		if rand.int_max(chance) == 0 {
			delete_key(&d.pages, no)
		}
	}
	for b in sorted_keys(d.blocks) {
		if rand.int_max(chance) == 0 {
			delete_key(&d.blocks, b)
		}
	}
}

@(private)
slow_disk_destroy :: proc(d: ^Slow_Disk) {
	memory_disk_destroy(&d.m)
	delete(d.pages)
	delete(d.blocks)
	delete(d.want_pages)
	delete(d.want_blocks)
}

// Brings everything asked for until nothing waits, as a host does: the store is then wholly opened and its work done.
@(private)
slow_settle :: proc(t: ^testing.T, d: ^Slow_Disk, s: ^Store) {
	for round := 0; ; round += 1 {
		waiting := store_work(s)
		if !waiting {
			return
		}
		if slow_fetch(d, all = true) == 0 || round > 10_000 {
			testing.fail_now(t, "waits for what never comes")
		}
	}
}

// A store whose reads may answer "not yet", under commits, crashes, evictions and fetches in any order, holds the
// same as one that always answers, and nothing read while something was missing is ever believed.
@(test)
slow_store_matches_quick :: proc(t: ^testing.T) {
	for seed in 0 ..< 8 {
		state := seeded(u64(seed) + 700)
		context.random_generator = rand.default_random_generator(&state)
		d: Slow_Disk
		defer slow_disk_destroy(&d)
		m: Memory_Disk
		defer memory_disk_destroy(&m)
		s, q: Store
		testing.expect(t, store_open(&s, slow_disk(&d)))
		d.store = &s
		testing.expect(t, store_open(&q, memory_disk(&m)))
		slow_settle(t, &d, &s)
		held := make([dynamic]Cell)
		defer delete(held)
		for round in 0 ..< 1500 {
			cells: [6]Cell
			for &c in cells {
				c = random_cell(300, 1_000_000)
				if rand.int_max(4) == 0 && (c.kind == .Value || c.kind == .Piece) {
					c.body = make([]byte, 400 + rand.int_max(3000), context.temp_allocator) // segments fill, and are evacuated
				}
			}
			// A commit is a step: done again until nothing it reads is missing.
			for tries := 0; ; tries += 1 {
				st := store_begin(&s)
				store_commit(&s, cells[:])
				if !store_missed(&s, &st) {
					store_end(&s, &st, true)
					break
				}
				store_end(&s, &st, false)
				slow_fetch(&d)
				testing.expect(t, tries < 10_000)
			}
			store_commit(&q, cells[:])
			switch r := rand.int_max(40); {
			case r < 4:
				store_flush(&s)
				slow_settle(t, &d, &s)
				testing.expect(t, store_checkpoint(&s))
				store_checkpoint(&q)
			case r < 6:
				// A crash: what was flushed is there, and the store opens again from it.
				store_flush(&s)
				store_flush(&q)
				store_close(&s)
				clear(&d.pages)
				clear(&d.blocks)
				d.store = nil
				testing.expect(t, store_open(&s, slow_disk(&d)))
				d.store = &s
				slow_settle(t, &d, &s)
			case r < 12:
				slow_evict(&d, 3)
			case r < 20:
				store_work(&s)
				slow_fetch(&d)
			}
			if round % 100 == 99 {
				slow_settle(t, &d, &s)
				d.all = true
				testing.expect_value(t, census(&s), census(&q))
				check_shelf(t, &s)
				d.all = false
			}
			free_all(context.temp_allocator)
		}
		testing.expect_value(t, d.unguarded, 0)
		testing.expectf(t, d.missed > 1000, "only %d reads missed", d.missed)
		first := max(u64)
		for seg in d.m.log {
			first = min(first, seg)
		}
		testing.expectf(t, first > 2, "segments were not evacuated: the first is %d", first)
		testing.expectf(t, !s.failed, "seed %d failed", seed)
		store_close(&s)
		store_close(&q)
		if testing.failed(t) {
			fmt.println("seed", seed)
			return
		}
	}
}
