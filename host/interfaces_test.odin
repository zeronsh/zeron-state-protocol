package host

import "core:net"
import "core:slice"
import "core:testing"

// The addresses this machine has, as the host finds them: loopback's among them, and each IPv4 address one a socket
// can be bound to, as only this machine's own can be. Where core:net lists interfaces soundly, every address it lists is
// among them too, with the same broadcast (interfaces_net_test.odin): on macOS and the BSDs it gathers them with
// map_entry, which can lose one (odin-lang/Odin#8642), and they are walked here instead.
@(test)
interfaces_are_those_the_system_has :: proc(t: ^testing.T) {
	mine := interfaces()
	testing.expectf(t, slice.any_of_proc(mine, proc(i: Interface) -> bool {
		return i.address == net.Address(net.IP4_Loopback)
	}), "no loopback among %v", mine)
	for i in mine {
		if _, v4 := i.address.(net.IP4_Address); !v4 {
			continue
		}
		s, err := net.make_bound_udp_socket(i.address, 0)
		if testing.expectf(t, err == nil, "%v is no address of this machine's: %v", i.address, err) {
			net.close(s)
		}
	}
	also_listed_by_core(t, mine)
}
