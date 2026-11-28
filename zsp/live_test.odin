#+build !js
package zsp

import "core:math/rand"
import "core:testing"

@(private = "file")
LIST :: List{1 << 32 | 5, 5}

// A live frame from a client, of piece 7 in the row's first data slot.
@(private = "file")
type :: proc(ui: ^Session, row: Id, offset: u64, body: string, piece: u64 = 7) {
	f: [dynamic]byte
	defer delete(f)
	at := frame_begin(&f, .Live)
	write_pair(&f, row)
	write_u8(&f, u8(DATA))
	write_u64(&f, piece)
	write_varint(&f, offset)
	write_stamp(&f, {})
	append(&f, ..transmute([]byte)body)
	frame_end(&f, at)
	session_input(ui, f[:])
}

// What a client makes of what it was told of piece 7: as one does, it takes no live text for a row it does not hold,
// and of a piece only what goes on from what it has.
// What a client has been sent, as its host takes it: all along, so that its pipe never stays full.
@(private = "file")
Seen :: map[^Session][dynamic]byte

@(private = "file")
take :: proc(seen: ^Seen, uis: ..^Session) {
	for ui in uis {
		out := session_output(ui)
		if ui not_in seen {
			seen[ui] = {}
		}
		append(&seen[ui], ..out)
		session_sent(ui, len(out))
	}
}

// Settles everything, taking what the clients are sent as it goes, until nothing more is.
@(private = "file")
settle :: proc(s: ^Sim, seen: ^Seen, uis: ..^Session) {
	for _ in 0 ..< 20 {
		sim_settle(s)
		before := 0
		for _, b in seen {
			before += len(b)
		}
		take(seen, ..uis)
		after := 0
		for _, b in seen {
			after += len(b)
		}
		if after == before {
			return
		}
	}
}

@(private = "file")
seen_destroy :: proc(seen: ^Seen) {
	for _, b in seen {
		delete(b)
	}
	delete(seen^)
}

@(private = "file")
read :: proc(seen: ^Seen, ui: ^Session, row: Id, piece: u64 = 7) -> string {
	have := make([dynamic]byte, context.temp_allocator)
	held := false
	out := seen[ui][:]
	rd := Reader{buf = out}
	for rd.pos < len(out) {
		frame := read_bytes(&rd)
		f := Reader{buf = frame[1:]}
		#partial switch Message(frame[0]) {
		case .Cells:
			_ = read_varint(&f)
			prev: Id
			for f.pos < len(f.buf) {
				c, ok := read_cell(&f, prev)
				if !ok {
					break
				}
				prev = c.row
				held ||= c.row == row
			}
		case .Live:
			if read_pair(&f, Id) != row || Slot(read_u8(&f)) != DATA || read_u64(&f) != piece || !held {
				continue
			}
			offset := int(read_varint(&f))
			_ = read_stamp(&f)
			body := f.buf[f.pos:]
			if offset <= len(have) && offset + len(body) > len(have) {
				append(&have, ..body[len(have) - offset:])
			}
		}
	}
	return string(have[:])
}

@(private = "file")
put :: proc(x: ^Sim_Node, order: u64 = 1, data := 0) -> Id {
	place: [24]byte
	put_u64(place[:], LIST[0])
	put_u64(place[8:], LIST[1])
	put_u64(place[16:], order)
	row := node_id(&x.node, 1)
	node_write(&x.node, {{row, PLACE, .Place, node_stamp(&x.node), place[:]}})
	if data > 0 {
		node_write(&x.node, {{row, DATA + 1, .Value, node_stamp(&x.node), make([]byte, data, context.temp_allocator)}})
	}
	return row
}

