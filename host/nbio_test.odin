package host

import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:slice"
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
	defer settle(t)
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
	defer settle(t)
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
	defer settle(t)
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
		code:  u16, // what the system said of it, as the operation keeps it
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
		r.done, r.n, r.error, r.code = true, op.recv.received, op.recv.err != nil, op.system_error
	})
	wait(t, &r, "a read of a reset connection")
	testing.expectf(t, r.error || r.n == 0, "a read of a reset connection read %d bytes", r.n)
	// What the system said of it, kept with the operation where it failed: not whatever the system said last, which by
	// its callback, on Windows, is what the loop's wait said (often 258, a timeout).
	reset_codes := RESET_CODES
	testing.expectf(t, !r.error || slice.contains(reset_codes[:], r.code), "a read of a reset connection says the system said %d", r.code)
	w: Result
	nbio.send_poly(socket, {buf[:]}, &w, proc(op: ^nbio.Operation, r: ^Result) {
		r.done, r.n, r.error, r.code = true, op.send.sent, op.send.err != nil, op.system_error
	})
	wait(t, &w, "a write to a reset connection")
	testing.expectf(t, w.error, "a write to a reset connection wrote %d bytes and said nothing wrong", w.n)
	testing.expectf(t, slice.contains(reset_codes[:], w.code), "a write to a reset connection says the system said %d", w.code)
}

// A dial refused: the system's own word for it is kept with the operation, as it is for every failure, so that whoever
// says why a connection failed (the forwarder does) says what the system said, not what it said last.
@(test)
loop_keeps_what_the_system_said_of_a_refusal :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)
	// A port nothing listens at: one listened at, and let go of.
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	at, _ := net.bound_endpoint(listener)
	net.close(listener)
	Dial :: struct {
		done:  bool,
		error: bool,
		code:  u16,
	}
	d: Dial
	nbio.dial_poly(at, &d, proc(op: ^nbio.Operation, d: ^Dial) {
		d^ = {true, op.dial.err != nil, op.system_error}
		if op.dial.err == nil {
			net.close(op.dial.socket)
		}
	})
	start := time.tick_now()
	for !d.done && time.tick_since(start) < 10 * time.Second {
		testing.expect(t, nbio.tick(10 * time.Millisecond) == nil)
	}
	testing.expectf(t, d.done && d.error, "the dial ended %v, with an error %v", d.done, d.error)
	testing.expectf(t, d.code == REFUSED_CODE, "the dial says the system said %d, not %d", d.code, REFUSED_CODE)
}

// A timeout whose callback removes the timeout due after it. On Windows core:nbio (dev-2026-11) went through the
// timeouts due with an iterator that held the next one meanwhile: the callback freed it under the iterator, which then
// went on from freed memory. Meaningful on Windows, which completes timeouts due together in the order they are due;
// elsewhere the system hands them over in an order of its own, the later may come first, and is then not removed.
@(test)
loop_lets_a_timeout_remove_the_one_after_it :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)
	Timeouts :: struct {
		later:             ^nbio.Operation,
		first, last, gone: bool,
	}
	o: Timeouts
	o.later = nbio.timeout_poly(30 * time.Millisecond, &o, proc(_: ^nbio.Operation, o: ^Timeouts) {
		o.gone = true // to be removed, and never to come where timeouts come in order
		o.later = nil // done with: no longer to be removed
	})
	nbio.timeout_poly(60 * time.Millisecond, &o, proc(_: ^nbio.Operation, o: ^Timeouts) {
		o.last = true
	})
	nbio.timeout_poly(time.Millisecond, &o, proc(_: ^nbio.Operation, o: ^Timeouts) {
		o.first = true
		if o.later != nil {
			nbio.remove(o.later)
		}
	})
	// Not ticked until all three are due, so that the loop finds them due together, in order.
	time.sleep(100 * time.Millisecond)
	start := time.tick_now()
	for !o.last && time.tick_since(start) < 5 * time.Second {
		testing.expect(t, nbio.tick(10 * time.Millisecond) == nil)
	}
	in_order := ODIN_OS == .Windows
	testing.expectf(t, o.first && o.last && !(in_order && o.gone), "the first came %v, the last %v, the one removed %v", o.first, o.last, o.gone)
}

