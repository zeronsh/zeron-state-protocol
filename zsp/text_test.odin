#+build !js
package zsp

import "core:math/rand"
import "core:slice"
import "core:strings"
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
	testing.expect_value(t, text_runs(&a), 1)
	testing.expect_value(t, text_runs(&b), 1)
	body, ok := text_close(&a, {1, 1})
	c := Cell{{1, 1}, DATA, .Piece, {1, 1}, body}
	testing.expect(t, ok && text_apply(&b, &c) == .Changed)
	testing.expect_value(t, text_string(&b), text_string(&a))
	testing.expect_value(t, text_apply(&b, &c), Text_Result.Same)
}

// The text holds to one written as simply as can be, whatever comes, and says rightly what has changed.
@(test)
text_is_what_it_should_be :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_TEXT_SEEDS, 40)
	white :: proc(b: byte) -> bool {return b == ' ' || b == '\n'}
	for seed in 0 ..< SEEDS {
		state := seeded(u64(seed) + 700)
		context.random_generator = rand.default_random_generator(&state)
		scribes: [3]Scribe
		plain: Plain_Text
		ours: Text
		all := make([dynamic]Cell, context.temp_allocator)
		clock: u64
		steps := 200 if seed % 8 != 0 else 1500
		apply :: proc(t: ^testing.T, ours: ^Text, plain: ^Plain_Text, c: ^Cell) -> (rebuilt: bool) {
			a, b := text_apply(ours, c), plain_text_apply(plain, c)
			testing.expect_value(t, int(a), int(b))
			if a == .Rebuild {
				// As a holder of it does: all of it again, in order of stamps.
				text_destroy(ours)
				plain_text_destroy(plain)
			}
			return a == .Rebuild
		}
		for step in 0 ..< steps {
			i := rand.int_max(len(scribes))
			s := &scribes[i]
			switch r := rand.int_max(12); {
			case r < 6:
				n := text_len(&s.text)
				if n > 0 && rand.int_max(3) == 0 {
					pos := rand.int_max(n)
					text_delete(&s.text, pos, min(1 + rand.int_max(12), n - pos), rand.uint64() | 1)
				} else {
					part := rand.choice([]string{"a", "bc ", " ", "def", "\n", "ghij kl", " m "})
					text_insert(&s.text, n if rand.int_max(2) == 0 else rand.int_max(n + 1), transmute([]byte)part, rand.uint64() | 1)
				}
			case r < 8:
				clock += 1
				stamp := Stamp{clock, rand.uint64()}
				if body, ok := text_close(&s.text, stamp); ok {
					append(&all, Cell{{1, 1}, DATA, .Piece, stamp, body})
				}
				// Two that were once one: another piece by the same name. And now and then a text beneath it all.
				if len(all) > 0 && rand.int_max(8) == 0 {
					if twin := rand.choice(all[:]); twin.kind == .Piece && len(twin.body) >= 8 {
						w := make([dynamic]byte, context.temp_allocator)
						append(&w, ..twin.body[:8])
						append(&w, byte(Op.Insert), 0, 0)
						write_bytes(&w, transmute([]byte)string("twin "))
						append(&all, Cell{{1, 1}, DATA, .Piece, {clock, rand.uint64() if rand.int_max(4) > 0 else twin.stamp.salt}, w[:]})
					}
				}
				// Someone who minds nothing: neighbours in any order, and of any piece.
				if len(all) > 2 && rand.int_max(6) == 0 {
					w := make([dynamic]byte, context.temp_allocator)
					write_u64(&w, rand.uint64() | 1)
					for _ in 0 ..< 2 {
						append(&w, byte(Op.Insert))
						for _ in 0 ..< 2 {
							near := rand.choice(all[:])
							if near.kind == .Piece && len(near.body) >= 8 {
								append(&w, 2)
								append(&w, ..near.body[:8])
								write_varint(&w, u64(rand.int_max(4)))
							} else {
								append(&w, 0)
							}
						}
						write_bytes(&w, transmute([]byte)string("ZZ"))
					}
					append(&all, Cell{{1, 1}, DATA, .Piece, {clock, rand.uint64()}, w[:]})
				}
				if rand.int_max(40) == 0 {
					append(&all, Cell{{1, 1}, DATA, .Value, {u64(rand.int_max(int(clock) + 1)), rand.uint64()}, transmute([]byte)string("beneath it")})
				}
			case r < 9: // seen live
				piece, offset, bytes := text_flush(&s.text)
				if piece != 0 && rand.int_max(2) == 0 {
					a, b := text_live(&ours, piece, offset, bytes), plain_text_live(&plain, piece, offset, bytes)
					testing.expect_value(t, int(a), int(b))
				}
			case:
				for _ in 0 ..< 4 {
					if len(all) == 0 {
						break
					}
					c := rand.choice(all[:])
					text_apply(&s.text, &c)
					// Some of it at once, and what has changed is said.
					before := text_string(&ours)
					follow := rand.int_max(2) == 0
					if follow {
						text_follow(&ours)
					}
					rebuilt := false
					many := 1 + rand.int_max(3)
					for _ in 0 ..< many {
						c = rand.choice(all[:])
						again := apply(t, &ours, &plain, &c)
						rebuilt ||= again
					}
					if follow && !rebuilt {
						Said :: struct {
							t:    ^testing.T,
							was, now: [dynamic]string,
						}
						said := Said{t = t, was = make([dynamic]string, context.temp_allocator), now = make([dynamic]string, context.temp_allocator)}
						text_changes(&ours, &said, proc(data: rawptr, was, now: []byte) {
							s := (^Said)(data)
							append(&s.was, string(slice.clone(was, context.temp_allocator)))
							append(&s.now, string(slice.clone(now, context.temp_allocator)))
						})
						// Taking the words there were, and putting those there are, makes of one the other.
						tally := make(map[string]int, context.temp_allocator)
						count :: proc(tally: ^map[string]int, s: string, by: int) {
							from := 0
							for i in 0 ..= len(s) {
								if i == len(s) || white(s[i]) {
									if i > from {
										tally[s[from:i]] += by
									}
									from = i + 1
								}
							}
						}
						count(&tally, before, 1)
						count(&tally, text_string(&ours), -1)
						for j in 0 ..< len(said.was) {
							count(&tally, said.was[j], -1)
							count(&tally, said.now[j], 1)
						}
						for word, n in tally {
							testing.expectf(t, n == 0, "seed %d step %d: %q is out by %d", seed, step, word, n)
						}
					} else if follow {
						ours.follow = false
						clear(&ours.touched)
					}
				}
			}
			if step % 10 == 0 || steps < 300 {
				w := make([dynamic]byte, context.temp_allocator)
				plain_text_read(&plain, &w)
				testing.expect_value(t, text_string(&ours), string(w[:]))
				testing.expect_value(t, text_len(&ours), plain_text_len(&plain))
			}
			// What holds it together.
			if step % 50 == 0 {
				visible := 0
				for b, at in ours.blocks {
					sum := 0
					for no in b.items[:b.count] {
						testing.expect(t, ours.spans[no].block == b && ours.spans[no].marks & {.New, .Killed} == {})
						sum += span_visible(&ours.spans[no])
					}
					testing.expect(t, b.at == at && b.visible == sum && b.count > 0)
					visible += sum
				}
				testing.expect_value(t, ours.visible, visible)
			}
			if testing.failed(t) {
				return
			}
		}
		text_destroy(&ours)
		plain_text_destroy(&plain)
		for &s in scribes {
			text_destroy(&s.text)
		}
		free_all(context.temp_allocator)
	}
}

