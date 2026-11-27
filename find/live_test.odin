#+build !js
package find

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"
import "../zsp"

// A client that asks, believes what it is told, and is held against the cells.

@(private)
Client :: struct {
	session: ^zsp.Session,
	answers: map[u64]Told,
	cells:   map[zsp.Id]map[zsp.Stamp][]byte, // as they came
}

@(private)
Told :: struct {
	flags: u8,
	total, first: int,
	ids:   [dynamic]zsp.Id,
	totals: []byte,
}

@(private)
client_hear :: proc(t: ^testing.T, c: ^Client) {
	out := zsp.session_output(c.session)
	r := zsp.Reader{buf = out}
	for r.pos < len(out) {
		frame := zsp.read_bytes(&r)
		f := zsp.Reader{buf = frame[1:]}
		#partial switch type := frame[0]; zsp.Message(type) {
		case .Cells:
			_ = zsp.read_varint(&f)
			row: zsp.Id
			for f.pos < len(f.buf) {
				cell, ok := zsp.read_cell(&f, row)
				testing.expect(t, ok)
				row = cell.row
				if row not_in c.cells {
					c.cells[row] = {}
				}
				m := &c.cells[row]
				if old, again := m[cell.stamp]; again {
					delete(old)
				}
				m[cell.stamp] = slice.clone(cell.body)
			}
		case:
			if type != ANSWER {
				break
			}
			id := zsp.read_varint(&f)
			flags := zsp.read_u8(&f)
			if id not_in c.answers {
				c.answers[id] = {}
			}
			a := &c.answers[id]
			a.flags = flags
			if flags & ~u8(33) != 0 {
				break
			}
			a.total, a.first = int(zsp.read_varint(&f)), int(zsp.read_varint(&f))
			clear(&a.ids)
			n := int(zsp.read_varint(&f))
			for _ in 0 ..< n {
				append(&a.ids, zsp.Id{zsp.read_u64(&f), zsp.read_u64(&f)})
			}
			for id in a.ids {
				testing.expect(t, id in c.cells, "a row is shown that was never sent")
			}
			delete(a.totals)
			a.totals = slice.clone(f.buf[f.pos:])
			many := zsp.read_varint(&f)
			for i := u64(0); i < many && !f.bad; i += 1 {
				_, _ = zsp.read_u8(&f), zsp.read_u64(&f)
				facets := zsp.read_varint(&f)
				for j := u64(0); j < facets && !f.bad; j += 1 {
					_ = zsp.read_varint(&f)
					_ = zsp.read_bytes(&f)
				}
			}
			testing.expect(t, f.pos == len(f.buf))
			testing.expect(t, !f.bad)
		}
	}
	zsp.session_sent(c.session, len(out))
}

// Hears all there is, and, where that shows it to have fallen behind, what is then said again.
@(private)
client_hear_out :: proc(t: ^testing.T, c: ^Client, f: ^Finder) {
	for {
		client_hear(t, c)
		if len(f.again) == 0 {
			return
		}
		for !finder_run(f) {
		}
	}
}

@(private)
client_free :: proc(c: ^Client) {
	for _, &a in c.answers {
		delete(a.ids)
		delete(a.totals)
	}
	for _, &m in c.cells {
		for _, b in m {
			delete(b)
		}
		delete(m)
	}
	delete(c.cells)
	delete(c.answers)
}

@(private)
client_open :: proc(w: ^World, f: ^Finder) -> (c: Client) {
	w.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
		zsp.session_accept(s, {{0, {.Read, .Write}, 0}})
	}
	w.node.host.questions = {
		data  = f,
		asked = proc(data: rawptr, s: ^zsp.Session, type: u8, payload: []byte) -> bool {return finder_asked((^Finder)(data), s, type, payload)},
		shows = proc(data: rawptr, s: ^zsp.Session, row: zsp.Id) -> bool {return finder_shows((^Finder)(data), s, row)},
		again = proc(data: rawptr, s: ^zsp.Session) {finder_again((^Finder)(data), s)},
		ended = proc(data: rawptr, s: ^zsp.Session) {finder_ended((^Finder)(data), s)},
		called = proc(data: rawptr, call: u64, device: zsp.Key32, scope: zsp.Scope, body: []byte) {finder_called((^Finder)(data), call, device, body)},
		flow = proc(data: rawptr, call: u64, kind: zsp.Flow, payload: []byte) {finder_flow((^Finder)(data), call, kind, payload)},
	}
	c.session = zsp.session_open(&w.node, .Open, false)
	hello := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&hello, .Hello)
	append(&hello, zsp.VERSION, 0)
	resize(&hello, len(hello) + 32)
	append(&hello, 0, 0)
	zsp.frame_end(&hello, at)
	zsp.session_input(c.session, hello[:])
	return
}

@(private)
client_ask :: proc(t: ^testing.T, c: ^Client, id: u64, question: []byte, type := ASK) {
	w := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&w, zsp.Message(type))
	zsp.write_varint(&w, id)
	append(&w, ..question)
	zsp.frame_end(&w, at)
	testing.expect(t, zsp.session_input(c.session, w[:]))
}

// A question that can only hold where a column has one value, newest first.
@(private)
ask_value_turned :: proc(w: ^World) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	a := Ask{w, &out}
	zsp.write_varint(&out, 1)
	append(&out, u8(Op.And), 2, u8(Op.Range))
	from := len(out)
	k := ask_column(&out, {.Bytes, .Fold, .Number, .Bool})
	_ = from
	append(&out, 15)
	v := make([dynamic]byte, context.temp_allocator)
	b := Ask{w, &v}
	ask_value(&b, k)
	append(&out, ..v[:])
	append(&out, ..v[:])
	if rand.int_max(2) == 0 {
		append(&out, u8(Op.All))
	} else {
		ask_pred(&a, 3)
	}
	append(&out, 1, 2, 1, 0, 0)
	zsp.write_varint(&out, 30)
	append(&out, 0)
	return out[:]
}

// A client that falls behind is told everything again, and one that may no longer read is told that.
@(test)
those_behind_are_told_again :: proc(t: ^testing.T) {
	state := rand.create(77)
	context.random_generator = rand.default_random_generator(&state)
	w: World
	world_make(t, &w)
	defer world_destroy(&w)
	f: Finder
	pages: Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages), w.secret)
	f.settled = true
	c := client_open(&w, &f)
	defer {
		zsp.session_close(c.session)
		finder_close(&f)
		client_free(&c)
		memory_disk_destroy(&pages)
	}
	for _ in 0 ..< 60 {
		world_write(t, &w)
	}
	client_ask(t, &c, 1, {1, 0, 0, 0, 0, 50, 0})
	for round in 0 ..< 8 {
		for _ in 0 ..< 4 {
			finder_run(&f, 1 << 16)
			client_hear(t, &c)
		}
		for id in c.answers[1].ids {
			scan := zsp.row_scan(&w.node.store, id)
			for cell in zsp.row_next(&w.node.store, &scan) {
				cell := cell
				_ = zsp.cell_open(&w.keys, &w.node.roster, &cell)
				got, has := c.cells[id][cell.stamp]
				testing.expectf(t, has && string(got) == string(cell.body), "round %d", round)
			}
		}
		// Many more changes than are remembered, to rows that are on the screen and stay there.
		for _ in 0 ..< 200 {
			id := rand.choice(c.answers[1].ids[:])
			v := make([]byte, 8, context.temp_allocator)
			zsp.put_u64(v, rand.uint64())
			testing.expect(t, zsp.node_write(&w.node, {{id, 30, .Value, zsp.node_stamp(&w.node), v}}))
		}
	}
	clear(&c.session.grants)
	finder_again(&f, c.session)
	finder_run(&f)
	client_hear(t, &c)
	testing.expect(t, c.answers[1].flags == 2 && len(f.live) == 0)
}

// Rows come and go while they are still being gone over; what is gone is not found once they have been.
@(test)
what_goes_meanwhile_is_gone :: proc(t: ^testing.T) {
	state := rand.create(78)
	context.random_generator = rand.default_random_generator(&state)
	for round in 0 ..< 40 {
		w: World
		world_make(t, &w)
		defer world_destroy(&w)
		for _ in 0 ..< 150 {
			world_write(t, &w)
		}
		source := make([dynamic]byte, context.temp_allocator)
		append(&source, 1, u8(Op.Exists), u8(Kind.Bytes), 16, 0, 0, 0, 0, 50, 0)
		q, ok := query_parse(source[:])
		testing.expect(t, ok)
		index_follow(&w.x)
		query_prepare(&w.x, &q)
		for !index_step(&w.x, 1 + rand.int_max(4)) {
			many := rand.int_max(3)
			for _ in 0 ..< many {
				id := rand.choice(w.rows[:])
				if zsp.row_scope(id) != 1 {
					continue
				}
				kind := rand.int_max(3)
				if kind == 0 {
					testing.expect(t, zsp.node_write(&w.node, {{id, 0, .Grave, zsp.node_stamp(&w.node), nil}}))
				} else if _, dead := zsp.row_grave(&w.node.store, id); !dead {
					testing.expect(t, zsp.node_write(&w.node, {{id, 16, .Value, zsp.node_stamp(&w.node), transmute([]byte)rand.choice(NAMES)}}))
				}
			}
			if round % 2 == 0 {
				world_write(t, &w)
			}
		}
		check_index(t, &w)
		if testing.failed(t) {
			fmt.println("round", round)
			return
		}
	}
}

// Holds what a client was last told, and what it was sent, against the cells.
@(private)
answer_check :: proc(t: ^testing.T, w: ^World, f: ^Finder, c: ^Client, id: u64, question: []byte, flags := u8(1)) -> bool {
	q, _ := query_parse(question)
	query_prepare(&f.x, &q)
	for !f.x.tailing || !query_ready(&f.x, &q) {
		index_step(&f.x, 1000)
	}
	s := index_scope(&f.x, q.scope)
	rows: Set
	defer set_destroy(&rows)
	for row in w.rows {
		if n, ok := row_number(s, row); ok && plain_holds(w, &q.where_, row) {
			set_add(&rows, n)
		}
	}
	page := query_page(s, &q, &rows)
	told := &c.answers[id]
	good := told != nil && told.flags == flags && told.total == rows.count && len(told.ids) == len(page)
	// How well rows answer turns on all that is said anywhere; an answer is not shuffled for that.
	ranked := false
	for o in q.order {
		ranked ||= o.by == .Relevance
	}
	for hit, i in page {
		good &&= ranked || told.ids[i] == hit.id
	}
	for id in told.ids {
		n, ok := row_number(s, id)
		good &&= ok && set_has(&rows, n)
	}
	if !good {
		testing.expectf(t, false, "told %v, and it is %d rows: %v", told, rows.count, page)
		fmt.println("question", id, q.where_)
		return false
	}
	// And the client has the rows it is shown, as they are.
	for row in told.ids {
		scan := zsp.row_scan(&w.node.store, row)
		for cell in zsp.row_next(&w.node.store, &scan) {
			cell := cell
			testing.expect(t, zsp.cell_open(&w.keys, &w.node.roster, &cell))
			got, has := c.cells[row][cell.stamp]
			if !has || string(got) != string(cell.body) {
				testing.expectf(t, false, "a row shown was not sent as it is")
				fmt.println("cell", cell.slot, cell.kind, has)
				return false
			}
		}
	}
	return true
}

