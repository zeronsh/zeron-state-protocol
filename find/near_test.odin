#+build !js
package find

import "core:math/rand"
import "core:slice"
import "core:testing"
import "../zsp"

// A partial replica with nobody to ask who can read, but a relay, which holds everything: what it fetches through the
// relay to answer a question, and when it may say that the answer is settled.

@(private)
Near :: struct {
	w, p, r: World, // one that writes and can read, a partial replica, a relay
	g:       Finder, // the partial replica's
	c:       Client, // of the partial replica
	pages:   Memory_Disk,
	links:   [dynamic][2]^zsp.Session,
}

@(private)
near_make :: proc(t: ^testing.T, n: ^Near) {
	world_make(t, &n.w, &n.p)
	n.r.space, n.r.roster = n.w.space, slice.clone(n.w.roster)
	testing.expect(t, zsp.node_init(&n.r.node, zsp.memory_disk(&n.r.disk), n.r.space, nil, true, 64))
	testing.expect(t, zsp.node_adopt(&n.r.node, n.r.roster))
	n.r.node.now = n.w.node.now
	finder_open(&n.g, &n.p.node, memory_disk(&n.pages), n.p.secret)
	n.c = client_open(&n.p, &n.g)
	n.p.node.host.questions.wanted = proc(_: rawptr, _: ^zsp.Session) {}
	for x in ([]^World{&n.w, &n.p, &n.r}) {
		x.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
			if s.role == .Peer {
				zsp.session_accept(s)
			} else {
				zsp.session_accept(s, {{0, {.Read, .Write}, 0}})
			}
		}
	}
}

@(private)
near_destroy :: proc(n: ^Near) {
	for l in n.links {
		zsp.session_close(l[0])
		zsp.session_close(l[1])
	}
	delete(n.links)
	zsp.session_close(n.c.session)
	finder_close(&n.g)
	client_free(&n.c)
	memory_disk_destroy(&n.pages)
	world_destroy(&n.w)
	world_destroy(&n.p)
	zsp.node_destroy(&n.r.node)
	zsp.memory_disk_destroy(&n.r.disk)
	delete(n.r.roster)
}

// A device dials the relay, as one dials a relay whose key it knows.
@(private)
near_link :: proc(n: ^Near, x: ^World) {
	relay: zsp.Key32
	relay[0] = 1
	append(&n.links, [2]^zsp.Session{zsp.session_open(&x.node, .Peer, true, relay, relay = true), zsp.session_open(&n.r.node, .Peer, false, x.keys.device)})
}

@(private)
near_cut :: proc(n: ^Near, x: ^World) {
	#reverse for l, i in n.links {
		if l[0].node == &x.node {
			zsp.session_close(l[0])
			zsp.session_close(l[1])
			ordered_remove(&n.links, i)
		}
	}
}

// Until nothing more is said, nor found.
@(private)
near_settle :: proc(t: ^testing.T, n: ^Near) {
	for quiet, rounds := 0, 0; quiet < 3 && rounds < 3000; rounds += 1 {
		busy := false
		for l in n.links {
			busy |= link_pass(t, l, max(int))
		}
		level := finder_run(&n.g)
		client_hear(t, &n.c)
		quiet = quiet + 1 if level && !busy else 0
	}
}

// A row in a list, with a value in slot 16, and perhaps another row named in slot 19.
@(private)
near_put :: proc(t: ^testing.T, w: ^World, list: zsp.List, order: u64, value: []byte, ref: zsp.Id = {}) -> zsp.Id {
	w.node.now += 1
	id := zsp.node_id(&w.node, zsp.key_scope(zsp.list_lo(list)))
	place := make([]byte, 24, context.temp_allocator)
	zsp.put_u64(place, list[0])
	zsp.put_u64(place[8:], list[1])
	zsp.put_u64(place[16:], order)
	cells := make([dynamic]zsp.Cell, context.temp_allocator)
	append(&cells, zsp.Cell{id, zsp.PLACE, .Place, zsp.node_stamp(&w.node), place})
	append(&cells, zsp.Cell{id, 16, .Value, zsp.node_stamp(&w.node), value})
	if ref != {} {
		b := make([]byte, 16, context.temp_allocator)
		zsp.put_u64(b, ref[0])
		zsp.put_u64(b[8:], ref[1])
		append(&cells, zsp.Cell{id, 19, .Value, zsp.node_stamp(&w.node), b})
	}
	testing.expect(t, zsp.node_write(&w.node, cells[:]))
	return id
}