// What is typed before a reader watches is not lost to it: a piece is a stream of operations from its start, and live
// frames from the middle of one are of no use to a reader that missed the start, so a watch that comes late is given
// what of the open piece the writer's node has seen, from its start, and the rest as it is typed; and only once the
// reader holds the row, which it may not yet when it begins to watch. Whether the reader is through a relay, straight
// across, another client of the writer's own node, a partial replica that holds nothing, or one that has yet to be sent
// the row as it watches.
@(test)
a_late_watch_is_given_the_open_piece :: proc(t: ^testing.T) {
	Case :: enum {
		Relayed,
		Direct,
		Same_Node,
		Partial,
		Unsent,
		Big, // what the reader is first sent fills its pipe past where live text is dropped
	}
	for c in Case {
		state := seeded(70)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, 1 if c == .Partial else 2, 1 if c == .Partial else 0, 1 if c == .Relayed else 0, 64)
		defer sim_destroy(&s)
		seen: Seen
		defer seen_destroy(&seen)
		uis: [dynamic]^Session
		defer delete(uis)
		switch c {
		case .Relayed:
			sim_link(&s, 0, 2)
			sim_link(&s, 1, 2)
		case .Direct, .Partial, .Unsent, .Big:
			sim_link(&s, 0, 1)
		case .Same_Node:
		}
		w := s.nodes[0]
		r := s.nodes[0] if c == .Same_Node else s.nodes[1]
		if c == .Big {
			for i in 0 ..< 40 {
				put(w, u64(i) + 10, 512)
			}
		}
		row := put(w, 100 if c == .Big else 1) // after all the rest, in what the reader is first sent
		if c != .Unsent {
			settle(&s, &seen, ..uis[:])
		}
		writer := sim_client(&s, w)
		append(&uis, writer)
		defer session_close(writer)
		type(writer, row, 0, "ab") // nobody watches yet
		if c != .Unsent {
			settle(&s, &seen, ..uis[:])
		}
		reader := sim_client(&s, r)
		append(&uis, reader)
		defer session_close(reader)
		sim_watch(reader, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
		settle(&s, &seen, ..uis[:])
		type(writer, row, 2, "cd")
		settle(&s, &seen, ..uis[:])
		got := read(&seen, reader, row)
		testing.expectf(t, got == "abcd", "%v: the reader has %q of %q", c, got, "abcd")
	}
}

// What a node keeps of its clients' typing it keeps whole or not at all, however many pieces come and go.
@(test)
typing_is_kept_whole_or_not_at_all :: proc(t: ^testing.T) {
	state := seeded(71)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 0, 0, 64)
	defer sim_destroy(&s)
		seen: Seen
		defer seen_destroy(&seen)
		uis: [dynamic]^Session
		defer delete(uis)
	w := s.nodes[0]
	n := &w.node
	a, b := put(w), put(w)
	writer := sim_client(&s, w)
	append(&uis, writer)
	defer session_close(writer)
	kept :: proc(n: ^Node, row: Id) -> (string, bool) {
		for x in n.typing {
			if x.row == row {
				return string(x.ops[:]), true
			}
		}
		return "", false
	}

	// One that has lain still too long goes, wherever it is among them, and those after it are still found.
	n.now = 1_000_000
	type(writer, a, 0, "a")
	n.now += TYPING_MS / 2
	type(writer, b, 0, "b")
	n.now += TYPING_MS / 2 + 1
	type(writer, b, 1, "c")
	got, ok := kept(n, b)
	testing.expectf(t, ok && got == "bc", "kept %q", got)
	_, ok = kept(n, a)
	testing.expect(t, !ok, "what lay still was kept")

	// No more of a piece than TYPING_BYTES, however it comes.
	chunk := make([]byte, TYPING_BYTES / 4, context.temp_allocator)
	for &x in chunk {
		x = 'x'
	}
	at := 2
	for _ in 0 ..< 3 {
		type(writer, b, u64(at), string(chunk))
		at += len(chunk)
	}
	got, ok = kept(n, b)
	testing.expectf(t, ok && len(got) == at, "kept %d of %d", len(got), at)
	type(writer, b, u64(at), string(chunk)) // past it
	_, ok = kept(n, b)
	testing.expect(t, !ok, "a piece longer than may be kept was kept")

	// And what says again some of what was said, within it, is no reason to let it go.
	type(writer, a, 0, "abcdefgh")
	type(writer, a, 0, "abcdefghij")
	type(writer, a, 4, "efghijkl")
	got, ok = kept(n, a)
	testing.expectf(t, ok && got == "abcdefghijkl", "kept %q", got)
}

