#+build !linux
package host

import "core:net"

@(private)
Interface :: struct {
	address:   net.Address,
	broadcast: Maybe(net.IP4_Address),
}

// Temporary memory.
@(private, require_results)
interfaces :: proc() -> []Interface {
	out := make([dynamic]Interface, context.temp_allocator)
	list, err := net.enumerate_interfaces(context.temp_allocator)
	if err != nil {
		return nil
	}
	for i in list {
		for lease in i.unicast {
			all: Maybe(net.IP4_Address)
			ip, v4 := lease.address.(net.IP4_Address)
			if mask, has := lease.netmask.(net.IP4_Address); has && v4 {
				all = net.IP4_Address{ip[0] | ~mask[0], ip[1] | ~mask[1], ip[2] | ~mask[2], ip[3] | ~mask[3]}
			}
			if lease.address != nil {
				append(&out, Interface{lease.address, all})
			}
		}
	}
	return out[:]
}
