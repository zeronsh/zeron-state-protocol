#+build !windows
package main

import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "../host"

@(private = "file")
Seen :: struct {
	dev, ino: u64,
}

@(private = "file")
seen: [1 << 12]Seen
@(private = "file")
seen_n: int // atomic

@(private = "file")
see :: proc(fd: posix.FD, how: host.Synced) {
	st: posix.stat_t
	if how == .Failed || posix.fstat(fd, &st) != .OK {
		return
	}
	if i := sync.atomic_add(&seen_n, 1); i < len(seen) {
		seen[i] = {u64(st.st_dev), u64(st.st_ino)}
	}
}

@(private = "file")
synced :: proc(path: string) -> bool {
	st: posix.stat_t
	b := make([]byte, len(path) + 1, context.temp_allocator)
	copy(b, path)
	if posix.stat(cstring(raw_data(b)), &st) != .OK {
		return false
	}
	for s in seen[:min(sync.atomic_load(&seen_n), len(seen))] {
		if s == {u64(st.st_dev), u64(st.st_ino)} {
			return true
		}
	}
	return false
}

// Joining a space in a directory that was not there makes it, and the space's store in it, each kept as it is made,
// with the one it was made in, as SPEC says: before join says it is done.
@(test)
join_keeps_what_it_makes :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	top, err := os.make_directory_temp(base, "zspd-join-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(top)
	defer os.remove_all(top)
	sync.atomic_store(&host.durable_hook, see)
	defer sync.atomic_store(&host.durable_hook, nil)

	dir := in_dir(in_dir(top, "a"), "device")
	space := "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
	testing.expect(t, join(dir, space, space, "ws://127.0.0.1:1"))
	for made in ([]string{in_dir(dir, space), dir, in_dir(top, "a"), top}) {
		testing.expectf(t, synced(made), "%s was not synced", made)
	}
}
