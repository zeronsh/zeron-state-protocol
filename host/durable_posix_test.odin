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

// Every sync made for durability while the test below looks, by any test: each its file's, as fstat says.
@(private = "file")
seen: [4096]Seen
@(private = "file")
seen_n: int // atomic

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

	// And one removed, which is not to come back.
	mark = sync.atomic_load(&seen_n)
	disk.log_truncate(disk.data, 4)
	testing.expect(t, !os.exists(segment_path(&d, 1)))
	testing.expect(t, disk.log_sync(disk.data))
	testing.expect_value(t, synced_since(mark, dir), FULL)

	mark = sync.atomic_load(&seen_n)
	path := file_in(top, "saved")
	testing.expect(t, save(path, transmute([]byte)string("whole")))
	testing.expect_value(t, synced_since(mark, path), FULL)
	testing.expect_value(t, synced_since(mark, top), FULL)
}
