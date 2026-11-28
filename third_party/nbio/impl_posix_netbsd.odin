#+private
package nbio

import "core:net"
import "core:sys/posix"

foreign import libc "system:c"

// ZSP: a socket had close-on-exec as it is made, as is one accepted (posix_socket, posix_accept).
POSIX_SOCK_CLOEXEC :: 0x10000000
posix_accept4 :: proc(s: posix.FD) -> posix.FD {
	foreign libc {
		accept4 :: proc(s: posix.FD, address: ^posix.sockaddr, address_len: ^posix.socklen_t, flags: i32) -> posix.FD ---
	}
	return accept4(s, nil, nil, POSIX_SOCK_CLOEXEC)
}
posix_create_socket_error :: net._create_socket_error

posix_listen_error   :: net._listen_error
posix_accept_error   :: net._accept_error
posix_dial_error     :: net._dial_error
posix_tcp_send_error :: net._tcp_send_error
posix_udp_send_error :: net._udp_send_error
posix_tcp_recv_error :: net._tcp_recv_error
posix_udp_recv_error :: net._udp_recv_error
