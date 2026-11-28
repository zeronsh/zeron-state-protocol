#+build !js
package zsp

import "core:math/rand"
import "core:strings"
import "core:testing"

// A local client that is told who wrote what.
@(private)
Reader_Client :: struct {
	s:       ^Session,
	authors: map[u32]string, // subjects, owned
	devices: map[u32]Key32,
	by:      map[Id]u32, // who wrote what is in slot 16
	body:    map[Id]string,
	refused: [dynamic]Id, // rows Acks said were not taken
	seq:     u64, // of the last Cells it sent
}

@(private)
reader_open :: proc(x: ^Sim_Node, credential: string, authors := true) -> (c: Reader_Client) {
	c.s = session_open(&x.node, .Open, false)
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Hello)
	append(&w, VERSION, u8(Hello_Flags{authors = authors}))
	resize(&w, len(w) + 32)
	write_varint(&w, 0)
	write_bytes(&w, transmute([]byte)credential)
	frame_end(&w, at)
	session_input(c.s, w[:])
	return
}

@(private)
reader_close :: proc(c: ^Reader_Client) {
	session_close(c.s)
	for _, a in c.authors {
		delete(a)
	}
	for _, b in c.body {
		delete(b)
	}
	delete(c.authors)
	delete(c.devices)
	delete(c.by)
	delete(c.body)
	delete(c.refused)
	c^ = {}
}

@(private)
reader_hear :: proc(t: ^testing.T, c: ^Reader_Client) {
	out := session_output(c.s)
	r := Reader{buf = out}
	for r.pos < len(out) {
		frame := read_bytes(&r)
		f := Reader{buf = frame[1:]}
		#partial switch Message(frame[0]) {
		case .Author:
			number := u32(read_varint(&f))
			c.devices[number] = read_key32(&f)
			if old, had := c.authors[number]; had {
				delete(old)
			}
			c.authors[number] = strings.clone(string(read_bytes(&f)))
			testing.expect(t, read_done(&f))
		case .Ack:
			_ = read_varint(&f)
			for f.pos < len(f.buf) {
				append(&c.refused, read_pair(&f, Id))
			}
			testing.expect(t, read_done(&f))
		case .Cells:
			_ = read_varint(&f)
			row: Id
			for f.pos < len(f.buf) {
				tag := f.buf[f.pos]
				f.buf[f.pos] &= ~u8(0x40)
				cell, ok := read_cell(&f, row)
				testing.expect(t, ok)
				row = cell.row
				if cell.slot == 16 {
					if old, had := c.body[row]; had {
						delete(old)
					}
					c.body[row] = strings.clone(string(cell.body))
					delete_key(&c.by, row)
				}
				if tag & 0x40 != 0 {
					number := u32(read_varint(&f))
					testing.expect(t, number in c.authors)
					if cell.slot == 16 {
						c.by[row] = number
					}
				}
			}
		}
	}
	session_sent(c.s, len(out))
}

@(private)
reader_write :: proc(x: ^Sim_Node, c: ^Reader_Client, scope: Scope, text: string) -> Id {
	x.node.now += 1000
	row := node_id(&x.node, scope)
	body: [24]byte
	list := list_tag(keyring_scope(&x.keys, scope), "a")
	put_u64(body[:], list[0])
	put_u64(body[8:], list[1])
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Cells)
	c.seq += 1
	write_varint(&w, c.seq)
	place := Cell{row, 1, .Place, node_stamp(&x.node), body[:]}
	value := Cell{row, 16, .Value, node_stamp(&x.node), transmute([]byte)text}
	write_cell(&w, &place, false)
	write_cell(&w, &value, true)
	frame_end(&w, at)
	session_input(c.s, w[:])
	return row
}

@(private)
reader_watch :: proc(c: ^Reader_Client, id: u64, scope: Scope) {
	sim_watch(c.s, id, scope_lo(scope), scope_hi(scope), 0, {data = true})
}

