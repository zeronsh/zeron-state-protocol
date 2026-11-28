#+build darwin
package host

import "core:fmt"
import "core:os"
import "core:strings"

// What of a node, with its store at `dir` and listening at those ports, a process has open: from what lsof says of each
// of its descriptors, on macOS.
@(private)
child_holds :: proc(pid: int, dir: string, tcp, udp: int) -> []string {
	held := make([dynamic]string, context.temp_allocator)
	real, _ := dir_real(dir)
	state, out, _, err := os.process_exec({command = {"lsof", "-n", "-P", "-p", fmt.tprint(pid), "-F", "fn"}}, context.temp_allocator)
	if err != nil || !state.exited {
		append(&held, fmt.tprintf("what could not be told (lsof: %v)", err))
		return held[:]
	}
	fd := ""
	for line in strings.split_lines(string(out), context.temp_allocator) {
		if strings.has_prefix(line, "f") {
			fd = line[1:]
		} else if strings.has_prefix(line, "n") {
			name := line[1:]
			mine := strings.contains(name, real) || strings.contains(name, dir)
			for port in ([]int{tcp, udp}) {
				mine ||= strings.has_suffix(name, fmt.tprintf(":%d", port)) || strings.contains(name, fmt.tprintf(":%d->", port)) || strings.contains(name, fmt.tprintf(":%d ", port))
			}
			if mine {
				append(&held, fmt.tprintf("its descriptor %s, of %s", fd, name))
			}
		}
	}
	return held[:]
}
