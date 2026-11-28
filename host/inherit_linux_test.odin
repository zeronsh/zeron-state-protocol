#+build linux
package host

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// What a process has open that it was handed: on Linux, anything, from what it says of each of its descriptors; on
// macOS, what of a store at `dir` or of a node listening at those ports it has, as lsof says. There a socket is made
// close-on-exec only once it is made, which another thread's fork may come between, as it may for any test beside this
// one: what the node has open is had so all the same, before anything is started that could be handed it.
@(private)
child_holds :: proc(pid: int, dir: string, tcp, udp: int) -> []string {
	held := make([dynamic]string, context.temp_allocator)
	real, _ := dir_real(dir)
	fds := fmt.tprintf("/proc/%d/fd", pid)
	entries, err := os.read_all_directory_by_path(fds, context.temp_allocator)
	if err != nil {
		append(&held, fmt.tprintf("what could not be told (%s: %v)", fds, err))
		return held[:]
	}
	// Anything at all, on Linux, where every descriptor of this process is had close-on-exec as it is made: but what
	// core:os opens in the child itself, /dev/null for what it is not given, which it does not close.
	ports := socket_inodes(tcp, udp)
	for e in entries {
		n, _ := strconv.parse_int(e.name)
		if n <= 2 {
			continue
		}
		to, _ := os.read_link(e.fullpath, context.temp_allocator)
		if to == "/dev/null" {
			continue
		}
		mine := strings.has_prefix(to, real) || strings.has_prefix(to, dir)
		for inode in ports {
			mine ||= to == fmt.tprintf("socket:[%s]", inode)
		}
		append(&held, fmt.tprintf("its descriptor %d, %s%s", n, to, ", the node's" if mine else ""))
	}
	return held[:]
}

// The inodes of the sockets bound to those local ports on loopback or anywhere, as /proc/net says, in hex there.
@(private = "file")
socket_inodes :: proc(tcp, udp: int) -> []string {
	inodes := make([dynamic]string, context.temp_allocator)
	for table in ([]struct {
			path: string,
			port: int,
		}{{"/proc/net/tcp", tcp}, {"/proc/net/tcp6", tcp}, {"/proc/net/udp", udp}, {"/proc/net/udp6", udp}}) {
		data, err := os.read_entire_file(table.path, context.temp_allocator)
		if err != nil {
			continue
		}
		want := fmt.tprintf(":%04X", table.port)
		for line, i in strings.split_lines(string(data), context.temp_allocator) {
			fields := strings.fields(line, context.temp_allocator)
			if i == 0 || len(fields) < 10 {
				continue
			}
			if strings.has_suffix(fields[1], want) {
				append(&inodes, fields[9])
			}
		}
	}
	return inodes[:]
}
