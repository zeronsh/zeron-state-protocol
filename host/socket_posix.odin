#+build !windows
package host

import "core:net"
import "core:sys/posix"

// Closes a connection with a reset rather than a goodbye, so that whoever is at the other end fails at once, as
// they would on a network that refused them. (core:net's linger option takes a time, not a lingering.)
@(private)
socket_abort :: proc(socket: net.TCP_Socket) {
	l := posix.linger{l_onoff = 1, l_linger = 0}
	posix.setsockopt(posix.FD(socket), posix.SOL_SOCKET, .LINGER, &l, size_of(l))
	net.close(socket)
}

// Keeps what the kernel holds unsent short, so that what is queued waits where it can still be put in order:
// here, behind what is more urgent, rather than in the kernel, behind everything.
@(private)
socket_lowat :: proc(socket: net.TCP_Socket, bytes: i32) {
	when ODIN_OS == .Linux {
		NOTSENT_LOWAT :: 25
	} else when ODIN_OS == .Darwin {
		NOTSENT_LOWAT :: 0x201
	} else when ODIN_OS == .FreeBSD {
		NOTSENT_LOWAT :: -1
	} else {
		NOTSENT_LOWAT :: -1
	}
	when NOTSENT_LOWAT >= 0 {
		v := bytes
		posix.setsockopt(posix.FD(socket), posix.IPPROTO_TCP, posix.Sock_Option(NOTSENT_LOWAT), &v, size_of(v))
	}
}