@(test)
answers_stay_true :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_FIND_SEEDS, 6)
	FIRST :: #config(ZSP_FIND_FIRST, 0)
	for seed in FIRST ..< FIRST + SEEDS {
		state := rand.create(u64(seed) + 5000)
		context.random_generator = rand.default_random_generator(&state)
		w: World
		world_make(t, &w)
		defer world_destroy(&w)
		f: Finder
		pages: Memory_Disk
		finder_open(&f, &w.node, memory_disk(&pages), w.secret)
		f.settled = true
		c := client_open(&w, &f)
		asked := make(map[u64][]byte)
		defer {
			zsp.session_close(c.session)
			finder_close(&f)
			client_free(&c)
			for _, q in asked {
				delete(q)
			}
			delete(asked)
			memory_disk_destroy(&pages)
		}
		for _ in 0 ..< 20 {
			world_write(t, &w)
		}
		for step in 0 ..< 60 {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			many_2 := (300 if rand.int_max(15) == 0 else rand.int_max(8))
			for _ in 0 ..< many_2 {
				world_write(t, &w)
			}
			if rand.int_max(3) == 0 {
				id := u64(rand.int_max(8))
				if id in asked && rand.int_max(3) == 0 {
					u := make([dynamic]byte, context.temp_allocator)
					at := zsp.frame_begin(&u, zsp.Message(UNASK))
					zsp.write_varint(&u, id)
					zsp.frame_end(&u, at)
					testing.expect(t, zsp.session_input(c.session, u[:]))
					delete(asked[id])
					delete_key(&asked, id)
				} else {
					q := ask(&w) if rand.int_max(2) == 0 else ask_value_turned(&w)
					delete(asked[id])
					asked[id] = slice.clone(q)
					client_ask(t, &c, id, q)
				}
			}
			if rand.int_max(3) == 0 {
				client_hear(t, &c) // in the middle
			}
			if rand.int_max(8) == 0 {
				world_rename(t, &w)
			}
			for !finder_run(&f, 1 + rand.int_max(200)) {
				if rand.int_max(10) == 0 {
					world_write(t, &w)
				}
			}
			finder_run(&f)
			if rand.int_max(4) == 0 {
				continue
			}
			client_hear_out(t, &c, &f)
			if rand.int_max(3) == 0 {
				// Asked once: answered, with what was written just before, and that is all.
				q := ask(&w) if rand.int_max(2) == 0 else ask_value_turned(&w)
				world_write(t, &w)
				before := len(f.live)
				client_ask(t, &c, 100, q, FETCH)
				for n := 0; n < 4000 && len(f.live) > before; n += 1 {
					finder_run(&f, 1 + rand.int_max(200))
				}
				client_hear_out(t, &c, &f)
				testing.expect(t, len(f.live) == before)
				if !answer_check(t, &w, &f, &c, 100, q, 33) {
					fmt.println("seed", seed, "step", step, "fetch")
					return
				}
				for _ in 0 ..< 3 {
					world_write(t, &w)
				}
				for !finder_run(&f) {
				}
				finder_run(&f)
				client_hear_out(t, &c, &f)
			}
			// Live text is asked for wherever a row is shown, and nowhere once none is.
			wanted := 0
			for l in f.live {
				wanted += len(l.lives)
				for id in l.shown {
					places := zsp.row_places(&w.node.store, id)
					if places.count == 0 || zsp.is_graveyard(zsp.key_list(places.keys[0])) {
						continue
					}
					covered := false
					for it in w.node.interests {
						covered ||= it.watch.live && !zsp.key_less(places.keys[0], it.watch.lo) && zsp.key_less(places.keys[0], it.watch.hi)
					}
					testing.expectf(t, covered, "seed %d: nothing typed in %v comes", seed, id)
				}
			}
			testing.expect_value(t, len(w.node.interests), wanted)
			for id, question in asked {
				if !answer_check(t, &w, &f, &c, id, question) {
					fmt.println("seed", seed, "step", step)
					return
				}
			}
			if testing.failed(t) {
				fmt.println("seed", seed, "step", step)
				return
			}
		}
	}
}

// Passes some bytes each way along a link, if there is one.
@(private)
link_pass :: proc(t: ^testing.T, link: [2]^zsp.Session, budget: int) -> (busy: bool) {
	for from, i in link {
		if from == nil {
			return
		}
		out := zsp.session_output(from)
		n := min(len(out), budget)
		if n == 0 {
			continue
		}
		busy = true
		copied := slice.clone(out[:n], context.temp_allocator)
		zsp.session_sent(from, n)
		testing.expectf(t, zsp.session_input(link[1 - i], copied), "%v", link[1 - i].fault)
	}
	return
}

@(private)
link_make :: proc(p, w: ^World) -> [2]^zsp.Session {
	return {zsp.session_open(&p.node, .Peer, true, w.keys.device), zsp.session_open(&w.node, .Peer, false, p.keys.device)}
}

// Until nobody has anything more to say.
@(private)
link_settle :: proc(t: ^testing.T, link: [2]^zsp.Session, f, g: ^Finder) -> bool {
	rounds := 0
	for quiet := 0; quiet < 3; {
		busy := link_pass(t, link, max(int))
		f_level, g_level := finder_run(f), finder_run(g)
		quiet = quiet + 1 if f_level && g_level && !busy else 0
		rounds += 1
		if rounds > 3000 {
			testing.expectf(t, false, "never quiet: %v %v %v", busy, f_level, g_level)
			return false
		}
	}
	return true
}

// A partial replica that has a full one answer, over a link that comes and goes.
@(test)
questions_are_passed_on :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_FIND_SEEDS, 6)
	FIRST :: #config(ZSP_FIND_FIRST, 0)
	for seed in FIRST ..< FIRST + SEEDS {
		state := rand.create(u64(seed) + 9000)
		context.random_generator = rand.default_random_generator(&state)
		w, p: World
		world_make(t, &w, &p)
		defer world_destroy(&w)
		defer world_destroy(&p)
		f, g, own: Finder
		pages: [3]Memory_Disk
		finder_open(&f, &w.node, memory_disk(&pages[0]), w.secret)
		finder_open(&g, &p.node, memory_disk(&pages[1]), p.secret)
		finder_open(&own, &p.node, memory_disk(&pages[2]), p.secret) // looks on
		f.settled = true
		elsewhere := client_open(&w, &f)
		c := client_open(&p, &g)
		for x in ([]^World{&w, &p}) {
			x.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
				if s.role == .Peer {
					zsp.session_accept(s)
				} else {
					zsp.session_accept(s, {{0, {.Read, .Write}, 0}})
				}
			}
		}
		link: [2]^zsp.Session
		asked := make(map[u64][]byte)
		defer {
			for s in link {
				if s != nil {
					zsp.session_close(s)
				}
			}
			zsp.session_close(c.session)
			zsp.session_close(elsewhere.session)
			finder_run(&f)
			testing.expect(t, len(f.live) == 0 && len(g.live) == 0 && len(p.node.interests) == 0)
			testing.expect(t, len(w.node.calls) == 0 && len(p.node.calls) == 0)
			for x in ([]^Finder{&f, &g, &own}) {
				finder_close(x)
			}
			client_free(&c)
			client_free(&elsewhere)
			for _, q in asked {
				delete(q)
			}
			delete(asked)
			for &d in pages {
				memory_disk_destroy(&d)
			}
		}
		for _ in 0 ..< 40 {
			world_write(t, &w)
		}
		for step in 0 ..< 40 {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			if link[0] == nil ? rand.int_max(2) == 0 : rand.int_max(6) == 0 {
				if link[0] == nil {
					link = link_make(&p, &w)
				} else {
					zsp.session_close(link[0])
					zsp.session_close(link[1])
					link = {}
				}
			}
			p.node.now = max(p.node.now, w.node.now)
			w.node.now = p.node.now
			many_3 := (200 if rand.int_max(15) == 0 else rand.int_max(8))
			for _ in 0 ..< many_3 {
				world_write(t, &w)
			}
			if told := c.answers[u64(rand.int_max(4))]; link[0] != nil && len(told.ids) > 0 && rand.int_max(2) == 0 {
				// Something is written here about what is shown.
				id := rand.choice(told.ids[:])
				if _, dead := zsp.row_grave(&p.node.store, id); !dead {
					testing.expect(t, zsp.node_write(&p.node, {{id, 16, .Value, zsp.node_stamp(&p.node), transmute([]byte)rand.choice(NAMES)}}))
				}
			}
			if rand.int_max(2) == 0 {
				id := u64(rand.int_max(4))
				if id in asked && rand.int_max(3) == 0 {
					u := make([dynamic]byte, context.temp_allocator)
					at := zsp.frame_begin(&u, zsp.Message(UNASK))
					zsp.write_varint(&u, id)
					zsp.frame_end(&u, at)
					testing.expect(t, zsp.session_input(c.session, u[:]))
					delete(asked[id])
					delete_key(&asked, id)
				} else {
					q := ask(&w) if rand.int_max(2) == 0 else ask_value_turned(&w)
					delete(asked[id])
					asked[id] = slice.clone(q)
					client_ask(t, &c, id, q)
				}
			}
			many_4 := rand.int_max(6)
			for _ in 0 ..< many_4 {
				link_pass(t, link, 1 + rand.int_max(2000))
				finder_run(&f, 1 + rand.int_max(200))
				finder_run(&g, 1 + rand.int_max(200))
				if rand.int_max(3) == 0 {
					client_hear(t, &c)
				}
			}
			if rand.int_max(3) == 0 {
				continue
			}
			if !link_settle(t, link, &f, &g) {
				fmt.println("seed", seed, "step", step)
				return
			}
			client_hear_out(t, &c, &g)
			if rand.int_max(3) == 0 {
				q := ask(&w) if rand.int_max(2) == 0 else ask_value_turned(&w)
				before := len(g.live)
				client_ask(t, &c, 100, q, FETCH)
				if !link_settle(t, link, &f, &g) {
					fmt.println("seed", seed, "step", step)
					return
				}
				client_hear_out(t, &c, &g)
				testing.expect(t, len(g.live) == before)
				good := answer_check(t, &w, &f, &c, 100, q, 33) if link[0] != nil else answer_check_here(t, &p, &own, &c, 100, q, 32)
				if !good {
					fmt.println("seed", seed, "step", step, "fetch", link[0] != nil)
					return
				}
			}
			// Nothing is wanted but what is shown, and no call goes on that nobody needs.
			wanted, calls := 0, 0
			for l in g.live {
				wanted += len(l.far.keys)
				calls += 1 if l.far.call != 0 else 0
			}
			held := 0
			for it in p.node.interests {
				held += 1 if it.watch.data else 0
			}
			testing.expectf(t, held == wanted && len(p.node.calls) == calls, "%d places wanted of %d, %d calls of %d", held, wanted, len(p.node.calls), calls)
			testing.expectf(t, len(w.node.calls) == (calls if link[0] != nil else 0) && len(f.live) == len(w.node.calls), "%d calls", len(w.node.calls))
			for id, question in asked {
				good: bool
				if link[0] != nil {
					good = answer_check(t, &w, &f, &c, id, question)
				} else {
					good = answer_check_here(t, &p, &own, &c, id, question)
				}
				if !good {
					fmt.println("seed", seed, "step", step, "linked", link[0] != nil)
					return
				}
			}
			if testing.failed(t) {
				fmt.println("seed", seed, "step", step)
				return
			}
		}
	}
}