// Who wrote something is whom the writer's host said it was for, if the space says to believe it; whoever the roster
// has the device belong to, if it does not; and nobody's to say where everyone writes with one key.
@(test)
authors_are_who_they_are :: proc(t: ^testing.T) {
	state := seeded(31)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 3, partial = 0, relays = 1, ring = 64)
	defer sim_destroy(&s)
	HOME :: Scope(1) // its key is everyone's
	SHOWN :: Scope(2) // signed; the first two write
	a, b, e := s.nodes[0], s.nodes[1], s.nodes[2]
	for i in 0 ..< 3 {
		sim_link(&s, i, 3)
	}
	change :: proc(t: ^testing.T, s: ^Sim, f: proc(s: ^Sim, d: ^Draft)) {
		x := s.nodes[0]
		x.node.now = sim_now(s, x)
		d := draft_from(&x.node.roster, max(x.node.clock, x.node.now << 16))
		d.random = sim_random
		f(s, &d)
		bytes, ok := roster_sign(&x.keys, s.root, &d)
		defer delete(bytes)
		testing.expect(t, ok && node_adopt(&x.node, bytes))
		sim_settle(s)
	}
	subject :: proc(d: ^Draft, device: Key32, name: string) {
		for &m in d.members {
			if m.device == device {
				m.subject = transmute([]byte)name
			}
		}
	}
	change(t, &s, proc(s: ^Sim, d: ^Draft) {
		subject(d, s.nodes[0].keys.device, "ann")
		subject(d, s.nodes[1].keys.device, "server")
	})
	me, other := reader_open(a, "as ann"), reader_open(e, "let me in")
	plain := reader_open(e, "let me in", authors = false)
	gate := reader_open(b, "as zoe")
	defer reader_close(&me)
	defer reader_close(&other)
	defer reader_close(&plain)
	for c in ([]^Reader_Client{&other, &plain}) {
		reader_watch(c, 1, HOME)
		reader_watch(c, 2, SHOWN)
	}
	hear :: proc(t: ^testing.T, s: ^Sim, all: ..^Reader_Client) {
		for _ in 0 ..< 3 {
			sim_settle(s)
			for c in all {
				reader_hear(t, c)
			}
		}
	}
	hear(t, &s, &me, &other, &plain, &gate)
	testing.expect(t, me.authors[0] == "ann" && me.devices[0] == a.keys.device)
	testing.expect_value(t, gate.authors[0], "zoe")

	// One's own device says so without a word.
	first := reader_write(a, &me, SHOWN, "mine")
	open := reader_write(a, &me, HOME, "anyone's")
	hear(t, &s, &me, &other, &plain)
	testing.expect_value(t, other.authors[other.by[first]], "ann")
	testing.expect(t, other.devices[other.by[first]] == a.keys.device)
	testing.expect(t, open not_in other.by && other.body[open] == "anyone's")
	testing.expect(t, plain.body[first] == "mine" && len(plain.by) == 0 && len(plain.authors) == 0)

	// A device that may not vouch writes for nobody else, whatever its host says, nor in their name: what it says is
	// refused, and said to be, in one scope; its session goes on, and so does what it writes in another.
	not_yet := reader_write(b, &gate, SHOWN, "not yet")
	hear(t, &s, &gate)
	testing.expect(t, !gate.s.closing && len(gate.refused) == 1 && gate.refused[0] == not_yet)
	forged: Id
	{
		b.node.now += 1000
		forged = node_id(&b.node, SHOWN)
		body: [24]byte
		list := list_tag(keyring_scope(&b.keys, SHOWN), "a")
		put_u64(body[:], list[0])
		put_u64(body[8:], list[1])
		testing.expect(t, node_write(&b.node, {{forged, 1, .Place, node_stamp(&b.node), body[:]}, {forged, 16, .Value, node_stamp(&b.node), transmute([]byte)string("as if")}}, transmute([]byte)string("ann")))
		longest := Cell{forged, 18, .Value, node_stamp(&b.node), make([]byte, MAX_OPEN, context.temp_allocator)}
		testing.expect(t, cell_seal(&b.keys, &b.node.roster, &longest, 0, make([]byte, MAX_AS, context.temp_allocator)) && len(longest.body) <= MAX_CELL)
		testing.expect(t, !node_write(&b.node, {{forged, 17, .Value, node_stamp(&b.node), nil}}, make([]byte, MAX_AS + 1, context.temp_allocator)))
	}
	// Where nobody is told, it is nobody's business.
	fine := reader_write(b, &gate, HOME, "anyone's too")
	hear(t, &s, &other, &gate)
	testing.expect_value(t, other.authors[other.by[forged]], "server")
	testing.expect(t, other.body[fine] == "anyone's too" && !gate.s.closing)
	testing.expect(t, not_yet not_in other.body, "what was refused was written")

	// It is let.
	change(t, &s, proc(s: ^Sim, d: ^Draft) {
		draft_grant(d, s.nodes[1].keys.device, s.nodes[1].keys.signer, SHOWN, {.Write, .Vouch})
	})
	zoe := reader_write(b, &gate, SHOWN, "hello")
	max := reader_open(b, "as max")
	hear(t, &s, &max)
	his := reader_write(b, &max, SHOWN, "hello too")
	hear(t, &s, &me, &other, &gate, &max)
	testing.expect_value(t, other.authors[other.by[zoe]], "zoe")
	testing.expect_value(t, other.authors[other.by[his]], "max")
	testing.expect(t, other.devices[other.by[zoe]] == b.keys.device)
	// Whom one may take the word of, one may take the word of whenever it was given: it could say now what it did then.
	testing.expect_value(t, other.authors[other.by[forged]], "ann")
	again := reader_open(e, "let me in")
	reader_watch(&again, 1, SHOWN)
	hear(t, &s, &again)
	testing.expect_value(t, again.authors[again.by[forged]], "ann")

	// A device is said to be somebody else's, and all who were told are told.
	change(t, &s, proc(s: ^Sim, d: ^Draft) {
		subject(d, s.nodes[0].keys.device, "ann smith")
	})
	hear(t, &s, &other, &me)
	testing.expect_value(t, other.authors[other.by[first]], "ann smith")
	testing.expect_value(t, me.authors[0], "ann") // whom its host says

	// It may no longer. What it was believed about then, it is still.
	change(t, &s, proc(s: ^Sim, d: ^Draft) {
		draft_grant(d, s.nodes[1].keys.device, s.nodes[1].keys.signer, SHOWN, {.Write})
	})
	reader_close(&again)
	again = reader_open(e, "let me in")
	reader_watch(&again, 1, SHOWN)
	hear(t, &s, &again)
	testing.expect_value(t, again.authors[again.by[zoe]], "zoe")
	no_more := reader_write(b, &gate, SHOWN, "no more")
	hear(t, &s, &gate)
	testing.expect(t, !gate.s.closing && gate.refused[len(gate.refused) - 1] == no_more)
	// So is what was put together since, of what was written then.
	{
		m := roster_member(&e.node.roster, b.keys.device)
		until: u64
		for g in m.grants {
			until = g.until if g.until > until else until
		}
		testing.expect(t, until > 0)
		c := Cell{zoe, 16, .Bundle, {until + 5, 1}, make([]byte, 20, context.temp_allocator)}
		put_u32(c.body, 1)
		for before in 0 ..< 2 {
			put_u64(c.body[4:], until + 1 - u64(before))
			no, _ := author_index(&b.keys, &e.node.roster)
			_, subject, vouched, _ := cell_author(&e.node.roster, &c, {u32(no) + 1, transmute([]byte)string("zoe")})
			testing.expect(t, vouched == (before == 1) && string(subject) == ("zoe" if before == 1 else "server"))
		}
	}
	// And under a new key it is what it was.
	change(t, &s, proc(s: ^Sim, d: ^Draft) {
		d.scopes[1].rotate = true
	})
	reader_close(&again)
	again = reader_open(e, "let me in")
	reader_watch(&again, 1, SHOWN)
	hear(t, &s, &again)
	testing.expect(t, again.authors[again.by[his]] == "max" && again.body[his] == "hello too")
	reader_close(&again)
	reader_close(&gate)
	reader_close(&max)
}

