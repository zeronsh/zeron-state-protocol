#+build linux, darwin, windows
package host

import "core:net"
import "core:testing"

// The system's own account of its sockets: a listener is seen to listen, and a connection made here is this user's.
@(test)
tcp_tables :: proc(t: ^testing.T) {
	for at in ([]net.Endpoint{{net.IP4_Loopback, 0}, {net.IP6_Loopback, 0}}) {
		listener, err := net.listen_tcp(at)
		if err != nil {
			continue // a machine without IPv6
		}
		defer net.close(listener)
		bound, _ := net.bound_endpoint(listener)
		mine := address_from(bound)
		list, ok := tcp_listening()
		testing.expect(t, ok)
		seen := false
		for a in list {
			seen ||= a == mine
		}
		testing.expectf(t, seen, "%v listens", bound)

		client, derr := net.dial_tcp(bound)
		testing.expect(t, derr == nil)
		defer net.close(client)
		server, from, aerr := net.accept_tcp(listener)
		testing.expect(t, aerr == nil)
		defer net.close(server)
		testing.expect(t, tcp_peer_is_mine(mine, address_from(from)))
		// Nobody is at an address that was never connected.
		nobody := address_from(from)
		nobody.port ~= 0x5a5a
		testing.expect(t, !tcp_peer_is_mine(mine, nobody))
	}
}
