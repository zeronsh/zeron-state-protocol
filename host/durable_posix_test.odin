#+build !windows
package host

import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "../zsp"

@(private = "file")
Seen :: struct {
	dev, ino: u64,
	how:      Synced,
}

// Every sync made for durability while a test below looks, by any test: each its file's, as fstat says.
@(private = "file")
seen: [1 << 16]Seen
@(private = "file")
seen_n: int // atomic

// Held by each test that looks, for as long as it does: so that no other's end stops it looking.
@(private = "file")
looking: sync.Mutex

@(private = "file")
see :: proc(fd: posix.FD, how: Synced) {
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return
	}
	if i := sync.atomic_add(&seen_n, 1); i < len(seen) {
		seen[i] = {u64(st.st_dev), u64(st.st_ino), how}
	}
}

// How the file at a path was last synced since the mark, if it was.
@(private = "file")
synced_since :: proc(mark: int, path: string) -> Synced {
	st: posix.stat_t
	if posix.stat(cstring_of(path), &st) != .OK {
		return .Failed
	}
	how := Synced.Failed
	for s in seen[mark:min(sync.atomic_load(&seen_n), len(seen))] {
		if s.dev == u64(st.st_dev) && s.ino == u64(st.st_ino) {
			how = s.how
		}
	}
	return how
}

@(private = "file")
cstring_of :: proc(s: string) -> cstring {
	b := make([]byte, len(s) + 1, context.temp_allocator)
	copy(b, s)
	return cstring(raw_data(b))
}

