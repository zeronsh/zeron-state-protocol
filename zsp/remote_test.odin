#+build !js
package zsp

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"

// The host a relay is, modelled unkindly: its own storage loses what was not synced when it crashes, and keeps a
// cache that forgets as it likes; object storage is slow, answers in any order, fails, says it failed when it did
// not, and lets puts under way when the host crashed land later, whenever.
@(private)
Model_Host :: struct {
	local:    Memory_Disk, // the host's own log
	manifest: []byte,
	cache:    [Cached]map[u64][]byte, // runs, by first key
	objects:  map[Remote_Object][]byte,
	ops:      [dynamic]^Remote_Op, // started, not answered
	zombies:  [dynamic]Zombie, // under way when it crashed, and perhaps landing yet
	clock:    u64, // milliseconds
	fail:     int, // one in this many operations fails
	// What it cost.
	rows:     int, // writes to its own storage
	class_a:  int,
	class_b:  int,
}

@(private)
Zombie :: struct {
	op:   ^Remote_Op,
	dies: u64, // by when it has landed or never will: no put lives for ever
}

ZOMBIE_LIFE :: 10 * 60 * 1000

@(private)
model_host :: proc(h: ^Model_Host) -> Remote_Host {
	return {
		data = h,
		log_write = proc(data: rawptr, off: u64, bytes: []byte) -> bool {
			h := (^Model_Host)(data)
			h.rows += 1
			return memory_disk(&h.local).log_write(&h.local, off, bytes)
		},
		log_read = proc(data: rawptr, off: u64, into: []byte) -> bool {
			h := (^Model_Host)(data)
			return memory_disk(&h.local).log_read(&h.local, off, into)
		},
		log_end = proc(data: rawptr) -> u64 {
			return memory_disk_end(&(^Model_Host)(data).local)
		},
		log_cut = proc(data: rawptr, lo, hi: u64) {
			h := (^Model_Host)(data)
			h.rows += 1
			if hi == max(u64) {
				memory_disk(&h.local).log_truncate(&h.local, lo)
				return
			}
			// Below the end: whole segments go, and of a segment cut in part, the part is made unreadable.
			for seg, &b in h.local.log {
				from, to := seg * SEGMENT, seg * SEGMENT + u64(len(b))
				if from >= lo && to <= hi {
					delete(b)
					delete_key(&h.local.log, seg)
				} else if lo < to && hi > from {
					a, z := max(lo, from) - from, min(hi, to) - from
					for &x in b[a:z] {
						x = 0xee // what is cut is not read again, and would be noticed
					}
				}
			}
		},
		log_sync = proc(data: rawptr) -> bool {
			h := (^Model_Host)(data)
			return memory_disk(&h.local).log_sync(&h.local)
		},
		manifest_read = proc(data: rawptr) -> []byte {
			h := (^Model_Host)(data)
			return slice.clone(h.manifest, context.temp_allocator) if h.manifest != nil else nil
		},
		manifest_write = proc(data: rawptr, bytes: []byte) -> bool {
			h := (^Model_Host)(data)
			h.rows += 1
			delete(h.manifest)
			h.manifest = slice.clone(bytes)
			return true
		},
		cache_get = proc(data: rawptr, kind: Cached, key: u64, into: []byte) -> bool {
			h := (^Model_Host)(data)
			unit := u64(1) if kind == .Page else 1
			for first, run in h.cache[kind] {
				if kind == .Page {
					if key >= first && (key - first) * PAGE_SIZE + u64(len(into)) <= u64(len(run)) && (key - first) * PAGE_SIZE < u64(len(run)) {
						copy(into, run[(key - first) * PAGE_SIZE:])
						return true
					}
				} else if key >= first && key - first + u64(len(into)) <= u64(len(run)) * unit {
					copy(into, run[key - first:])
					return true
				}
			}
			return false
		},
		cache_put = proc(data: rawptr, kind: Cached, key: u64, bytes: []byte) {
			h := (^Model_Host)(data)
			if rand.int_max(4) == 0 {
				return // it would rather not
			}
			h.rows += 1
			if old, ok := h.cache[kind][key]; ok {
				delete(old)
			}
			h.cache[kind][key] = slice.clone(bytes)
		},
		cache_drop = proc(data: rawptr, kind: Cached, lo, hi: u64) {
			h := (^Model_Host)(data)
			gone := make([dynamic]u64, context.temp_allocator)
			for first in h.cache[kind] {
				if first >= lo && first < hi {
					append(&gone, first)
				}
			}
			for k in gone {
				delete(h.cache[kind][k])
				delete_key(&h.cache[kind], k)
			}
		},
		start = proc(data: rawptr, op: ^Remote_Op) {
			h := (^Model_Host)(data)
			// The host's copy, for the op itself belongs to the Remote.
			c := new(Remote_Op)
			c^ = op^
			c.body = slice.clone(op.body)
			c.objects = slice.clone(op.objects)
			if op.kind == .Put_Extent {
				c.body = make([]byte, op.len)
				if !memory_disk(&h.local).log_read(&h.local, op.off, c.body) {
					delete(c.body)
					c.body = nil // it cannot be read: the put fails
				}
			}
			append(&h.ops, c)
		},
		now = proc(data: rawptr) -> u64 {
			return (^Model_Host)(data).clock
		},
	}
}

