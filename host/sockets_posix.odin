#+build !windows
package host

import "core:net"
import "core:sys/posix"

// A more specific address may share a port with a socket listening on every address (BSD, given SO_REUSEADDR);
// the very same address and port, nobody may share without SO_REUSEPORT, which this never sets.
@(private)
exclusive :: proc(socket: net.TCP_Socket) {
	net.set_option(socket, .Reuse_Address, true)
}

@(private)
socket_listen :: proc(socket: net.TCP_Socket, backlog: int) -> bool {
	return posix.listen(posix.FD(socket), i32(backlog)) == .OK
}