// A store's syncs keep what it says is kept through a loss of power: on macOS F_FULLFSYNC's, which an fsync there is
// not; and the names of the files it makes, and its directory's, in the directory each is in, before anything written to
// them is said to be kept, which a sync of the file alone does not keep; and a save, its directory too.
@(test)
durable_syncs_keep_files_and_names :: proc(t: ^testing.T) {
	FULL :: Synced.Full when ODIN_OS == .Darwin else Synced.Fsync
	base, _ := os.temp_directory(context.temp_allocator)
	top, err := os.make_directory_temp(base, "zsp-durable-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(top)
	defer os.remove_all(top)
	sync.guard(&looking)
	sync.atomic_store(&durable_hook, see)
	defer sync.atomic_store(&durable_hook, nil)

	// A store where there was none: made by what it first writes.
	dir := file_in(top, "store")
	d: File_Disk
	testing.expect(t, file_disk_open(&d, dir, false))
	disk := file_disk(&d)
	defer disk.close(disk.data)
	mark := sync.atomic_load(&seen_n)
	testing.expect(t, disk.log_write(disk.data, 0, transmute([]byte)string("kept")))
	testing.expect(t, disk.log_sync(disk.data))
	testing.expect_value(t, synced_since(mark, segment_path(&d, 0)), FULL)
	testing.expect_value(t, synced_since(mark, dir), FULL) // the segment's name, and the tree's
	testing.expect_value(t, synced_since(mark, top), FULL) // the store's own

	page: [zsp.PAGE_SIZE]byte
	mark = sync.atomic_load(&seen_n)
	testing.expect(t, disk.page_write(disk.data, 0, page[:]))
	testing.expect(t, disk.page_sync(disk.data))
	testing.expect_value(t, synced_since(mark, file_in(dir, "tree")), FULL)
	testing.expect_value(t, synced_since(mark, dir), Synced.Failed) // kept already, with the segment's

	// A segment made later, its name too.
	mark = sync.atomic_load(&seen_n)
	testing.expect(t, disk.log_write(disk.data, zsp.SEGMENT, transmute([]byte)string("more")))
	testing.expect(t, disk.log_sync(disk.data))
	testing.expect_value(t, synced_since(mark, segment_path(&d, 0)), Synced.Failed) // nothing written there since
	testing.expect_value(t, synced_since(mark, segment_path(&d, 1)), FULL)
	testing.expect_value(t, synced_since(mark, dir), FULL)

	// And one removed, which is not to come back; and the cut, with nothing written after it.
	mark = sync.atomic_load(&seen_n)
	disk.log_truncate(disk.data, 4)
	testing.expect(t, !os.exists(segment_path(&d, 1)))
	testing.expect(t, disk.log_sync(disk.data))
	testing.expect_value(t, synced_since(mark, dir), FULL)
	testing.expect_value(t, synced_since(mark, segment_path(&d, 0)), FULL)

	mark = sync.atomic_load(&seen_n)
	path := file_in(top, "saved")
	testing.expect(t, save(path, transmute([]byte)string("whole")))
	testing.expect_value(t, synced_since(mark, path), FULL)
	testing.expect_value(t, synced_since(mark, top), FULL)
}

// Every directory made is kept as it is made, with each above it that was made with it and the one they were made in,
// by whatever makes it: before anything is saved or written in it, which would else be kept in a directory that a loss
// of power could take away, with all in it. A directory there already costs nothing.
@(test)
durable_dirs_made_are_kept :: proc(t: ^testing.T) {
	FULL :: Synced.Full when ODIN_OS == .Darwin else Synced.Fsync
	base, _ := os.temp_directory(context.temp_allocator)
	top, err := os.make_directory_temp(base, "zsp-made-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(top)
	defer os.remove_all(top)
	sync.guard(&looking)
	sync.atomic_store(&durable_hook, see)
	defer sync.atomic_store(&durable_hook, nil)

	// A store's directory held, as zspd and a relay hold theirs.
	held := file_in(file_in(top, "a"), "b")
	mark := sync.atomic_load(&seen_n)
	lock, ok := dir_hold(held)
	testing.expect(t, ok)
	testing.expect_value(t, synced_since(mark, held), FULL)
	testing.expect_value(t, synced_since(mark, file_in(top, "a")), FULL)
	testing.expect_value(t, synced_since(mark, top), FULL)
	dir_unlock(lock)
	mark = sync.atomic_load(&seen_n)
	lock, ok = dir_hold(held)
	testing.expect(t, ok)
	for there in ([]string{held, file_in(top, "a"), top}) {
		testing.expect_value(t, synced_since(mark, there), Synced.Failed) // there already
	}
	dir_unlock(lock)

	// A device's directory, as a node starting or a command makes it.
	starting := file_in(file_in(top, "c"), "d")
	mark = sync.atomic_load(&seen_n)
	start, started := dir_starting(starting)
	testing.expect(t, started)
	testing.expect_value(t, synced_since(mark, starting), FULL)
	testing.expect_value(t, synced_since(mark, file_in(top, "c")), FULL)
	testing.expect_value(t, synced_since(mark, top), FULL)
	dir_started(start)

	// A store's, as it first keeps something, held or not.
	for hold in ([]bool{false, true}) {
		dir := file_in(file_in(top, "e" if hold else "f"), "store")
		d: File_Disk
		testing.expect(t, file_disk_open(&d, dir, hold))
		mark = sync.atomic_load(&seen_n)
		testing.expect(t, file_disk_make(&d))
		testing.expect_value(t, synced_since(mark, dir), FULL)
		testing.expect_value(t, synced_since(mark, os.dir(dir)), FULL)
		testing.expect_value(t, synced_since(mark, top), FULL)
		file_disk_close(&d)
	}
}

// A space's keys, kept in a store that was not there before, as a node keeps them, and its roster, on learning them (see
// space_open's keep and roster, which make the store alike): kept with the store's own name, before any sync of its log
// or pages, which may be long after or never.
@(test)
durable_keys_in_a_new_store :: proc(t: ^testing.T) {
	FULL :: Synced.Full when ODIN_OS == .Darwin else Synced.Fsync
	base, _ := os.temp_directory(context.temp_allocator)
	top, err := os.make_directory_temp(base, "zsp-keys-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(top)
	defer os.remove_all(top)
	sync.guard(&looking)
	sync.atomic_store(&durable_hook, see)
	defer sync.atomic_store(&durable_hook, nil)

	dir := file_in(top, "space")
	d: File_Disk
	testing.expect(t, file_disk_open(&d, dir, true))
	defer file_disk_close(&d)
	testing.expect(t, !os.exists(dir))
	mark := sync.atomic_load(&seen_n)
	testing.expect(t, file_disk_make(&d) && save(file_in(dir, "keys"), transmute([]byte)string("keys")))
	testing.expect_value(t, synced_since(mark, file_in(dir, "keys")), FULL)
	testing.expect_value(t, synced_since(mark, dir), FULL)
	testing.expect_value(t, synced_since(mark, top), FULL) // the store's name, which the keys are found by
}

// A log whose tail was cut, as replay cuts a torn one, keeps the cut at its next sync, with nothing written after it:
// else a sync would keep the log as it was, the torn tail and all.
@(test)
durable_cut_with_nothing_after :: proc(t: ^testing.T) {
	FULL :: Synced.Full when ODIN_OS == .Darwin else Synced.Fsync
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-cut-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	sync.guard(&looking)
	sync.atomic_store(&durable_hook, see)
	defer sync.atomic_store(&durable_hook, nil)

	{
		d: File_Disk
		testing.expect(t, file_disk_open(&d, dir))
		disk := file_disk(&d)
		testing.expect(t, disk.log_write(disk.data, 0, transmute([]byte)string("kept torn")))
		testing.expect(t, disk.log_write(disk.data, zsp.SEGMENT, transmute([]byte)string("torn")))
		testing.expect(t, disk.log_sync(disk.data))
		disk.close(disk.data)
	}

	// Opened again, as at a start, and cut in a segment not open: the one the log goes on in from there.
	d: File_Disk
	testing.expect(t, file_disk_open(&d, dir))
	disk := file_disk(&d)
	defer disk.close(disk.data)
	mark := sync.atomic_load(&seen_n)
	disk.log_truncate(disk.data, 4)
	testing.expect(t, disk.log_sync(disk.data))
	testing.expect_value(t, synced_since(mark, segment_path(&d, 0)), FULL)
	testing.expect_value(t, disk.log_end(disk.data), 4)

	// Cut again in the segment being written, with nothing written since its last sync.
	testing.expect(t, disk.log_write(disk.data, 4, transmute([]byte)string(" more")))
	testing.expect(t, disk.log_sync(disk.data))
	mark = sync.atomic_load(&seen_n)
	disk.log_truncate(disk.data, 6)
	testing.expect(t, disk.log_sync(disk.data))
	testing.expect_value(t, synced_since(mark, segment_path(&d, 0)), FULL)

	// And written on from the cut, in the same file.
	testing.expect(t, disk.log_write(disk.data, 6, transmute([]byte)string("on")))
	testing.expect(t, disk.log_sync(disk.data))
	got: [8]byte
	testing.expect(t, disk.log_read(disk.data, 0, got[:]))
	testing.expect_value(t, string(got[:]), "kept mon")
}