@(private)
model_land :: proc(h: ^Model_Host, op: ^Remote_Op) {
	switch op.kind {
	case .Put_Pack:
		h.class_a += 1
		h.objects[{op.number, true}] = slice.clone(op.body)
	case .Put_Extent:
		h.class_a += 1
		if op.body != nil {
			h.objects[{op.number, false}] = slice.clone(op.body)
		}
	case .Delete:
		for o in op.objects {
			if old, ok := h.objects[o]; ok {
				delete(old)
				delete_key(&h.objects, o)
			}
		}
	case .Get_Pages, .Get_Log, .Get_Hints:
		h.class_b += 1
	}
}

@(private)
model_free :: proc(op: ^Remote_Op) {
	delete(op.body)
	delete(op.objects)
	free(op)
}

// Answers some of what is under way, in any order. Returns how many.
@(private)
model_tick :: proc(h: ^Model_Host, r: ^Remote, most: int) -> (answered: int) {
	for _ in 0 ..< most {
		h.clock += 50
		#reverse for z, i in h.zombies {
			if rand.int_max(256) == 0 || h.clock >= z.dies {
				// A put from before the crash lands now, or never.
				unordered_remove(&h.zombies, i)
				if rand.int_max(2) == 0 {
					model_land(h, z.op)
				}
				model_free(z.op)
			}
		}
		if len(h.ops) == 0 {
			return
		}
		i := rand.int_max(len(h.ops))
		op := h.ops[i]
		unordered_remove(&h.ops, i)
		answered += 1
		failed := h.fail > 0 && rand.int_max(h.fail) == 0
		switch op.kind {
		case .Get_Pages, .Get_Log, .Get_Hints:
			model_land(h, op)
			o := Remote_Object{op.number, b64(op.kind != .Get_Log)}
			bytes, there := h.objects[o]
			if failed || !there {
				remote_done(r, op.id, !failed, absent = !there)
			} else {
				lo := min(int(op.off), len(bytes))
				hi := min(int(op.off + op.len), len(bytes))
				remote_done(r, op.id, true, bytes = bytes[lo:hi])
			}
		case .Put_Pack, .Put_Extent, .Delete:
			// It may fail, or seem to, having landed all the same.
			if !failed || rand.int_max(2) == 0 {
				model_land(h, op)
			}
			remote_done(r, op.id, !failed && op.body != nil || op.kind == .Delete && !failed)
		}
		model_free(op)
	}
	return
}

// The host dies: what its own storage had not synced is partly lost, its cache partly, and what it had under way
// is in flight still, to land or not.
@(private)
model_crash :: proc(h: ^Model_Host) {
	m := &h.local
	if end := memory_disk_end(m); end > m.kept && m.kept / SEGMENT == end / SEGMENT {
		memory_disk(m).log_truncate(m, m.kept + u64(rand.int_max(int(end - m.kept) + 1)))
	}
	for kind in Cached {
		for k in sorted_keys(h.cache[kind]) {
			if rand.int_max(3) == 0 {
				delete(h.cache[kind][k])
				delete_key(&h.cache[kind], k)
			}
		}
	}
	for op in h.ops {
		if op.kind == .Put_Pack || op.kind == .Put_Extent || op.kind == .Delete {
			append(&h.zombies, Zombie{op, h.clock + u64(rand.int_max(ZOMBIE_LIFE))})
		} else {
			model_free(op)
		}
	}
	clear(&h.ops)
}

@(private)
model_host_destroy :: proc(h: ^Model_Host) {
	memory_disk_destroy(&h.local)
	delete(h.manifest)
	for kind in Cached {
		for _, b in h.cache[kind] {
			delete(b)
		}
		delete(h.cache[kind])
	}
	for _, b in h.objects {
		delete(b)
	}
	delete(h.objects)
	for op in h.ops {
		model_free(op)
	}
	for z in h.zombies {
		model_free(z.op)
	}
	delete(h.ops)
	delete(h.zombies)
}

