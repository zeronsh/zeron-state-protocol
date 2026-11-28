#+build !windows
#+build !freebsd
package host

import "core:net"
import "core:testing"

// Where the host walks the system's interfaces itself, each IPv4 address it finds is one a socket can be bound to, as
// only this machine's own can be. It is not held to core:net's list: core:net lists none on Linux, and on macOS and the
// BSDs gathers them with map_entry, which can lose one (odin-lang/Odin#8642). (On Windows, where the host takes core:net's
// list, an adapter with no link keeps an address, 169.254.x.x, that cannot be bound: held to core:net's list there.)
@(private)
held_to_the_system :: proc(t: ^testing.T, mine: []Interface) {
	for i in mine {
		if _, v4 := i.address.(net.IP4_Address); !v4 {
			continue
		}
		s, err := net.make_bound_udp_socket(i.address, 0)
		if testing.expectf(t, err == nil, "%v is no address of this machine's: %v", i.address, err) {
			net.close(s)
		}
	}
}
