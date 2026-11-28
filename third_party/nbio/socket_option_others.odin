#+build !windows
#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
package nbio

import "core:net"

@(private="package")
_set_socket_option :: proc(s: net.Socket, option: Socket_Option, value: Socket_Option_Value) -> (err: Socket_Option_Error, code: int) {
	return .Unsupported, 0
}

@(private="package")
_socket_option :: proc(s: net.Socket, option: Socket_Option) -> (value: Socket_Option_Value, err: Socket_Option_Error, code: int) {
	return nil, .Unsupported, 0
}
