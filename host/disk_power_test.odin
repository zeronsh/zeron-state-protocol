package host

import "core:crypto"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "../zsp"

// Power lost at any point of what a host asked of its files, with real files and the host's own File_Disk: the host's
// thread is a test's here (Disk_Queue.hook), which makes each fsync it was given whenever it likes, of whichever file,
// and notes what each made durable, as it notes each write the loop makes (Disk_Queue.noted). Power going leaves, of
// each file, the writes an fsync of it made since made durable, and of the rest whatever the disk got to, each perhaps
// torn. A store opened on that has every commit the store counted as synced, and reads back each as it was written.
//
// And the process killed outright, as it may be at any point too, without power going: what it wrote is there, durable
// or not, and a host opens on it and goes on, until power goes later. What it replays from a log it did not make
// durable, it must, before it counts on it.

@(private = "file")
Noted :: struct {
	path:      string,
	at:        i64,
	bytes:     []byte,
	truncated: bool, // cut short there, which is taken as durable at once
	durable:   bool,
}

@(private = "file")
Power :: struct {
	given:  [dynamic]^Disk_Op, // fsyncs given the test's thread, not yet made
	noted:  [dynamic]Noted, // in the order made
	dead:   bool, // of a host killed: what it does as it is let go of is nobody's
	syncs:  int, // made
	twice:  int, // made of a file let go of meanwhile, and so closed only after
}

@(private = "file", thread_local)
power: Power // each test's own, as tests run beside each other

@(private = "file")
power_note :: proc(h: ^Host, f: ^os.File, at: i64, bytes: []byte, truncated: bool) {
	if !power.dead {
		append(&power.noted, Noted{strings.clone(filepath.base(os.name(f))), at, slice.clone(bytes), truncated, truncated})
	}
}

@(private = "file")
power_give :: proc(h: ^Host, op: ^Disk_Op) {
	append(&power.given, op)
}

// Makes the fsync given, as the thread would, now.
@(private = "file")
power_do :: proc(h: ^Host, i: int) {
	op := power.given[i]
	unordered_remove(&power.given, i)
	power.twice += int(op.file.closing && !power.dead) // let go of before its fsync was made
	disk_do(op)
	if !power.dead && op.ok {
		power_durable(filepath.base(os.name(op.file.file)))
	}
	disk_done(h, op)
}

@(private = "file")
power_hooks :: proc(h: ^Host) {
	h.disk.hook = power_give
	h.disk.waiting = proc(h: ^Host) {
		if len(power.given) > 0 {
			power_do(h, rand.int_max(len(power.given)))
		}
	}
	h.disk.noted = power_note
	h.disk.synced = proc(h: ^Host, f: ^os.File) {
		if !power.dead {
			power_durable(filepath.base(os.name(f)))
		}
	}
}

// What was written of a file before an fsync of it is durable.
@(private = "file")
power_durable :: proc(path: string) {
	for &w in power.noted {
		w.durable ||= w.path == path
	}
	power.syncs += 1
}

// The files of the log and the pages as power lost would leave them, the rest as they are, in a directory of their own.
@(private = "file")
power_image :: proc(dir, into: string) {
	os.make_directory_all(into)
	noted := make(map[string]bool, context.temp_allocator)
	for w in power.noted {
		noted[w.path] = true
	}
	files, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for f in files {
		if f.type != .Directory && f.name not_in noted {
			data, _ := os.read_entire_file(f.fullpath, context.temp_allocator)
			_ = os.write_entire_file(file_in(into, f.name), data)
		}
	}
	for path in noted {
		if !os.exists(file_in(dir, path)) {
			continue // dropped, which is taken as durable at once
		}
		image: [dynamic]byte
		defer delete(image)
		for w in power.noted {
			if w.path != path {
				continue
			}
			if w.truncated {
				resize(&image, min(len(image), int(w.at)))
				continue
			}
			n := len(w.bytes)
			if !w.durable {
				switch rand.int_max(3) {
				case 0:
					n = 0
				case 1:
					n = rand.int_max(n + 1)
				}
			}
			if int(w.at) + n > len(image) {
				resize(&image, int(w.at) + n)
			}
			copy(image[w.at:], w.bytes[:n])
		}
		_ = os.write_entire_file(file_in(into, path), image[:])
	}
}

// The process killed: every file as it is, in the system's keeping, in a directory of its own, and what was noted of
// them noted of their copies, which have their names. What was not yet made of the fsyncs given never will be.
@(private = "file")
power_kill :: proc(dir, into: string) {
	os.make_directory_all(into)
	files, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for f in files {
		if f.type != .Directory {
			data, _ := os.read_entire_file(f.fullpath, context.temp_allocator)
			_ = os.write_entire_file(file_in(into, f.name), data)
		}
	}
}

@(private = "file")
power_reset :: proc() {
	for w in power.noted {
		delete(w.path)
		delete(w.bytes)
	}
	delete(power.noted)
	delete(power.given)
	power = {}
}

@(private = "file")
power_body :: proc(stamp: u64, size: int) -> []byte {
	b := make([]byte, size, context.temp_allocator)
	for &x, i in b {
		x = byte(stamp * 31 + u64(i) * 7)
	}
	return b
}

