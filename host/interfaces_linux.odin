package host

import "core:net"

foreign import libc "system:c"

// core:net does not enumerate interfaces on Linux.

@(private = "file")
Ifaddrs :: struct {
	next:    ^Ifaddrs,
	name:    cstring,
	flags:   u32,
	addr:    ^[28]byte,
	netmask: ^[28]byte,
	other:   rawptr,
	data:    rawptr,
}

@(default_calling_convention = "c", private = "file")
foreign libc {
	getifaddrs :: proc(list: ^^Ifaddrs) -> i32 ---
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
	UP_AND_RUNNING :: 0x1 | 0x40
	out := make([dynamic]Interface, context.temp_allocator)
	head: ^Ifaddrs
	if getifaddrs(&head) != 0 {
		return nil
	}
	defer freeifaddrs(head)
	for a := head; a != nil; a = a.next {
		if a.addr == nil || a.flags & UP_AND_RUNNING != UP_AND_RUNNING {
			continue
		}
		switch (^u16)(a.addr)^ {
		case 2:
			ip := net.IP4_Address{a.addr[4], a.addr[5], a.addr[6], a.addr[7]}
			all: Maybe(net.IP4_Address)
			if a.netmask != nil {
				m := a.netmask
				all = net.IP4_Address{ip[0] | ~m[4], ip[1] | ~m[5], ip[2] | ~m[6], ip[3] | ~m[7]}
			}
			append(&out, Interface{ip, all})
		case 10:
			ip: net.IP6_Address
			for &part, i in ip {
				part = u16be(u16(a.addr[8 + i * 2]) << 8 | u16(a.addr[9 + i * 2]))
			}
			append(&out, Interface{ip, nil})
		}
	}
	return out[:]
}