// With nobody to ask, an answer is what is held here, and says that it is.
@(private)
answer_check_here :: proc(t: ^testing.T, p: ^World, own: ^Finder, c: ^Client, id: u64, question: []byte, flags := u8(0)) -> bool {
	q, _ := query_parse(question)
	index_follow(&own.x)
	query_prepare(&own.x, &q)
	for !own.x.tailing || !query_ready(&own.x, &q) {
		index_step(&own.x, 1000)
	}
	index_step(&own.x, 1 << 20)
	s := index_scope(&own.x, q.scope)
	rows := pred_rows(s, &q.where_)
	defer set_destroy(&rows)
	told := &c.answers[id]
	testing.expectf(t, told.flags == flags && told.total == rows.count, "told %v of %d", told, rows.count)
	return !testing.failed(t)
}

// What is passed on is as much as it is, to whoever will have it, for as long as it may be.
@(test)
questions_are_passed_on_in_all_weathers :: proc(t: ^testing.T) {
	state := rand.create(91)
	context.random_generator = rand.default_random_generator(&state)
	w, p: World
	world_make(t, &w, &p)
	defer world_destroy(&w)
	defer world_destroy(&p)
	f, g: Finder
	pages: [2]Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages[0]), w.secret)
	finder_open(&g, &p.node, memory_disk(&pages[1]), p.secret)
	c := client_open(&p, &g)
	elsewhere := client_open(&w, &f)
	p.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
		zsp.session_accept(s, {{0, {.Read, .Write}, 0}} if s.role == .Open else nil)
	}
	w.node.host.authenticate = p.node.host.authenticate
	link := link_make(&p, &w)
	defer {
		zsp.session_close(link[0])
		zsp.session_close(link[1])
		zsp.session_close(c.session)
		zsp.session_close(elsewhere.session)
		finder_close(&f)
		finder_close(&g)
		client_free(&c)
		client_free(&elsewhere)
		for &d in pages {
			memory_disk_destroy(&d)
		}
	}
	for &x in w.node.roster.members {
		testing.expect(t, .Call not_in zsp.member_rights(&x, 1)) // to read is enough
	}
	p.node.now = w.node.now
	place :: proc(w: ^World, order: u64) -> (id: zsp.Id) {
		id = zsp.node_id(&w.node, 1)
		append(&w.rows, id)
		b := make([]byte, 24, context.temp_allocator)
		l := list_of(1, 0)
		zsp.put_u64(b, l[0])
		zsp.put_u64(b[8:], l[1])
		zsp.put_u64(b[16:], order)
		zsp.node_write(&w.node, {{id, 1, .Place, zsp.node_stamp(&w.node), b}})
		return
	}
	for i in 0 ..< 1500 {
		place(&w, u64(i))
	}
	// A thousand of them, the newest first; and in another, what refers to something in another scope.
	q := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&q, 1)
	append(&q, u8(Op.All), 1, 2, 1, 0, 0)
	zsp.write_varint(&q, 1000)
	append(&q, 0)
	joined := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&joined, 1)
	append(&joined, u8(Op.Not), u8(Op.Ref), u8(Kind.Id), 19, 0)
	zsp.write_varint(&joined, 2)
	append(&joined, u8(Op.All), 0, 0, 0, 5, 0)
	client_ask(t, &c, 1, q[:])
	client_ask(t, &c, 2, joined[:])

	// Nobody will, yet.
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect(t, c.answers[1].flags == 0 && len(f.live) == 0 && len(w.node.calls) == 0)
	zsp.session_close(link[0])
	zsp.session_close(link[1])
	f.settled = true
	finder_run(&g)
	link = link_make(&p, &w)
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect(t, answer_check(t, &w, &f, &c, 1, q[:]) && answer_check(t, &w, &f, &c, 2, joined[:]))

	// Again and again, so that it comes to far more than may be said unasked.
	for i in 0 ..< 60 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		place(&w, 5000 + u64(i))
		testing.expect(t, link_settle(t, link, &f, &g))
		client_hear_out(t, &c, &g)
		testing.expect_value(t, c.answers[1].total, 1501 + i)
		if testing.failed(t) {
			return
		}
	}
	// And while nobody listens, which is made up for when somebody does.
	for i in 0 ..< 20 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		place(&w, 6000 + u64(i))
		for !finder_run(&f) {
		}
	}
	testing.expect(t, len(zsp.session_output(link[1])) <= 2 * zsp.CALL_WINDOW)
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect_value(t, c.answers[1].total, 1580)
	testing.expect(t, answer_check(t, &w, &f, &c, 1, q[:]))

	// A roster that takes nothing away ends nothing; one that does ends what turned on it.
	change :: proc(t: ^testing.T, w, p: ^World, revoke: bool) {
		d := zsp.draft_from(&w.node.roster, max(w.node.clock, w.node.now << 16))
		if revoke {
			zsp.draft_revoke(&d, p.keys.device, 2)
		} else {
			d.scopes[0].rotate = true
		}
		bytes, ok := zsp.roster_sign(&w.keys, w.root, &d)
		defer delete(bytes)
		testing.expect(t, ok && zsp.node_adopt(&w.node, bytes))
	}
	change(t, &w, &p, false)
	testing.expect(t, len(w.node.calls) == 2)
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect(t, len(w.node.calls) == 2 && c.answers[2].flags == 1)
	change(t, &w, &p, true)
	finder_run(&f)
	testing.expect(t, len(f.live) == 1 && len(w.node.calls) == 1) // though the other has yet to hear
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect(t, c.answers[2].flags == 2)
	testing.expect(t, answer_check(t, &w, &f, &c, 1, q[:]))

	// Who answered does so no more, and says so.
	finder_close(&f)
	finder_open(&f, &w.node, memory_disk(&pages[0]), w.secret)
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect(t, c.answers[1].flags == 0 && len(w.node.calls) == 0 && len(p.node.calls) == 0)
}

// The words of a column are read afresh while a question is asked of them, and rows change meanwhile.
@(test)
words_renewed_beneath_a_question :: proc(t: ^testing.T) {
	state := rand.create(93)
	context.random_generator = rand.default_random_generator(&state)
	w: World
	world_make(t, &w)
	defer world_destroy(&w)
	f: Finder
	pages: Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages), w.secret)
	f.settled = true
	c := client_open(&w, &f)
	defer {
		zsp.session_close(c.session)
		finder_close(&f)
		client_free(&c)
		memory_disk_destroy(&pages)
	}
	write :: proc(t: ^testing.T, w: ^World, id: zsp.Id, text: string) {
		w.node.now += 10
		testing.expect(t, zsp.node_write(&w.node, {{id, 20, .Value, zsp.node_stamp(&w.node), transmute([]byte)text}}))
	}
	for _ in 0 ..< 40 {
		id := zsp.node_id(&w.node, 1)
		append(&w.rows, id)
		b := make([]byte, 24, context.temp_allocator)
		l := list_of(1, 0)
		zsp.put_u64(b, l[0])
		zsp.put_u64(b[8:], l[1])
		testing.expect(t, zsp.node_write(&w.node, {{id, 1, .Place, zsp.node_stamp(&w.node), b}}))
		write(t, &w, id, "band apple")
	}
	q := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&q, 1)
	append(&q, u8(Op.Match), u8(Kind.Words), 20, 0, 0, 0, 4)
	append(&q, "band")
	append(&q, 1, 2, 1, 0, 0, 50, 0)
	client_ask(t, &c, 1, q[:])
	renewed := 0
	for round in 0 ..< 400 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		many := 1 + rand.int_max(6)
		for _ in 0 ..< many {
			write(t, &w, rand.choice(w.rows[:]), rand.choice([]string{"band apple", "band fig", "fig", "grape"}))
		}
		finder_run(&f, 1 + rand.int_max(12))
		h := f.live[0].q.where_.held
		renewed += 1 if h != nil && round > 40 && h.filling != nil else 0
		if round % 4 == 3 {
			for !finder_run(&f) {
			}
			finder_run(&f)
			client_hear_out(t, &c, &f)
			if !answer_check(t, &w, &f, &c, 1, q[:]) {
				fmt.println("round", round)
				return
			}
		}
	}
	testing.expect(t, renewed > 5)
}