@(private)
Remote_Store :: struct {
	host:   Model_Host,
	remote: Remote,
	store:  Store,
}

@(private)
remote_store_open :: proc(t: ^testing.T, x: ^Remote_Store, pages := 64, blocks := 8) {
	testing.expect(t, remote_open(&x.remote, model_host(&x.host), pages, blocks))
	x.store.remote = &x.remote
	testing.expect(t, store_open(&x.store, remote_disk(&x.remote)))
	x.remote.store = &x.store
}

@(private)
remote_store_close :: proc(x: ^Remote_Store) {
	store_close(&x.store)
	remote_close(&x.remote)
}

// Does whatever is due, and answers some of what is under way. Returns whether anything waits.
@(private)
remote_store_turn :: proc(x: ^Remote_Store, answers: int) -> bool {
	waiting := store_work(&x.store)
	waiting = remote_work(&x.remote) || waiting
	remote_ops(&x.remote)
	n := model_tick(&x.host, &x.remote, answers)
	remote_rest(&x.remote)
	return waiting || n > 0 || len(x.host.ops) > 0
}

// Until nothing is under way or wanted.
@(private)
remote_store_settle :: proc(t: ^testing.T, x: ^Remote_Store) {
	for round := 0; remote_store_turn(x, 1 << 20); round += 1 {
		if round > 100_000 {
			r := &x.remote
			testing.expectf(t, false, "stuck: ops %d zombies %d inflight %v gc %v/%v slot %v asked %v wantp %d wantb %d gettingp %d gettingb %d replaying %v evac %v dirty %d pending %d acc %d uploading %d uploaded %d synced %d tail %d dropped %v evacuated %v",
				len(x.host.ops), len(x.host.zombies), r.inflight != nil, r.gc.active, r.gc.gen, r.gc.slot, r.gc.asked, len(r.want_pages), len(r.want_blocks), len(r.getting_pages), len(r.getting_blocks),
				x.store.replaying, x.store.evac, len(x.store.dirty), len(x.store.pending), r.accounted, r.uploading, r.uploaded, x.store.synced, store_tail(&x.store), x.store.dropped[:], x.store.evacuated[:])
			testing.fail_now(t, "never settles")
		}
	}
}

// A step, done again until it reads nothing missing.
@(private)
remote_store_step :: proc(t: ^testing.T, x: ^Remote_Store, data: rawptr, f: proc(s: ^Store, data: rawptr)) {
	for tries := 0; ; tries += 1 {
		st := store_begin(&x.store)
		f(&x.store, data)
		if !store_missed(&x.store, &st) {
			store_end(&x.store, &st, true)
			return
		}
		store_end(&x.store, &st, false)
		remote_ops(&x.remote)
		model_tick(&x.host, &x.remote, 4)
		if tries > 100_000 {
			r := &x.remote
			testing.expectf(t, false, "stuck step: failed %v ops %d wantp %v wantb %v gettingp %d gettingb %d pages %d blocks %d local_from %d uploaded %d",
				x.store.failed, len(x.host.ops), len(r.want_pages), len(r.want_blocks), len(r.getting_pages), len(r.getting_blocks), len(r.pages), len(r.blocks), r.local_from, r.uploaded)
			fmt.println("seed/round", context.user_index)
			testing.fail_now(t, "a step never has what it reads")
		}
	}
}

@(private)
remote_census :: proc(t: ^testing.T, x: ^Remote_Store) -> (c: Census) {
	remote_store_step(t, x, &c, proc(s: ^Store, data: rawptr) {
		(^Census)(data)^ = census(s)
	})
	return
}

// What check_shelf checks, as an answer: within a step, what is read may be nonsense until it is all at hand.
@(private)
shelf_sound :: proc(s: ^Store) -> bool {
	expect := 0
	scan := tree_scan(s, s.cells, KEY_MIN, KEY_MAX)
	last: Id
	for leaf in tree_next(&scan) {
		row := Id{leaf.key[0], leaf.key[1]}
		if row == last {
			continue
		}
		last = row
		places := row_places(s, row)
		expect += places.count
		for k in places.keys[:places.count] {
			v, ok := tree_get(s, s.shelf, k)
			if !ok || v != row_print(s, row) {
				return false
			}
		}
	}
	return store_range(s, KEY_MIN, KEY_MAX).count == expect
}