// What is written puts an end to what was kept of what was being typed there, at the writer's node and at the reader's:
// a piece sealed, or the text written over, is not given a reader afterwards as if it were still being typed.
@(test)
what_is_written_ends_what_was_typed :: proc(t: ^testing.T) {
	How :: enum {
		Sealed,
		Overwritten,
		Bundled, // sealed with another into one cell, as tidying does, and only so said to the reader
	}
	for how in How {
		state := seeded(72)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, 2, 0, 0, 64)
		defer sim_destroy(&s)
		seen: Seen
		defer seen_destroy(&seen)
		uis: [dynamic]^Session
		defer delete(uis)
		sim_link(&s, 0, 1)
		w, r := s.nodes[0], s.nodes[1]
		row := put(w)
		settle(&s, &seen, ..uis[:])
		writer := sim_client(&s, w)
		append(&uis, writer)
		defer session_close(writer)
		reader := sim_client(&s, r)
		append(&uis, reader)
		defer session_close(reader)
		sim_watch(reader, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
		settle(&s, &seen, ..uis[:])
		type(writer, row, 0, "old")
		settle(&s, &seen, ..uis[:])
		testing.expect(t, len(w.node.typing) == 1 && len(r.node.typing) == 1, "what is typed is kept where it is typed and where it is read")
		body: [dynamic]byte
		defer delete(body)
		write_u64(&body, 7)
		append(&body, "old")
		if how == .Bundled {
			other: [dynamic]byte
			defer delete(other)
			write_u64(&other, 8)
			append(&other, "x")
			pieces := []Cell{{row, DATA, .Piece, node_stamp(&w.node), body[:]}, {row, DATA, .Piece, node_stamp(&w.node), other[:]}}
			bundle := text_bundle(pieces, context.temp_allocator)
			bundle.stamp = node_stamp(&w.node)
			testing.expect(t, node_write(&w.node, {bundle}))
		} else {
			testing.expect(t, node_write(&w.node, {{row, DATA, .Piece, node_stamp(&w.node), body[:]}}))
		}
		if how == .Overwritten {
			testing.expect(t, node_write(&w.node, {{row, DATA, .Value, node_stamp(&w.node), transmute([]byte)string("new")}}))
		}
		settle(&s, &seen, ..uis[:])
		testing.expectf(t, len(w.node.typing) == 0 && len(r.node.typing) == 0, "%v: kept after it was written: %d and %d", how, len(w.node.typing), len(r.node.typing))
		late := sim_client(&s, r)
		append(&uis, late)
		defer session_close(late)
		sim_watch(late, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
		settle(&s, &seen, ..uis[:])
		testing.expectf(t, read(&seen, late, row) == "", "%v: a late reader was given what was written already as being typed", how)
	}
}

// Two writing in one place at once, through one relay, are each given whole to a reader who comes late; and what a node
// keeps of what peers send is kept piece by piece, whatever order and road its frames come by.
@(test)
pieces_from_peers_are_kept_apart :: proc(t: ^testing.T) {
	state := seeded(73)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 1, 64)
	defer sim_destroy(&s)
		seen: Seen
		defer seen_destroy(&seen)
		uis: [dynamic]^Session
		defer delete(uis)
	for i in 0 ..< 3 {
		sim_link(&s, i, 3)
	}
	a, b, c := s.nodes[0], s.nodes[1], s.nodes[2]
	row := put(a)
	settle(&s, &seen, ..uis[:])
	wa, wb := sim_client(&s, a), sim_client(&s, b)
	append(&uis, wa, wb)
	defer session_close(wa)
	defer session_close(wb)
	first := sim_client(&s, c) // so that what is typed reaches c's node
	append(&uis, first)
	defer session_close(first)
	sim_watch(first, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
	settle(&s, &seen, ..uis[:])
	type(wa, row, 0, "ab", 101)
	type(wb, row, 0, "xy", 202)
	settle(&s, &seen, ..uis[:])
	type(wa, row, 2, "cd", 101)
	settle(&s, &seen, ..uis[:])
	late := sim_client(&s, c)
	append(&uis, late)
	defer session_close(late)
	sim_watch(late, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
	settle(&s, &seen, ..uis[:])
	got_a, got_b := read(&seen, late, row, 101), read(&seen, late, row, 202)
	testing.expectf(t, got_a == "abcd" && got_b == "xy", "the late reader has %q and %q of %q and %q", got_a, got_b, "abcd", "xy")

	// By hand, as frames may come: out of order, and by two roads.
	n := &c.node
	clear_typing :: proc(n: ^Node) {
		for &x in n.typing {
			delete(x.ops)
		}
		clear(&n.typing)
	}
	clear_typing(n)
	one, two := n.sessions[0], n.sessions[len(n.sessions) - 1]
	frame :: proc(n: ^Node, s: ^Session, row: Id, piece, offset: u64, body: string) {
		l := Live{row = row, slot = DATA, piece = piece, offset = offset, body = transmute([]byte)body}
		typing_keep(n, s, &l, false)
	}
	kept :: proc(n: ^Node, piece: u64) -> string {
		for x in n.typing {
			if x.piece == piece {
				return string(x.ops[:])
			}
		}
		return "-"
	}
	frame(n, one, row, 2, 0, "ef")
	frame(n, one, row, 1, 2, "cd") // late, of a piece before
	frame(n, one, row, 2, 2, "gh")
	testing.expectf(t, kept(n, 2) == "efgh", "out of order: kept %q", kept(n, 2))
	clear_typing(n)
	frame(n, one, row, 3, 0, "ab")
	frame(n, two, row, 3, 2, "cd") // by the other road
	frame(n, one, row, 3, 6, "gh") // ahead of what came between
	frame(n, one, row, 3, 4, "ef")
	testing.expectf(t, kept(n, 3) == "abcdef", "by two roads: kept %q", kept(n, 3))
}

// A row moved, while a piece is typed in it, to where a reader watches what is typed is given it from the start: by a
// peer that holds the row already, and so is sent only where it now is, as by any other.
@(test)
a_row_moved_into_view_brings_its_open_piece :: proc(t: ^testing.T) {
	for relayed in ([]bool{false, true}) {
		state := seeded(74)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, 2, 0, 1 if relayed else 0, 64)
		defer sim_destroy(&s)
		seen: Seen
		defer seen_destroy(&seen)
		uis: [dynamic]^Session
		defer delete(uis)
		if relayed {
			sim_link(&s, 0, 2)
			sim_link(&s, 1, 2)
		} else {
			sim_link(&s, 0, 1)
		}
		w, r := s.nodes[0], s.nodes[1]
		elsewhere := List{1 << 32 | 6, 6}
		place :: proc(x: ^Sim_Node, row: Id, list: List) {
			body: [24]byte
			put_u64(body[:], list[0])
			put_u64(body[8:], list[1])
			put_u64(body[16:], 1)
			node_write(&x.node, {{row, PLACE, .Place, node_stamp(&x.node), body[:]}})
		}
		row := node_id(&w.node, 1)
		place(w, row, elsewhere)
		settle(&s, &seen, ..uis[:])
		writer := sim_client(&s, w)
		defer session_close(writer)
		reader := sim_client(&s, r)
		defer session_close(reader)
		append(&uis, writer, reader)
		sim_watch(reader, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
		settle(&s, &seen, ..uis[:])
		type(writer, row, 0, "ab") // where nobody watches
		settle(&s, &seen, ..uis[:])
		s.now += 3
		w.node.now = sim_now(&s, w)
		place(w, row, LIST) // and now where the reader does
		settle(&s, &seen, ..uis[:])
		type(writer, row, 2, "cd")
		settle(&s, &seen, ..uis[:])
		got := read(&seen, reader, row)
		testing.expectf(t, got == "abcd", "relayed %v: the reader has %q of %q", relayed, got, "abcd")
	}
}

// Live text goes to a reader whose pipe is full at the moment it is typed, by a relay as by a device: it is not let go
// of because what was said before it has yet to go, as though the piece itself would follow soon, which it does only
// once sealed, a second later, the reader having seen nothing of it as it was typed. (The Windows flake, "as it is
// typed, not once it is sealed".)
@(test)
live_overtakes_a_full_pipe :: proc(t: ^testing.T) {
	Case :: enum {
		Relayed, // the relay's pipe to the reader's node is full
		Direct, // the writer's node's pipe to the reader's
	}
	for c in Case {
		state := seeded(71)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, 2, 0, 1 if c == .Relayed else 0, 4096) // all that is written is sent as it changed, not compared afresh
		defer sim_destroy(&s)
		seen: Seen
		defer seen_destroy(&seen)
		w, r := s.nodes[0], s.nodes[1]
		if c == .Relayed {
			sim_link(&s, 0, 2)
			sim_link(&s, 1, 2)
		} else {
			sim_link(&s, 0, 1)
		}
		row := put(w, 1)
		settle(&s, &seen)
		writer := sim_client(&s, w)
		defer session_close(writer)
		reader := sim_client(&s, r)
		defer session_close(reader)
		sim_watch(reader, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
		settle(&s, &seen, writer, reader)
		// Much is written elsewhere, on its way to the reader's node, and made for it but not yet taken: its pipe is full.
		ROWS :: 600 // more than is made for a pipe at once
		for i in 0 ..< ROWS {
			place: [24]byte
			put_u64(place[:], LIST[0])
			put_u64(place[8:], LIST[1] + 1)
			put_u64(place[16:], u64(i))
			other := node_id(&w.node, 1)
			node_write(&w.node, {{other, PLACE, .Place, node_stamp(&w.node), place[:]}, {other, DATA + 1, .Value, node_stamp(&w.node), make([]byte, 1024, context.temp_allocator)}})
		}
		toward := s.links[0] if c == .Direct else s.links[1] // the way to the reader's node
		from_w := s.links[0]
		if c == .Relayed {
			// What the writer's node says reaches the relay, and the relay makes all it can for the reader's node.
			for _ in 0 ..< 500 {
				out := session_output(from_w.a)
				if len(out) == 0 {
					break
				}
				testing.expect(t, session_input(from_w.b, out))
				session_sent(from_w.a, len(out))
			}
		}
		full := toward.b if c == .Relayed else toward.a // the end that sends toward the reader's node
		_ = session_output(full)
		testing.expectf(t, len(full.out) - full.sent > OUT_LIVE, "%v: the pipe is not full: %d", c, len(full.out) - full.sent)
		// Typed now: it reaches the writer's node, and goes on as far as the full pipe.
		type(writer, row, 0, "ab")
		if c == .Relayed {
			out := session_output(from_w.a)
			testing.expect(t, session_input(from_w.b, out))
			session_sent(from_w.a, len(out))
		}
		// What is sent toward the reader's node goes a piece at a time: what is typed comes once what was made before it has
		// gone, and before what is made after, not once all of the rest has.
		peer := toward.a if c == .Relayed else toward.b
		backlog := List{LIST[0], LIST[1] + 1}
		held_then := -1
		for _ in 0 ..< 2000 {
			out := session_output(full)
			if len(out) == 0 {
				break
			}
			n := min(len(out), 4096)
			testing.expect(t, session_input(peer, out[:n]))
			session_sent(full, n)
			if held_then < 0 {
				for x in r.node.typing {
					if x.row == row && len(x.ops) > 0 {
						held_then = store_range(&r.node.store, list_lo(backlog), list_hi(backlog)).count
					}
				}
			}
		}
		testing.expectf(t, held_then >= 0 && held_then < ROWS, "%v: what was typed came once %d of the %d rows before it had", c, held_then, ROWS)
		// And then all goes as it can: the reader has it, as typed, without the piece's being sealed.
		settle(&s, &seen, writer, reader)
		got := read(&seen, reader, row)
		testing.expectf(t, got == "ab", "%v: the reader has %q of what was typed, %q", c, got, "ab")
		free_all(context.temp_allocator)
	}
}

// And so to a client whose own pipe from its node is full, of rows it watches, as a client's is while it is shown much:
// what is typed reaches it before all of those, not once the rest has gone.
@(test)
live_overtakes_a_full_pipe_to_a_client :: proc(t: ^testing.T) {
	state := seeded(72)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 4096)
	defer sim_destroy(&s)
	seen: Seen
	defer seen_destroy(&seen)
	w, r := s.nodes[0], s.nodes[1]
	sim_link(&s, 0, 1)
	row := put(w, 1)
	settle(&s, &seen)
	writer := sim_client(&s, w)
	defer session_close(writer)
	reader := sim_client(&s, r)
	defer session_close(reader)
	backlog := List{LIST[0], LIST[1] + 1}
	sim_watch(reader, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
	sim_watch(reader, 2, list_lo(backlog), list_hi(backlog), 0, {data = true})
	settle(&s, &seen, writer, reader)
	ROWS :: 600
	for i in 0 ..< ROWS {
		place: [24]byte
		put_u64(place[:], backlog[0])
		put_u64(place[8:], backlog[1])
		put_u64(place[16:], u64(i))
		other := node_id(&w.node, 1)
		node_write(&w.node, {{other, PLACE, .Place, node_stamp(&w.node), place[:]}, {other, DATA + 1, .Value, node_stamp(&w.node), make([]byte, 1024, context.temp_allocator)}})
	}
	sim_settle(&s) // all of it reaches the reader's node, and is made for its client, which has yet to take it
	take(&seen, writer)
	_ = session_output(reader)
	testing.expectf(t, len(reader.out) - reader.sent > OUT_LIVE, "the pipe is not full: %d", len(reader.out) - reader.sent)
	type(writer, row, 0, "ab")
	sim_settle(&s)
	// The client takes what it is sent a piece at a time: how many of the rows had come by the time what was typed did.
	got := make([dynamic]byte, context.temp_allocator)
	rows_then := -1
	for _ in 0 ..< 4000 {
		out := session_output(reader)
		if len(out) == 0 {
			break
		}
		n := min(len(out), 4096)
		append(&got, ..out[:n])
		session_sent(reader, n)
		if rows_then >= 0 {
			continue
		}
		rows := map[Id]bool{}
		defer delete(rows)
		rd := Reader{buf = got[:]}
		for rd.pos < len(got) {
			size := read_varint(&rd)
			if rd.bad || rd.pos + int(size) > len(got) {
				break
			}
			frame := got[rd.pos:][:size]
			rd.pos += int(size)
			f := Reader{buf = frame[1:]}
			#partial switch Message(frame[0]) {
			case .Cells:
				_ = read_varint(&f)
				prev: Id
				for f.pos < len(f.buf) {
					c, ok := read_cell(&f, prev)
					if !ok {
						break
					}
					prev = c.row
					if c.row != row {
						rows[c.row] = true
					}
				}
			case .Live:
				if read_pair(&f, Id) == row && rows_then < 0 {
					rows_then = len(rows)
				}
			}
		}
	}
	testing.expectf(t, rows_then >= 0 && rows_then < ROWS, "what was typed came to the client once %d of the %d rows had", rows_then, ROWS)
	free_all(context.temp_allocator)
}

// While what has changed waits on live text, a replica becoming partial does not say it has said all it holds: what is
// held back is not yet said, and may be what fell off the ring, to be compared afresh. (Review 1 of #41, 1.)
@(test)
told_waits_for_what_live_text_holds_back :: proc(t: ^testing.T) {
	state := seeded(73)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 256)
	defer sim_destroy(&s)
	desk, laptop := s.nodes[0], s.nodes[1]
	sim_put(&s, desk, 1)
	sim_put(&s, laptop, 2)
	sim_restart(&s, laptop, full = false) // becoming partial
	sim_link(&s, 0, 1) // the desk dials
	sim_settle(&s)
	at := s.links[0].b // the laptop's end
	testing.expect(t, at.told, "never said it had said all it holds")
	at.told = false
	at.typing_due = true // live text owed, and no room for it
	append(&at.out, ..make([]byte, OUT_LIVE + 1, context.temp_allocator))
	_ = session_output(at)
	testing.expect(t, !at.told, "said it had said all it holds while what had changed waited on live text")
	session_sent(at, len(at.out) - at.sent) // what was in the way goes, unread: the link is not passed again
	_ = session_output(at)
	testing.expect(t, at.told, "never said so once there was room")
	free_all(context.temp_allocator)
}

