#+build !js
package zsp

import "core:math/rand"
import "core:slice"
import "core:testing"

@(private)
Log_Entry :: struct {
	cell: Cell,
}

@(private)
text_string :: proc(t: ^Text) -> string {
	w := make([dynamic]byte, context.temp_allocator)
	text_read(t, &w)
	return string(w[:])
}

@(private)
Scribe :: struct {
	text: Text,
	seen: int, // of the shared log
	mine: [dynamic]Cell,
}

@(private)
scribble :: proc(s: ^Scribe) {
	n := text_len(&s.text)
	if n > 0 && rand.int_max(4) == 0 {
		pos := rand.int_max(n)
		text_delete(&s.text, pos, min(1 + rand.int_max(6), n - pos), rand.uint64() | 1)
		return
	}
	word: [5]byte
	for &b in word {
		b = 'a' + byte(rand.int_max(26))
	}
	pos := n if rand.int_max(2) == 0 else rand.int_max(n + 1)
	text_insert(&s.text, pos, word[:1 + rand.int_max(5)], rand.uint64() | 1)
}

// Any writers, any order, any duplication, live frames lost or not: one text.
@(test)
text_converges :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_TEXT_SEEDS, 40)
	for seed in 0 ..< SEEDS {
		state := seeded(u64(seed))
		context.random_generator = rand.default_random_generator(&state)
		scribes: [3]Scribe
		all := make([dynamic]Cell, context.temp_allocator)
		clock: u64
		for _ in 0 ..< 250 {
			i := rand.int_max(len(scribes))
			s := &scribes[i]
			switch r := rand.int_max(10); {
			case r < 5:
				scribble(s)
			case r < 7: // a live flush, which each other scribe may or may not catch
				piece, offset, bytes := text_flush(&s.text)
				for &o in scribes {
					if &o != s && piece != 0 && rand.int_max(3) > 0 {
						text_live(&o.text, piece, offset, bytes)
					}
				}
			case r < 8:
				clock += 1
				stamp := Stamp{clock, rand.uint64()}
				if body, ok := text_close(&s.text, stamp); ok {
					append(&all, Cell{{1, 1}, DATA, .Piece, stamp, body})
				}
			case: // catch up, out of order and with repeats
				for _ in 0 ..< 4 {
					if len(all) > 0 {
						c := rand.choice(all[:])
						text_apply(&s.text, &c)
					}
				}
			}
		}
		for &s in scribes {
			clock += 1
			stamp := Stamp{clock, rand.uint64()}
			if body, ok := text_close(&s.text, stamp); ok {
				append(&all, Cell{{1, 1}, DATA, .Piece, stamp, body})
			}
		}
		want := ""
		for &s, i in scribes {
			rand.shuffle(all[:])
			for &c in all {
				text_apply(&s.text, &c)
			}
			testing.expect_value(t, len(s.text.waiting), 0)
			if i == 0 {
				want = text_string(&s.text)
			}
			testing.expect_value(t, text_string(&s.text), want)
		}

		// A newcomer, from pieces; another, from one bundle of them all plus stragglers.
		newcomer, late: Text
		slice.reverse(all[:])
		for &c in all {
			text_apply(&newcomer, &c)
		}
		testing.expect_value(t, text_string(&newcomer), want)
		bundle := text_bundle(all[:], context.temp_allocator)
		bundle.stamp = {clock + 1, 1}
		text_apply(&late, &all[0])
		text_apply(&late, &bundle)
		testing.expect_value(t, text_string(&late), want)
		testing.expect_value(t, len(late.waiting), 0)

		text_destroy(&newcomer)
		text_destroy(&late)
		for &s in scribes {
			text_destroy(&s.text)
		}
		free_all(context.temp_allocator)
		if testing.failed(t) {
			return
		}
	}
}

// A streamed answer costs one span, whatever the number of tokens.
@(test)
text_streams_flat :: proc(t: ^testing.T) {
	a, b: Text
	defer text_destroy(&a)
	defer text_destroy(&b)
	for i in 0 ..< 1000 {
		text_insert(&a, text_len(&a), transmute([]byte)string("token "), 7)
		if i % 3 == 0 {
			text_live(&b, text_flush(&a))
		}
	}
	text_live(&b, text_flush(&a))
	testing.expect_value(t, len(a.spans), 1)
	testing.expect_value(t, len(b.spans), 1)
	body, ok := text_close(&a, {1, 1})
	c := Cell{{1, 1}, DATA, .Piece, {1, 1}, body}
	testing.expect(t, ok && text_apply(&b, &c) == .Changed)
	testing.expect_value(t, text_string(&b), text_string(&a))
	testing.expect_value(t, text_apply(&b, &c), Text_Result.Same)
}