// An operation with a timeout, done while the changes kqueue is to be given have overflowed what one call gives it, and
// its timer due before the call that would delete it: kqueue still has the timer, with the operation in it.
// core:nbio (dev-2026-11) put the operation back in its pool at once, and the timer, firing, handed the loop an
// operation freed (or another's by then). Meaningful where the loop is kqueue's; elsewhere it must merely work.
@(test)
loop_keeps_an_operation_kqueue_may_still_name :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)
	context.logger.lowest_level = .Error // the loop warns of each change it holds back
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	peer, derr := net.dial_tcp(at)
	testing.expect(t, derr == nil)
	defer net.close(peer)
	socket, _, aerr := net.accept_tcp(listener)
	testing.expect(t, aerr == nil)
	defer net.close(socket)
	testing.expect(t, nbio.associate_socket(socket) == nil)

	State :: struct {
		read, later: int,
	}
	s: State
	N :: 3 * #config(ODIN_NBIO_QUEUE_SIZE, 2048) + 7
	buf: [64]byte
	// A read that waits, with a timeout of its own, given to the system before anything comes.
	nbio.recv_poly(socket, {buf[:]}, &s, proc(op: ^nbio.Operation, s: ^State) {
		s.read = op.recv.received
		// More changes than fit what the next call gives kqueue, made before this read is let go of...
		for _ in 0 ..< N {
			nbio.timeout_poly(50 * time.Millisecond, s, proc(_: ^nbio.Operation, s: ^State) {
				s.later += 1
			})
		}
		// ...and the read's timer due before that call. Long enough a timeout that what is sent comes first, however busy
		// the machine: with 10 ms, on a busy Linux runner, the read timed out first.
		time.sleep(350 * time.Millisecond)
	}, timeout = 300 * time.Millisecond)
	testing.expect(t, nbio.tick(0) == nil)
	net.send_tcp(peer, {1, 2, 3})
	start := time.tick_now()
	for s.later < N && time.tick_since(start) < 5 * time.Second {
		wait := 10 * time.Millisecond
		if loop_held_back() {
			wait = 0
		}
		testing.expect(t, nbio.tick(wait) == nil)
	}
	testing.expectf(t, s.read == 3 && s.later == N, "read %d bytes; %d of %d timeouts came", s.read, s.later, N)
}

