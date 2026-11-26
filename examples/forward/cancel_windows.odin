package main

import "core:net"
import win "core:sys/windows"

// Where a shut socket's overlapped reads may wait yet: aborted, each completing on the port all the same.
socket_cancel :: proc(socket: net.TCP_Socket) {
	win.CancelIoEx(win.HANDLE(uintptr(socket)), nil)
}
