#+build !linux
package host

import "core:net"

// Elsewhere each device's port is listened for at its own address, which takes nothing from this machine's own
// services: see catch_linux.odin.

@(private)
Catch :: struct {}

@(private)
catch_open :: proc(h: ^Host, at: net.Endpoint) {}

@(private)
catch_close :: proc(h: ^Host) {}

@(private)
catch_try :: proc(h: ^Host) {}

@(private)
caught :: proc(h: ^Host) -> bool {
	return false
}

@(private)
catch_port :: proc(h: ^Host) -> int {
	return -1
}
