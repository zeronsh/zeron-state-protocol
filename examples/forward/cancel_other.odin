#+build !windows
package main

import "core:net"

// Shutting a socket both ways ends what waits on it already.
socket_cancel :: proc(socket: net.TCP_Socket) {}
