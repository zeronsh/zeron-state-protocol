package host

import "base:runtime"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"

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
		path: string,
		done: bool, // atomic
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
			if round % 64 == 63 {
				size /= 3 // and shrinks now and then
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
	for reads < 2000 {
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
}
