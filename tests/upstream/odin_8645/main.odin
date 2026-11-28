// Reproduces odin-lang/Odin#8645: on Windows, core:nbio's dial whose bind fails closes its socket twice.
//
// dial_exec closes the socket when bind fails, and dial_callback closes it again: by then the handle may have been
// given to a socket made meanwhile, which the second close takes from its owner. bind(0.0.0.0:0) fails once the
// machine's ephemeral TCP ports are all used, which this does first: so it is run only on a machine of its own, a CI
// runner, and never by ./x test.
//
// Prints one line and exits 0: "BROKEN: ..." if any socket made between a failed dial and its callback was closed under
// its owner, or "FIXED: ..." if none of 20 was. Anything else (ports that could not all be taken, a dial that did not
// fail, a crash) is the repro's own failure. Meaningful on Windows only.
//
// Run by .github/workflows/upstream.yml; tests/upstream/run.sh runs it. The copy third_party/nbio is dropped once a
// release has this fixed, with odin-lang/Odin#8642, #8644 and #8647.
package odin_8645

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"
import win "core:sys/windows"

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}

	// Every ephemeral port taken, by sockets bound to port 0 and held.
	held: [dynamic]net.TCP_Socket
	defer for s in held {
		net.close(s)
	}
	for failed := 0; failed < 64; {
		s, err := net.create_socket(.IP4, .TCP)
		if err != nil {
			break
		}
		if net.bind(s, {net.IP4_Any, 0}) != nil {
			net.close(s)
			failed += 1
			continue
		}
		failed = 0
		append(&held, s.(net.TCP_Socket))
	}
	probe, _ := net.create_socket(.IP4, .TCP)
	if net.bind(probe, {net.IP4_Any, 0}) == nil {
		fmt.eprintfln("with %d ports held, a bind to port 0 still succeeds: the dial's bind would not fail", len(held))
		os.exit(2)
	}
	net.close(probe)

	Dial :: struct {
		done: bool,
		err:  net.Network_Error,
	}
	TRIES :: 20
	killed := 0
	for _ in 0 ..< TRIES {
		d: Dial
		nbio.dial_poly(net.Endpoint{net.IP4_Loopback, 9}, &d, proc(op: ^nbio.Operation, d: ^Dial) {
			d^ = {true, op.dial.err}
		})
		// The dial's bind has failed by now. A socket made now is given any handle the dial let go of.
		victim, verr := net.create_socket(.IP4, .TCP)
		if verr != nil {
			fmt.eprintln("no socket could be made:", verr)
			os.exit(2)
		}
		start := time.tick_now()
		for !d.done && time.tick_since(start) < 5 * time.Second {
			nbio.tick(10 * time.Millisecond)
		}
		if !d.done || d.err == nil {
			fmt.eprintfln("the dial, its bind to fail, ended %v, with %v", d.done, d.err)
			os.exit(2)
		}
		// Whether the victim is still a socket, once the dial's callback has run.
		kind: i32
		size := i32(size_of(kind))
		if win.getsockopt(win.SOCKET(net.any_socket_to_socket(victim)), win.SOL_SOCKET, 0x1008 /* SO_TYPE */, ([^]u8)(&kind), &size) != 0 {
			killed += 1
		} else {
			net.close(victim)
		}
	}
	if killed > 0 {
		fmt.printfln("BROKEN: %d of %d sockets made between a failed dial and its callback were closed under their owner", killed, TRIES)
	} else {
		fmt.printfln("FIXED: none of %d sockets made between a failed dial and its callback was closed under its owner", TRIES)
	}
}