// The books: each pack's count of live pages is what the trees reach of it, less what has been given up and not yet
// counted against it. An answer, as shelf_sound's is.
@(private)
books_balance :: proc(s: ^Store) -> (ok: bool) {
	r := s.remote
	reached := make(map[u64]u64, context.temp_allocator)
	walk :: proc(s: ^Store, no: Page_No, reached: ^map[u64]u64) {
		if no < TEMP_PAGES {
			reached[no >> PACK_SHIFT] += 1
		}
		pg := page(s, no)
		if pg.level > 0 {
			for e in pg.branch[:pg.count] {
				walk(s, e.child, reached)
			}
		}
	}
	for t in ([]Tree{s.shelf, s.cells, s.waste, s.outbox, s.repair, r.packs}) {
		if t.root != 0 {
			walk(s, t.root, &reached)
		}
	}
	for no in s.pending[r.accounted:] {
		reached[no >> PACK_SHIFT] += 1
	}
	ok = true
	scan := tree_scan(s, r.packs, KEY_MIN, KEY_MAX)
	seen := 0
	for leaf in tree_next(&scan) {
		g := leaf.key[4]
		if f, flying := r.inflight.?; flying && f.gen == g {
			continue
		}
		if leaf.val[1] == 0 {
			continue // the next pack's entry, before it has pages
		}
		seen += 1
		if reached[g] != leaf.val[0] {
			ok = false
		}
	}
	for g, n in reached {
		if f, flying := r.inflight.?; flying && f.gen == g {
			continue
		}
		if _, there := tree_get(s, r.packs, {0, 0, 0, 0, g}); !there && n > 0 {
			ok = false
		}
	}
	return
}

// Every page the trees reach, as object storage has it, bypassing every cache: what a cache would hide.
@(private)
objects_sound :: proc(s: ^Store, h: ^Model_Host) -> bool {
	Walk :: struct {
		h:  ^Model_Host,
		ok: bool,
	}
	walk :: proc(s: ^Store, no: Page_No, w: ^Walk) {
		pg := page(s, no)
		if no < TEMP_PAGES && no not_in s.remote.flushing {
			bytes, there := w.h.objects[{no >> PACK_SHIFT, true}]
			at := int(no & (1 << PACK_SHIFT - 1)) * PAGE_SIZE
			if !there || at + size_of(Page) > len(bytes) || string(bytes[at:][:size_of(Page)]) != string(([^]byte)(pg)[:size_of(Page)]) {
				w.ok = false
			}
		}
		if pg.level > 0 {
			for e in pg.branch[:pg.count] {
				walk(s, e.child, w)
			}
		}
	}
	w := Walk{h, true}
	for t in ([]Tree{s.shelf, s.cells, s.waste, s.outbox, s.repair, s.remote.packs}) {
		if t.root != 0 {
			walk(s, t.root, &w)
		}
	}
	return w.ok
}

