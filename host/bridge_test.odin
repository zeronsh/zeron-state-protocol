package host

import "core:math/rand"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../zsp"

// The port a test lets B be reached at; each test runs on a thread of its own.
@(thread_local, private)
open_port: u16

@(private)
permit_open_port :: proc(sp: ^Space, caller: zsp.Key32, scope: zsp.Scope, port: u16, target: string) -> (bool, bool) {
	return port == open_port && scope == 1 && (target == "" || target == "127.0.0.1"), false
}

// A connection made on a thread of its own to a listener on the loop, which forwards what it accepts to B.
@(private)
Client :: struct {
	port:     int, // of the listener
	send:     int, // bytes to send, then half-close
	read_all: bool, // read the echo, until it ends
	got:      [dynamic]byte,
	sent:     [dynamic]byte,
	reset:    bool, // the connection was reset
	finished: bool, // atomic
	read_too: bool, // read at all
	prefix:   string, // sent first
	slow:     bool, // a little at a time
	heard:    int, // atomic; bytes read
}

@(private)
client_start :: proc(c: ^Client) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data(c, proc(c: ^Client) {
		defer sync.atomic_store(&c.finished, true)
		s, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, c.port})
		if err != nil {
			c.reset = true
			return
		}
		defer net.close(s)
		reader: ^thread.Thread
		Reading :: struct {
			c: ^Client,
			s: net.TCP_Socket,
		}
		r := Reading{c, s}
		if c.read_too {
			reader = thread.create_and_start_with_poly_data(&r, proc(r: ^Reading) {
				buf: [16 << 10]byte
				for {
					n, err := net.recv_tcp(r.s, buf[:])
					if err != nil {
						r.c.reset = true
						return
					}
					if n == 0 {
						return
					}
					append(&r.c.got, ..buf[:n])
					sync.atomic_add(&r.c.heard, n)
				}
			})
		}
		if len(c.prefix) > 0 {
			net.send_tcp(s, transmute([]byte)c.prefix)
			append(&c.sent, ..transmute([]byte)c.prefix)
		}
		chunk: [8 << 10]byte
		for len(c.sent) < c.send + len(c.prefix) {
			for &b in chunk {
				b = byte(rand.uint32())
			}
			n := min(len(chunk), c.send + len(c.prefix) - len(c.sent))
			if c.slow {
				time.sleep(time.Millisecond)
			}
			if _, serr := net.send_tcp(s, chunk[:n]); serr != nil {
				c.reset = true
				break
			}
			append(&c.sent, ..chunk[:n])
		}
		net.shutdown(s, .Send)
		if reader != nil {
			thread.join(reader)
			thread.destroy(reader)
		}
	})
}

@(private)
client_destroy :: proc(c: ^Client, t: ^thread.Thread) {
	thread.join(t)
	thread.destroy(t)
	delete(c.got)
	delete(c.sent)
}

// Listens on the loop, forwarding each connection it accepts to a port on B.
@(private)
Gate :: struct {
	w:        ^World,
	listener: net.TCP_Socket,
	port:     int,
	to:       u16, // B's port
	scope:    zsp.Scope,
	op:       ^nbio.Operation,
	status:   [dynamic]Forward_Status,
	forwards: int,
	early:    []byte,
	inspect:  proc(data: rawptr, first: []byte) -> Inspection,
	last:     ^Forward,
}

@(private)
gate_open :: proc(g: ^Gate, w: ^World, to: u16, scope: zsp.Scope = 1) -> bool {
	g.w, g.to, g.scope = w, to, scope
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		return false
	}
	if nbio.associate_socket(listener) != nil {
		return false
	}
	g.listener = listener
	bound, _ := net.bound_endpoint(listener)
	g.port = bound.port
	g.op = nbio.accept_poly(listener, g, gate_accepted)
	return true
}

@(private)
gate_accepted :: proc(op: ^nbio.Operation, g: ^Gate) {
	g.op = nbio.accept_poly(g.listener, g, gate_accepted)
	if op.accept.err != nil {
		return
	}
	g.forwards += 1
	g.last = forward(world_space(g.w, 1), g.w.keys[2].device, g.scope, g.to, "", op.accept.client, proc(data: rawptr, status: Forward_Status) {
		g := (^Gate)(data)
		append(&g.status, status)
		if status != .Connected {
			g.last = nil
		}
	}, g, g.inspect, g.early)
}

