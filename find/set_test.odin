package find

import "core:math/rand"
import "core:testing"

@(test)
sets_match_maps :: proc(t: ^testing.T) {
	state := rand.create(5)
	context.random_generator = rand.default_random_generator(&state)
	for round in 0 ..< 60 {
		s: [2]Set
		m: [2]map[u32]bool
		defer for i in 0 ..< 2 {
			set_destroy(&s[i])
			delete(m[i])
		}
		for i in 0 ..< 2 {
			span := u32(200_000) >> uint(rand.int_max(8))
			many := rand.int_max(40_000 if round % 2 == 0 else 3000)
			for _ in 0 ..< many {
				v := rand.uint32() % span
				if rand.int_max(5) == 0 {
					testing.expect(t, set_remove(&s[i], v) == (v in m[i]))
					delete_key(&m[i], v)
				} else {
					testing.expect(t, set_add(&s[i], v) == (v not_in m[i]))
					m[i][v] = true
				}
			}
			same(t, &s[i], m[i])
		}
		want := make(map[u32]bool)
		defer delete(want)
		got := set_clone(&s[0])
		defer set_destroy(&got)
		switch round % 3 {
		case 0:
			set_and(&got, &s[1])
			for v in m[0] {
				if v in m[1] {
					want[v] = true
				}
			}
		case 1:
			set_or(&got, &s[1])
			for x in m {
				for v in x {
					want[v] = true
				}
			}
		case 2:
			set_and_not(&got, &s[1])
			for v in m[0] {
				if v not_in m[1] {
					want[v] = true
				}
			}
		}
		same(t, &got, want)
	}

	same :: proc(t: ^testing.T, s: ^Set, m: map[u32]bool) {
		testing.expect_value(t, s.count, len(m))
		it := set_iterator(s)
		n, last := 0, i64(-1)
		for v in set_next(&it) {
			testing.expect(t, v in m && i64(v) > last && set_has(s, v))
			last = i64(v)
			n += 1
		}
		testing.expect_value(t, n, len(m))
	}
}

@(test)
words_are_found :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"Hello, World!", "hello world"},
		{"don't  STOP-now", "dont stop now"},
		{"Crème brûlée à la Ångström", "creme brulee a la angstrom"},
		{"straße Ærø œuvre", "straße æro œuvre"},
		{"naïve café", "naive cafe"},
		{"東京都に行く", "東京 京都 都に に行 行く"},
		{"a東b", "a 東 b"},
		{"foo_bar.baz42", "foo bar baz42"},
		{"ПРИВЕТ мир", "привет мир"},
		{"ＡＢＣ１２", "abc12"},
		{"", ""},
		{"!!! ... 🎉", ""},
	}
	for c in cases {
		w := words(transmute([]byte)c[0])
		got := make([dynamic]byte, context.temp_allocator)
		for word in words_next(&w) {
			if len(got) > 0 {
				append(&got, ' ')
			}
			word := word
			append(&got, ..word.bytes[:word.len])
		}
		testing.expect_value(t, string(got[:]), c[1])
	}
	f := make([dynamic]byte, context.temp_allocator)
	fold(transmute([]byte)string("ÉCLAIR \xff ß"), &f)
	testing.expect_value(t, string(f[:]), "eclair \xff ß")
}