// And where they are read afresh, and all of it done, within one go at what changed, what changed is judged once they
// are: not against the column while it is empty.
@(test)
words_renewed_at_once :: proc(t: ^testing.T) {
	state := rand.create(94)
	context.random_generator = rand.default_random_generator(&state)
	w: World
	world_make(t, &w)
	defer world_destroy(&w)
	f: Finder
	pages: Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages), w.secret)
	f.settled, f.pace = true, false
	c := client_open(&w, &f)
	defer {
		zsp.session_close(c.session)
		finder_close(&f)
		client_free(&c)
		memory_disk_destroy(&pages)
	}
	write :: proc(t: ^testing.T, w: ^World, id: zsp.Id, text: string) {
		w.node.now += 10
		testing.expect(t, zsp.node_write(&w.node, {{id, 20, .Value, zsp.node_stamp(&w.node), transmute([]byte)text}}))
	}
	for i in 0 ..< 2 {
		id := zsp.node_id(&w.node, 1)
		append(&w.rows, id)
		b := make([]byte, 24, context.temp_allocator)
		l := list_of(1, 0)
		zsp.put_u64(b, l[0])
		zsp.put_u64(b[8:], l[1])
		testing.expect(t, zsp.node_write(&w.node, {{id, 1, .Place, zsp.node_stamp(&w.node), b}}))
		write(t, &w, id, "apple" if i == 0 else "noise")
	}
	q := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&q, 1)
	append(&q, u8(Op.Match), u8(Kind.Words), 20, 0, 0, 0, 5)
	append(&q, "apple")
	append(&q, 1, 2, 1, 0, 0, 50, 0)
	client_ask(t, &c, 1, q[:])
	for i in 0 ..< 4 * DEAD {
		write(t, &w, w.rows[1], fmt.tprintf("noise%d", i))
		if i % 3 == 0 {
			write(t, &w, w.rows[0], "apple" if i % 2 == 0 else "apple band")
		}
		for !finder_run(&f, 1 << 16) {
		}
		client_hear_out(t, &c, &f)
		if !answer_check(t, &w, &f, &c, 1, q[:]) {
			fmt.println("edit", i)
			return
		}
	}
}

// What is dear to answer is answered no more often than it is worth, but is in the end.
@(test)
dear_answers_are_paced :: proc(t: ^testing.T) {
	state := rand.create(95)
	context.random_generator = rand.default_random_generator(&state)
	w: World
	world_make(t, &w)
	defer world_destroy(&w)
	f: Finder
	pages: Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages), w.secret)
	f.settled, f.pace = true, true
	c := client_open(&w, &f)
	defer {
		zsp.session_close(c.session)
		finder_close(&f)
		client_free(&c)
		memory_disk_destroy(&pages)
	}
	q := []byte{1, 0, 1, 2, 1, 0, 0, 50, 0}
	client_ask(t, &c, 1, q)
	for !finder_run(&f) {
	}
	finder_run(&f)
	client_hear_out(t, &c, &f)
	testing.expect(t, answer_check(t, &w, &f, &c, 1, q) && f.wake == nil)
	// As if it had been dear: not again for an hour, however slowly the writes go here.
	l := f.live[0]
	l.due = time.tick_add(time.tick_now(), time.Hour)
	for _ in 0 ..< 20 {
		world_write(t, &w)
	}
	finder_run(&f)
	client_hear_out(t, &c, &f)
	testing.expect(t, c.answers[1].total == 0 && f.wake == l.due)
	// And the hour gone by, as the host would wake it then.
	l.due = time.tick_now()
	finder_run(&f)
	client_hear_out(t, &c, &f)
	testing.expect(t, answer_check(t, &w, &f, &c, 1, q) && f.wake == nil)
}

// A question asked again for another part of the same, or by another, is not gone over again, nor are its rows
// said again.
@(test)
what_is_known_is_not_found_again :: proc(t: ^testing.T) {
	state := rand.create(97)
	context.random_generator = rand.default_random_generator(&state)
	w: World
	world_make(t, &w)
	defer world_destroy(&w)
	f: Finder
	pages: Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages), w.secret)
	f.settled = true
	c := client_open(&w, &f)
	defer {
		zsp.session_close(c.session)
		finder_close(&f)
		client_free(&c)
		memory_disk_destroy(&pages)
	}
	for _ in 0 ..< 100 {
		world_write(t, &w)
	}
	q := []byte{1, 0, 1, 2, 1, 0, 0, 5, 0}
	moved := []byte{1, 0, 1, 2, 1, 0, 3, 5, 0}
	other := []byte{1, 3, 0, 1, 2, 1, 0, 0, 5, 0}
	client_ask(t, &c, 1, q)
	testing.expect(t, !f.live[0].ready)
	for !finder_run(&f) {
	}
	finder_run(&f)
	client_hear_out(t, &c, &f)
	client_ask(t, &c, 2, other)
	testing.expect(t, !f.live[1].ready)
	client_ask(t, &c, 1, moved)
	testing.expect(t, len(f.live) == 2 && live_find(&f, c.session, 1).ready)
	finder_run(&f)
	before := len(c.cells)
	for _, m in c.cells {
		for _, b in m {
			delete(b)
		}
		delete(m)
	}
	clear(&c.cells)
	shown := slice.clone(c.answers[1].ids[:], context.temp_allocator)
	for id in shown {
		c.cells[id] = {} // as good as held
	}
	testing.expect(t, before == 5)
	client_hear_out(t, &c, &f)
	testing.expect(t, len(c.answers[1].ids) == 5 && c.answers[1].ids[0] == shown[3])
	for id, i in shown {
		testing.expect_value(t, len(c.cells[id]) == 0, true)
		_ = i
	}
	for id in c.answers[1].ids[2:] {
		testing.expect(t, len(c.cells[id]) > 0)
	}
}

// A roster that says someone had no right to what they wrote takes it out of every replica, and out of the answers.
@(test)
what_a_roster_takes_is_not_answered :: proc(t: ^testing.T) {
	state := rand.create(99)
	context.random_generator = rand.default_random_generator(&state)
	for round in 0 ..< 6 {
		w, p: World
		world_make(t, &w, &p, {.Signed})
		defer world_destroy(&w)
		defer world_destroy(&p)
		f: Finder
		pages: Memory_Disk
		finder_open(&f, &w.node, memory_disk(&pages), w.secret)
		f.settled = true
		c := client_open(&w, &f)
		w.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
			zsp.session_accept(s, {{0, {.Read, .Write}, 0}} if s.role == .Open else nil)
		}
		p.node.host.authenticate = w.node.host.authenticate
		g: Finder
		link := link_make(&p, &w)
		defer {
			zsp.session_close(link[0])
			zsp.session_close(link[1])
			zsp.session_close(c.session)
			finder_close(&f)
			client_free(&c)
			memory_disk_destroy(&pages)
		}
		for _ in 0 ..< 30 {
			world_write(t, &w)
		}
		w.node.now += 60_000
		before := w.node.now
		p.node.now = before + 60_000
		mine := make([dynamic]zsp.Id, context.temp_allocator)
		for i in 0 ..< 20 {
			id := zsp.node_id(&p.node, 1)
			b := make([]byte, 24, context.temp_allocator)
			l := list_of(1, 0)
			zsp.put_u64(b, l[0])
			zsp.put_u64(b[8:], l[1])
			zsp.put_u64(b[16:], u64(i))
			testing.expect(t, zsp.node_write(&p.node, {{id, 1, .Place, zsp.node_stamp(&p.node), b}, {id, 16, .Value, zsp.node_stamp(&p.node), transmute([]byte)rand.choice(NAMES)}}))
			append(&mine, id)
			append(&w.rows, id)
		}
		w.node.now = p.node.now
		q := make([dynamic]byte, context.temp_allocator)
		zsp.write_varint(&q, 1)
		append(&q, u8(Op.Exists), u8(Kind.Bytes), 16, 0, 1, 2, 1, 0, 0, 50, 0)
		g.n = &p.node
		client_ask(t, &c, 1, q[:])
		for _ in 0 ..< 6 {
			link_pass(t, link, max(int))
			finder_run(&f, 1 << 16)
		}
		client_hear_out(t, &c, &f)
		testing.expect(t, answer_check(t, &w, &f, &c, 1, q[:]) && c.answers[1].total >= 20)
		if round % 2 == 1 {
			index_save(&f.x)
		}
		d := zsp.draft_from(&w.node.roster, before << 16)
		zsp.draft_revoke(&d, p.keys.device, 1)
		bytes, ok := zsp.roster_sign(&w.keys, w.root, &d)
		defer delete(bytes)
		testing.expect(t, ok && zsp.node_adopt(&w.node, bytes))
		for id in mine {
			testing.expect(t, zsp.row_places(&w.node.store, id).count == 0)
		}
		for _ in 0 ..< 4 {
			for !finder_run(&f, 1 + rand.int_max(4)) {
			}
			client_hear_out(t, &c, &f)
		}
		for id in c.answers[1].ids {
			testing.expect(t, !slice.contains(mine[:], id))
		}
		testing.expect(t, answer_check(t, &w, &f, &c, 1, q[:]))
	}
}

// A partial replica that can watch no more answers of what it holds, rather than wait for ever for rows it could not
// ask for; and what it let go of after is only what it had asked for, not what another question had.
@(test)
what_cannot_be_watched_is_not_waited_for :: proc(t: ^testing.T) {
	state := rand.create(111)
	context.random_generator = rand.default_random_generator(&state)
	w, p: World
	world_make(t, &w, &p)
	defer world_destroy(&w)
	defer world_destroy(&p)
	f, g: Finder
	pages: [2]Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages[0]), w.secret)
	finder_open(&g, &p.node, memory_disk(&pages[1]), p.secret)
	f.settled = true
	elsewhere := client_open(&w, &f)
	c := client_open(&p, &g)
	filler := client_open(&p, &g)
	for x in ([]^World{&w, &p}) {
		x.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
			zsp.session_accept(s, nil if s.role == .Peer else {{0, {.Read, .Write}, 0}})
		}
	}
	for _ in 0 ..< 40 {
		world_write(t, &w)
	}
	link := link_make(&p, &w)
	defer {
		zsp.session_close(link[0])
		zsp.session_close(link[1])
		zsp.session_close(c.session)
		zsp.session_close(elsewhere.session)
		finder_close(&f)
		finder_close(&g)
		client_free(&c)
		client_free(&elsewhere)
		client_free(&filler)
		for &d in pages {
			memory_disk_destroy(&d)
		}
	}
	testing.expect(t, link_settle(t, link, &f, &g))
	few := []byte{1, 0, 1, 2, 1, 0, 0, 5, 0} // the newest five
	client_ask(t, &c, 1, few)
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect(t, 1 in c.answers && len(c.answers[1].ids) == 5)
	held := len(p.node.interests)
	for i := 0; len(p.node.interests) < zsp.MAX_INTERESTS; i += 1 {
		k := zsp.Key{1 << 32 | 99, u64(i), 0, 0, 0}
		testing.expect(t, zsp.session_wants(filler.session, k, zsp.key_next(k), true))
	}
	all := []byte{1, 8, 1, 16, 0, 1, 2, 1, 0, 0, 50, 0} // every one with a value, newest first
	client_ask(t, &c, 2, all, FETCH)
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect_value(t, c.answers[2].flags, 32) // what is held, and not said to be settled: it is not all there is
	zsp.session_close(filler.session)
	testing.expect_value(t, len(p.node.interests), held)
	unask := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&unask, zsp.Message(UNASK))
	zsp.write_varint(&unask, 2)
	zsp.frame_end(&unask, at)
	testing.expect(t, zsp.session_input(c.session, unask[:]))
	testing.expect(t, link_settle(t, link, &f, &g))
	testing.expect_value(t, len(p.node.interests), held)
}

