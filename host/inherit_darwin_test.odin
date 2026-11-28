#+build darwin
package host

import "core:fmt"
import "core:os"
import "core:strings"

// What a process has open that it was handed: on Linux, anything, from what it says of each of its descriptors; on
// macOS, what of a store at `dir` or of a node listening at those ports it has, as lsof says. There a socket is made
// close-on-exec only once it is made, which another thread's fork may come between, as it may for any test beside this
// one: what the node has open is had so all the same, before anything is started that could be handed it.
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