// Live text overtakes the rest and never takes its place: however much of it is given at once, and however often, so
// much of the rest is made each time as would have been without it. (Review 1 of #41, 2.)
@(test)
live_text_never_starves_the_rest :: proc(t: ^testing.T) {
	state := seeded(74)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 4096)
	defer sim_destroy(&s)
	seen: Seen
	defer seen_destroy(&seen)
	w, r := s.nodes[0], s.nodes[1]
	sim_link(&s, 0, 1)
	rows: [5]Id
	for &x, i in rows {
		x = put(w, u64(i) + 1)
	}
	settle(&s, &seen)
	writer := sim_client(&s, w)
	defer session_close(writer)
	reader := sim_client(&s, r)
	defer session_close(reader)
	sim_watch(reader, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
	settle(&s, &seen, writer, reader)
	big := make([]byte, 13 << 10, context.temp_allocator)
	for &b in big {
		b = 'x'
	}
	for x in rows {
		type(writer, x, 0, string(big)) // five pieces open, 65 KiB of them
	}
	take(&seen, writer)
	for i in 0 ..< 120 {
		place: [24]byte
		put_u64(place[:], LIST[0])
		put_u64(place[8:], LIST[1] + 1)
		put_u64(place[16:], u64(i))
		other := node_id(&w.node, 1)
		node_write(&w.node, {{other, PLACE, .Place, node_stamp(&w.node), place[:]}, {other, DATA + 1, .Value, node_stamp(&w.node), make([]byte, 1024, context.temp_allocator)}})
	}
	full, peer := s.links[0].a, s.links[0].b // the writer's node toward the reader's, and the reader's
	began := full.cursor
	for _ in 0 ..< 200 {
		if !full.typing_due && len(full.out) - full.sent > OUT_LIVE {
			full.typing_due = true // a key pressed, and dropped for want of room
		}
		out := session_output(full)
		n := min(len(out), 4096)
		testing.expect(t, session_input(peer, out[:n]))
		session_sent(full, n)
		back := session_output(peer) // and what the reader's node says of it, as it would: what it took
		testing.expect(t, session_input(full, back))
		session_sent(peer, len(back))
	}
	testing.expectf(t, full.cursor > began, "nothing more was made of the rest: %d of %d changes said", full.cursor - began, w.node.store.events.next - began)
	free_all(context.temp_allocator)
}