// A question of scope 2 (unsigned) whose where is as given, with no order, no totals, up to `limit` rows.
@(private)
near_question :: proc(where_: []byte, limit := 50) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&out, 2)
	append(&out, ..where_)
	append(&out, 0, 0) // no order, not from the end
	zsp.write_varint(&out, 0)
	zsp.write_varint(&out, u64(limit))
	zsp.write_varint(&out, 0)
	return out[:]
}

@(private)
where_list :: proc(out: ^[dynamic]byte, list: zsp.List) {
	append(out, u8(Op.List))
	zsp.write_u64(out, list[0])
	zsp.write_u64(out, list[1])
}

// That slot 16 holds anything.
@(private)
where_exists :: proc(out: ^[dynamic]byte) {
	append(out, u8(Op.Exists), u8(Kind.Bytes), 16, 0)
}

// Rows are fetched from the relay, and once they are all here the answer is settled: by then, and not before, it is
// the whole answer. Nor is it settled once the relay is gone.
@(test)
near_answers_whole :: proc(t: ^testing.T) {
	state := rand.create(31)
	context.random_generator = rand.default_random_generator(&state)
	n: Near
	near_make(t, &n)
	defer near_destroy(&n)
	big := list_of(2, 1)
	value := make([]byte, 1500)
	defer delete(value)
	for i in 0 ..< 600 {
		near_put(t, &n.w, big, u64(i), value)
	}
	near_put(t, &n.w, list_of(2, 2), 0, value)
	near_link(&n, &n.w)
	near_settle(t, &n)
	near_cut(&n, &n.w)
	near_link(&n, &n.p)
	near_settle(t, &n)
	q := make([dynamic]byte, context.temp_allocator)
	append(&q, u8(Op.And), 2)
	where_list(&q, big)
	where_exists(&q)
	client_ask(t, &n.c, 1, near_question(q[:]))
	// A step at a time, as a host does: never settled with less than the whole answer.
	for _ in 0 ..< 3000 {
		for l in n.links {
			link_pass(t, l, max(int))
		}
		level := finder_run(&n.g)
		client_hear(t, &n.c)
		if a, ok := n.c.answers[1]; ok && a.flags & 1 != 0 {
			testing.expectf(t, a.total == 600, "settled with %d of 600", a.total)
			break
		}
		_ = level
	}
	testing.expect(t, n.c.answers[1].flags & 1 != 0, "never settled")
	// The relay goes: what is held is all there is, and is said to be.
	near_cut(&n, &n.p)
	near_settle(t, &n)
	testing.expect(t, n.c.answers[1].flags & 1 == 0, "still settled with nobody behind it")
}

// A question that joins rows of another list, or scope, is about more than the list it names: it is not fetched for
// as though it were, nor said to be settled.
@(test)
near_joins_are_not_settled :: proc(t: ^testing.T) {
	state := rand.create(32)
	context.random_generator = rand.default_random_generator(&state)
	n: Near
	near_make(t, &n)
	defer near_destroy(&n)
	parent := near_put(t, &n.w, list_of(2, 1), 0, transmute([]byte)string("active"))
	near_put(t, &n.w, list_of(2, 2), 0, transmute([]byte)string("child"), parent)
	near_link(&n, &n.w)
	near_settle(t, &n)
	near_cut(&n, &n.w)
	near_link(&n, &n.p)
	near_settle(t, &n)
	q := make([dynamic]byte, context.temp_allocator)
	append(&q, u8(Op.And), 2)
	where_list(&q, list_of(2, 2))
	append(&q, u8(Op.Ref), u8(Kind.Id), 19, 0, 2)
	where_exists(&q)
	client_ask(t, &n.c, 1, near_question(q[:]))
	near_settle(t, &n)
	a := n.c.answers[1]
	testing.expectf(t, a.flags & 1 == 0 || a.total == 1, "settled, with %d", a.total)
}