// A question asked again, as when it is moved, holds what was watched of its answer from afar only while another is
// asked to put it right: with nobody to ask, or nobody to be asked now that this holds everything, it is let go of.
@(test)
moved_questions_let_go_of_what_nobody_answers :: proc(t: ^testing.T) {
	for round in 0 ..< 2 {
		state := rand.create(114)
		context.random_generator = rand.default_random_generator(&state)
		w, p: World
		world_make(t, &w, &p)
		defer world_destroy(&w)
		defer world_destroy(&p)
		f, g: Finder
		pages: [2]Memory_Disk
		finder_open(&f, &w.node, memory_disk(&pages[0]), w.secret)
		finder_open(&g, &p.node, memory_disk(&pages[1]), p.secret)
		f.settled = true
		elsewhere := client_open(&w, &f)
		c := client_open(&p, &g)
		for x in ([]^World{&w, &p}) {
			x.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
				zsp.session_accept(s, nil if s.role == .Peer else {{0, {.Read, .Write}, 0}})
			}
		}
		for _ in 0 ..< 40 {
			world_write(t, &w)
		}
		link := link_make(&p, &w)
		defer {
			zsp.session_close(c.session)
			zsp.session_close(elsewhere.session)
			finder_close(&f)
			finder_close(&g)
			client_free(&c)
			client_free(&elsewhere)
			for &d in pages {
				memory_disk_destroy(&d)
			}
		}
		testing.expect(t, link_settle(t, link, &f, &g))
		client_ask(t, &c, 1, []byte{1, 0, 1, 2, 1, 0, 0, 5, 0}) // the newest five
		testing.expect(t, link_settle(t, link, &f, &g))
		client_hear_out(t, &c, &g)
		testing.expectf(t, 1 in c.answers && c.answers[1].flags & 1 != 0 && len(c.answers[1].ids) > 0, "%v", c.answers[1] if 1 in c.answers else Told{})
		shown := len(c.answers[1].ids)
		watched :: proc(p: ^World, c: ^Client) -> (n: int) {
			for it in p.node.interests {
				n += 1 if it.session == c.session.id && it.watch.id == max(u64) && it.watch.data else 0 // in what an answer shows
			}
			return
		}
		testing.expect_value(t, watched(&p, &c), shown) // each of them, until it is held
		if round == 0 {
			zsp.session_close(link[0]) // nobody is left to ask
			zsp.session_close(link[1])
		} else {
			g.settled = true // nor need anyone be
		}
		client_ask(t, &c, 1, []byte{1, 0, 1, 2, 1, 0, 100, 5, 0}) // moved past them all
		for _ in 0 ..< 10 {
			if round == 1 {
				link_pass(t, link, max(int))
				finder_run(&f)
			}
			finder_run(&g)
		}
		client_hear_out(t, &c, &g)
		testing.expectf(t, watched(&p, &c) == 0, "round %d: %d watched still", round, watched(&p, &c))
		if round == 1 {
			testing.expect_value(t, len(p.node.calls), 0) // and the call that answered it is over
			zsp.session_close(link[0])
			zsp.session_close(link[1])
		}
	}
}

@(private, thread_local)
phantoms_said, phantoms_unsound: int

// A Fetch whose answer from afar is given up on, as one that names a row where a full replica says there is none, or
// one that is no answer at all, asks another that can answer it, there and then: it is not answered with what is held while one can be asked.
@(test)
a_fetch_given_up_on_asks_another :: proc(t: ^testing.T) {
	for round in 0 ..< 2 {
		state := rand.create(115)
		context.random_generator = rand.default_random_generator(&state)
		good, p: World
		for x in ([]^World{&good, &p}) {
			for &b in x.secret {
				b = byte(rand.uint32())
			}
			zsp.keyring_init(&x.keys, x.secret)
		}
		liar_secret, root: zsp.Key32
		for &b in liar_secret {
			b = byte(rand.uint32())
		}
		for &b in root {
			b = byte(rand.uint32())
		}
		liar_keys: zsp.Keyring
		zsp.keyring_init(&liar_keys, liar_secret)
		defer zsp.keyring_destroy(&liar_keys)
		none: zsp.Roster
		d := zsp.draft_from(&none, 1)
		scope := zsp.draft_scope(&d)
		m := zsp.draft_grant(&d, good.keys.device, good.keys.signer, scope, {.Write})
		m.owner = true
		zsp.draft_grant(&d, p.keys.device, p.keys.signer, scope, {.Read, .Write})
		zsp.draft_grant(&d, liar_keys.device, liar_keys.signer, scope, {.Read, .Write})
		ok: bool
		good.roster, ok = zsp.roster_sign(&good.keys, root, &d)
		testing.expect(t, ok)
		good.space = zsp.ed25519_public(root)
		world_start(t, &good)
		p.roster, p.space = slice.clone(good.roster), good.space
		world_start(t, &p, false)
		defer world_destroy(&good)
		defer world_destroy(&p)
		liar_disk: zsp.Memory_Disk
		defer zsp.memory_disk_destroy(&liar_disk)
		liar: zsp.Node
		testing.expect(t, zsp.node_init(&liar, zsp.memory_disk(&liar_disk), good.space, &liar_keys, true, 64))
		defer zsp.node_destroy(&liar)
		testing.expect(t, zsp.node_adopt(&liar, good.roster))
		for i in 0 ..< 3 {
			good.node.now += 1000
			id := zsp.node_id(&good.node, scope)
			b: [24]byte
			l := list_of(scope, 0)
			zsp.put_u64(b[:], l[0])
			zsp.put_u64(b[8:], l[1])
			zsp.put_u64(b[16:], u64(i))
			testing.expect(t, zsp.node_write(&good.node, {{id, zsp.PLACE, .Place, zsp.node_stamp(&good.node), b[:]}}))
		}
		p.node.now, liar.now = good.node.now, good.node.now
		f, g: Finder
		pages: [2]Memory_Disk
		finder_open(&f, &good.node, memory_disk(&pages[0]), good.secret)
		finder_open(&g, &p.node, memory_disk(&pages[1]), p.secret)
		f.settled = true
		elsewhere := client_open(&good, &f)
		c := client_open(&p, &g)
		accept :: proc(_: rawptr, s: ^zsp.Session, _: []byte) {
			zsp.session_accept(s, nil if s.role == .Peer else {{0, {.Read, .Write}, 0}})
		}
		good.node.host.authenticate, p.node.host.authenticate, liar.host.authenticate = accept, accept, accept
		// One answers at once with a row that is nowhere.
		phantoms_said, phantoms_unsound = 0, round
		liar.host.questions = {
			data = &liar,
			called = proc(data: rawptr, call: u64, _: zsp.Key32, _: zsp.Scope, _: []byte) {
				phantoms_said += 1
				out := make([dynamic]byte, context.temp_allocator)
				append(&out, 1 if phantoms_unsound == 0 else 9) // or what is no answer at all
				zsp.write_varint(&out, 1)
				zsp.write_varint(&out, 0)
				zsp.write_varint(&out, 1)
				zsp.write_key(&out, {1 << 32 | 9, 1, 42, 1 << 32 | 99, 777})
				zsp.write_varint(&out, 0)
				zsp.node_flow((^zsp.Node)(data), call, .Data, out[:])
			},
		}
		lying := [2]^zsp.Session{zsp.session_open(&p.node, .Peer, true, liar_keys.device), zsp.session_open(&liar, .Peer, false, p.keys.device)}
		link := link_make(&p, &good)
		defer {
			for x in ([]^zsp.Session{link[0], link[1], lying[0], lying[1], c.session, elsewhere.session}) {
				zsp.session_close(x)
			}
			finder_close(&f)
			finder_close(&g)
			client_free(&c)
			client_free(&elsewhere)
			for &x in pages {
				memory_disk_destroy(&x)
			}
		}
		turn :: proc(t: ^testing.T, links: [2][2]^zsp.Session, f, g: ^Finder) {
			for _ in 0 ..< 100 {
				for l in links {
					link_pass(t, l, max(int))
				}
				finder_run(f)
				finder_run(g)
			}
		}
		turn(t, {lying, link}, &f, &g)
		testing.expect(t, lying[0].ready && link[0].ready)
		client_ask(t, &c, 1, []byte{1, 0, 0, 0, 0, 50, 0}, FETCH)
		turn(t, {lying, link}, &f, &g)
		client_hear_out(t, &c, &g)
		testing.expectf(t, phantoms_said == 1, "the one that names what is nowhere was asked %d times", phantoms_said) // first, as it was first reached
		testing.expectf(t, 1 in c.answers && c.answers[1].flags & 1 != 0 && c.answers[1].total == 3 && len(c.answers[1].ids) == 3, "%v", c.answers[1] if 1 in c.answers else Told{})
	}
}

@(private, thread_local)
far_called: u64

// An answer from afar that names a row where a full replica says there is none is no answer: what is here is.
@(test)
rows_said_to_be_where_none_is_are_not_waited_for :: proc(t: ^testing.T) {
	state := rand.create(113)
	context.random_generator = rand.default_random_generator(&state)
	w, p: World
	world_make(t, &w, &p)
	defer world_destroy(&w)
	defer world_destroy(&p)
	g: Finder
	pages: Memory_Disk
	finder_open(&g, &p.node, memory_disk(&pages), p.secret)
	c := client_open(&p, &g)
	for x in ([]^World{&w, &p}) {
		x.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
			zsp.session_accept(s, nil if s.role == .Peer else {{0, {.Read, .Write}, 0}})
		}
	}
	// It answers, at once, with a row that is nowhere.
	w.node.host.questions = {
		data = &w.node,
		called = proc(data: rawptr, call: u64, _: zsp.Key32, _: zsp.Scope, _: []byte) {
			far_called = call
			out := make([dynamic]byte, context.temp_allocator)
			append(&out, 1)
			zsp.write_varint(&out, 1)
			zsp.write_varint(&out, 0)
			zsp.write_varint(&out, 1)
			zsp.write_key(&out, {1 << 32 | 9, 1, 42, 1 << 32 | 99, 777})
			zsp.write_varint(&out, 0)
			zsp.node_flow((^zsp.Node)(data), call, .Data, out[:])
		},
	}
	link := link_make(&p, &w)
	defer {
		zsp.session_close(link[0])
		zsp.session_close(link[1])
		zsp.session_close(c.session)
		finder_close(&g)
		client_free(&c)
		memory_disk_destroy(&pages)
	}
	for _ in 0 ..< 20 {
		link_pass(t, link, max(int))
		finder_run(&g)
	}
	client_ask(t, &c, 1, []byte{1, 0, 0, 0, 0, 50, 0}, FETCH)
	for _ in 0 ..< 100 {
		link_pass(t, link, max(int))
		finder_run(&g)
	}
	client_hear_out(t, &c, &g)
	testing.expectf(t, 1 in c.answers && c.answers[1].flags & 1 == 0, "%v", c.answers[1] if 1 in c.answers else Told{})
	// One that stays is put right by the next answer, which is taken: what is here is said meanwhile.
	client_ask(t, &c, 2, []byte{1, 0, 0, 0, 0, 50, 0})
	for _ in 0 ..< 100 {
		link_pass(t, link, max(int))
		finder_run(&g)
	}
	client_hear_out(t, &c, &g)
	testing.expectf(t, 2 in c.answers && c.answers[2].flags & 1 == 0, "%v", c.answers[2] if 2 in c.answers else Told{})
	right := make([dynamic]byte, context.temp_allocator)
	append(&right, 1, 0, 0, 0, 0)
	zsp.node_flow(&w.node, far_called, .Data, right[:])
	for _ in 0 ..< 100 {
		link_pass(t, link, max(int))
		finder_run(&g)
	}
	client_hear_out(t, &c, &g)
	testing.expectf(t, 2 in c.answers && c.answers[2].flags & 1 != 0 && c.answers[2].total == 0, "%v", c.answers[2] if 2 in c.answers else Told{})
}