// What a relay keeps of live text is never more than LIVE_OWED, however large what comes, and what it gives up it lets
// go of. (Review 1 of #41, 3.)
@(test)
a_relay_keeps_so_much_live_text_at_most :: proc(t: ^testing.T) {
	state := seeded(75)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 0, 1, 256)
	defer sim_destroy(&s)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	at := s.links[0].b // the relay's end
	testing.expect(t, at.node.keys == nil, "not a relay")
	append(&at.out, ..make([]byte, OUT_LIVE + 1, context.temp_allocator)) // no room
	body := make([]byte, 20 << 10, context.temp_allocator)
	most, gave_up := 0, false
	for i in 0 ..< 6 {
		l := Live{row = {1, u64(i)}, slot = DATA, piece = 7, body = body}
		was := len(at.live_owed)
		testing.expect(t, send_live(at, &l))
		most = max(most, len(at.live_owed), cap(at.live_owed))
		if len(at.live_owed) == 0 && was > 0 {
			gave_up = true
			testing.expectf(t, cap(at.live_owed) <= 4096, "what was given up is held still: %d", cap(at.live_owed))
		}
	}
	testing.expectf(t, most <= LIVE_OWED + 4096, "kept %d of live text", most)
	testing.expect(t, gave_up, "never gave up")
	// Owing live text, it does not sleep; and what it owes goes with a watch let go of, and when what it may read is
	// judged again. (Neon on #41, P41-1.)
	l := Live{row = {1, 9}, slot = DATA, piece = 7, body = body[:1024]}
	testing.expect(t, send_live(at, &l) && len(at.live_owed) > 0)
	saved := make([dynamic]byte, context.temp_allocator)
	testing.expect(t, !session_save(at, &saved), "a relay would sleep owing live text")
	unwatch :: proc(t: ^testing.T, at: ^Session, id: u64) {
		f: [dynamic]byte
		defer delete(f)
		frame := frame_begin(&f, .Unwatch)
		write_varint(&f, id)
		frame_end(&f, frame)
		testing.expect(t, session_input(at, f[:]))
	}
	unwatch(t, at, 12345) // of no watch it has: what it owes stays
	testing.expect(t, len(at.live_owed) > 0, "let go of live text for no watch let go of")
	testing.expect(t, len(at.watches) > 0, "the peer watches nothing")
	if len(at.watches) > 0 {
		unwatch(t, at, at.watches[0].id)
	}
	testing.expectf(t, len(at.live_owed) == 0, "kept %d of live text for a watch let go of", len(at.live_owed))
	testing.expect(t, send_live(at, &l) && len(at.live_owed) > 0)
	session_authorize(at)
	testing.expectf(t, len(at.live_owed) == 0, "kept %d of live text through what it may read being judged again", len(at.live_owed))
	clear(&at.out)
	at.sent = 0
	free_all(context.temp_allocator)
}
