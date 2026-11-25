#+build !js
package zsp

import "core:math/rand"
import "core:slice"
import "core:testing"

// The text as SPEC.md defines it: every element hangs in a tree by what its own operation says, and the text is the
// tree read in order. Slowly, and with no history of its own: any order of applying it does.

@(private)
Tree_Node :: struct {
	id:     u64,
	number: u32,
	parent: int, // 0 is the start of the document
	right:  bool, // which side of it
	value:  u8,
	dead:   bool,
	kids:   [dynamic]int,
}

@(private)
Tree_Piece :: struct {
	id:    u64,
	ops:   []byte,
	at:    int,
	count: u32,
	last:  int, // the right neighbour of the last insertion, as it was written
}

@(private)
TREE_END :: -1

// What a slot of these cells says: pieces and bundles, of which the earlier of two claiming an id keeps it.
@(private)
tree_text :: proc(cells: []Cell) -> string {
	Inner :: struct {
		stamp: Stamp,
		id:    u64,
		ops:   []byte,
	}
	inner := make([dynamic]Inner, context.temp_allocator)
	for c in cells {
		#partial switch c.kind {
		case .Piece:
			if len(c.body) >= 8 {
				append(&inner, Inner{c.stamp, get_u64(c.body), c.body[8:]})
			}
		case .Bundle:
			r := Reader{buf = c.body, pos = clear_size(.Bundle, c.body)}
			for r.pos < len(r.buf) {
				stamp := read_stamp(&r)
				id := read_u64(&r)
				append(&inner, Inner{stamp, id, read_bytes(&r)})
			}
		}
	}
	slice.sort_by(inner[:], proc(a, b: Inner) -> bool {return stamp_less(a.stamp, b.stamp)})
	pieces := make([dynamic]Tree_Piece, context.temp_allocator)
	named := make(map[u64]bool, context.temp_allocator)
	last: Stamp
	for x in inner {
		if x.stamp == last {
			continue
		}
		last = x.stamp
		id := x.id
		if id in named {
			id = x.stamp.salt
		}
		if id == 0 || id in named {
			continue
		}
		named[id] = true
		append(&pieces, Tree_Piece{id = id, ops = x.ops})
	}

	nodes := make([dynamic]Tree_Node, context.temp_allocator)
	append(&nodes, Tree_Node{})
	by := make(map[[2]u64]int, context.temp_allocator)
	find :: proc(by: ^map[[2]u64]int, ref: Ref, n: u32) -> (at: int, ok: bool) {
		for i in 0 ..< u64(n) {
			_ = by[{ref.piece, u64(ref.offset) + i}] or_return
		}
		return by[{ref.piece, u64(ref.offset)}]
	}
	below :: proc(nodes: []Tree_Node, a, b: int) -> bool {
		if b == TREE_END || a == b {
			return false
		}
		for x := b; x != 0; {
			x = nodes[x].parent
			if x == a {
				return true
			}
		}
		return false
	}
	for progress := true; progress; {
		progress = false
		for &p in pieces {
			for p.at < len(p.ops) {
				r := Reader{buf = p.ops, pos = p.at}
				a, b := 0, TREE_END
				ok := true
				bytes: []byte
				switch Op(read_u8(&r)) {
				case .Insert:
					l, rr := read_ref(&r, p.id), read_ref(&r, p.id)
					bytes = read_bytes(&r)
					if l.piece != 0 {
						a, ok = find(&by, l, 1)
					}
					if rr.piece != 0 && ok {
						b, ok = find(&by, rr, 1)
					}
				case .Extend:
					bytes = read_bytes(&r)
					ok = p.count > 0
					if ok {
						a, b = by[{p.id, u64(p.count - 1)}], p.last
					}
				case .Delete:
					first := read_ref(&r, p.id)
					n := read_varint(&r)
					at: int
					if at, ok = find(&by, first, u32(n)); ok && !r.bad {
						for i in 0 ..< u32(n) {
							nodes[by[{first.piece, u64(first.offset + i)}]].dead = true
						}
						_ = at
					}
				case:
					r.bad = true
				}
				if r.bad {
					p.at = len(p.ops)
					break
				}
				if !ok {
					break
				}
				if len(bytes) > 0 {
					p.last = b
					// Beneath the right one, if that is beneath the left; otherwise beneath the left.
					parent, right := a, true
					if below(nodes[:], a, b) {
						parent, right = b, false
					}
					for v in bytes {
						append(&nodes, Tree_Node{id = p.id, number = p.count, parent = parent, right = right, value = v})
						at := len(nodes) - 1
						append(&nodes[parent].kids, at)
						by[{p.id, u64(p.count)}] = at
						p.count += 1
						parent, right = at, true
					}
				}
				p.at = r.pos
				progress = true
			}
		}
	}
	out := make([dynamic]byte, context.temp_allocator)
	read :: proc(nodes: []Tree_Node, at: int, out: ^[dynamic]byte) {
		n := &nodes[at]
		kids := slice.clone(n.kids[:], context.temp_allocator)
		Key :: struct {
			id: u64,
			no: u32,
			at: int,
		}
		keys := make([]Key, len(kids), context.temp_allocator)
		for k, i in kids {
			keys[i] = {nodes[k].id, nodes[k].number, k}
		}
		slice.sort_by(keys, proc(a, b: Key) -> bool {return a.id < b.id || (a.id == b.id && a.no < b.no)})
		for k in keys {
			if !nodes[k.at].right {
				read(nodes, k.at, out)
			}
		}
		if at != 0 && !n.dead {
			append(out, n.value)
		}
		for k in keys {
			if nodes[k.at].right {
				read(nodes, k.at, out)
			}
		}
	}
	read(nodes[:], 0, &out)
	for &n in nodes {
		delete(n.kids)
	}
	return string(out[:])
}

