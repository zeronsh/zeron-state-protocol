package host

import "core:os"
import "core:testing"

// A file written to is synced, as are the directory it is in and the one that is in, on every system: that each may be
// is what a store's first Ack waits on (see durable_posix_test.odin for which syncs are made).
@(test)
durable_file_and_directory :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-durable-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	f, ferr := os.open(file_in(dir, "file"), {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
	testing.expect(t, ferr == nil)
	defer os.close(f)
	_, werr := os.write(f, transmute([]byte)string("kept"))
	testing.expect(t, werr == nil)
	testing.expect(t, file_durable(f))
	testing.expect(t, dir_durable(dir))
	testing.expect(t, dir_durable(base))
}
