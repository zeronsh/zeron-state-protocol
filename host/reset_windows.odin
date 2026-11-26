package host

import "core:net"
import win "core:sys/windows"

// Closes a connection so that the other end hears a reset, not an orderly end: what it was talking to has
// failed, and it should not take what it got for all there was. (core:net's Linger option is not this.)
@(private)
socket_reset :: proc(socket: net.TCP_Socket) {
	abort := win.LINGER{l_onoff = 1, l_linger = 0}
	win.setsockopt(win.SOCKET(uintptr(socket)), win.SOL_SOCKET, win.SO_LINGER, &abort, size_of(abort))
	net.close(socket)
}
