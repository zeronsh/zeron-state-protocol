package host

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// The byte a test's file has at an offset, wherever it is written from.
@(private = "file")
pattern :: proc(at: int) -> byte {
	return byte(at % 251)
}

// A file is read whole whatever its size, as much as was asked for in a read or more, or nothing at all; and a file that
// grows or shrinks while it is read, as one another process is writing does, is read to wherever its end is by then.
@(test)
files_read_whole :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-read-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	path := file_in(dir, "file")
	for size in ([]int{0, 1, 4095, 4096, 4097, 65536, 1 << 20 + 3}) {
		b := make([]byte, size, context.temp_allocator)
		for &x, i in b {
			x = pattern(i)
		}
		testing.expect(t, os.write_entire_file(path, b) == nil)
		data, ok := read_file(path)
		testing.expectf(t, ok && string(data) == string(b), "%d bytes: read %v, %d bytes", size, ok, len(data))
		delete(data)
	}
	_, missing := read_file(file_in(dir, "none"))
	testing.expect(t, !missing, "a file that is not there is read")

	Shared :: struct {
		path:   string,
		done:   bool, // atomic
		shrunk: int, // atomic: to more than nothing, while it was read
	}
	sh := Shared{path = path}
	writer := thread.create_and_start_with_poly_data(&sh, proc(sh: ^Shared) {
		context = runtime.default_context()
		f, ferr := os.open(sh.path, {.Read, .Write, .Trunc})
		if ferr != nil {
			return
		}
		defer os.close(f)
		chunk: [3001]byte
		size := 0
		for round := 0; !sync.atomic_load(&sh.done); round += 1 {
			if round % 128 == 127 {
				// And shrinks now and then, to none of it, a quarter, a half or three quarters of it in turn (0, 64, 192
				// and 384 KiB, as it grows here), each to a whole number of pages of any size a system has (4, 16 or
				// 64 KiB). Shrunk within a page, the system zeroes the rest of that page, and a read that took the file
				// to be longer meanwhile may copy those zeros before the file grows past them again: bytes it never
				// held, which Linux allows a read beside a truncation to see. No file a host keeps is shrunk where it is
				// read: each is replaced whole (see save). And one handed to it, as a roster to join by, is held to its
				// signature.
				size = size / 4 * (round / 128 % 4) / (64 << 10) * (64 << 10)
				if size > 0 {
					sync.atomic_add(&sh.shrunk, 1)
				}
				os.truncate(f, i64(size))
			}
			for &x, i in chunk {
				x = pattern(size + i)
			}
			n, _ := os.write_at(f, chunk[:], i64(size))
			size += n
			if size > 4 << 20 {
				size = 0
				os.truncate(f, 0)
			}
		}
	})
	reads, failed, wrong := 0, 0, 0
	// Until it has been read 2000 times and shrunk to each of 64, 192 and 384 KiB meanwhile.
	for start := time.tick_now(); (reads < 2000 || sync.atomic_load(&sh.shrunk) < 3) && time.tick_since(start) < 20 * time.Second; {
		data, ok := read_file(path)
		reads += 1
		if !ok {
			failed += 1
			continue
		}
		for x, i in data {
			if x != pattern(i) {
				wrong += 1
				break
			}
		}
		delete(data)
	}
	sync.atomic_store(&sh.done, true)
	thread.join(writer)
	thread.destroy(writer)
	testing.expectf(t, failed == 0 && wrong == 0, "of %d reads while it changed, %d failed and %d were not what it held", reads, failed, wrong)
	testing.expectf(t, sh.shrunk >= 3, "the file was shrunk to more than nothing only %d times while it was read", sh.shrunk)
}

@(private = "file", thread_local)
drawn: byte

// What a process that ended mid-save left behind is no hindrance to a save, whatever process left it: not even a staging
// file at the very name a save draws, as a process with this one's number, as every process in a container has, would
// leave at the name it drew. And it is removed when the directory is next opened, while a staging file a save is still
// writing, here or in another process, is not.
@(test)
files_left_behind :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-left-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	path := file_in(dir, "roster")

	// Names drawn in turn, all zero bytes and then all ones, and so on, the first of which is taken.
	drawn = 0
	staging_random = proc(into: []byte) {
		for &b in into {
			b = drawn
		}
		drawn += 1
	}
	taken := staging_name(path)
	drawn = 0
	testing.expect(t, os.write_entire_file(taken, transmute([]byte)string("left")) == nil)
	testing.expect(t, save(path, transmute([]byte)string("kept")), "a save fails for a file left at its name")
	staging_random = nil
	kept, _ := read_file(path, context.temp_allocator)
	testing.expect(t, string(kept) == "kept")

	writing, held := staging_make(path) // as another save, in this process or another, has made and is writing
	testing.expect(t, held)
	other := strings.concatenate({path, ".1234.0.new"}, context.temp_allocator) // no staging file's name
	testing.expect(t, os.write_entire_file(other, nil) == nil)
	for _ in 0 ..< 3 {
		testing.expect(t, os.write_entire_file(staging_name(path), transmute([]byte)string("left")) == nil)
	}
	_, _ = device_secret(dir) // which opens the directory zspd keeps its files in
	files, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	left := 0
	for f in files {
		left += 1 if staging_named(f.name) else 0
	}
	testing.expectf(t, left == 1, "%d staging files are left, of the one being written and four left behind", left)
	testing.expect(t, os.exists(other), "a file that is no staging file was removed")
	if held {
		staging_drop(writing)
	}
}