// Pages that are not what was last written are known not to be, and the answers are right all the same.
@(test)
pages_are_believed_only_if_they_are :: proc(t: ^testing.T) {
	state := rand.create(101)
	context.random_generator = rand.default_random_generator(&state)
	ROUNDS :: max(#config(ZSP_FIND_SEEDS, 6) / 2, 10)
	for round in 0 ..< ROUNDS {
		w: World
		world_make(t, &w)
		defer world_destroy(&w)
		Past :: struct {
			pages: Memory_Disk,
			was:   [dynamic]struct {no: u32, bytes: [PAGE_SIZE]byte},
			open:  bool,
		}
		past: Past
		defer {
			memory_disk_destroy(&past.pages)
			delete(past.was)
		}
		disk :: proc(p: ^Past) -> Disk {
			d := memory_disk(&p.pages)
			d.write = proc(data: rawptr, no: u32, bytes: []byte) -> bool {
				p := (^Past)(data)
				if pg, ok := p.pages.pages[no]; ok {
					append(&p.was, struct {no: u32, bytes: [PAGE_SIZE]byte}{no, pg^})
				}
				pg, ok := p.pages.pages[no]
				if !ok {
					pg = new([PAGE_SIZE]byte)
					p.pages.pages[no] = pg
				}
				copy(pg[:], bytes)
				return true
			}
			d.data = p
			return d
		}
		#assert(offset_of(Past, pages) == 0)
		clean: Memory_Disk
		own: Finder // looks on
		finder_open(&own, &w.node, memory_disk(&clean), w.secret)
		defer {
			finder_close(&own)
			memory_disk_destroy(&clean)
		}
		asked: [dynamic][]byte
		defer {
			for q in asked {
				delete(q)
			}
			delete(asked)
		}
		for _ in 0 ..< 3 {
			append(&asked, slice.clone(ask(&w) if len(w.rows) > 0 else []byte{1, 0, 1, 2, 1, 0, 0, 50, 0}))
		}
		for life in 0 ..< 5 {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			f: Finder
			finder_open(&f, &w.node, disk(&past), w.secret)
			f.settled = true
			c := client_open(&w, &f)
			for q, i in asked {
				client_ask(t, &c, u64(i), q)
			}
			for step in 0 ..< 6 {
				many := rand.int_max(60)
				for _ in 0 ..< many {
					world_write(t, &w)
				}
				if rand.int_max(3) == 0 && len(past.was) > 0 {
					// Somebody else has been at it.
					for _ in 0 ..< 1 + step {
						at := rand.choice(past.was[:])
						if past.pages.pages[at.no] == nil {
							continue
						}
						switch rand.int_max(4) {
						case 0: // what it once was
							past.pages.pages[at.no]^ = at.bytes
						case 1: // what another was
							if pg, ok := past.pages.pages[at.no / 2 + 1]; ok {
								pg^ = at.bytes
							}
						case 2:
							past.pages.pages[at.no][rand.int_max(PAGE_SIZE)] ~= 1 << uint(rand.int_max(8))
						case 3:
							free(past.pages.pages[at.no])
							delete_key(&past.pages.pages, at.no)
						}
					}
				}
				for quiet, n := 0, 0; quiet < 3 && n < 4000; n += 1 {
					quiet = quiet + 1 if finder_run(&f, 100) && !f.x.failed else 0
				}
				client_hear_out(t, &c, &f)
				index_follow(&own.x)
				for q, i in asked {
					if !answer_check(t, &w, &own, &c, u64(i), q) {
						fmt.println("round", round, "life", life, "step", step)
						return
					}
				}
				zsp.store_sync(&w.node.store)
				if rand.int_max(2) == 0 {
					index_save(&f.x)
				}
			}
			zsp.session_close(c.session)
			finder_close(&f)
			client_free(&c)
		}
	}
}

// What another node says in a call is not believed for saying it.
@(test)
answers_from_afar_are_sound :: proc(t: ^testing.T) {
	state := rand.create(103)
	context.random_generator = rand.default_random_generator(&state)
	w, p: World
	world_make(t, &w, &p)
	defer world_destroy(&w)
	defer world_destroy(&p)
	f, g: Finder
	pages: [2]Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages[0]), w.secret)
	finder_open(&g, &p.node, memory_disk(&pages[1]), p.secret)
	f.settled = true
	c := client_open(&p, &g)
	elsewhere := client_open(&w, &f)
	p.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
		zsp.session_accept(s, {{0, {.Read, .Write}, 0}} if s.role == .Open else nil)
	}
	w.node.host.authenticate = p.node.host.authenticate
	p.node.now = w.node.now
	link := link_make(&p, &w)
	defer {
		zsp.session_close(link[0])
		zsp.session_close(link[1])
		zsp.session_close(c.session)
		zsp.session_close(elsewhere.session)
		finder_close(&f)
		finder_close(&g)
		client_free(&c)
		client_free(&elsewhere)
		for &d in pages {
			memory_disk_destroy(&d)
		}
	}
	for _ in 0 ..< 60 {
		world_write(t, &w)
	}
	q := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&q, 1)
	append(&q, u8(Op.All), 1, 2, 1, 0, 0, 10, 3, u8(Fn.Facet), u8(Kind.Bytes), 16, 0, 3, u8(Fn.Sum), u8(Kind.Number), 17, 0, 0, u8(Fn.Min), u8(Kind.Number), 17, 0, 0)
	client_ask(t, &c, 1, q[:])
	testing.expect(t, link_settle(t, link, &f, &g))
	client_hear_out(t, &c, &g)
	testing.expect(t, answer_check(t, &w, &f, &c, 1, q[:]))
	l := g.live[0]
	good := slice.clone(l.far.answer, context.temp_allocator)
	ROUNDS :: max(#config(ZSP_FIND_SEEDS, 6) * 50, 3000)
	for round in 0 ..< ROUNDS {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		bad := make([dynamic]byte, context.temp_allocator)
		switch round {
		case 0:
			append(&bad, 0x10, 0, 0, 0x80, 0x80, 4)
		case 1:
			append(&bad, 0, 0, 0, 0x80, 0x80, 0x80, 0x80, 0x10)
		case 2:
			append(&bad, 0, 0, 0, 0, 1, 1)
		case 3, 4, 5:
			// A value, where there is none to a sum; one that is too short; and one row by two keys.
			append(&bad, 1, 2, 0, 2 if round == 5 else 0)
			if round == 5 {
				k := l.far.keys[0]
				zsp.write_key(&bad, k)
				k[2] += 1
				zsp.write_key(&bad, k)
			}
			append(&bad, 3)
			for i in 0 ..< 3 {
				append(&bad, 1)
				resize(&bad, len(bad) + 8)
				switch {
				case i == 1 && round == 3:
					append(&bad, 1, 1, 8)
					resize(&bad, len(bad) + 8)
				case i == 2 && round == 4:
					append(&bad, 1, 1, 7)
					resize(&bad, len(bad) + 7)
				case:
					append(&bad, 0)
				}
			}
			refused := l.far.call
			finder_flow(&g, l.far.call, .Data, bad[:])
			finder_run(&g)
			testing.expectf(t, l.far.call != refused, "%d", round)
			clear(&l.far.tried)
			testing.expect(t, link_settle(t, link, &f, &g))
			continue
		case:
			append(&bad, ..good)
			for _ in 0 ..< 1 + round % 4 {
				switch rand.int_max(4) {
				case 0:
					bad[rand.int_max(len(bad))] = byte(rand.uint32())
				case 1:
					bad[rand.int_max(min(len(bad), 8))] = byte(rand.uint32())
				case 2:
					resize(&bad, 1 + rand.int_max(len(bad)))
				case 3:
					inject_at(&bad, rand.int_max(len(bad)), byte(rand.uint32()))
				}
			}
		}
		call := l.far.call
		finder_flow(&g, call, .Data, bad[:])
		finder_run(&g)
		// Nothing is passed on that the client could not read, or that says what only its own node may.
		client_hear_out(t, &c, &g)
		flags := c.answers[1].flags
		testing.expect(t, flags == 0 || flags == 1 || flags == 8)
		testing.expect_value(t, len(c.answers), 1)
		if l.far.call == 0 {
			clear(&l.far.tried)
			finder_run(&g)
		}
		if testing.failed(t) {
			fmt.println("round", round, bad)
			return
		}
		if round % 50 == 0 {
			testing.expect(t, link_settle(t, link, &f, &g))
			client_hear_out(t, &c, &g)
		}
	}
	// And the next that is sound is taken.
	for id in 0 ..< 2 {
		_ = id
		clear(&l.far.tried)
		world_write(t, &w)
		testing.expect(t, link_settle(t, link, &f, &g))
	}
	client_hear_out(t, &c, &g)
	testing.expect(t, answer_check(t, &w, &f, &c, 1, q[:]))
}

