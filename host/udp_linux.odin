#+build linux
package host

import "core:net"
import "core:sys/linux"
import "../pipe"

// On Linux a link's packets go out many to a system call, and, when they are all of a size as a bulk transfer's are,
// as one buffer the kernel cuts into datagrams itself (UDP_SEGMENT); and they come in many to a call.

UDP_GSO :: true

@(private)
udp_send_batch :: proc(h: ^Host, b: ^Batch, to: pipe.Address) {
	if b.n == 0 {
		return
	}
	defer b.n = 0
	u := &h.udp
	v4 := pipe.address_is_v4(to)
	if !v4 && !u.have6 {
		return
	}
	fd := linux.Fd(u.socket if v4 else u.socket6)
	addr: linux.Sock_Addr_Any
	size: i32
	if v4 {
		addr.ipv4 = {sin_family = .INET, sin_port = u16be(to.port), sin_addr = {to.ip[12], to.ip[13], to.ip[14], to.ip[15]}}
		size = size_of(linux.Sock_Addr_In)
	} else {
		addr.ipv6 = {sin6_family = .INET6, sin6_port = u16be(to.port), sin6_addr = to.ip}
		size = size_of(linux.Sock_Addr_In6)
	}
	iov: [UDP_BATCH]linux.IO_Vec
	for i in 0 ..< b.n {
		iov[i] = {raw_data(b.packets[i][:]), uint(b.sizes[i])}
	}
	if b.n > 1 && !u.no_gso {
		same := true
		for i in 1 ..< b.n - 1 {
			same &&= b.sizes[i] == b.sizes[0]
		}
		if same && b.sizes[b.n - 1] <= b.sizes[0] {
			// One message: its bytes are the packets end to end, cut by the kernel at every sizes[0].
			UDP_SEGMENT :: 103
			control: [24]byte
			(^u64)(&control[0])^ = 18 // the header, and the segment's size
			(^i32)(&control[8])^ = i32(linux.SOL_UDP)
			(^i32)(&control[12])^ = UDP_SEGMENT
			(^u16)(&control[16])^ = u16(b.sizes[0])
			msg := linux.Msg_Hdr{name = &addr, namelen = size, iov = iov[:b.n], control = control[:]}
			_, err := linux.sendmsg(fd, &msg, {.NOSIGNAL})
			#partial switch err {
			case .NONE:
				return
			case .EIO, .EINVAL, .ENOPROTOOPT, .EOPNOTSUPP:
				u.no_gso = true // not here: one datagram at a time, many to a call
			case:
				return // the socket is full: dropped, as any datagram may be
			}
		}
	}
	msgs: [UDP_BATCH]linux.MMsg_Hdr
	for i in 0 ..< b.n {
		msgs[i].hdr = {name = &addr, namelen = size, iov = iov[i:i + 1]}
	}
	for sent := 0; sent < b.n; {
		n, err := linux.sendmmsg(fd, msgs[sent:b.n], {.NOSIGNAL})
		if err != .NONE || n <= 0 {
			return
		}
		sent += n
	}
}

// Takes what has come to a socket, many datagrams to a call, until there is none: each to udp_input.
@(private)
udp_receive :: proc(h: ^Host, socket: net.UDP_Socket) {
	SLOT :: 2048 // a datagram, at most, of what links send
	COUNT :: SHARED_BUFFER / SLOT
	fd := linux.Fd(socket)
	for _ in 0 ..< 256 / COUNT {
		msgs: [COUNT]linux.MMsg_Hdr
		iov: [COUNT]linux.IO_Vec
		from: [COUNT]linux.Sock_Addr_Any
		for i in 0 ..< COUNT {
			iov[i] = {raw_data(h.shared[i * SLOT:]), SLOT}
			msgs[i].hdr = {name = &from[i], namelen = size_of(linux.Sock_Addr_Any), iov = iov[i:i + 1]}
		}
		// Five arguments, the last no timeout: core:sys/linux's recvmmsg passes four, leaving the fifth to chance.
		ret := linux.syscall(linux.SYS_recvmmsg, fd, raw_data(msgs[:]), len(msgs), transmute(i32)linux.Socket_Msg{.DONTWAIT}, uintptr(0))
		n := int(ret)
		if ret < 0 || n <= 0 {
			return // nothing more now, or an unreachable peer reported late, which the link will notice
		}
		for i in 0 ..< n {
			a: pipe.Address
			if from[i].family == .INET {
				a = pipe.address_v4(from[i].ipv4.sin_addr[0], from[i].ipv4.sin_addr[1], from[i].ipv4.sin_addr[2], from[i].ipv4.sin_addr[3], u16(from[i].ipv4.sin_port))
			} else {
				a.ip, a.port = from[i].ipv6.sin6_addr, u16(from[i].ipv6.sin6_port)
			}
			udp_input(h, h.shared[i * SLOT:][:min(int(msgs[i].len), SLOT)], a)
		}
		if n < COUNT {
			return
		}
	}
}
