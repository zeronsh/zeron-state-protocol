package host

import "core:math/rand"
import "core:net"
import "core:testing"
import "core:time"
import "../third_party/nbio"

// Where the loop is kqueue's (macOS, the BSDs) it keeps what it has asked the system for in a map, by what each waits
// on: a socket and which way. Here a few sockets at a time are waited on, of many, and one of them heard at a time,
// over and over, as a busy node's sockets are: so that map churns, its entries placed and taken away, at its smallest
// and fullest. core:nbio (dev-2026-11) placed each with the runtime's map_entry, which, inserting into a map with no
// slot empty, can give back the slot of another key: what it wrote there landed on that key, this one was left with
// nothing, and the loop failed an assertion when the system said it was ready (a forwarder died so on macOS). On
// Linux and Windows the loop keeps no such map, and this is only churn there, which must lose nothing all the same.
@(test)
loop_churn_loses_no_operation :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	SOCKETS :: 32
	Churn :: struct {
		sockets: [SOCKETS]net.UDP_Socket,
		at:      [SOCKETS]net.Endpoint,
		polls:   [SOCKETS]^nbio.Operation, // waited on, until heard
		heard:   int,
	}
	c: Churn
	for i in 0 ..< SOCKETS {
		err: net.Network_Error
		c.sockets[i], err = nbio.create_udp_socket(.IP4)
		testing.expect(t, err == nil)
		testing.expect(t, net.bind(c.sockets[i], {net.IP4_Loopback, 0}) == nil)
		c.at[i], _ = net.bound_endpoint(c.sockets[i])
	}
	sender, err := net.make_unbound_udp_socket(.IP4)
	testing.expect(t, err == nil)
	defer net.close(sender)
	defer {
		// What waits yet is taken back, and the loop let finish with it, before its socket goes.
		for &p in c.polls {
			if p != nil {
				nbio.remove(p)
				p = nil
			}
		}
		for _ in 0 ..< 3 {
			nbio.tick(0)
		}
		for s in c.sockets {
			net.close(s)
		}
	}
	Poll :: struct {
		c: ^Churn,
		i: int,
	}
	polls: [SOCKETS]Poll
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	// With six or fewer waited on, the map is at its smallest, eight slots, and it is where kqueue's loop went wrong
	// within a thousand or so rounds; at seven it is sixteen, where it rarely does.
	for most in 4 ..= 6 {
		live := 0
		for round in 0 ..< 20_000 {
			for live < most {
				i := rand.int_max(SOCKETS)
				if c.polls[i] != nil {
					continue
				}
				polls[i] = {&c, i}
				c.polls[i] = nbio.poll_poly(c.sockets[i], .Receive, &polls[i], proc(op: ^nbio.Operation, p: ^Poll) {
					buf: [8]byte
					net.recv_udp(p.c.sockets[p.i], buf[:])
					p.c.polls[p.i] = nil
					p.c.heard += 1
				})
				live += 1
			}
			// One of those waited on hears something, and is done with: the next round waits on another.
			i := rand.int_max(SOCKETS)
			for c.polls[i] == nil {
				i = rand.int_max(SOCKETS)
			}
			was := c.heard
			net.send_udp(sender, {1}, c.at[i])
			start := time.tick_now()
			for c.heard == was && time.tick_since(start) < 5 * time.Second {
				testing.expect(t, nbio.tick(10 * time.Millisecond) == nil)
			}
			if !testing.expectf(t, c.heard == was + 1 && c.polls[i] == nil, "with %d waited on, round %d: %d heard, not the one told", most, round, c.heard - was) {
				return
			}
			live -= 1
		}
	}
}

// More changes at once than kqueue is given in one call (QUEUE_SIZE, which the tests build at 256): those beyond wait,
// and are given after. core:nbio (dev-2026-11) moved them over one call at a time, and when more waited than one call
// takes, dropped the first that did not fit: kqueue never heard of it, and what it was for never came. Meaningful
// where the loop is kqueue's; elsewhere it is only many timeouts, which must all come all the same.
@(test)
loop_gives_every_change_it_held_back :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	context.logger.lowest_level = .Error // the loop warns of each it holds back, thousands; what fails is still said
	// Past what two calls give, whatever the loop's size: the define the tests build with, or the largest default.
	N :: 3 * #config(ODIN_NBIO_QUEUE_SIZE, 2048) + 7
	came := 0
	for _ in 0 ..< N {
		nbio.timeout_poly(time.Millisecond, &came, proc(_: ^nbio.Operation, came: ^int) {
			came^ += 1
		})
	}
	start := time.tick_now()
	for came < N && time.tick_since(start) < 5 * time.Second {
		wait := 10 * time.Millisecond
		if loop_held_back() {
			wait = 0
		}
		testing.expect(t, nbio.tick(wait) == nil)
	}
	testing.expectf(t, came == N, "%d of %d timeouts came", came, N)
}

// What a socket has said, read at once, is what it said; and a connection reset under a read or a write ends each with
// an error, at once. On Windows core:nbio (dev-2026-11) took a read or write that failed as it was made, with the
// failure in its OVERLAPPED, for one under way, and waited for ever for a completion the system would never send.
@(test)
loop_ends_reads_and_writes_of_a_reset_connection :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	peer, derr := net.dial_tcp(at)
	testing.expect(t, derr == nil)
	socket, _, aerr := net.accept_tcp(listener)
	testing.expect(t, aerr == nil)
	defer net.close(socket)
	testing.expect(t, nbio.associate_socket(socket) == nil)

	Result :: struct {
		done:  bool,
		n:     int,
		error: bool,
	}
	wait :: proc(t: ^testing.T, r: ^Result, what: string) {
		start := time.tick_now()
		for !r.done && time.tick_since(start) < 5 * time.Second {
			testing.expect(t, nbio.tick(10 * time.Millisecond) == nil)
		}
		testing.expectf(t, r.done, "%s never ended", what)
	}

	// Said before it is read: the read ends as it is made, and has all of it.
	said := "what the peer said first"
	sent, _ := net.send_tcp(peer, transmute([]byte)said)
	testing.expect(t, sent == len(said))
	time.sleep(50 * time.Millisecond)
	buf: [4096]byte
	r: Result
	nbio.recv_poly(socket, {buf[:]}, &r, proc(op: ^nbio.Operation, r: ^Result) {
		r.done, r.n, r.error = true, op.recv.received, op.recv.err != nil
	})
	wait(t, &r, "a read of what was there")
	testing.expectf(t, !r.error && r.n == len(said) && string(buf[:r.n]) == said, "read %d bytes, %q", r.n, string(buf[:r.n]))

	// The peer closes with what it was sent unread, which resets the connection.
	net.send_tcp(socket, transmute([]byte)said)
	time.sleep(50 * time.Millisecond)
	net.close(peer)
	time.sleep(50 * time.Millisecond)
	r = {}
	nbio.recv_poly(socket, {buf[:]}, &r, proc(op: ^nbio.Operation, r: ^Result) {
		r.done, r.n, r.error = true, op.recv.received, op.recv.err != nil
	})
	wait(t, &r, "a read of a reset connection")
	testing.expectf(t, r.error || r.n == 0, "a read of a reset connection read %d bytes", r.n)
	w: Result
	nbio.send_poly(socket, {buf[:]}, &w, proc(op: ^nbio.Operation, r: ^Result) {
		r.done, r.n, r.error = true, op.send.sent, op.send.err != nil
	})
	wait(t, &w, "a write to a reset connection")
	testing.expectf(t, w.error, "a write to a reset connection wrote %d bytes and said nothing wrong", w.n)
}
