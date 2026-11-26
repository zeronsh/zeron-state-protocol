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
	for overwrite in ([]bool{false, true}) {
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
		testing.expect(t, node_write(&w.node, {{row, DATA, .Piece, node_stamp(&w.node), body[:]}}))
		if overwrite {
			testing.expect(t, node_write(&w.node, {{row, DATA, .Value, node_stamp(&w.node), transmute([]byte)string("new")}}))
		}
		settle(&s, &seen, ..uis[:])
		testing.expectf(t, len(w.node.typing) == 0 && len(r.node.typing) == 0, "overwrite %v: kept after it was written: %d and %d", overwrite, len(w.node.typing), len(r.node.typing))
		late := sim_client(&s, r)
		append(&uis, late)
		defer session_close(late)
		sim_watch(late, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
		settle(&s, &seen, ..uis[:])
		testing.expectf(t, read(&seen, late, row) == "", "overwrite %v: a late reader was given what was written already as being typed", overwrite)
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