// Of a question about rows that must be in several lists, one list is fetched: all its rows are in it.
@(test)
near_fetches_one_list :: proc(t: ^testing.T) {
	state := rand.create(33)
	context.random_generator = rand.default_random_generator(&state)
	n: Near
	near_make(t, &n)
	defer near_destroy(&n)
	for i in 1 ..= 10 {
		near_put(t, &n.w, list_of(2, i), 0, transmute([]byte)string("x"))
	}
	near_link(&n, &n.w)
	near_settle(t, &n)
	near_cut(&n, &n.w)
	near_link(&n, &n.p)
	near_settle(t, &n)
	q := make([dynamic]byte, context.temp_allocator)
	append(&q, u8(Op.And), 10)
	for i in 1 ..= 10 {
		where_list(&q, list_of(2, i))
	}
	client_ask(t, &n.c, 1, near_question(q[:]))
	near_settle(t, &n)
	wanted := 0
	for it in n.p.node.interests {
		wanted += int(it.watch.data)
	}
	testing.expect_value(t, wanted, 1)
	testing.expect(t, n.c.answers[1].flags & 1 != 0)
}

// A Fetch asked while a relay can be had, and answered once what it is about is here; when the relay goes before then,
// it is answered with what is held, and not left waiting for ever.
@(test)
near_fetch_without_relay :: proc(t: ^testing.T) {
	state := rand.create(34)
	context.random_generator = rand.default_random_generator(&state)
	n: Near
	near_make(t, &n)
	defer near_destroy(&n)
	for i in 0 ..< 20 {
		near_put(t, &n.w, list_of(2, 1), u64(i), transmute([]byte)string("x"))
	}
	near_link(&n, &n.w)
	near_settle(t, &n)
	near_cut(&n, &n.w)
	near_link(&n, &n.p)
	near_settle(t, &n)
	q := make([dynamic]byte, context.temp_allocator)
	where_list(&q, list_of(2, 1))
	client_ask(t, &n.c, 1, near_question(q[:]), FETCH)
	finder_run(&n.g) // asks for the list, which has yet to come
	near_cut(&n, &n.p)
	near_settle(t, &n)
	a, answered := n.c.answers[1]
	testing.expect(t, answered && a.flags & 32 != 0, "the Fetch was never answered")
	testing.expect_value(t, len(n.g.live), 0)
}

// A Fetch is answered with what is held when the only full replica reached may not be sent what it is about, and when
// the one asked refuses to say: neither will ever confirm it. (Review 2, 4A, 4B.)
@(test)
near_fetch_unconfirmable :: proc(t: ^testing.T) {
	for way in 0 ..< 2 {
		state := rand.create(35)
		context.random_generator = rand.default_random_generator(&state)
		n: Near
		near_make(t, &n)
		defer near_destroy(&n)
		f: World
		defer if way == 0 {
			world_destroy(&f)
		}
		if way == 0 {
			// Another full replica, which may read only scope 1, and nothing of scope 2.
			for &b in f.secret {
				b = byte(rand.uint32())
			}
			zsp.keyring_init(&f.keys, f.secret)
			d := zsp.draft_from(&n.w.node.roster, 2)
			zsp.draft_grant(&d, f.keys.device, f.keys.signer, 1, {.Read, .Write})
			roster, ok := zsp.roster_sign(&n.w.keys, n.w.root, &d)
			testing.expect(t, ok)
			f.roster, f.space = roster, n.w.space
			world_start(t, &f)
			f.node.host.authenticate = n.w.node.host.authenticate
			testing.expect(t, zsp.node_adopt(&n.p.node, roster))
			append(&n.links, link_make(&n.p, &f))
		} else {
			near_link(&n, &n.p)
		}
		near_settle(t, &n)
		q := make([dynamic]byte, context.temp_allocator)
		where_list(&q, list_of(2, 1))
		client_ask(t, &n.c, 1, near_question(q[:]), FETCH)
		finder_run(&n.g)
		if way == 1 {
			// The relay refuses to say anything of it.
			for it in n.p.node.interests {
				if !it.watch.data {
					continue
				}
				w := make([dynamic]byte, context.temp_allocator)
				at := zsp.frame_begin(&w, .Synced)
				zsp.write_varint(&w, it.id)
				zsp.write_u8(&w, 4)
				zsp.write_key(&w, it.watch.lo)
				zsp.write_key(&w, it.watch.hi)
				zsp.write_varint(&w, 0)
				zsp.write_varint(&w, 0)
				zsp.frame_end(&w, at)
				zsp.session_input(n.links[0][0], w[:])
			}
		}
		for _ in 0 ..< 50 {
			finder_run(&n.g)
			client_hear(t, &n.c)
		}
		a, answered := n.c.answers[1]
		testing.expectf(t, answered && a.flags & 32 != 0, "way %d: the Fetch was never answered", way)
		testing.expectf(t, len(n.g.live) == 0, "way %d: %d questions left", way, len(n.g.live))
	}
}