// As loop_keeps_an_operation_kqueue_may_still_name, after many removals of the first of two reads of one socket, each
// of which gives kqueue the second afresh. The loop counted the changes it queued, and missed that way of queueing one
// (and the wake-up it begins with), while it counted every one it gave: given ran ahead of queued, one for each such
// removal, and once it was further ahead than the changes held back, an operation went back to the pool while its
// timer's deletion was still held, as in the release. Meaningful where the loop is kqueue's.
@(test)
loop_counts_every_change_it_gives_kqueue :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)
	context.logger.lowest_level = .Error // the loop warns of each change it holds back
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	Pair :: struct {
		peer, socket: net.TCP_Socket,
	}
	pairs: [2]Pair
	for &p in pairs {
		derr, aerr: net.Network_Error
		p.peer, derr = net.dial_tcp(at)
		testing.expect(t, derr == nil)
		p.socket, _, aerr = net.accept_tcp(listener)
		testing.expect(t, aerr == nil)
		testing.expect(t, nbio.associate_socket(p.socket) == nil)
	}
	defer for p in pairs {
		net.close(p.peer)
		net.close(p.socket)
	}
	QUEUE :: #config(ODIN_NBIO_QUEUE_SIZE, 2048)

	// More removals of the first of two waiting reads than kqueue is given changes in one call.
	called := 0
	buf: [8]byte
	for _ in 0 ..< QUEUE + 50 {
		first := nbio.recv_poly(pairs[0].socket, {buf[:]}, &called, proc(_: ^nbio.Operation, called: ^int) { called^ += 1 })
		second := nbio.recv_poly(pairs[0].socket, {buf[:]}, &called, proc(_: ^nbio.Operation, called: ^int) { called^ += 1 })
		testing.expect(t, nbio.tick(0) == nil) // both given to kqueue, the second behind the first
		nbio.remove(first)
		testing.expect(t, nbio.tick(0) == nil)
		nbio.remove(second)
		testing.expect(t, nbio.tick(0) == nil)
	}
	testing.expectf(t, called == 0, "%d removed reads called back", called)

	// Then a read with a timeout, done while more changes are held back than one call gives, its timer due before the
	// call that would delete it.
	State :: struct {
		read, later: int,
	}
	s: State
	N :: QUEUE + 7
	nbio.recv_poly(pairs[1].socket, {buf[:]}, &s, proc(op: ^nbio.Operation, s: ^State) {
		s.read = op.recv.received
		for _ in 0 ..< N {
			nbio.timeout_poly(50 * time.Millisecond, s, proc(_: ^nbio.Operation, s: ^State) {
				s.later += 1
			})
		}
		time.sleep(350 * time.Millisecond)
	}, timeout = 300 * time.Millisecond)
	testing.expect(t, nbio.tick(0) == nil)
	net.send_tcp(pairs[1].peer, {1, 2, 3})
	start := time.tick_now()
	for s.later < N && time.tick_since(start) < 5 * time.Second {
		wait := 10 * time.Millisecond
		if loop_held_back() {
			wait = 0
		}
		testing.expect(t, nbio.tick(wait) == nil)
	}
	testing.expectf(t, s.read == 3 && s.later == N, "read %d bytes; %d of %d timeouts came", s.read, s.later, N)
}

// An accept removed after the system has accepted for it all the same: nobody is handed what it accepted, so it is let
// go of. core:nbio (dev-2026-11) accepted on kqueue for an accept removed in the tick it was ready, and on io_uring
// left open what was accepted before the removal took: the peer was never told the connection had gone.
@(test)
loop_lets_go_of_what_a_removed_accept_took :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)
	listener, err := nbio.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	at, _ := net.bound_endpoint(listener)
	called := false
	accepting := nbio.accept_poly(listener, &called, proc(op: ^nbio.Operation, called: ^bool) {
		called^ = true
		if op.accept.err == nil {
			net.close(op.accept.client)
		}
	})
	testing.expect(t, nbio.tick(0) == nil) // given to the system
	peer, derr := net.dial_tcp(at)
	testing.expect(t, derr == nil)
	defer net.close(peer)
	time.sleep(20 * time.Millisecond) // and accepted there, where the system accepts on its own
	nbio.remove(accepting)
	for _ in 0 ..< 10 {
		testing.expect(t, nbio.tick(5 * time.Millisecond) == nil)
	}
	net.close(listener)
	for _ in 0 ..< 3 {
		testing.expect(t, nbio.tick(0) == nil)
	}
	testing.expect(t, !called, "a removed accept called back")
	// The peer is told its connection has gone, one way or another: an end, or a reset. Left open, it would wait.
	net.set_option(peer, .Receive_Timeout, 2 * time.Second)
	b: [8]byte
	n, rerr := net.recv_tcp(peer, b[:])
	testing.expectf(t, (rerr == nil && n == 0) || (rerr != nil && rerr != .Timeout && rerr != .Would_Block), "the peer's connection was left open: read %d bytes, %v", n, rerr)
}

