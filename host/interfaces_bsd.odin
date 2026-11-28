#+build darwin, openbsd, netbsd
package host

import "core:net"
import "core:sys/posix"

// Here core:net (dev-2026-11) gathers interfaces into a map with the runtime's map_entry, which can give back another
// key's slot (see third_party/nbio/README.md): so they are walked here, as on Linux, and each address taken as it
// comes. What is taken is what core:net gave: every address of every interface, and an IPv4 one's broadcast address.

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

// The fields every one of these systems puts first, in this order; NetBSD has one more after them.
@(private = "file")
Ifaddrs :: struct {
	next:    ^Ifaddrs,
	name:    cstring,
	flags:   u32,
	addr:    ^posix.sockaddr,
	netmask: ^posix.sockaddr,
	dstaddr: ^posix.sockaddr,
	data:    rawptr,
}

@(default_calling_convention = "c", private = "file")
foreign libc {
	getifaddrs :: proc(list: ^^Ifaddrs) -> posix.result ---
	freeifaddrs :: proc(list: ^Ifaddrs) ---
}

@(private)
Interface :: struct {
	address:   net.Address,
	broadcast: Maybe(net.IP4_Address),
}

// Temporary memory.
@(private, require_results)
interfaces :: proc() -> []Interface {
	out := make([dynamic]Interface, context.temp_allocator)
	head: ^Ifaddrs
	if getifaddrs(&head) != .OK {
		return nil
	}
	defer freeifaddrs(head)
	for a := head; a != nil; a = a.next {
		if a.addr == nil {
			continue
		}
		#partial switch a.addr.sa_family {
		case .INET:
			ip := transmute(net.IP4_Address)(^posix.sockaddr_in)(a.addr).sin_addr
			all: Maybe(net.IP4_Address)
			if a.netmask != nil && a.netmask.sa_family == .INET {
				m := transmute(net.IP4_Address)(^posix.sockaddr_in)(a.netmask).sin_addr
				all = net.IP4_Address{ip[0] | ~m[0], ip[1] | ~m[1], ip[2] | ~m[2], ip[3] | ~m[3]}
			}
			append(&out, Interface{ip, all})
		case .INET6:
			append(&out, Interface{transmute(net.IP6_Address)(^posix.sockaddr_in6)(a.addr).sin6_addr, nil})
		}
	}
	return out[:]
}