// An answer that would be longer than one may be is not one; nor does what has grown stop what is passed on.
@(test)
answers_are_not_too_long :: proc(t: ^testing.T) {
	state := rand.create(105)
	context.random_generator = rand.default_random_generator(&state)
	w, p: World
	world_make(t, &w, &p)
	defer world_destroy(&w)
	defer world_destroy(&p)
	f, g: Finder
	pages: [2]Memory_Disk
	finder_open(&f, &w.node, memory_disk(&pages[0]), w.secret)
	finder_open(&g, &p.node, memory_disk(&pages[1]), p.secret)
	f.settled = true
	c := client_open(&p, &g)
	near := client_open(&w, &f)
	p.node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
		zsp.session_accept(s, {{0, {.Read, .Write}, 0}} if s.role == .Open else nil)
	}
	w.node.host.authenticate = p.node.host.authenticate
	p.node.now = w.node.now
	link := link_make(&p, &w)
	defer {
		zsp.session_close(link[0])
		zsp.session_close(link[1])
		zsp.session_close(c.session)
		zsp.session_close(near.session)
		finder_close(&f)
		finder_close(&g)
		client_free(&c)
		client_free(&near)
		for &d in pages {
			memory_disk_destroy(&d)
		}
	}
	put :: proc(t: ^testing.T, w: ^World, n, size: int) {
		id := zsp.node_id(&w.node, 1)
		append(&w.rows, id)
		b := make([]byte, 24, context.temp_allocator)
		l := list_of(1, 0)
		zsp.put_u64(b, l[0])
		zsp.put_u64(b[8:], l[1])
		v := make([]byte, size, context.temp_allocator)
		slice.fill(v, 'x')
		zsp.put_u64(v[size - 8:], u64(n) << 8 | 1)
		testing.expect(t, zsp.node_write(&w.node, {{id, 1, .Place, zsp.node_stamp(&w.node), b}, {id, 16, .Value, zsp.node_stamp(&w.node), v}}))
	}
	q := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&q, 1)
	append(&q, u8(Op.All), 1, 2, 1, 0, 0, 0, 1, u8(Fn.Facet), u8(Kind.Bytes), 16, 0)
	zsp.write_varint(&q, 500)
	client_ask(t, &c, 1, q[:])
	client_ask(t, &near, 1, q[:])
	for n in 0 ..< 250 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		put(t, &w, n, 1200)
		if n % 25 != 24 {
			continue
		}
		testing.expect(t, link_settle(t, link, &f, &g))
		client_hear_out(t, &c, &g)
		client_hear_out(t, &near, &f)
		if n < 200 {
			// Each near twice the last that was said, and no less sure to come.
			testing.expectf(t, c.answers[1].total == n + 1 && c.answers[1].flags == 1, "%d: %v", n, c.answers[1].total)
		}
	}
	testing.expect(t, near.answers[1].flags == 4 && c.answers[1].flags & 5 != 1 && len(f.live) == 0)
	// Nor is what is longest of all the death of anyone.
	put(t, &w, 999, 60_000)
	q2 := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&q2, 1)
	append(&q2, u8(Op.All), 1, 2, 1, 0, 0, 0, 64)
	for _ in 0 ..< 64 {
		append(&q2, u8(Fn.Max), u8(Kind.Bytes), 16, 0, 0)
	}
	client_ask(t, &near, 2, q2[:])
	for !finder_run(&f) {
	}
	finder_run(&f)
	client_hear_out(t, &near, &f)
	testing.expect(t, near.answers[2].flags == 4)
	// What makes no sense is said to make none.
	for bad in ([][]byte{
		{1, u8(Op.Exists), u8(Kind.Words), 16, 0, 0, 0, 0, 1, 0},
		{1, u8(Op.Range), u8(Kind.Words), 16, 0, 0, 0, 0, 0, 1, 0},
		{1, u8(Op.In), u8(Kind.Words), 16, 0, 0, 0, 0, 0, 1, 0},
		{0x81, 0x80, 0x80, 0x80, 0x10, 0, 0, 0, 0, 1, 0},
		{1, u8(Op.Ref), u8(Kind.Id), 19, 0, 0, 0, 0, 0, 0, 1, 0},
	}) {
		client_ask(t, &near, 3, bad)
		finder_run(&f)
		client_hear_out(t, &near, &f)
		testing.expectf(t, near.answers[3].flags == 4, "%v", bad)
	}
}

// Cells are forgotten while nothing is asked, and nothing but a number kept says so.
@(test)
what_is_forgotten_meanwhile_is_gone :: proc(t: ^testing.T) {
	state := rand.create(107)
	context.random_generator = rand.default_random_generator(&state)
	for asleep in 0 ..< 2 {
		w, p: World
		world_make(t, &w, &p, {.Signed})
		defer world_destroy(&w)
		defer world_destroy(&p)
		pages: Memory_Disk
		defer memory_disk_destroy(&pages)
		f: Finder
		finder_open(&f, &w.node, memory_disk(&pages), w.secret)
		f.settled = true
		c := client_open(&w, &f)
		for _ in 0 ..< 30 {
			world_write(t, &w)
		}
		q := []byte{1, 0, 1, 2, 1, 0, 0, 50, 0}
		client_ask(t, &c, 1, q)
		for !finder_run(&f) {
		}
		finder_run(&f)
		zsp.store_sync(&w.node.store)
		testing.expect(t, index_save(&f.x))
		zsp.session_close(c.session)
		client_free(&c)
		finder_close(&f)
		// As when where they lay could not be read.
		lost := w.rows[:0]
		taken := make([dynamic]zsp.Id, context.temp_allocator)
		for id, i in w.rows {
			if i % 3 == 0 {
				append(&taken, id)
			}
		}
		_ = lost
		zsp.store_lose(&w.node.store, taken[:])
		if asleep == 1 {
			testing.expect(t, zsp.store_checkpoint(&w.node.store))
			zsp.node_destroy(&w.node)
			w.node = {}
			testing.expect(t, zsp.node_init(&w.node, zsp.memory_disk(&w.disk), w.space, &w.keys, true, 64))
			testing.expect(t, zsp.node_resume(&w.node, nil, w.roster))
			w.node.now = 1_700_001_000_000
		}
		finder_open(&f, &w.node, memory_disk(&pages), w.secret)
		f.settled = true
		c = client_open(&w, &f)
		client_ask(t, &c, 1, q)
		for !finder_run(&f) {
		}
		finder_run(&f)
		client_hear_out(t, &c, &f)
		testing.expectf(t, answer_check(t, &w, &f, &c, 1, q), "%d", asleep)
		zsp.session_close(c.session)
		client_free(&c)
		finder_close(&f)
	}
}

// Rows are made while what was gone over is being put in order.
@(test)
what_comes_while_merging_is_there :: proc(t: ^testing.T) {
	state := rand.create(109)
	context.random_generator = rand.default_random_generator(&state)
	for round in 0 ..< 6 {
		w: World
		world_make(t, &w)
		defer world_destroy(&w)
		put :: proc(t: ^testing.T, w: ^World) {
			w.node.now += 1000
			id := zsp.node_id(&w.node, 1)
			append(&w.rows, id)
			b := make([]byte, 24, context.temp_allocator)
			l := list_of(1, 0)
			zsp.put_u64(b, l[0])
			zsp.put_u64(b[8:], l[1])
			text := fmt.tprint(rand.int63(), rand.int63(), rand.int63(), "band")
			testing.expect(t, zsp.node_write(&w.node, {{id, 1, .Place, zsp.node_stamp(&w.node), b}, {id, 16, .Value, zsp.node_stamp(&w.node), transmute([]byte)text[:20]}, {id, 20, .Value, zsp.node_stamp(&w.node), transmute([]byte)text}}))
		}
		for _ in 0 ..< 300 {
			put(t, &w)
		}
		source := make([dynamic]byte, context.temp_allocator)
		append(&source, 1, u8(Op.And), 2, u8(Op.Match), u8(Kind.Words), 20, 0, 0, 0, 4, 'b', 'a', 'n', 'd', u8(Op.Exists), u8(Kind.Bytes), 16, 0, 0, 0, 0, 50, 0)
		q, ok := query_parse(source[:])
		testing.expect(t, ok)
		index_follow(&w.x)
		query_prepare(&w.x, &q)
		merging := 0
		for !index_step(&w.x, 2 + round) {
			for s in w.x.scopes {
				now := s.filling != nil
				for h in s.columns {
					now ||= h.filling != nil
				}
				if now && rand.int_max(6) == 0 {
					merging += 1
					put(t, &w)
				}
			}
		}
		testing.expect(t, merging > 3)
		s := index_scope(&w.x, 1)
		testing.expect_value(t, s.all.count, len(w.rows))
		testing.expect_value(t, tree_total(&w.x, s.rows).count, len(w.rows))
		for h in s.columns {
			testing.expect(t, h.kind != .Words || h.alive == len(w.rows))
		}
		got := pred_rows(s, &q.where_)
		testing.expect_value(t, got.count, len(w.rows))
		set_destroy(&got)
		check_index(t, &w)
	}
}

// Rows go that nothing said had gone while a scope's rows were being put in order, and some of that was done: it is
// begun again from nothing, and nothing of what was gone over before is there after.
@(test)
what_goes_while_merging_is_gone :: proc(t: ^testing.T) {
	state := rand.create(110)
	context.random_generator = rand.default_random_generator(&state)
	for keep in ([]int{0, 1}) {
		w: World
		world_make(t, &w)
		defer world_destroy(&w)
		put :: proc(t: ^testing.T, w: ^World) {
			w.node.now += 1000
			id := zsp.node_id(&w.node, 1)
			append(&w.rows, id)
			b := make([]byte, 24, context.temp_allocator)
			l := list_of(1, 0)
			zsp.put_u64(b, l[0])
			zsp.put_u64(b[8:], l[1])
			testing.expect(t, zsp.node_write(&w.node, {{id, 1, .Place, zsp.node_stamp(&w.node), b}}))
		}
		for _ in 0 ..< 300 {
			put(t, &w)
		}
		index_follow(&w.x)
		s := index_want_scope(&w.x, 1)
		for s.filling == nil || s.ids.root == 0 {
			testing.expect(t, !index_step(&w.x, 1))
		}
		zsp.store_lose(&w.node.store, w.rows[keep:])
		index_finish(&w.x)
		check_index(t, &w)
		put(t, &w)
		index_finish(&w.x)
		check_index(t, &w)
		testing.expect_value(t, tree_total(&w.x, s.ids).count, keep + 1)
	}
}

// The least id a scope's row may have is a row's as any other is, when the index is first made.
@(test)
the_first_row_there_can_be_is_found :: proc(t: ^testing.T) {
	state := rand.create(112)
	context.random_generator = rand.default_random_generator(&state)
	w: World
	world_make(t, &w)
	defer world_destroy(&w)
	for i in 0 ..< 2 {
		id := zsp.Id{2 << 32, u64(i)}
		append(&w.rows, id)
		b := make([]byte, 24, context.temp_allocator)
		l := list_of(2, 0)
		zsp.put_u64(b, l[0])
		zsp.put_u64(b[8:], l[1])
		zsp.put_u64(b[16:], u64(i))
		testing.expect(t, zsp.node_write(&w.node, {{id, 1, .Place, zsp.node_stamp(&w.node), b}}))
	}
	index_follow(&w.x)
	_ = index_want_scope(&w.x, 2)
	index_finish(&w.x)
	testing.expect_value(t, index_scope(&w.x, 2).all.count, 2)
	check_index(t, &w)
}