// Reads removed in the same tick as they would have read: what is there for them stays there. core:nbio (dev-2026-11)
// read on kqueue for a read removed in the tick it was ready, into a buffer its owner may have let go of. On io_uring
// and Windows the system reads for the operation itself, before any removal can take: only kqueue's loop reads.
@(test)
loop_reads_nothing_for_a_removed_read :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin && ODIN_OS != .FreeBSD && ODIN_OS != .OpenBSD && ODIN_OS != .NetBSD {
		return
	}
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	Pair :: struct {
		peer, socket: net.TCP_Socket,
		read:         ^nbio.Operation,
		buf:          [16]byte,
		other:        ^Pair,
		called:       bool,
	}
	pairs: [2]Pair
	for &p, i in pairs {
		derr: net.Network_Error
		p.peer, derr = net.dial_tcp(at)
		testing.expect(t, derr == nil)
		aerr: net.Network_Error
		p.socket, _, aerr = net.accept_tcp(listener)
		testing.expect(t, aerr == nil)
		testing.expect(t, nbio.associate_socket(p.socket) == nil)
		p.other = &pairs[1 - i]
	}
	defer for p in pairs {
		net.close(p.peer)
		net.close(p.socket)
	}
	// Each read, if it comes first, removes the other.
	for &p in pairs {
		p.read = nbio.recv_poly(p.socket, {p.buf[:]}, &p, proc(op: ^nbio.Operation, p: ^Pair) {
			p.called = true
			p.read = nil
			if p.other.read != nil {
				nbio.remove(p.other.read)
				p.other.read = nil
			}
		})
	}
	testing.expect(t, nbio.tick(0) == nil) // both given to kqueue, waiting
	for p in pairs {
		net.send_tcp(p.peer, transmute([]byte)string("there"))
	}
	time.sleep(20 * time.Millisecond) // both ready, for the same tick
	for _ in 0 ..< 5 {
		testing.expect(t, nbio.tick(5 * time.Millisecond) == nil)
	}
	testing.expect(t, pairs[0].called != pairs[1].called, "one read called back, and only one")
	for p in pairs {
		if p.called {
			continue
		}
		// The removed read's socket has what was sent it still.
		b: [16]byte
		n, rerr := net.recv_tcp(p.socket, b[:])
		testing.expectf(t, rerr == nil && string(b[:n]) == "there", "what was sent for a removed read is gone: read %d bytes, %v", n, rerr)
	}
}

// A file read that fails as it is made (here, of a file opened only to write) ends, with the error. On Windows
// core:nbio (dev-2026-11) took it for one under way, as Windows leaves its OVERLAPPED pending, and waited for ever.
@(test)
loop_ends_a_read_that_fails_as_it_is_made :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)
	dir, derr := os.make_directory_temp("", "zsp-nbio-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/written-only", dir)
	handle, oerr := nbio.open_sync(path, mode = {.Write, .Create})
	testing.expectf(t, oerr == nil, "could not open %s: %v", path, oerr)
	defer nbio.close(handle)
	Read :: struct {
		done, error: bool,
	}
	r: Read
	buf: [16]byte
	nbio.read_poly(handle, 0, buf[:], &r, proc(op: ^nbio.Operation, r: ^Read) {
		r.done, r.error = true, op.read.err != nil
	})
	start := time.tick_now()
	for !r.done && time.tick_since(start) < 5 * time.Second {
		testing.expect(t, nbio.tick(10 * time.Millisecond) == nil)
	}
	testing.expectf(t, r.done && r.error, "a read of a file opened only to write: ended %v, with an error %v", r.done, r.error)
}