// Whoever writes, however they say where, and in whatever order it comes: one text, which is the tree read in order.
@(test)
text_is_what_was_written :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_TEXT_SEEDS, 40)
	for seed in 0 ..< SEEDS * 4 {
		state := seeded(u64(seed) + 4000)
		context.random_generator = rand.default_random_generator(&state)
		scribes: [3]Scribe
		all := make([dynamic]Cell, context.temp_allocator)
		clock: u64
		hostile := seed % 2 == 1
		for _ in 0 ..< 120 {
			s := &scribes[rand.int_max(len(scribes))]
			switch r := rand.int_max(10); {
			case r < 5:
				scribble(s)
			case r < 7:
				clock += 1
				stamp := Stamp{clock, rand.uint64()}
				if body, ok := text_close(&s.text, stamp); ok {
					append(&all, Cell{{1, 1}, DATA, .Piece, stamp, body})
				}
				if hostile && len(all) > 0 && rand.int_max(3) == 0 {
					// Someone who minds nothing: neighbours of any pieces, in any order, the same one twice.
					w := make([dynamic]byte, context.temp_allocator)
					write_u64(&w, rand.uint64() | 1)
					for _ in 0 ..< 1 + rand.int_max(3) {
						append(&w, byte(Op.Insert))
						for _ in 0 ..< 2 {
							near := rand.choice(all[:])
							if rand.int_max(5) > 0 && near.kind == .Piece {
								append(&w, 2)
								append(&w, ..near.body[:8])
								write_varint(&w, u64(rand.int_max(3)))
							} else {
								append(&w, 0)
							}
						}
						write_bytes(&w, {'A' + byte(rand.int_max(26)), 'A' + byte(rand.int_max(26))})
						if rand.int_max(3) == 0 {
							append(&w, byte(Op.Extend))
							write_bytes(&w, {'+'})
						}
					}
					clock += 1
					append(&all, Cell{{1, 1}, DATA, .Piece, {clock, rand.uint64()}, w[:]})
				}
			case:
				for _ in 0 ..< 3 {
					if len(all) > 0 {
						c := rand.choice(all[:])
						text_apply(&s.text, &c)
					}
				}
			}
		}
		if len(all) > 4 && rand.int_max(2) == 0 {
			b := text_bundle(all[:len(all) / 2], context.temp_allocator)
			clock += 1
			b.stamp = {clock, rand.uint64()}
			append(&all, b)
		}
		want := tree_text(all[:])
		for round in 0 ..< 6 {
			cells := slice.clone(all[:], context.temp_allocator)
			if round > 0 {
				rand.shuffle(cells)
			}
			ours: Text
			for &c in cells {
				if text_apply(&ours, &c) == .Rebuild {
					text_destroy(&ours)
					sorted := slice.clone(all[:], context.temp_allocator)
					slice.sort_by(sorted, proc(a, b: Cell) -> bool {return stamp_less(a.stamp, b.stamp)})
					for &d in sorted {
						text_apply(&ours, &d)
					}
					break
				}
			}
			got := text_string(&ours)
			testing.expectf(t, got == want, "seed %d round %d: %q, not %q", seed, round, got, want)
			text_destroy(&ours)
			if testing.failed(t) {
				return
			}
		}
		for &s in scribes {
			text_destroy(&s.text)
		}
		free_all(context.temp_allocator)
	}
}