// Every acknowledged commit survives every crash, nothing stale is ever read back, nothing is left in object storage
// that nothing names, and the store holds just what one that always answers holds.
@(test)
remote_store_matches_quick :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_REMOTE_SEEDS, 6)
	for seed in 0 ..< SEEDS {
		state := seeded(u64(seed) + 900)
		context.random_generator = rand.default_random_generator(&state)
		x: Remote_Store
		x.host.fail = 0 if seed == 0 else 5
		defer model_host_destroy(&x.host)
		remote_store_open(t, &x)
		remote_store_settle(t, &x)
		batches := make([dynamic][]Cell)
		defer {
			for b in batches {
				for c in b {
					delete(c.body)
				}
				delete(b)
			}
			delete(batches)
		}
		quick :: proc(batches: [][]Cell) -> (c: Census) {
			m: Memory_Disk
			defer memory_disk_destroy(&m)
			q: Store
			_ = store_open(&q, memory_disk(&m))
			defer store_close(&q)
			for b in batches {
				store_commit(&q, b)
			}
			return census(&q)
		}
		crashes, checkpoints := 0, 0
		for round in 0 ..< 600 {
			context.user_index = seed * 1000 + round
			cells := make([]Cell, 1 + rand.int_max(8))
			for &c in cells {
				c = random_cell(400, 1_000_000)
				if rand.int_max(3) == 0 && (c.kind == .Value || c.kind == .Piece) {
					c.body = make([]byte, 300 + rand.int_max(4000), context.temp_allocator)
				}
				c.body = slice.clone(c.body)
			}
			append(&batches, cells)
			remote_store_step(t, &x, &cells, proc(s: ^Store, data: rawptr) {
				store_commit(s, (^[]Cell)(data)^)
			})
			// Acknowledged, unless the host is about to die.
			dying := rand.int_max(30) == 0
			if !dying || rand.int_max(2) == 0 {
				testing.expect(t, store_sync(&x.store))
			} else {
				store_flush(&x.store)
			}
			for _ in 0 ..< rand.int_max(3) {
				remote_store_turn(&x, rand.int_max(6))
			}
			if dying {
				synced := !store_unsynced(&x.store)
				if rand.int_max(2) == 0 {
					// Mid-checkpoint: its pack is under way, and perhaps lands after.
					x.remote.want_checkpoint = true
					remote_work(&x.remote)
					remote_ops(&x.remote)
					model_tick(&x.host, &x.remote, rand.int_max(3))
				}
				model_crash(&x.host)
				checkpoints += x.remote.stats.checkpoints
				remote_store_close(&x)
				remote_store_open(t, &x)
				if rand.int_max(2) == 0 {
					remote_store_settle(t, &x)
				} else {
					// Opened, and on with more before anything else: the next checkpoint differs from the one lost.
					for x.store.replaying {
						store_work(&x.store)
						remote_ops(&x.remote)
						model_tick(&x.host, &x.remote, 16)
					}
				}
				crashes += 1
				got := remote_census(t, &x)
				if got != quick(batches[:]) {
					// Only what was not acknowledged may be lost, and then the whole of it.
					testing.expectf(t, !synced, "seed %d round %d: an acknowledged commit was lost", seed, round)
					last := pop(&batches)
					for c in last {
						delete(c.body)
					}
					delete(last)
					testing.expectf(t, got == quick(batches[:]), "seed %d round %d: what came back is not what was", seed, round)
				}
			}
			if round % 75 == 74 {
				remote_store_settle(t, &x)
				testing.expectf(t, remote_census(t, &x) == quick(batches[:]), "seed %d round %d: differs", seed, round)
				sound := false
				remote_store_step(t, &x, &sound, proc(s: ^Store, data: rawptr) {
					(^bool)(data)^ = shelf_sound(s)
				})
				testing.expectf(t, sound, "seed %d round %d: the shelf is not what the cells say", seed, round)
				Check :: struct {
					h:  ^Model_Host,
					ok: bool,
				}
				c := Check{&x.host, false}
				remote_store_step(t, &x, &c, proc(s: ^Store, data: rawptr) {
					c := (^Check)(data)
					c.ok = objects_sound(s, c.h)
				})
				testing.expectf(t, c.ok, "seed %d round %d: object storage holds other than what the store reads", seed, round)
			}
			balanced := false
			remote_store_step(t, &x, &balanced, proc(s: ^Store, data: rawptr) {
				(^bool)(data)^ = books_balance(s)
			})
			testing.expectf(t, balanced, "seed %d round %d: the books do not balance", seed, round)
			testing.expect_value(t, x.remote.unguarded, 0)
			testing.expectf(t, !x.store.failed, "seed %d round %d: failed", seed, round)
			free_all(context.temp_allocator)
			if testing.failed(t) {
				fmt.println("seed", seed, "round", round)
				remote_store_close(&x)
				return
			}
		}
		// Everything in object storage is something the store names: once whatever was under way when it crashed has
		// landed or not, and what was deleted has been deleted again.
		for z in x.host.zombies {
			model_land(&x.host, z.op)
			model_free(z.op)
		}
		clear(&x.host.zombies)
		x.host.clock += REDELETE_AFTER
		for _ in 0 ..< 3 {
			x.remote.want_checkpoint = true
			remote_store_settle(t, &x)
		}
		live := make(map[u64]bool, context.temp_allocator)
		remote_store_step(t, &x, &live, proc(s: ^Store, data: rawptr) {
			live := (^map[u64]bool)(data)
			clear(live)
			scan := tree_scan(s, s.remote.packs, KEY_MIN, KEY_MAX)
			for leaf in tree_next(&scan) {
				live[leaf.key[4]] = true
			}
		})
		for o in x.host.objects {
			if o.pack {
				testing.expectf(t, live[o.number], "seed %d: pack %d is named by nothing", seed, o.number)
			} else {
				testing.expectf(t, o.number * EXTENT < store_tail(&x.store), "seed %d: extent %d is past the end", seed, o.number)
			}
		}
		for g in live {
			testing.expectf(t, Remote_Object{g, true} in x.host.objects, "seed %d: pack %d is named and gone", seed, g)
		}
		checkpoints += x.remote.stats.checkpoints
		testing.expectf(t, crashes > 0 && checkpoints > 10, "seed %d: %d crashes, %d checkpoints", seed, crashes, checkpoints)
		remote_store_close(&x)
	}
}
