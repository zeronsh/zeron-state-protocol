package host

import "core:net"
import win "core:sys/windows"

// Nobody else may take the very same address and port, as Windows would otherwise let anyone with SO_REUSEADDR.
@(private)
exclusive :: proc(socket: net.TCP_Socket) {
	yes: i32 = 1
	win.setsockopt(win.SOCKET(uintptr(socket)), win.SOL_SOCKET, win.SO_EXCLUSIVEADDRUSE, &yes, size_of(yes))
}

@(private)
socket_listen :: proc(socket: net.TCP_Socket, backlog: int) -> bool {
	return win.listen(win.SOCKET(uintptr(socket)), i32(backlog)) == 0
}
