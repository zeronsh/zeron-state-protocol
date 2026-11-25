package find

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"
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
			delete(a.totals)
			a.totals = slice.clone(f.buf[f.pos:])
			testing.expect(t, !f.bad)
		}
	}
	zsp.session_sent(c.session, len(out))
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
			for _ in 0 ..< rand.int_max(3) {
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
			for _ in 0 ..< (300 if rand.int_max(15) == 0 else rand.int_max(8)) {
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
			client_hear(t, &c)
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
				q, _ := query_parse(question)
				query_prepare(&f.x, &q)
				for !query_ready(&f.x, &q) {
					finder_run(&f)
				}
				s := index_scope(&f.x, q.scope)
				rows: Set
				defer set_destroy(&rows)
				for row in w.rows {
					if n, ok := row_number(s, row); ok && plain_holds(&w, &q.where_, row) {
						set_add(&rows, n)
					}
				}
				page := query_page(s, &q, &rows)
				told := &c.answers[id]
				good := told != nil && told.flags == 1 && told.total == rows.count && len(told.ids) == len(page)
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
					fmt.println("seed", seed, "step", step, "question", id, q.where_)
					return
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
							fmt.println("seed", seed, "step", step, "cell", cell.slot, cell.kind, has)
							return
						}
					}
				}
			}
			if testing.failed(t) {
				fmt.println("seed", seed, "step", step)
				return
			}
		}
	}
}
