#+build !windows
package host

import "core:net"
import "core:sys/posix"

// Closes a connection so that the other end hears a reset, not an orderly end: what it was talking to has
// failed, and it should not take what it got for all there was. (core:net's Linger option is not this.)
@(private)
socket_reset :: proc(socket: net.TCP_Socket) {
	abort := posix.linger{l_onoff = 1, l_linger = 0}
	posix.setsockopt(posix.FD(socket), posix.SOL_SOCKET, .LINGER, &abort, size_of(abort))
	net.close(socket)
}
