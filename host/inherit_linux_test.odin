#+build linux
package host

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// What of a node, with its store at `dir` and listening at those ports, a process has open: from what Linux says of each
// of its descriptors.
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
	// What is the node's: a file of its store, one of its sockets, or anything of an event loop's (an io_uring, an
	// eventfd), which only nbio makes. Not whatever else a test beside this one may have open, which is that test's.
	ports := socket_inodes(tcp, udp)
	for e in entries {
		n, _ := strconv.parse_int(e.name)
		if n <= 2 {
			continue
		}
		to, _ := os.read_link(e.fullpath, context.temp_allocator)
		mine := strings.has_prefix(to, real) || strings.has_prefix(to, dir) || strings.has_prefix(to, "anon_inode:")
		for inode in ports {
			mine ||= to == fmt.tprintf("socket:[%s]", inode)
		}
		if mine {
			append(&held, fmt.tprintf("its descriptor %d, %s", n, to))
		}
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