@(private)
gate_close :: proc(g: ^Gate) {
	if g.op != nil {
		nbio.remove(g.op)
	}
	net.close(g.listener)
	delete(g.status)
}

@(private)
client_done :: proc(w: ^World, data: rawptr) -> bool {
	return sync.atomic_load(&(^Client)(data).finished)
}

// What A's connection says reaches B's port and comes back, byte for byte, both halves closing in turn; directly,
// and through the relay; and B writes down who opened what, and how much passed.
@(test)
forward_reaches_a_port :: proc(t: ^testing.T) {
	for udp in ([]bool{true, false}) {
		w: World
		testing.expect(t, world_init(t, &w, udp = udp))
		defer world_destroy(&w)
		testing.expect(t, world_ready(&w, direct = udp))
		e: Echo
		testing.expect(t, echo_start(&e))
		defer echo_stop(&e)
		open_port = u16(e.port)
		w.hosts[2].port_permitted = permit_open_port
		g: Gate
		testing.expect(t, gate_open(&g, &w, u16(e.port)))
		defer gate_close(&g)

		c := Client{port = g.port, send = 3 << 20, read_too = true}
		th := client_start(&c)
		testing.expect(t, world_run(&w, client_done, &c, 60 * time.Second))
		testing.expectf(t, !c.reset && len(c.got) == len(c.sent) && string(c.got[:]) == string(c.sent[:]), "udp %v: %d of %d came back", udp, len(c.got), len(c.sent))
		// Without UDP, a link the relay carries; with it, none.
		testing.expect_value(t, len(world_space(&w, 1).relayed) > 0, !udp)
		client_destroy(&c, th)
		// Both ends let go of everything.
		testing.expect(t, world_run(&w, proc(w: ^World, _: rawptr) -> bool {
			return len(world_space(w, 1).bridges) + len(world_space(w, 2).bridges) + len(world_space(w, 1).calls) + len(world_space(w, 2).calls) == 0
		}))
		testing.expectf(t, len(g.status) == 2 && g.status[0] == .Connected && g.status[1] == .Closed, "%v", g.status[:])
		log, err := os.read_entire_file(file_in(world_space(&w, 2).dir, "audit.log"), context.temp_allocator)
		testing.expect(t, err == nil && strings.contains(string(log), `"event":"open"`) && strings.contains(string(log), `"service":"tcp"`))
		testing.expectf(t, strings.contains(string(log), `"in":3145728,"out":3145728`), "%s", log)
	}
}

// A port nobody offers, a port where nothing listens, a scope the caller has no part in: each refused, the
// connection reset at once, and nothing left behind.
@(test)
forward_refused :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	w.hosts[2].port_permitted = permit_open_port
	// Nothing listens on the port the echo had before it: offered, but refused.
	free_port := u16(0)
	{
		l, _ := net.listen_tcp({net.IP4_Loopback, 0})
		bound, _ := net.bound_endpoint(l)
		free_port = u16(bound.port)
		net.close(l)
	}
	Case :: struct {
		port:   u16,
		open:   u16,
		scope:  zsp.Scope,
		status: Forward_Status,
	}
	for k in ([]Case{{u16(e.port), 1, 1, .Not_Offered}, {free_port, free_port, 1, .Refused}, {u16(e.port), u16(e.port), 2, .Unreachable}}) {
		open_port = k.open
		g: Gate
		testing.expect(t, gate_open(&g, &w, k.port, k.scope))
		c := Client{port = g.port, send = 1000, read_too = true}
		th := client_start(&c)
		testing.expect(t, world_run(&w, client_done, &c))
		testing.expect(t, world_run(&w, proc(w: ^World, g: rawptr) -> bool {return len((^Gate)(g).status) > 0}, &g))
		testing.expectf(t, len(g.status) == 1 && g.status[0] == k.status, "port %d scope %d: %v", k.port, k.scope, g.status[:])
		testing.expectf(t, c.reset && len(c.got) == 0, "port %d: reset %v, %d back", k.port, c.reset, len(c.got))
		client_destroy(&c, th)
		gate_close(&g)
		testing.expect(t, world_run(&w, proc(w: ^World, _: rawptr) -> bool {
			return len(world_space(w, 1).bridges) + len(world_space(w, 2).bridges) + len(world_space(w, 1).calls) + len(world_space(w, 2).calls) == 0
		}))
	}
	testing.expect_value(t, sync.atomic_load(&e.accepted), 0)
}