// And who calls is whom its host says, by the same rule.
@(test)
callers_are_who_they_are :: proc(t: ^testing.T) {
	for relayed in 0 ..< 2 {
		state := seeded(u64(33 + relayed))
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
		defer sim_destroy(&s)
		a, b := s.nodes[0], s.nodes[1]
		if relayed == 1 {
			sim_link(&s, 0, 2)
			sim_link(&s, 1, 2)
		} else {
			sim_link(&s, 0, 1)
		}
		sim_settle(&s)
		grant :: proc(t: ^testing.T, s: ^Sim, rights: Rights) {
			x := s.nodes[0]
			x.node.now = sim_now(s, x) + 1
			d := draft_from(&x.node.roster, max(x.node.clock, x.node.now << 16))
			d.random = sim_random
			draft_grant(&d, x.keys.device, x.keys.signer, 1, rights)
			for &m in d.members {
				if m.device == x.keys.device {
					m.subject = transmute([]byte)string("gateway")
				}
			}
			bytes, ok := roster_sign(&x.keys, s.root, &d)
			defer delete(bytes)
			testing.expect(t, ok && node_adopt(&x.node, bytes))
			sim_settle(s)
		}
		grant(t, &s, {.Write, .Call})
		cb := Caller{s = sim_client(&s, b)}
		defer caller_destroy(&cb)
		caller_serve(&cb, 1, "echo")
		settle(&s, &cb)
		call :: proc(s: ^Sim, x: ^Sim_Node, credential: string, to: Key32, cb: ^Caller, id: u64) -> (who: string, fault: Maybe(Call_Fault)) {
			c := reader_open(x, credential)
			ca := Caller{s = c.s}
			ca.claim = transmute([]byte)string("the president")
			defer caller_destroy(&ca)
			defer delete(c.authors)
			settle(s, &ca)
			calls := len(cb.calls)
			caller_call(&ca, id, to, 1, "echo", "hi")
			settle(s, &ca, cb)
			if len(ca.faults) > 0 {
				fault = ca.faults[0]
			}
			who = strings.clone(cb.who, context.temp_allocator) if len(cb.calls) > calls else "nobody"
			session_close(c.s)
			return
		}
		// It may say nothing but whose it is, and claims are for nothing.
		who, fault := call(&s, a, "let me in", b.keys.device, &cb, 1)
		testing.expect(t, who == "gateway" && fault == nil)
		who, fault = call(&s, a, "as gateway", b.keys.device, &cb, 2)
		testing.expect(t, who == "gateway" && fault == nil)
		who, fault = call(&s, a, "as zoe", b.keys.device, &cb, 3)
		testing.expect(t, who == "nobody" && fault == Call_Fault.Denied)
		if relayed == 0 {
			// One that lies of itself.
			calls := len(cb.calls)
			for p in a.node.sessions {
				if p.ready && p.role == .Peer && p.peer == b.keys.device {
					call_put(&p.out, p, 1 << 20, b.keys.device, 1, "echo", transmute([]byte)string("zoe"), transmute([]byte)string("hi"))
				}
			}
			settle(&s, &cb)
			testing.expect(t, len(cb.calls) == calls + 1 && cb.who == "gateway")
		}
		grant(t, &s, {.Write, .Call, .Vouch})
		who, fault = call(&s, a, "as zoe", b.keys.device, &cb, 4)
		testing.expectf(t, who == "zoe" && fault == nil, "%v %v", who, fault)
		// And on the one device.
		ours := Caller{s = sim_client(&s, a)}
		caller_serve(&ours, 1, "echo")
		settle(&s, &ours)
		who, fault = call(&s, a, "as zoe", a.keys.device, &ours, 5)
		testing.expectf(t, who == "zoe" && fault == nil, "%v %v", who, fault)
		session_close(ours.s)
		caller_destroy(&ours)
		session_close(cb.s)
	}
}

