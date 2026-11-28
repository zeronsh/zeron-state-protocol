package host

import "core:net"
import "core:slice"
import "core:testing"

// The addresses this machine has, as the host finds them: loopback's among them, and each held to the system by a way
// of its own (interfaces_net_test.odin, interfaces_walked_test.odin).
@(test)
interfaces_are_those_the_system_has :: proc(t: ^testing.T) {
	mine := interfaces()
	testing.expectf(t, slice.any_of_proc(mine, proc(i: Interface) -> bool {
		return i.address == net.Address(net.IP4_Loopback)
	}), "no loopback among %v", mine)
	held_to_the_system(t, mine)
}
