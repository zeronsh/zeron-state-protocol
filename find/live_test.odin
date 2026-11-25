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
			if flags & ~u8(1) != 0 {
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
client_ask :: proc(t: ^testing.T, c: ^Client, id: u64, question: []byte) {
	w := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&w, zsp.Message(ASK))
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
answer_check_here :: proc(t: ^testing.T, p: ^World, own: ^Finder, c: ^Client, id: u64, question: []byte) -> bool {
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
	testing.expectf(t, told.flags == 0 && told.total == rows.count, "told %v of %d", told, rows.count)
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
	// As if it had been dear.
	l := f.live[0]
	l.due = time.tick_add(time.tick_now(), 60 * time.Millisecond)
	for _ in 0 ..< 20 {
		world_write(t, &w)
	}
	finder_run(&f)
	client_hear_out(t, &c, &f)
	testing.expect(t, c.answers[1].total == 0 && f.wake == l.due)
	time.accurate_sleep(70 * time.Millisecond)
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
