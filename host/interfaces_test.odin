package host

import "core:net"
import "core:slice"
import "core:testing"

// The addresses this machine has, as the host finds them: loopback's among them, and, where core:net lists interfaces
// too, every address it lists, with the same broadcast. (On macOS and the BSDs they are walked here rather than taken
// from core:net, whose map_entry can lose one; see third_party/nbio/README.md.)
@(test)
interfaces_are_those_the_system_has :: proc(t: ^testing.T) {
	mine := interfaces()
	testing.expectf(t, slice.any_of_proc(mine, proc(i: Interface) -> bool {
		return i.address == net.Address(net.IP4_Loopback)
	}), "no loopback among %v", mine)
	when ODIN_OS != .Linux {
		listed, err := net.enumerate_interfaces(context.temp_allocator)
		if !testing.expectf(t, err == nil, "core:net listed nothing: %v", err) {
			return
		}
		for i in listed {
			for lease in i.unicast {
				if lease.address == nil {
					continue
				}
				all: Maybe(net.IP4_Address)
				ip, v4 := lease.address.(net.IP4_Address)
				if mask, has := lease.netmask.(net.IP4_Address); has && v4 {
					all = net.IP4_Address{ip[0] | ~mask[0], ip[1] | ~mask[1], ip[2] | ~mask[2], ip[3] | ~mask[3]}
				}
				testing.expectf(t, slice.contains(mine, Interface{lease.address, all}), "%s's %v (broadcast %v) is not among %v", i.adapter_name, lease.address, all, mine)
			}
		}
	}
}