// And says the same itself, when it is written here.
@(test)
text_is_written_as_it_should_be :: proc(t: ^testing.T) {
	for seed in 0 ..< 60 {
		state := seeded(u64(seed) + 900)
		context.random_generator = rand.default_random_generator(&state)
		ours: Text
		plain: Plain_Text
		for _ in 0 ..< 400 {
			n := text_len(&ours)
			fresh := rand.uint64() | 1
			switch rand.int_max(8) {
			case 0, 1:
				if n > 0 {
					pos := rand.int_max(n)
					count := 1 + rand.int_max(10)
					text_delete(&ours, pos, count, fresh)
					plain_text_delete(&plain, pos, count, fresh)
				}
			case 2:
				stamp := Stamp{u64(rand.int63()), 5}
				a, _ := text_close(&ours, stamp)
				b, _ := plain_text_close(&plain, stamp)
				testing.expect_value(t, string(a), string(b))
			case:
				pos := rand.int_max(n + 1)
				part := rand.choice([]string{"a", "bcd", "e f"})
				text_insert(&ours, pos, transmute([]byte)part, fresh)
				plain_text_insert(&plain, pos, transmute([]byte)part, fresh)
			}
			w := make([dynamic]byte, context.temp_allocator)
			plain_text_read(&plain, &w)
			testing.expect_value(t, text_string(&ours), string(w[:]))
			testing.expect_value(t, string(ours.ops[:]), string(plain.ops[:]))
			if testing.failed(t) {
				return
			}
		}
		text_destroy(&ours)
		plain_text_destroy(&plain)
		free_all(context.temp_allocator)
	}
}

