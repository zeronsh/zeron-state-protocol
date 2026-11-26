package host

import "core:encoding/endian"
import "core:sys/linux"
import "../pipe"

// What the kernel says of TCP sockets, through sock_diag (NETLINK_INET_DIAG), which anyone may ask: which are
// listening, and whose a connected one is. It is asked when there is a question, never on a clock.

@(private = "file")
NETLINK_INET_DIAG :: linux.Protocol(4)
@(private = "file")
SOCK_DIAG_BY_FAMILY :: 20
@(private = "file")
NLMSG_ERROR :: 2
@(private = "file")
NLMSG_DONE :: 3
@(private = "file")
TCP_LISTEN :: 10
@(private = "file")
HEADER :: 16
@(private = "file")
REQUEST :: 56 // inet_diag_req_v2
@(private = "file")
MESSAGE :: 72 // inet_diag_msg

@(private = "file")
diag :: proc(family: u8, states: u32, exact: ^[2]pipe.Address, each: proc(data: rawptr, local, remote: pipe.Address, uid: u32), data: rawptr) -> bool {
	fd, err := linux.socket(.NETLINK, .DGRAM, {.CLOEXEC}, NETLINK_INET_DIAG)
	if err != nil {
		return false
	}
	defer linux.close(fd)
	req: [HEADER + REQUEST]byte
	endian.unchecked_put_u32le(req[0:], len(req))
	endian.unchecked_put_u16le(req[4:], SOCK_DIAG_BY_FAMILY)
	endian.unchecked_put_u16le(req[6:], 0x1 if exact != nil else 0x1 | 0x300) // a request, and of all of them unless one is named
	endian.unchecked_put_u32le(req[8:], 1)
	req[16] = family
	req[17] = 6 // TCP
	endian.unchecked_put_u32le(req[20:], states)
	if exact != nil {
		// The socket at the far end of ours: its source is our remote, its destination our local.
		local, remote := exact[0], exact[1]
		endian.unchecked_put_u16be(req[24:], remote.port)
		endian.unchecked_put_u16be(req[26:], local.port)
		v4 := family == 2
		copy(req[28:44], remote.ip[12:] if v4 else remote.ip[:])
		copy(req[44:60], local.ip[12:] if v4 else local.ip[:])
		endian.unchecked_put_u32le(req[64:], 0xffffffff) // no cookie
		endian.unchecked_put_u32le(req[68:], 0xffffffff)
	}
	if _, serr := linux.send(fd, req[:], {}); serr != nil {
		return false
	}
	buf: [16 << 10]byte
	for {
		n, rerr := linux.recv(fd, buf[:], {})
		if rerr != nil || n <= 0 {
			return false
		}
		at := 0
		for at + HEADER <= n {
			size := int(endian.unchecked_get_u32le(buf[at:]))
			type := endian.unchecked_get_u16le(buf[at + 4:])
			if size < HEADER || at + size > n {
				return false
			}
			switch type {
			case NLMSG_DONE:
				return true
			case NLMSG_ERROR:
				return false // as for an exact question that has no answer
			case SOCK_DIAG_BY_FAMILY:
				if size >= HEADER + MESSAGE {
					m := buf[at + HEADER:]
					local, remote: pipe.Address
					local.port = endian.unchecked_get_u16be(m[4:])
					remote.port = endian.unchecked_get_u16be(m[6:])
					if m[0] == 2 {
						local = pipe.address_v4(m[8], m[9], m[10], m[11], local.port)
						remote = pipe.address_v4(m[24], m[25], m[26], m[27], remote.port)
					} else {
						copy(local.ip[:], m[8:24])
						copy(remote.ip[:], m[24:40])
					}
					each(data, local, remote, endian.unchecked_get_u32le(m[64:]))
				}
			}
			at += (size + 3) &~ 3
		}
		if exact != nil {
			return true
		}
	}
}

// Every address some socket listens at, in temporary memory.
@(private, require_results)
tcp_listening :: proc() -> (list: []pipe.Address, ok: bool) {
	out := make([dynamic]pipe.Address, context.temp_allocator)
	add :: proc(data: rawptr, local, _: pipe.Address, _: u32) {
		append((^[dynamic]pipe.Address)(data), local)
	}
	ok = diag(2, 1 << TCP_LISTEN, nil, add, &out)
	ok &&= diag(10, 1 << TCP_LISTEN, nil, add, &out)
	return out[:], ok
}

// Whether the socket that connected from `remote` to our `local`, on this machine, is this user's, or root's:
// nobody else on the machine may borrow what this device may reach.
@(private, require_results)
tcp_peer_is_mine :: proc(local, remote: pipe.Address) -> bool {
	Found :: struct {
		uid:   u32,
		found: bool,
	}
	found: Found
	exact := [2]pipe.Address{local, remote}
	family := u8(2) if pipe.address_is_v4(remote) else u8(10)
	ok := diag(family, 0xffffffff, &exact, proc(data: rawptr, _, _: pipe.Address, uid: u32) {
		f := (^Found)(data)
		f.uid, f.found = uid, true
	}, &found)
	me := u32(linux.getuid())
	return ok && found.found && (found.uid == me || found.uid == 0)
}