// A read of all, with a timeout, that comes in two pieces: read again for the rest, it keeps the timeout it has. On
// Windows core:nbio (dev-2026-11) linked it a second, in the first's place, and the first, left behind, fired at the
// read once it was done with, failing an assertion. Meaningful on Windows.
@(test)
loop_keeps_one_timeout_for_a_read_of_all :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	peer, derr := net.dial_tcp(at)
	testing.expect(t, derr == nil)
	defer net.close(peer)
	socket, _, aerr := net.accept_tcp(listener)
	testing.expect(t, aerr == nil)
	defer net.close(socket)
	testing.expect(t, nbio.associate_socket(socket) == nil)
	Read :: struct {
		done, error: bool,
		n:           int,
	}
	r: Read
	buf: [10]byte
	// A timeout long enough that both pieces come first, however busy the machine.
	submitted := time.tick_now()
	nbio.recv_poly(socket, {buf[:]}, &r, proc(op: ^nbio.Operation, r: ^Read) {
		r^ = {true, op.recv.err != nil, op.recv.received}
	}, all = true, timeout = time.Second)
	testing.expect(t, nbio.tick(0) == nil)
	net.send_tcp(peer, {1, 2, 3, 4, 5})
	for _ in 0 ..< 5 {
		testing.expect(t, nbio.tick(10 * time.Millisecond) == nil)
	}
	net.send_tcp(peer, {6, 7, 8, 9, 10})
	start := time.tick_now()
	for !r.done && time.tick_since(start) < 2 * time.Second {
		testing.expect(t, nbio.tick(10 * time.Millisecond) == nil)
	}
	testing.expectf(t, r.done && !r.error && r.n == 10, "the read ended %v, with an error %v, %d bytes", r.done, r.error, r.n)
	// Past when the timeout would have come: nothing is left to fire.
	for time.tick_since(submitted) < 1300 * time.Millisecond {
		testing.expect(t, nbio.tick(10 * time.Millisecond) == nil)
	}
}

// Waits of under a millisecond: asked of a tick, and to a timeout due that soon. core:nbio (dev-2026-11) on Windows
// waited in whole milliseconds, truncated: such a wait was none, and the loop spun until it was over. It spun so at the
// end of most waits, as the system wakes a little early, and the host with it: relayed_held_back_waits went round 1135
// times in 50 ms on Windows, 1133 of them in a wait of under a millisecond.
@(test)
loop_waits_out_a_wait_of_under_a_millisecond :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	defer settle(t)

	// A tick asked to wait half a millisecond, with something waiting all the while, for 30 ms.
	waiting := nbio.timeout(time.Second, proc(_: ^nbio.Operation) {})
	ticks := 0
	start := time.tick_now()
	for time.tick_since(start) < 30 * time.Millisecond {
		testing.expect(t, nbio.tick(500 * time.Microsecond) == nil)
		ticks += 1
	}
	nbio.remove(waiting)
	// Waiting, at most 60; spinning, thousands.
	testing.expectf(t, ticks < 300, "ticks of half a millisecond went round %d times in 30 ms", ticks)

	// Twenty timeouts one after the other, each due 0.9 ms after the one before it, the loop ticked without a limit.
	Chain :: struct {
		left: int,
	}
	c := Chain{20}
	next :: proc(_: ^nbio.Operation, c: ^Chain) {
		c.left -= 1
		if c.left > 0 {
			nbio.timeout_poly(900 * time.Microsecond, c, next)
		}
	}
	nbio.timeout_poly(900 * time.Microsecond, &c, next)
	ticks = 0
	start = time.tick_now()
	for c.left > 0 && time.tick_since(start) < 5 * time.Second {
		testing.expect(t, nbio.tick() == nil)
		ticks += 1
	}
	// Waiting, some 20 to 40; spinning, thousands.
	testing.expectf(t, c.left == 0 && ticks < 200, "%d timeouts left; the loop went round %d times for 20 of 0.9 ms", c.left, ticks)
}

// Whatever a test began on its loop, finished before the loop is let go of, after what the test closes on its way out:
// on Windows the loops of every thread share one completion port, and what one left under way comes to another's.
settle :: proc(t: ^testing.T) {
	start := time.tick_now()
	for nbio.num_waiting() > 0 && time.tick_since(start) < 5 * time.Second {
		_ = nbio.tick(10 * time.Millisecond)
	}
	testing.expectf(t, nbio.num_waiting() == 0, "%d operations still waiting as the test ends", nbio.num_waiting())
}
