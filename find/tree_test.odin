#+build !js
package find

import "base:runtime"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "../zsp"

@(test)
tree_matches_model :: proc(t: ^testing.T) {
	for width, round in ([]Width{.None, .Byte, .Varint, .None}) {
		state := rand.create(u64(round) + 1)
		context.random_generator = rand.default_random_generator(&state)
		m: Memory_Disk
		defer memory_disk_destroy(&m)
		p: Pager
		key: zsp.Key32
		pager_open(&p, memory_disk(&m), key)
		defer pager_close(&p)
		tr := Tree{width = width, sums = round == 3}
		model := make(map[Entry]u64)
		defer delete(model)
		for batch in 0 ..< 200 {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			edits := make([dynamic]Edit, context.temp_allocator)
			seen := make(map[Entry]bool, context.temp_allocator)
			many := 1 + rand.int_max(1 if batch % 3 == 0 else 1500)
			for _ in 0 ..< many {
				e: Entry
				switch round {
				case 0: // postings: few keys, many subs
					e = {key = {u64(rand.int_max(5)) << 56, 0}, sub = rand.uint32() % 40000}
				case 1: // words
					e = {key = {u64(rand.int_max(300)) * 0x0101_0203_0000_0000, u64(rand.int_max(3)) << 40}, sub = rand.uint32() % 3000}
				case 2: // ids
					e = {key = {rand.uint64() % 5000, rand.uint64() % 3}, sub = u32(rand.int_max(2)) * max(u32)}
				case 3: // numbers
					e = {key = number_key(f64(rand.int_max(2000) - 1000)), sub = rand.uint32() % 50}
				}
				if e in seen {
					continue
				}
				seen[e] = true
				gone := rand.int_max(3) == 0 || (batch > 150 && rand.int_max(10) > 0)
				if gone && rand.int_max(2) == 0 && len(model) > 0 {
					// Usually something that is there.
					for k in model {
						if k not_in seen {
							seen[e], seen[k] = false, true
							e = k
						}
						break
					}
				}
				v := rand.uint64() % (256 if width == .Byte else 100000) if width != .None else 0
				append(&edits, Edit{entry = {e.key, e.sub, v}, gone = gone})
			}
			slice.sort_by(edits[:], proc(a, b: Edit) -> bool {return entry_less(a.key, a.sub, b.key, b.sub)})
			n := 0
			for e, i in edits {
				if i > 0 && e.key == edits[n - 1].key && e.sub == edits[n - 1].sub {
					continue
				}
				edits[n] = e
				n += 1
			}
			for e in edits[:n] {
				id := Entry{e.key, e.sub, 0}
				if e.gone {
					delete_key(&model, id)
				} else {
					model[id] = e.val
				}
			}
			tree_apply(&p, &tr, edits[:n])
			if rand.int_max(4) == 0 {
				testing.expect(t, pager_write(&p))
				append(&p.free, ..p.pending[:])
				clear(&p.pending)
				set_destroy(&p.fresh)
			}
			if batch % 10 != 0 && batch < 195 {
				continue
			}
			all := make([dynamic]Entry, context.temp_allocator)
			for e, v in model {
				append(&all, Entry{e.key, e.sub, v})
			}
			slice.sort_by(all[:], proc(a, b: Entry) -> bool {return entry_less(a.key, a.sub, b.key, b.sub)})
			testing.expect_value(t, tree_total(&p, tr).count, len(all))
			// Forwards, backwards, and in between.
			c := cursor_make(&p, tr)
			cursor_seek(&c, KEY_MIN)
			for want in all {
				got, ok := cursor_next(&c)
				testing.expect(t, ok && got == want)
			}
			_, more := cursor_next(&c)
			testing.expect(t, !more)
			#reverse for want in all {
				got, ok := cursor_prev(&c)
				testing.expect(t, ok && got == want)
			}
			_, more = cursor_prev(&c)
			testing.expect(t, !more)
			Seen :: struct {
				all: []Entry,
				at:  int,
				ok:  bool,
			}
			for _ in 0 ..< 20 {
				probe := Entry{key = {rand.uint64() >> uint(rand.int_max(64)), 0}, sub = rand.uint32() % 100}
				if len(all) > 0 && rand.int_max(2) == 0 {
					probe = rand.choice(all[:])
				}
				at := 0
				sum: f64
				for at < len(all) && entry_less(all[at].key, all[at].sub, probe.key, probe.sub) {
					sum += key_number(all[at].key) if tr.sums else 0
					at += 1
				}
				b := tree_before(&p, tr, probe.key, probe.sub)
				testing.expect(t, b.count == at && abs(b.sum - sum) < 1e-6)
				v, ok := tree_get(&p, tr, probe.key, probe.sub)
				here := at < len(all) && all[at].key == probe.key && all[at].sub == probe.sub
				testing.expect(t, ok == here && (!ok || v == all[at].val))
				cursor_seek(&c, probe.key, probe.sub)
				next, has := cursor_next(&c)
				testing.expect(t, has == (at < len(all)) && (!has || next == all[at]))
				cursor_seek(&c, probe.key, probe.sub)
				prev, had := cursor_prev(&c)
				testing.expect(t, had == (at > 0) && (!had || prev == all[at - 1]))
				first := 0
				for first < len(all) && key_less(all[first].key, probe.key) {
					first += 1
				}
				s := Seen{all[:], first, true}
				tree_each(&p, tr, probe.key, KEY_MAX, &s, proc(data: rawptr, e: ^Entry) {
					s := (^Seen)(data)
					s.ok &&= s.at < len(s.all) && s.all[s.at] == e^
					s.at += 1
				})
				testing.expect(t, s.ok && s.at == len(all))
			}
			cursor_destroy(&c)
		}
		testing.expect(t, !p.failed)
		tree_clear(&p, &tr)
		testing.expect_value(t, len(p.free) + len(p.pending) + HEADERS, int(p.next))
	}
}

@(test)
numbers_sort_as_numbers :: proc(t: ^testing.T) {
	inf := transmute(f64)u64(0x7ff0_0000_0000_0000)
	in_order := []f64{-inf, -1e300, -2, -1.5, -1e-300, 0, 1e-300, 1, 1.5, 2, 1e300, inf}
	for a, i in in_order {
		testing.expect_value(t, key_number(number_key(a)), a)
		for b in in_order[i + 1:] {
			testing.expect(t, key_less(number_key(a), number_key(b)))
		}
	}
	testing.expect(t, number_key(-0.0) == number_key(0))
}
