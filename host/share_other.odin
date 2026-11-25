#+build !darwin
package host

import "core:net"

// Lets others listen at the same port. On Linux and Windows, reusing the address does.
@(private)
port_share :: proc(socket: net.UDP_Socket) {
	when ODIN_OS == .FreeBSD {
		net.set_option(socket, .Reuse_Port, true)
	}
}
