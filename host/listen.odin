package host

import "core:nbio"
import "core:net"

// Listens at an address of another device's, here. Where the system would let another socket take the very same
// address and port (Windows, given SO_REUSEADDR), nobody else may; elsewhere a more specific address may share a
// port with a socket listening on every address, as it may only with SO_REUSEADDR.
@(private)
// Connections waiting to be accepted, at most (the system caps it, at somaxconn): applications open many at once, and a
// queue that overflows has the system answer with SYN cookies and drop what comes, so that the first bytes of a
// connection may be lost or come a second late.
LISTEN_BACKLOG :: 4096

listen_on :: proc(at: net.Endpoint, backlog := LISTEN_BACKLOG) -> (socket: net.TCP_Socket, err: net.Network_Error) {
	socket = nbio.create_tcp_socket(nbio.family_from_endpoint(at)) or_return
	defer if err != nil {
		net.close(socket)
	}
	exclusive(socket)
	net.bind(socket, at) or_return
	if !socket_listen(socket, backlog) {
		err = net.Listen_Error.Insufficient_Resources
	}
	return
}
