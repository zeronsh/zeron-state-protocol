package host

import "core:net"
import "core:sys/posix"

// Lets others listen at the same port. core:net does not know how to here.
@(private)
port_share :: proc(socket: net.UDP_Socket) {
	SO_REUSEPORT :: posix.Sock_Option(0x0200)
	yes: i32 = 1
	posix.setsockopt(posix.FD(socket), posix.SOL_SOCKET, SO_REUSEPORT, &yes, size_of(yes))
}