// A piece too short to name itself is no piece of the text, and is bundled away with nothing in its place.
@(test)
short_pieces_are_bundled_away :: proc(t: ^testing.T) {
	row := Id{1 << 32, 1}
	x: Text
	defer text_destroy(&x)
	text_insert(&x, 0, transmute([]byte)string("hello"), 7)
	body, _ := text_close(&x, {2 << 16, 2})
	cells := []Cell{{row, DATA, .Piece, {1 << 16, 1}, nil}, {row, DATA, .Piece, {2 << 16, 2}, body}, {row, DATA, .Piece, {3 << 16, 3}, {1, 2, 3}}}
	b := text_bundle(cells)
	defer delete(b.body)
	testing.expect_value(t, get_u32(b.body), 3)
	y: Text
	defer text_destroy(&y)
	b.stamp = {4 << 16, 4}
	testing.expect(t, cell_valid(&b) && text_apply(&y, &b) == .Changed)
	testing.expect_value(t, text_string(&y), "hello")
	// And what a bundle holds that cannot be read is passed over, however short it falls.
	short := make([dynamic]byte, context.temp_allocator)
	append(&short, ..b.body)
	append(&short, 1)
	broken := Cell{row, DATA, .Bundle, {5 << 16, 5}, short[:]}
	again := text_bundle({broken})
	defer delete(again.body)
	z: Text
	defer text_destroy(&z)
	again.stamp = {6 << 16, 6}
	testing.expect(t, cell_valid(&again) && text_apply(&z, &again) == .Changed)
	testing.expect_value(t, text_string(&z), "hello")
}

// What is no operation at all, or one that refers to what its own piece has yet to make, waits for nothing: it is never
// to be, and is neither kept nor gone over again at every edit. What refers to another piece waits for it.
@(test)
nonsense_does_not_wait :: proc(t: ^testing.T) {
	x: Text
	defer text_destroy(&x)
	insert :: proc(w: ^[dynamic]byte, left: []byte, s: string) {
		append(w, 1)
		append(w, ..left)
		append(w, 0)
		write_bytes(w, transmute([]byte)s)
	}
	piece :: proc(x: ^Text, id: u64, ops: []byte) -> Text_Result {
		body := make([dynamic]byte, context.temp_allocator)
		write_u64(&body, id)
		append(&body, ..ops)
		c := Cell{{1 << 32, 1}, DATA, .Piece, {id << 16, id}, body[:]}
		return text_apply(x, &c)
	}
	ops := make([dynamic]byte, context.temp_allocator)
	insert(&ops, {0}, "hello")
	testing.expect_value(t, piece(&x, 1, ops[:]), Text_Result.Changed)
	for i in 0 ..< 50 {
		clear(&ops)
		insert(&ops, {0}, "a")
		switch i % 4 {
		case 0:
			append(&ops, 9, 9, 9) // no such operation
		case 1:
			append(&ops, 1, 0, 0, 0xff) // a length that does not end
		case 2:
			insert(&ops, {1, 5}, "b") // after what this piece never made
		case 3:
			append(&ops, 3, 1, 9, 1) // and the deletion of it
		}
		testing.expect_value(t, piece(&x, u64(i) + 2, ops[:]), Text_Result.Changed)
	}
	testing.expect_value(t, len(x.waiting), 0)
	// But one that refers to a piece not yet here waits for it, and goes on once it is.
	clear(&ops)
	ref := make([dynamic]byte, context.temp_allocator)
	append(&ref, 2)
	write_u64(&ref, 99)
	append(&ref, 0)
	insert(&ops, ref[:], "!")
	testing.expect_value(t, piece(&x, 98, ops[:]), Text_Result.Waiting)
	testing.expect_value(t, len(x.waiting), 1)
	clear(&ops)
	insert(&ops, {0}, "?")
	testing.expect_value(t, piece(&x, 99, ops[:]), Text_Result.Changed)
	testing.expect_value(t, len(x.waiting), 0)
	testing.expect_value(t, strings.count(text_string(&x), "!"), 1)
}
