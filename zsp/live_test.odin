#+build !js
package zsp

import "core:math/rand"
import "core:testing"

@(private = "file")
LIST :: List{1 << 32 | 5, 5}

// A live frame from a client, of piece 7 in the row's first data slot.
@(private = "file")
type :: proc(ui: ^Session, row: Id, offset: u64, body: string) {
	f: [dynamic]byte
	defer delete(f)
	at := frame_begin(&f, .Live)
	write_pair(&f, row)
	write_u8(&f, u8(DATA))
	write_u64(&f, 7)
	write_varint(&f, offset)
	write_stamp(&f, {})
	append(&f, ..transmute([]byte)body)
	frame_end(&f, at)
	session_input(ui, f[:])
}

// What a client makes of what it was told of piece 7: as one does, it takes no live text for a row it does not hold,
// and of a piece only what goes on from what it has.
@(private = "file")
read :: proc(ui: ^Session, row: Id) -> string {
	have: [dynamic]byte
	held := false
	out := session_output(ui)
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
			if read_pair(&f, Id) != row || Slot(read_u8(&f)) != DATA || read_u64(&f) != 7 || !held {
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
put :: proc(x: ^Sim_Node) -> Id {
	place: [24]byte
	put_u64(place[:], LIST[0])
	put_u64(place[8:], LIST[1])
	put_u64(place[16:], 1)
	row := node_id(&x.node, 1)
	node_write(&x.node, {{row, PLACE, .Place, node_stamp(&x.node), place[:]}})
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
	}
	for c in Case {
		state := seeded(70)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, 1 if c == .Partial else 2, 1 if c == .Partial else 0, 1 if c == .Relayed else 0, 64)
		defer sim_destroy(&s)
		switch c {
		case .Relayed:
			sim_link(&s, 0, 2)
			sim_link(&s, 1, 2)
		case .Direct, .Partial, .Unsent:
			sim_link(&s, 0, 1)
		case .Same_Node:
		}
		w := s.nodes[0]
		r := s.nodes[0] if c == .Same_Node else s.nodes[1]
		row := put(w)
		if c != .Unsent {
			sim_settle(&s)
		}
		writer := sim_client(&s, w)
		defer session_close(writer)
		type(writer, row, 0, "ab") // nobody watches yet
		if c != .Unsent {
			sim_settle(&s)
		}
		reader := sim_client(&s, r)
		defer session_close(reader)
		sim_watch(reader, 1, list_lo(LIST), list_hi(LIST), 50, {data = true, live = true, known = true})
		sim_settle(&s)
		type(writer, row, 2, "cd")
		sim_settle(&s)
		got := read(reader, row)
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
	w := s.nodes[0]
	n := &w.node
	a, b := put(w), put(w)
	writer := sim_client(&s, w)
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