// Lets go of a host killed: what it does as it is let go of, closing its spaces, is not noted, as it never happened.
@(private = "file")
power_bury :: proc(h: ^Host) {
	power.dead = true
	for len(power.given) > 0 {
		power_do(h, 0)
	}
	host_destroy(h)
	power.dead = false
	clear(&power.given)
}

@(test)
power_cuts_lose_nothing_the_host_counted_on :: proc(t: ^testing.T) {
	SEEDS :: 30
	kills, twice, syncs, rolled := 0, 0, 0, 0
	for seed in 0 ..< u64(SEEDS) {
		state := rand.create(seed + 9100)
		context.random_generator = rand.default_random_generator(&state)
		base, _ := os.temp_directory(context.temp_allocator)
		root, err := os.make_directory_temp(base, "zsp-power-*", context.allocator)
		testing.expect(t, err == nil)
		defer delete(root)
		defer os.remove_all(root)
		space: zsp.Key32
		crypto.rand_bytes(space[:])
		h := new(Host)
		defer free(h)
		dir := file_in(root, "a")
		power_hooks(h)
		testing.expect(t, host_init(h, {dir = dir, full = true}))
		power_hooks(h)
		sp := space_open(h, space)
		size := max(zsp.SEGMENT / 128, 64)
		ROWS :: 400
		stamp := u64(1)
		Wrote :: struct {
			stamp, end: u64,
		}
		wrote: map[u64][dynamic]Wrote
		defer {
			for _, w in wrote {
				delete(w)
			}
			delete(wrote)
		}
		// What any start before counted as synced, and so must be there whatever comes after.
		kept: map[u64]u64
		defer delete(kept)
		lives := 1 + rand.int_max(3)
		for life in 0 ..< lives {
			st := &sp.node.store
			for step in 0 ..< 150 + rand.int_max(900) {
				switch r := rand.int_max(100); {
				case r < 45:
					n := u64(rand.int_max(ROWS)) + 1
					c := zsp.Cell{row = {1 << 32, n}, slot = 16, kind = .Value, stamp = {stamp, 0}, body = power_body(stamp, size)}
					if zsp.store_commit(st, {c}) == 1 {
						if n not_in wrote {
							wrote[n] = {}
						}
						append(&wrote[n], Wrote{stamp, zsp.store_tail(st)})
					}
					stamp += 1
				case r < 55:
					zsp.store_flush(st)
				case r < 65:
					testing.expect(t, zsp.store_sync_start(st))
				case r < 73:
					testing.expect(t, zsp.store_checkpoint_start(st))
				case r < 75:
					// One that must be had at once, the last perhaps under way: as node_level, retaining or a roster asks.
					testing.expect(t, zsp.store_checkpoint(st))
				case r < 95:
					if len(power.given) > 0 {
						power_do(h, rand.int_max(len(power.given)))
					}
				case:
					disk_collect(h)
				}
				if step % 5 == 0 {
					disk_collect(h)
					file_disk_settle(&sp.disk)
				}
			}
			for n, w in wrote {
				for x in w {
					if x.end <= st.synced {
						kept[n] = max(kept[n], x.stamp)
					}
				}
			}
			clear(&wrote)
			if life == lives - 1 {
				break
			}
			// Killed, here and now, and started again on what it left: half the time just after the log has gone on from a
			// segment it has not yet made durable, which it may have to replay from.
			if rand.int_max(2) == 0 {
				for i := 0; i < 4000 && len(sp.disk.rolled) == 0; i += 1 {
					n := u64(rand.int_max(ROWS)) + 1
					c := zsp.Cell{row = {1 << 32, n}, slot = 16, kind = .Value, stamp = {stamp, 0}, body = power_body(stamp, size)}
					stamp += 1
					zsp.store_commit(st, {c})
					zsp.store_flush(st)
				}
				rolled += int(len(sp.disk.rolled) > 0)
			}
			kills += 1
			names := [3]string{"b", "c", "d"}
			next := file_in(root, names[life])
			power_kill(sp.dir, file_in(next, filepath.base(sp.dir)))
			for name in ([]string{"device.key"}) {
				data, _ := os.read_entire_file(file_in(dir, name), context.temp_allocator)
				_ = os.write_entire_file(file_in(next, name), data)
			}
			power_bury(h)
			h^ = {}
			dir = next
			power_hooks(h)
			testing.expect(t, host_init(h, {dir = dir, full = true}))
			power_hooks(h)
			sp = space_open(h, space)
			testing.expectf(t, sp != nil && !sp.node.failed, "seed %d: the space opens again after it was killed", seed)
			if t.error_count > 0 {
				break
			}
		}
		twice += power.twice
		syncs += power.syncs
		image := file_in(root, "image")
		power_image(sp.dir, image)
		power_bury(h)
		d: File_Disk
		testing.expect(t, file_disk_open(&d, image))
		s: zsp.Store
		testing.expectf(t, zsp.store_open(&s, file_disk(&d)), "seed %d: the store opens", seed)
		for n in 1 ..= u64(ROWS) {
			want := kept[n] or_else 0
			got := u64(0)
			scan := zsp.row_scan(&s, {1 << 32, n}, 16, 16)
			for c in zsp.row_next(&s, &scan) {
				got = max(got, c.stamp.time)
				if string(c.body) != string(power_body(c.stamp.time, size)) {
					testing.expectf(t, false, "seed %d: row %d's value of %d reads back otherwise", seed, n, c.stamp.time)
				}
			}
			testing.expectf(t, got >= want, "seed %d: row %d holds %d, not %d, which was synced", seed, n, got, want)
		}
		testing.expect(t, !s.failed)
		zsp.store_close(&s)
		power_reset()
		if t.error_count > 0 {
			return
		}
	}
	testing.expectf(t, kills > 0 && rolled > 0 && twice > 0 && syncs > 0, "killed %d times, %d with a segment gone on from not yet durable; fsyncs of a file let go of meanwhile %d, %d made", kills, rolled, twice, syncs)
}

