#+build windows, freebsd
package host

import "core:net"
import "core:slice"
import "core:testing"

// Where core:net lists interfaces soundly, every address it lists is among the host's, with the same broadcast. On
// Linux it lists none, and on macOS and the BSDs it gathers them with map_entry (odin-lang/Odin#8642).
@(private)
also_listed_by_core :: proc(t: ^testing.T, mine: []Interface) {
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