@(private)
nobody_left :: proc(w: ^World, _: rawptr) -> bool {
	return len(world_space(w, 1).bridges) + len(world_space(w, 2).bridges) + len(world_space(w, 1).calls) + len(world_space(w, 2).calls) == 0
}

// What the gate had before it dialled goes first; an inspector sees what follows, and rejecting it writes a reply that
// is read, not lost to a reset; one that passes lets all of it through.
@(test)
forward_inspects :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	open_port = u16(e.port)
	w.hosts[2].port_permitted = permit_open_port
	for pass in ([]bool{true, false}) {
		g: Gate
		testing.expect(t, gate_open(&g, &w, u16(e.port)))
		g.early = transmute([]byte)string("early:")
		g.inspect = proc(data: rawptr, first: []byte) -> Inspection {
			g := (^Gate)(data)
			if len(first) < 8 {
				return .More
			}
			if string(first[:4]) == "good" {
				return .Pass
			}
			forward_reject(g.last, transmute([]byte)string("HTTP/1.1 403 Forbidden\r\n\r\n"))
			return .Reject
		}
		c := Client{port = g.port, send = 0, read_too = true}
		c.prefix = "good, and more" if pass else "evil, and more"
		th := client_start(&c)
		testing.expect(t, world_run(&w, client_done, &c))
		if pass {
			testing.expectf(t, string(c.got[:]) == "early:good, and more", "%q", string(c.got[:]))
		} else {
			testing.expectf(t, string(c.got[:]) == "HTTP/1.1 403 Forbidden\r\n\r\n" && !c.reset, "%q reset %v", string(c.got[:]), c.reset)
		}
		client_destroy(&c, th)
		testing.expect(t, world_run(&w, nobody_left))
		testing.expectf(t, len(g.status) > 0 && g.status[len(g.status) - 1] == (.Closed if pass else .Rejected), "%v", g.status[:])
		gate_close(&g)
	}
}

// A port no longer offered is cut off, mid-connection, with a reset.
@(test)
forward_rechecked :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	open_port = u16(e.port)
	w.hosts[2].port_permitted = permit_open_port
	g: Gate
	testing.expect(t, gate_open(&g, &w, u16(e.port)))
	defer gate_close(&g)
	c := Client{port = g.port, send = 64 << 20, read_too = true, slow = true}
	th := client_start(&c)
	testing.expect(t, world_run(&w, proc(w: ^World, c: rawptr) -> bool {return sync.atomic_load(&(^Client)(c).heard) > 10_000}, &c))
	open_port = 1
	forwards_recheck(world_space(&w, 2))
	testing.expect(t, world_run(&w, client_done, &c))
	testing.expect(t, c.reset)
	client_destroy(&c, th)
	testing.expect(t, world_run(&w, nobody_left))
	testing.expect(t, len(g.status) == 2 && g.status[1] == .Denied)
	log, _ := os.read_entire_file(file_in(world_space(&w, 2).dir, "audit.log"), context.temp_allocator)
	testing.expect(t, strings.contains(string(log), `"event":"denied"`))
}

