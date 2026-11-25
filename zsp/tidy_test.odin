#+build !js
package zsp

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"

// A piece that puts a word at the beginning.
@(private)
tidy_write :: proc(t: ^testing.T, s: ^Sim, x: ^Sim_Node, row: Id, word: string, as := "") -> Cell {
	s.now += 500
	for y in s.nodes {
		y.node.now = sim_now(s, y)
	}
	body := make([dynamic]byte, context.temp_allocator)
	write_u64(&body, rand.uint64() | 1)
	append(&body, 1, 0, 0)
	write_bytes(&body, transmute([]byte)word)
	c := Cell{row, DATA, .Piece, node_stamp(&x.node), body[:]}
	plain := c
	x.node.now += 60_000 // it is written down later than it was written
	testing.expect(t, node_write(&x.node, {c}, transmute([]byte)as))
	return plain
}

@(private)
tidy_row :: proc(t: ^testing.T, x: ^Sim_Node, scope: Scope) -> Id {
	row := node_id(&x.node, scope)
	body: [24]byte
	put_u64(body[:], u64(scope) << 32 | 5)
	put_u64(body[8:], 5)
	testing.expect(t, node_write(&x.node, {{row, PLACE, .Place, node_stamp(&x.node), body[:]}}))
	return row
}

@(private)
tidy_read :: proc(x: ^Sim_Node, row: Id) -> (said: string, cells: int) {
	text: Text
	defer text_destroy(&text)
	scan := row_scan(&x.node.store, row, DATA, DATA)
	for c in row_next(&x.node.store, &scan) {
		c := c
		if cell_open(&x.keys, &x.node.roster, &c) {
			text_apply(&text, &c)
			cells += 1
		}
	}
	out := make([dynamic]byte, context.temp_allocator)
	text_read(&text, &out)
	return string(out[:]), cells
}

@(private)
tidy_plain :: proc(cells: []Cell) -> string {
	text: Text
	defer text_destroy(&text)
	slice.sort_by(cells, proc(a, b: Cell) -> bool {return stamp_less(a.stamp, b.stamp)})
	for &c in cells {
		text_apply(&text, &c)
	}
	out := make([dynamic]byte, context.temp_allocator)
	text_read(&text, &out)
	return string(out[:])
}

// However much is written in a text it is a few cells, which say what was written, and whose it is.
@(test)
long_texts_are_kept_short :: proc(t: ^testing.T) {
	for scope in Scope(1) ..= 2 {
		state := seeded(91)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, 3, 0, 1, 64)
		defer sim_destroy(&s)
		a, b, e := s.nodes[0], s.nodes[1], s.nodes[2]
		testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
			draft_grant(d, s.nodes[0].keys.device, s.nodes[0].keys.signer, 2, {.Write, .Vouch})
		}))
		for i in 0 ..< 3 {
			sim_link(&s, i, 3)
		}
		sim_settle(&s)
		row := tidy_row(t, a, scope)
		sim_settle(&s)
		all := make([dynamic]Cell, context.temp_allocator)
		mine := 0
		N :: 60 * LOOSE
		for i in 0 ..< N {
			x := rand.choice([]^Sim_Node{a, b})
			as := "zoe" if x == a && rand.int_max(2) == 0 else ""
			append(&all, tidy_write(t, &s, x, row, fmt.tprintf("%s%d ", as if as != "" else "bob" if x == b else "ann", i), as))
			mine += 1 if as == "zoe" else 0
			if rand.int_max(5) == 0 {
				sim_settle(&s)
			}
		}
		sim_settle(&s)
		sim_check(&s)
		want := tidy_plain(all[:])
		by := make(map[string]int, context.temp_allocator)
		for x in ([]^Sim_Node{a, b, e}) {
			said, cells := tidy_read(x, row)
			testing.expect_value(t, said, want)
			// Three write, in a signed scope: each has what is loose, by and by, and what is not.
			testing.expectf(t, cells < 3 * (LOOSE + LOOSE / 2 + 8), "%d cells", cells)
		}
		scan := row_scan(&e.node.store, row, DATA, DATA)
		latest, modified: u64
		for c in row_next(&e.node.store, &scan) {
			c := c
			who: By
			testing.expect(t, cell_open(&e.keys, &e.node.roster, &c, &who))
			device, _, vouched, known := cell_author(&e.node.roster, &c, who)
			testing.expect(t, known == (scope == 2))
			inner := make([dynamic]byte, context.temp_allocator)
			one: Text
			text_apply(&one, &c)
			text_read(&one, &inner)
			text_destroy(&one)
			zoes := 0
			for i in 0 ..< len(inner) {
				zoes += 1 if inner[i] == 'z' else 0
			}
			by["zoe" if vouched else ""] += zoes
			if scope == 2 {
				// All of it is of the one whose it is said to be.
				name := "zoe" if vouched else "bob" if device == b.keys.device else "ann"
				testing.expect(t, strings.count(string(inner[:]), " ") == strings.count(string(inner[:]), name))
			}
			modified = max(modified, c.stamp.time)
		}
		for c in all {
			latest = max(latest, c.stamp.time)
		}
		testing.expect(t, modified >> 16 == latest >> 16) // it is no later for having been tidied
		testing.expect_value(t, by["zoe"], mine if scope == 2 else 0)
	}
}

