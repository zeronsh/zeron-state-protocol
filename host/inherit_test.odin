package host

import "core:crypto"
import "core:net"
import "core:os"
import "core:testing"
import "core:time"
import "../third_party/nbio"
import "../zsp"

// A process the embedder starts while a node runs, as one that execs a helper, is handed none of the node's files, nor
// its sockets, nor anything else of it: core:os starts it as most do, with every descriptor that may be inherited
// inherited (on Windows, every inheritable handle). So once the node is done, though that process lives on, its store
// and its spaces are another's to have at once, and its ports another's to bind; and on Linux and macOS the child is
// seen to have none of them.
@(test)
host_hands_a_child_nothing :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-inherit-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)

	a: Host
	// A relay, which has no beacon: whose port, shared by every node of the machine, is nobody's to have alone.
	if !testing.expect(t, host_init(&a, {dir = dir, relay = true, full = true, listen = net.Endpoint{net.IP4_Loopback, 0}, udp_port = 0}), "the node does not start") {
		return
	}
	destroyed := false
	defer if !destroyed {
		host_destroy(&a)
	}
	space: zsp.Key32
	crypto.rand_bytes(space[:])
	testing.expect(t, space_open(&a, space) != nil, "the space does not open")
	listening, lerr := net.bound_endpoint(a.listener)
	testing.expect(t, lerr == nil)
	udp := a.udp.port
	testing.expect(t, udp != 0)

	// A connection it has accepted, the other end let go of first, so that what is left of it once the node is done is
	// nothing that holds the port (a TIME_WAIT is the side that closed first's).
	client, derr := net.dial_tcp(listening)
	if testing.expect(t, derr == nil, "could not connect to the node") {
		for start := time.tick_now(); len(a.streams) == 0 && time.tick_since(start) < 10 * time.Second; {
			nbio.tick(10 * time.Millisecond)
		}
		testing.expect(t, len(a.streams) == 1, "the node did not accept the connection")
		net.close(client)
	}

	// The child, alive until this test is done with it.
	command := []string{"ping", "-n", "60", "127.0.0.1"} when ODIN_OS == .Windows else []string{"/bin/sleep", "60"}
	child, serr := os.process_start({command = command})
	if !testing.expectf(t, serr == nil, "could not start a child: %v", serr) {
		return
	}
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child)
	}
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		for what in child_holds(child.pid, dir, listening.port, udp) {
			testing.expectf(t, false, "the child holds %s", what)
		}
	}

	host_destroy(&a)
	destroyed = true
	b: Host
	resumed := host_init(&b, {dir = dir, relay = true, full = true})
	testing.expect(t, resumed, "the store is held by the child after its node was done")
	if resumed {
		testing.expect(t, space_open(&b, space) != nil, "the space is held by the child after its node was done")
		host_destroy(&b)
	}
	// Bound as nothing else is, without any option that would let it share a port: had by nothing still.
	// By core:net's sockets, which need no event loop, this thread's being let go of with the node's.
	if s, e := net.create_socket(.IP4, .TCP); testing.expect(t, e == nil) {
		testing.expectf(t, net.bind(s, listening) == nil, "the port the node listened on, %d, is held by the child", listening.port)
		net.close(s)
	}
	if s, e := net.create_socket(.IP4, .UDP); testing.expect(t, e == nil) {
		testing.expectf(t, net.bind(s, {net.IP4_Any, udp}) == nil, "the node's UDP port, %d, is held by the child", udp)
		net.close(s)
	}
}
