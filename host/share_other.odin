#+build linux, windows
package host

import "core:net"

// Lets others listen at the same port. On Linux and Windows, reusing the address does.
@(private)
port_share :: proc(socket: net.UDP_Socket) {}