// What was rightly written is not lost because it was put together with what was not, by someone who had not heard.
@(test)
tidying_takes_nothing_with_it :: proc(t: ^testing.T) {
	state := seeded(92)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 1, 64)
	defer sim_destroy(&s)
	a, b, e := s.nodes[0], s.nodes[1], s.nodes[2]
	for i in 0 ..< 3 {
		sim_link(&s, i, 3)
	}
	row := tidy_row(t, b, 2)
	old := Cell{row, DATA, .Bundle, node_stamp(&b.node), make([]byte, 20, context.temp_allocator)}
	put_u32(old.body, 1)
	testing.expect(t, !cell_valid(&old)) // nothing in it can be older than its row
	put_u64(old.body[4:], row_born(row))
	testing.expect(t, cell_valid(&old))
	all := make([dynamic]Cell, context.temp_allocator)
	for i in 0 ..< 3 * LOOSE {
		append(&all, tidy_write(t, &s, b, row, fmt.tprintf("%d ", i)))
	}
	sim_settle(&s)
	want := tidy_plain(all[:])
	before, _ := tidy_read(e, row)
	testing.expect_value(t, before, want)
	#reverse for l, i in s.links {
		if l.an == 1 || l.an == 2 {
			sim_cut(&s, i)
		}
	}
	sim_link(&s, 1, 2)
	// Some that nobody else has, when it ends.
	for i in 0 ..< LOOSE / 2 {
		append(&all, tidy_write(t, &s, b, row, fmt.tprintf("late %d ", i)))
	}
	sim_settle(&s)
	want = tidy_plain(all[:])
	s.now += 60 * 60 * 1000
	for y in s.nodes {
		y.node.now = sim_now(&s, y)
	}
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		draft_grant(d, s.nodes[1].keys.device, s.nodes[1].keys.signer, 2, {.Read})
	}))
	s.now += 10 * 60 * 1000
	for i in 0 ..< 5 * LOOSE {
		append(&all, tidy_write(t, &s, b, row, fmt.tprintf("more %d ", i)))
		if i % LOOSE == 0 {
			sim_settle(&s)
		}
	}
	sim_settle(&s)
	more, _ := tidy_read(e, row)
	testing.expect_value(t, more, tidy_plain(all[:]))
	sim_link(&s, 2, 3)
	sim_settle(&s)
	sim_settle(&s)
	for x in ([]^Sim_Node{a, b, e}) {
		said, _ := tidy_read(x, row)
		testing.expect_value(t, said, want)
	}
	sim_check(&s)
}

// And what a local client types is as well, which hears that it was.
@(test)
clients_are_tidied_after :: proc(t: ^testing.T) {
	state := seeded(93)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 0, 0, 64)
	defer sim_destroy(&s)
	a := s.nodes[0]
	ui := sim_client(&s, a)
	row := tidy_row(t, a, 2)
	sim_watch(ui, 1, scope_lo(2), scope_hi(2), 0, {data = true})
	pieces, bundles := 0, 0
	for i in 0 ..< 10 * LOOSE {
		s.now += 500
		a.node.now = sim_now(&s, a)
		body := make([dynamic]byte, context.temp_allocator)
		write_u64(&body, rand.uint64() | 1)
		append(&body, 1, 0, 0, 1, 'x')
		c := Cell{row, DATA, .Piece, node_stamp(&a.node), body[:]}
		w := make([dynamic]byte, context.temp_allocator)
		at := frame_begin(&w, .Cells)
		write_varint(&w, u64(i + 1))
		write_cell(&w, &c, false)
		frame_end(&w, at)
		testing.expect(t, session_input(ui, w[:]))
		out := session_output(ui)
		r := Reader{buf = out}
		for r.pos < len(out) {
			frame := read_bytes(&r)
			f := Reader{buf = frame[1:]}
			if Message(frame[0]) == .Cells {
				_ = read_varint(&f)
				last: Id
				for f.pos < len(f.buf) {
					cell, ok := read_cell(&f, last)
					testing.expect(t, ok)
					last = cell.row
					pieces += 1 if cell.kind == .Piece else 0
					bundles += 1 if cell.kind == .Bundle else 0
				}
			}
		}
		session_sent(ui, len(out))
	}
	said, cells := tidy_read(a, row)
	testing.expect_value(t, len(said), 10 * LOOSE)
	testing.expectf(t, cells < LOOSE * 2 + 8 && bundles > 0 && pieces < LOOSE, "%d cells, %d bundles, %d pieces", cells, bundles, pieces)
}
