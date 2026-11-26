#+build windows
package host

import "core:net"
import win "core:sys/windows"

// Closes a connection with a reset rather than a goodbye, so that whoever is at the other end fails at once.
@(private)
socket_abort :: proc(socket: net.TCP_Socket) {
	l := win.LINGER{l_onoff = 1, l_linger = 0}
	win.setsockopt(win.SOCKET(socket), win.SOL_SOCKET, win.SO_LINGER, &l, size_of(l))
	net.close(socket)
}

// Windows keeps no such mark; its send buffer is sized to the path by itself, and what is queued here is ordered
// before it gets there.
@(private)
socket_lowat :: proc(socket: net.TCP_Socket, bytes: i32) {}
