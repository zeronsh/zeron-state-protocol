#+build !js
package zsp

import "core:math/rand"
import "core:testing"

// What is typed before a reader watches is not lost to it: a piece is a stream of operations from its start, and live
// frames from the middle of one are of no use to a reader that missed the start, so a watch that comes late, whether
// straight from the reader or through a relay, is given what of the open piece the writer's node has seen, from its
// start, and the rest as it is typed.
@(test)
a_late_watch_is_given_the_open_piece :: proc(t: ^testing.T) {
	for relayed in ([]bool{true, false}) {
		state := seeded(70)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, 2, 0, 1 if relayed else 0, 64)
		defer sim_destroy(&s)
		if relayed {
			sim_link(&s, 0, 2)
			sim_link(&s, 1, 2)
		} else {
			sim_link(&s, 0, 1)
		}
		w, r := s.nodes[0], s.nodes[1]
		list := List{1 << 32 | 5, 5}
		place: [24]byte
		put_u64(place[:], list[0])
		put_u64(place[8:], list[1])
		put_u64(place[16:], 1)
		row := node_id(&w.node, 1)
		testing.expect(t, node_write(&w.node, {{row, PLACE, .Place, node_stamp(&w.node), place[:]}}))
		sim_settle(&s)

		live :: proc(ui: ^Session, row: Id, offset: u64, body: string) {
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
		writer := sim_client(&s, w)
		defer session_close(writer)
		live(writer, row, 0, "ab") // nobody watches yet
		sim_settle(&s)

		reader := sim_client(&s, r)
		defer session_close(reader)
		sim_watch(reader, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, known = true})
		sim_settle(&s)
		live(writer, row, 2, "cd")
		sim_settle(&s)

		// What the reader can make of what it was given: the piece's operations from the start, as far as they go.
		have: [dynamic]byte
		defer delete(have)
		frames := 0
		out := session_output(reader)
		rd := Reader{buf = out}
		for rd.pos < len(out) {
			frame := read_bytes(&rd)
			if Message(frame[0]) != .Live {
				continue
			}
			f := Reader{buf = frame[1:]}
			if read_pair(&f, Id) != row || Slot(read_u8(&f)) != DATA || read_u64(&f) != 7 {
				continue
			}
			offset := int(read_varint(&f))
			_ = read_stamp(&f)
			body := f.buf[f.pos:]
			frames += 1
			if offset <= len(have) && offset + len(body) > len(have) {
				append(&have, ..body[len(have) - offset:])
			}
		}
		testing.expectf(t, string(have[:]) == "abcd", "relayed %v: the reader has %q of %q, from %d frames", relayed, string(have[:]), "abcd", frames)
	}
}