// A file is closed only once nothing asked of it is left, however many fsyncs of it were asked, and whoever let go of it
// meanwhile; one that failed fails each after it, though the store no longer waited for it.
@(test)
a_file_outlives_what_is_asked_of_it :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-queue-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	h: Host
	h.disk.hook = power_give
	defer power_reset()
	f, ferr := os.open(file_in(dir, "x"), {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
	testing.expect(t, ferr == nil)
	disk_sync_ask(&h, 1, f)
	disk_sync_ask(&h, 2, f)
	id := disk_release(&h, f)
	testing.expect(t, id != 0 && disk_known(&h, id))
	testing.expect_value(t, len(power.given), 1) // one at a time
	first := power.given[0]
	clear(&power.given)
	first.ok = false // as an fsync that failed, whose store no longer waits
	disk_done(&h, first)
	disk_advance(&h)
	testing.expect(t, len(h.disk.files) == 1 && len(power.given) == 1, "still open, the second given")
	second := power.given[0]
	clear(&power.given)
	testing.expect(t, os.sync(second.file.file) == nil, "a file asked an fsync is open")
	second.ok = true
	disk_done(&h, second)
	disk_advance(&h)
	testing.expect_value(t, len(h.disk.files), 0) // closed, now nothing is asked of it
	// And known to be, though another file is given its handle's address, as the allocator may give it.
	_ = disk_file(&h, f)
	testing.expect(t, !disk_known(&h, id), "a file closed is not taken for whatever has its handle's address now")
	testing.expect(t, len(h.disk.answers) == 2 && !h.disk.answers[0].ok && !h.disk.answers[1].ok, "the second fails, as the first did")
	disk_end(&h)
}

// A segment dropped is removed only once nothing asked of it is left to do: else an fsync of it would be of nothing,
// and on Windows the removal fails while the thread holds it. One whose removal fails is removed at a later settle,
// rather than left for good with nothing to say it is there.
@(test)
a_segment_is_dropped_after_what_is_asked_of_it :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-drop-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	defer power_reset()
	h: Host
	testing.expect(t, host_init(&h, {dir = dir, full = true}))
	@(thread_local) gone_first: bool
	h.disk.hook = power_give
	h.disk.waiting = proc(h: ^Host) {
		for len(power.given) > 0 {
			op := power.given[0]
			gone_first ||= !os.exists(os.name(op.file.file)) // the system's own name for it, whatever it was opened by
			unordered_remove(&power.given, 0)
			disk_do(op)
			disk_done(h, op)
		}
	}
	space: zsp.Key32
	crypto.rand_bytes(space[:])
	sp := space_open(&h, space)
	st := &sp.node.store
	body := make([]byte, 4000)
	defer delete(body)
	for i := u64(0); zsp.store_tail(st) < zsp.SEGMENT + 4096; i += 1 {
		zsp.store_commit(st, {{row = {1, 100 + i}, slot = 16, kind = .Value, stamp = {1000 + i, 1}, body = body}})
		zsp.store_flush(st)
	}
	testing.expect(t, zsp.store_sync_start(st) && len(power.given) > 0) // segment 0's fsync, given and not yet made
	first := segment_path(&sp.disk, 0)
	st.disk.log_drop(st.disk.data, 0)
	testing.expect(t, !gone_first, "made before the segment went")
	testing.expect(t, !os.exists(first) && len(sp.disk.unremoved) == 0)
	when ODIN_OS != .Windows {
		// A removal that fails, here by a directory that may not be changed, is made again later.
		second := segment_path(&sp.disk, 1)
		os.chmod(sp.dir, {.Read_User, .Execute_User})
		st.disk.log_drop(st.disk.data, 1)
		testing.expect(t, os.exists(second) && len(sp.disk.unremoved) == 1)
		os.chmod(sp.dir, {.Read_User, .Write_User, .Execute_User})
		file_disk_settle(&sp.disk)
		testing.expect(t, !os.exists(second) && len(sp.disk.unremoved) == 0)
	}
	h.disk.waiting(&h)
	testing.expect(t, !gone_first, "no fsync is made of a segment gone")
	disk_collect(&h)
	host_destroy(&h)
}
