#+build !linux
package host

import "core:net"
import "../pipe"

UDP_GSO :: false

@(private)
udp_send_batch :: proc(h: ^Host, b: ^Batch, to: pipe.Address) {
	for i in 0 ..< b.n {
		udp_send(h, b.packets[i][:b.sizes[i]], to)
	}
	b.n = 0
}

@(private)
udp_receive :: proc(h: ^Host, socket: net.UDP_Socket) {
	for _ in 0 ..< 256 {
		n, from, err := net.recv_udp(socket, h.shared)
		if err == .Would_Block {
			break
		}
		if err != nil {
			continue // an unreachable peer, reported late; the link will notice
		}
		udp_input(h, h.shared[:n], address_from(from))
	}
}