// A local client's right to write in one scope ends as it writes there and in another: what it said in that scope, as it
// crossed the new roster, is refused, and named in the Ack; the session goes on, and what it wrote in the other is taken.
// Neither it nor anything else it wrote is refused for good.
@(test)
a_scope_written_in_no_longer_refuses_only_that :: proc(t: ^testing.T) {
	state := seeded(37)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
	defer sim_destroy(&s)
	HOME :: Scope(1)
	SHOWN :: Scope(2) // the first two write
	a, b := s.nodes[0], s.nodes[1]
	for i in 0 ..< 2 {
		sim_link(&s, i, 2)
	}
	sim_settle(&s)
	writer, other := reader_open(b, "let me in"), reader_open(a, "let me in")
	defer reader_close(&writer)
	defer reader_close(&other)
	reader_watch(&other, 1, HOME)
	reader_watch(&other, 2, SHOWN)
	for _ in 0 ..< 3 {
		sim_settle(&s)
		reader_hear(t, &writer)
		reader_hear(t, &other)
	}
	// b may no longer write in SHOWN, and has heard so before what its client wrote there comes.
	{
		a.node.now = sim_now(&s, a)
		d := draft_from(&a.node.roster, max(a.node.clock, a.node.now << 16))
		d.random = sim_random
		draft_grant(&d, b.keys.device, b.keys.signer, SHOWN, {.Read})
		bytes, ok := roster_sign(&a.keys, s.root, &d)
		defer delete(bytes)
		testing.expect(t, ok && node_adopt(&a.node, bytes) && node_adopt(&b.node, bytes))
	}
	shown := reader_write(b, &writer, SHOWN, "too late")
	testing.expectf(t, !writer.s.closing && writer.s.fault == .None, "a write where it may no longer refused the client: %v", writer.s.fault)
	home := reader_write(b, &writer, HOME, "in time")
	for _ in 0 ..< 3 {
		sim_settle(&s)
		reader_hear(t, &writer)
		reader_hear(t, &other)
	}
	testing.expect(t, !writer.s.closing, "and ended it after")
	testing.expectf(t, len(writer.refused) == 1 && writer.refused[0] == shown, "refused %v", writer.refused[:])
	testing.expect(t, other.body[home] == "in time", "what it wrote where it may was not taken")
	testing.expect(t, shown not_in other.body, "what it wrote where it may not was")
}
