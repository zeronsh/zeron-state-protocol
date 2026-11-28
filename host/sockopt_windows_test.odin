#+build windows
package host

import "core:net"
import win "core:sys/windows"

// The room a socket has of its own to send from, set: core:net's set_option sets integer options wrong (see
// nbio/PATCHES.md), so the system is asked itself.
@(private)
set_send_buffer :: proc(s: net.TCP_Socket, size: i32) -> bool {
	size := size
	return win.setsockopt(win.SOCKET(s), win.SOL_SOCKET, win.SO_SNDBUF, &size, size_of(size)) == 0
}