// However deep or wide someone makes the tree, what hangs above what is found in a few steps, and rightly; and a
// place among siblings, however many.
@(test)
deep_texts_are_quick :: proc(t: ^testing.T) {
	state := seeded(4100)
	context.random_generator = rand.default_random_generator(&state)
	x: Text
	defer text_destroy(&x)
	N :: 60000
	ids := make([dynamic]u64, context.temp_allocator)
	fan := rand.uint64() | 1
	took: [2]int
	cells := make([dynamic]Cell, context.temp_allocator)
	for i in 0 ..< N {
		w := make([dynamic]byte, context.temp_allocator)
		id := rand.uint64() | 1
		if i == 0 {
			id = fan
		}
		write_u64(&w, id)
		append(&w, byte(Op.Insert))
		ref :: proc(w: ^[dynamic]byte, id: u64) {
			append(w, 2)
			write_u64(w, id)
			write_varint(w, 0)
		}
		switch {
		case i == 0:
			append(&w, 0, 0)
		case i % 3 == 0:
			// Each before the one before it, by a piece of its own: as deep as there are of them.
			append(&w, 0)
			ref(&w, ids[len(ids) - 3] if i > 3 else fan)
		case i % 3 == 1:
			// After one and the same, as if all at once.
			ref(&w, fan)
			append(&w, 0)
		case:
			ref(&w, rand.choice(ids[:]))
			ref(&w, rand.choice(ids[:]))
		}
		write_bytes(&w, {'a' + byte(i % 26)})
		c := Cell{{1, 1}, DATA, .Piece, {u64(i + 1), 1}, w[:]}
		start := text_steps
		testing.expect(t, text_apply(&x, &c) == .Changed)
		if i < 3000 {
			took[0] += text_steps - start
		} else if i >= N - 3000 {
			took[1] += text_steps - start
		}
		append(&ids, id)
		if i < 3000 {
			append(&cells, c)
		}
	}
	most: u32
	for &r in x.runs {
		most = max(most, r.depth)
	}
	testing.expectf(t, most > N / 4, "only %d deep", most)
	// Twenty times as much, and as many steps but for its depth and length in powers of two.
	testing.expectf(t, took[1] < 3 * took[0], "the last took %d steps, the first %d", took[1], took[0])
	// Held against walking up a step at a time.
	for _ in 0 ..< 2000 {
		s := Spot{x.numbers[rand.choice(ids[:])], 0}
		d := text_depth(&x, s)
		want := u32(rand.int_max(int(d) + 1))
		at := s
		for text_depth(&x, at) > want {
			at = x.runs[run_find(&x, at)].parent
		}
		testing.expect_value(t, text_ancestor(&x, s, want), at)
	}
	// And the first of it held against the tree itself.
	some: Text
	defer text_destroy(&some)
	for &c in cells {
		_ = text_apply(&some, &c)
	}
	testing.expect_value(t, text_string(&some), tree_text(cells[:]))
}