// What cannot be synced is not made over and over; and what has fallen far behind is followed a little at a time.
@(test)
index_is_patient :: proc(t: ^testing.T) {
	state := rand.create(111)
	context.random_generator = rand.default_random_generator(&state)
	w: World
	world_make(t, &w)
	defer world_destroy(&w)
	pages: Memory_Disk
	defer memory_disk_destroy(&pages)
	f: Finder
	q := []byte{1, 0, 1, 2, 1, 0, 0, 50, 0}
	for _ in 0 ..< 20 {
		world_write(t, &w)
	}
	for life in 0 ..< 3 {
		disk := memory_disk(&pages)
		if life == 0 {
			disk.sync = proc(_: rawptr) -> bool {return false}
		}
		finder_open(&f, &w.node, disk, w.secret)
		f.settled = true
		c := client_open(&w, &f)
		client_ask(t, &c, 1, q)
		if life == 2 {
			testing.expect(t, len(f.x.scopes) > 0 && !f.x.tailing) // not all at once
		}
		for !finder_run(&f) {
		}
		finder_run(&f)
		client_hear_out(t, &c, &f)
		testing.expect(t, answer_check(t, &w, &f, &c, 1, q))
		zsp.store_sync(&w.node.store)
		testing.expect(t, index_save(&f.x) == (life > 0))
		if life == 0 {
			f.failed = time.tick_now()
			for _ in 0 ..< 10 {
				testing.expect(t, finder_run(&f) && f.x.failed && f.wake != nil)
			}
		}
		zsp.session_close(c.session)
		client_free(&c)
		finder_close(&f)
		for _ in 0 ..< 200 {
			world_write(t, &w)
		}
	}
	// And one with a page it cannot read is not opened as though it could.
	x: Index
	index_open(&x, &w.node, memory_disk(&pages), w.secret)
	testing.expect(t, len(x.scopes) > 0)
	root := x.scopes[0].ids.root
	index_close(&x)
	pages.pages[root][100] ~= 1
	index_open(&x, &w.node, memory_disk(&pages), w.secret)
	testing.expect(t, len(x.scopes) == 0 && !x.failed && len(x.free) == 0)
	index_close(&x)
}

// Texts are edited anywhere in them, a piece at a time, and what is kept of their words is what they come to.
@(test)
texts_are_read_again_only_where_they_change :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_FIND_SEEDS, 6)
	PARTS := []string{"apple", "apples ", " band", " ", "don", "'", "t", "\n", "京都", "大学 ", "é", "Crème ", "x", "counterrevolutionary ", "counterrevolutionaries", "́", "  ", "fig fig fig "}
	for seed in 0 ..< SEEDS {
		state := rand.create(u64(seed) + 12000)
		context.random_generator = rand.default_random_generator(&state)
		w: World
		world_make(t, &w)
		defer world_destroy(&w)
		Doc :: struct {
			id:   zsp.Id,
			text: zsp.Text,
			held: [dynamic]zsp.Cell, // written elsewhere, and not here yet
		}
		docs: [4]Doc
		defer for &d in docs {
			zsp.text_destroy(&d.text)
			for c in d.held {
				delete(c.body)
			}
			delete(d.held)
		}
		write :: proc(t: ^testing.T, w: ^World, cells: []zsp.Cell) {
			testing.expect(t, zsp.node_write(&w.node, cells))
		}
		for &d in docs {
			d.id = zsp.node_id(&w.node, 1)
			append(&w.rows, d.id)
			b := make([]byte, 24, context.temp_allocator)
			l := list_of(1, 0)
			zsp.put_u64(b, l[0])
			zsp.put_u64(b[8:], l[1])
			write(t, &w, {{d.id, 1, .Place, zsp.node_stamp(&w.node), b}})
		}
		q, ok := query_parse([]byte{1, u8(Op.And), 2, u8(Op.Match), u8(Kind.Words), 20, 0, 0, 0, 3, 'f', 'i', 'g', u8(Op.Match), u8(Kind.Words), 22, 0, 0, 0, 3, 'f', 'i', 'g', 0, 0, 0, 50, 0})
		testing.expect(t, ok)
		index_follow(&w.x)
		query_prepare(&w.x, &q)
		index_finish(&w.x)
		h := q.where_.kids[0].held
		again, edits, opened := 0, 0, 0
		for step in 0 ..< 150 {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			many := 1 + rand.int_max(3)
			for _ in 0 ..< many {
				w.node.now += u64(rand.int_max(3000))
				d := &docs[rand.int_max(len(docs))]
				edits_made := 1 + rand.int_max(3)
				for _ in 0 ..< edits_made {
					n := zsp.text_len(&d.text)
					if n > 0 && rand.int_max(3) == 0 {
						at := rand.int_max(n)
						zsp.text_delete(&d.text, at, min(1 + rand.int_max(12), n - at), rand.uint64() | 1)
					} else {
						// Where a character begins, or anywhere: what is not text is read all the same.
						zsp.text_insert(&d.text, rand.int_max(n + 1), transmute([]byte)rand.choice(PARTS), rand.uint64() | 1)
					}
				}
				stamp := zsp.node_stamp(&w.node)
				body, made := zsp.text_close(&d.text, stamp)
				if !made {
					continue
				}
				edits += 1
				// Some come late, after those that were written after them.
				if rand.int_max(6) == 0 {
					append(&d.held, zsp.Cell{d.id, 20, .Piece, stamp, slice.clone(body)})
					continue
				}
				write(t, &w, {{d.id, 20, .Piece, stamp, body}})
				if rand.int_max(4) == 0 { // in another text of it
					b := make([dynamic]byte, context.temp_allocator)
					zsp.write_u64(&b, rand.uint64() | 1)
					append(&b, 1, 0, 0)
					zsp.write_bytes(&b, transmute([]byte)rand.choice(PARTS))
					write(t, &w, {{d.id, 22, .Piece, zsp.node_stamp(&w.node), b[:]}})
				}
				if rand.int_max(4) == 0 {
					for c in d.held {
						write(t, &w, {c})
						delete(c.body)
					}
					clear(&d.held)
				}
			}
			switch rand.int_max(25) {
			case 4: // another piece by the name of one there is, and of before it
				d := &docs[rand.int_max(len(docs))]
				scan := zsp.row_scan(&w.node.store, d.id, 20, 20)
				for c in zsp.row_next(&w.node.store, &scan) {
					c := c
					if c.kind != .Piece || rand.int_max(3) > 0 || !zsp.cell_open(&w.keys, &w.node.roster, &c) {
						continue
					}
					b := make([dynamic]byte, context.temp_allocator)
					append(&b, ..c.body[:8])
					append(&b, 1, 0, 0)
					zsp.write_bytes(&b, transmute([]byte)string("twin fig "))
					before := c.stamp
					before.time -= 1
					if before.time > zsp.row_born(d.id) {
						write(t, &w, {{d.id, 20, .Piece, before, b[:]}})
					}
					break
				}
			case 2, 3: // what was written is gathered up
				d := &docs[rand.int_max(len(docs))]
				cells := make([dynamic]zsp.Cell, context.temp_allocator)
				scan := zsp.row_scan(&w.node.store, d.id, 20, 20)
				for c in zsp.row_next(&w.node.store, &scan) {
					c := c
					if c.kind == .Piece && zsp.cell_open(&w.keys, &w.node.roster, &c) {
						c.body = slice.clone(c.body, context.temp_allocator)
						append(&cells, c)
					}
				}
				if len(cells) > 1 {
					b := zsp.text_bundle(cells[:1 + rand.int_max(len(cells) - 1)], context.temp_allocator)
					b.row, b.slot, b.stamp = d.id, 20, zsp.node_stamp(&w.node)
					write(t, &w, {b})
				}
			case 0: // a text beneath it all
				d := &docs[rand.int_max(len(docs))]
				if zsp.text_len(&d.text) == 0 && len(d.held) == 0 {
					write(t, &w, {{d.id, 20, .Value, zsp.node_stamp(&w.node), transmute([]byte)string("grape fig")}})
				}
			case 1: // more than is remembered
				id := docs[0].id
				for i in 0 ..< 80 {
					write(t, &w, {{id, 16, .Value, zsp.node_stamp(&w.node), {byte(i)}}})
				}
			}
			before := h.next_text
			index_finish(&w.x)
			again += max(int(h.next_text) - int(before), 0) // unless the words were all read again
			for hot in w.x.hot {
				// What is kept open is what there is too.
				r := Row{n = &w.node, id = hot.id}
				bytes, _ := row_slot(&r, hot.slot)
				kept := make([dynamic]byte, context.temp_allocator)
				zsp.text_read(&hot.text, &kept)
				testing.expect(t, hot.level && string(kept[:]) == string(bytes))
				opened += 1
			}
			// What is kept is what there is, and nothing else is.
			s := index_scope(&w.x, 1)
			for &k in q.where_.kids {
				held := k.held
				whole, length := 0, u64(0)
				for &d in docs {
					r := Row{n = &w.node, id = d.id}
					bytes, _ := row_slot(&r, held.slot)
					tally := make(map[Key]int, context.temp_allocator)
					n := 0
					it := words(bytes)
					for word in words_next(&it) {
						word := word
						k, _ := bytes_key(word.bytes[:word.len])
						tally[k] += 1
						n += 1
					}
					row, _ := row_number(s, d.id)
					text, has := held_text(held, row)
					testing.expect_value(t, has, n > 0)
					if !has {
						continue
					}
					entry, _ := text_entry(held, text)
					testing.expect(t, int(entry.length) == n && entry.row == row)
					for k, count in tally {
						had, _ := tree_get(&w.x, held.by_key, k, text)
						testing.expect_value(t, int(had), count)
						_, known := tree_get(&w.x, held.lexicon, k, 0)
						testing.expect(t, known)
					}
					whole += len(tally)
					length += u64(n)
				}
				testing.expect_value(t, held.length, length)
				if held.dead == 0 {
					testing.expect_value(t, tree_total(&w.x, held.by_key).count, whole)
				}
			}
			if testing.failed(t) {
				fmt.println("seed", seed, "step", step)
				return
			}
		}
		testing.expect(t, HOT_LEAST > 0 || opened > 0)
		testing.expectf(t, again * 3 < edits, "read in whole %d times, of %d", again, edits)
	}
}
