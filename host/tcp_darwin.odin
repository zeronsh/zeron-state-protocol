package host

import "core:encoding/endian"
import "core:sys/posix"
import "../pipe"

// What the kernel says of TCP sockets, through the sysctl netstat reads (net.inet.tcp.pcblist_n), which anyone
// may: which are listening, and whose a connected one is. It is asked when there is a question, never on a clock.
//
// The list is records, each length ‖ kind and padded to eight bytes: for each socket its protocol block, the socket,
// buffers, statistics and TCP's block, in that order, between headers of 24 bytes. Offsets are of xnu's records as
// they are laid out (four-byte packing), and are checked against the system's own account in tcp_test.odin.

@(private = "file")
XSO_SOCKET :: 0x01
@(private = "file")
XSO_INPCB :: 0x10
@(private = "file")
XSO_TCPCB :: 0x20
@(private = "file")
TCPS_LISTEN :: 1

foreign import libc "system:c"

@(default_calling_convention = "c", private = "file")
foreign libc {
	sysctlbyname :: proc(name: cstring, old: rawptr, oldlen: ^uint, new: rawptr, newlen: uint) -> i32 ---
}

@(private = "file")
Tcp_Entry :: struct {
	local, remote: pipe.Address,
	uid:           u32,
	listening:     bool,
}

@(private = "file")
tcp_entries :: proc() -> (out: [dynamic]Tcp_Entry, ok: bool) {
	out = make([dynamic]Tcp_Entry, context.temp_allocator)
	size: uint
	buf: []byte
	for _ in 0 ..< 4 {
		if sysctlbyname("net.inet.tcp.pcblist_n", nil, &size, nil, 0) != 0 {
			return
		}
		size += size / 4 + 4096 // room for sockets made meanwhile
		buf = make([]byte, size, context.temp_allocator)
		if sysctlbyname("net.inet.tcp.pcblist_n", raw_data(buf), &size, nil, 0) == 0 {
			break
		}
		buf = nil
	}
	if len(buf) < 24 {
		return
	}
	b := buf[:size]
	at := int(endian.unchecked_get_u32le(b))
	e: Tcp_Entry
	family: u32
	local, remote: [16]byte
	for at + 24 < len(b) {
		n := int(endian.unchecked_get_u32le(b[at:]))
		kind := endian.unchecked_get_u32le(b[at + 4:])
		if n < 8 || at + n > len(b) {
			return
		}
		r := b[at:at + n]
		switch kind {
		case XSO_INPCB:
			if n < 80 {
				return
			}
			e = {}
			e.remote.port = endian.unchecked_get_u16be(r[16:])
			e.local.port = endian.unchecked_get_u16be(r[18:])
			copy(remote[:], r[48:64])
			copy(local[:], r[64:80])
		case XSO_SOCKET:
			if n < 68 {
				return
			}
			family = endian.unchecked_get_u32le(r[40:])
			e.uid = endian.unchecked_get_u32le(r[64:])
		case XSO_TCPCB:
			if n < 40 {
				return
			}
			e.listening = endian.unchecked_get_u32le(r[36:]) == TCPS_LISTEN
			if family == 2 {
				e.local = pipe.address_v4(local[12], local[13], local[14], local[15], e.local.port)
				e.remote = pipe.address_v4(remote[12], remote[13], remote[14], remote[15], e.remote.port)
			} else {
				e.local.ip, e.remote.ip = local, remote
			}
			append(&out, e)
		}
		at += (n + 7) &~ 7
	}
	return out, true
}

// Every address some socket listens at, in temporary memory.
@(private, require_results)
tcp_listening :: proc() -> (list: []pipe.Address, ok: bool) {
	all := tcp_entries() or_return
	out := make([dynamic]pipe.Address, context.temp_allocator)
	for e in all {
		if e.listening {
			append(&out, e.local)
		}
	}
	return out[:], true
}

// Whether the socket that connected from `remote` to our `local`, on this machine, is this user's, or root's:
// nobody else on the machine may borrow what this device may reach.
@(private, require_results)
tcp_peer_is_mine :: proc(local, remote: pipe.Address) -> bool {
	all, ok := tcp_entries()
	if !ok {
		return false
	}
	me := u32(posix.getuid())
	for e in all {
		if !e.listening && e.local == remote && e.remote == local {
			return e.uid == me || e.uid == 0
		}
	}
	return false
}