// A reader that never reads: what is sent fills what lies between, and stops, holding no more at any hop than the
// windows let it; then it lets go of everything.
@(test)
forward_holds_little_for_a_reader_that_never_reads :: proc(t: ^testing.T) {
	for udp in ([]bool{true, false}) {
		w: World
		testing.expect(t, world_init(t, &w, udp = udp))
		defer world_destroy(&w)
		testing.expect(t, world_ready(&w, direct = udp))
		e: Echo
		testing.expect(t, echo_start(&e, giving_up = true))
		defer echo_stop(&e)
		open_port = u16(e.port)
		w.hosts[2].port_permitted = permit_open_port
		g: Gate
		testing.expect(t, gate_open(&g, &w, u16(e.port)))
		defer gate_close(&g)
		// It sends and sends, and reads nothing of the echo: the echo stops when it cannot write, and so on back.
		c := Client{port = g.port, send = 1 << 30, read_too = false}
		th := client_start(&c)
		Most :: struct {
			pending: int,
			lanes:   int,
			held:    int,
			relay:   int,
			start:   time.Tick,
		}
		most := Most{start = time.tick_now()}
		world_run(&w, proc(w: ^World, data: rawptr) -> bool {
			m := (^Most)(data)
			for i in 1 ..= 2 {
				sp := world_space(w, i)
				for b in sp.bridges {
					m.pending = max(m.pending, len(b.pending) - b.written + len(b.held))
				}
				for s in sp.node.sessions {
					out := len(s.out) - s.sent
					for l in s.lanes {
						out += len(l.out) - l.sent
					}
					m.lanes = max(m.lanes, out)
				}
				for p in w.hosts[i].udp.links {
					if p.link != nil {
						m.held = max(m.held, p.link.held)
					}
				}
			}
			for st in w.hosts[0].streams {
				queued := len(st.out) - st.sent
				if st.session != nil {
					queued += len(st.session.out) - st.session.sent
				}
				m.relay = max(m.relay, queued)
			}
			return time.tick_since(m.start) > 3 * time.Second
		}, &most, 10 * time.Second)
		sent := len(c.sent)
		testing.expectf(t, sent < 32 << 20, "udp %v: %d bytes went into a reader that never reads", udp, sent)
		testing.expectf(t, most.pending <= WINDOW_MOST, "udp %v: a bridge held %d", udp, most.pending)
		testing.expectf(t, most.lanes <= WINDOW_MOST + 64 << 10, "udp %v: a session held %d", udp, most.lanes)
		testing.expectf(t, most.held <= 2 * WINDOW_MOST, "udp %v: a link held %d", udp, most.held)
		testing.expectf(t, most.relay <= 2 * WINDOW_MOST, "udp %v: the relay held %d", udp, most.relay)
		// The gate goes; so does everything.
		forward_close(g.last)
		testing.expect(t, world_run(&w, nobody_left))
		sync.atomic_store(&e.stop, true)
		testing.expect(t, world_run(&w, client_done, &c))
		client_destroy(&c, th)
	}
}

// The relay a forward goes through dies, mid-transfer, as a process does; another both devices are at carries the
// link on, and not a byte is lost.
@(test)
forward_outlives_its_relay :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false, relays = 2))
	defer world_destroy(&w)
	testing.expect(t, world_run(&w, proc(w: ^World, _: rawptr) -> bool {
		// Both devices at both relays.
		for i in 1 ..= 2 {
			at := 0
			for s in world_space(w, i).node.sessions {
				if s.ready && s.peer_relay && len(s.online) > 0 {
					at += 1
				}
			}
			if at < 2 {
				return false
			}
		}
		return true
	}))
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	open_port = u16(e.port)
	w.hosts[2].port_permitted = permit_open_port
	g: Gate
	testing.expect(t, gate_open(&g, &w, u16(e.port)))
	defer gate_close(&g)
	c := Client{port = g.port, send = 8 << 20, read_too = true, slow = true}
	th := client_start(&c)
	testing.expect(t, world_run(&w, proc(w: ^World, c: rawptr) -> bool {return sync.atomic_load(&(^Client)(c).heard) > 256 << 10}, &c))
	// Whichever relay carries it goes.
	a := world_space(&w, 1)
	testing.expect_value(t, len(a.relayed), 1)
	via := zsp.node_session(&a.node, a.relayed[0].via)
	world_kill(&w, 0 if via.peer == w.keys[0].device else 3)
	testing.expect(t, world_run(&w, client_done, &c, 60 * time.Second))
	testing.expectf(t, !c.reset && len(c.got) == len(c.sent) && string(c.got[:]) == string(c.sent[:]), "%d of %d came back", len(c.got), len(c.sent))
	client_destroy(&c, th)
	testing.expect(t, world_run(&w, nobody_left))
	testing.expectf(t, len(g.status) == 2 && g.status[1] == .Closed, "%v", g.status[:])
}
