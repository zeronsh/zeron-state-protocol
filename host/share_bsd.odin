#+build darwin, freebsd, openbsd, netbsd
package host

import "core:net"
import "../third_party/nbio"

// Lets others listen at the same port: on macOS and the BSDs, by SO_REUSEPORT.
@(private)
port_share :: proc(socket: net.UDP_Socket) {
	nbio.set_socket_option(socket, .Reuse_Port, true)
}
