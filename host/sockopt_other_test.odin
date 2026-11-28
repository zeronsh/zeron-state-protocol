#+build !windows
package host

import "core:net"
import "core:sys/posix"

// The room a socket has of its own to send from, set: core:net's set_option sets integer options wrong (see
// nbio/PATCHES.md), so the system is asked itself.
@(private)
set_send_buffer :: proc(s: net.TCP_Socket, size: i32) -> bool {
	size := size
	return posix.setsockopt(posix.FD(s), posix.SOL_SOCKET, .SNDBUF, &size, size_of(size)) == .OK
}

// As little room as a socket may have to send from, so that a write waits on its peer reading: 4 KiB, as macOS refuses
// none, and Linux makes either its least.
@(private)
LEAST_SEND_BUFFER :: 4096
