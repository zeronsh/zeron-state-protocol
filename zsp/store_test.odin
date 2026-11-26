#+build !js
package zsp

import "base:runtime"
import "core:hash/xxhash"
import "core:math/rand"
import "core:slice"
import "core:testing"

@(private)
random_id :: proc(space: int) -> Id {
	return {1 << 32, u64(rand.int_max(space)) + 1}
}

@(private)
seeded :: proc(seed: u64) -> rand.Default_Random_State {
	return rand.create(seed)
}

@(test)
tree_matches_model :: proc(t: ^testing.T) {
	state := seeded(1)
	context.random_generator = rand.default_random_generator(&state)
	m: Memory_Disk
	defer memory_disk_destroy(&m)
	s: Store
	testing.expect(t, store_open(&s, memory_disk(&m)))
	defer store_close(&s)

	model: map[Key]Print
	defer delete(model)
	tr: Tree
	for round in 0 ..< 40_000 {
		k := Key{u64(rand.int_max(40)), 0, u64(rand.int_max(200)), 0, 1}
		if rand.float32() < (0.6 if round < 25_000 else 0.3) {
			v := Print{rand.uint64(), rand.uint64()}
			tree_put(&s, &tr, k, v)
			model[k] = v
		} else {
			testing.expect_value(t, tree_delete(&s, &tr, k), k in model)
			delete_key(&model, k)
		}
		if round % 1000 != 0 {
			continue
		}
		keys, _ := slice.map_keys(model, context.temp_allocator)
		slice.sort_by(keys, proc(a, b: Key) -> bool {return key_less(a, b)})
		scan := tree_scan(&s, tr, KEY_MIN, KEY_MAX)
		for want, i in keys {
			got, ok := tree_next(&scan)
			testing.expect(t, ok && got.key == want && got.val == model[want])
			if i % 97 == 0 {
				at, found := tree_select(&s, tr, i)
				testing.expect(t, found && at == want)
			}
		}
		_, more := tree_next(&scan)
		testing.expect(t, !more)

		lo, hi := Key{0 = u64(rand.int_max(40))}, Key{0 = u64(rand.int_max(40))}
		want: Sum
		for k2 in keys {
			if !key_less(k2, lo) && key_less(k2, hi) {
				want.count += 1
				want.print += model[k2]
			}
		}
		testing.expect_value(t, tree_range(&s, tr, lo, hi), want)
		free_all(context.temp_allocator)
	}
}

@(private)
random_cell :: proc(rows, times: int) -> (c: Cell) {
	body := make([]byte, 40, context.temp_allocator)
	for &b in body {
		b = byte(rand.uint32())
	}
	c = {row = random_id(rows), stamp = {u64(rand.int_max(times)) + 1, rand.uint64() % 4}, body = body}
	switch r := rand.int_max(100); {
	case r < 1:
		c.kind, c.slot, c.body = .Grave, GRAVE, body[:16]
	case r < 30:
		c.kind, c.slot = .Place, PLACE + Slot(rand.int_max(3))
		put_u64(body, 1 << 32 | u64(rand.int_max(5)))
		put_u64(body[8:], 1)
		put_u64(body[16:], u64(rand.int_max(10)))
	case r < 60:
		c.kind, c.slot = .Value, DATA + Slot(rand.int_max(3))
	case:
		c.kind, c.slot = .Piece, DATA + Slot(rand.int_max(3))
	}
	return
}

@(private)
Census :: struct {
	shelf, cells: Sum,
	bodies:       u64,
}

@(private)
census :: proc(s: ^Store, shelved := false, reader: ^Sim_Node = nil) -> (c: Census) {
	c.shelf = store_range(s, KEY_MIN, KEY_MAX)
	scan := tree_scan(s, s.cells, KEY_MIN, KEY_MAX)
	for leaf in tree_next(&scan) {
		cell, at := cell_unkey(leaf)
		if shelved && row_places(s, cell.row).count == 0 {
			continue // it is nowhere, and may differ there
		}
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		cell.body = log_bytes(s, at.off, at.len)
		c.cells.print += cell_print(&cell)
		if reader != nil {
			_ = cell_open(&reader.keys, &reader.node.roster, &cell) // what it says, however it was sealed
		}
		c.bodies += xxhash.XXH64(cell.body) * cell.stamp.salt
		c.cells.count += 1
	}
	return
}

// Merge is commutative, associative and idempotent: any order, any batching, any repetition.
@(test)
merge_is_order_free :: proc(t: ^testing.T) {
	state := seeded(2)
	context.random_generator = rand.default_random_generator(&state)
	for _ in 0 ..< 60 {
		cells := make([]Cell, 300)
		defer delete(cells)
		for &c in cells {
			c = random_cell(6, 50)
			// Equal identity implies equal content, as stamps guarantee in real use.
			c.stamp.salt = rand.uint64()
		}
		// Bundle some pieces, sometimes twice over.
		pieces: [dynamic]Stamp
		defer delete(pieces)
		for &c, i in cells {
			if i % 10 != 0 || c.kind != .Piece {
				continue
			}
			clear(&pieces)
			for other, j in cells {
				if j % 10 != 0 && other.kind == .Piece && other.row == c.row && other.slot == c.slot && stamp_less(other.stamp, c.stamp) && rand.int_max(2) == 0 {
					append(&pieces, other.stamp)
				}
			}
			if len(pieces) > 0 {
				slice.sort_by(pieces[:], proc(a, b: Stamp) -> bool {return stamp_less(a, b)})
				c.kind = .Bundle
				c.body = make([]byte, 4 + 16 * len(pieces), context.temp_allocator)
				put_u32(c.body, u32(len(pieces)))
				for p, k in pieces {
					put_u64(c.body[4 + k * 16:], p.time)
					put_u64(c.body[12 + k * 16:], p.salt)
				}
			}
		}
		want: Census
		for round in 0 ..< 3 {
			rand.shuffle(cells)
			m: Memory_Disk
			defer memory_disk_destroy(&m)
			s: Store
			testing.expect(t, store_open(&s, memory_disk(&m)))
			defer store_close(&s)
			for i := 0; i < len(cells); {
				n := min(1 + rand.int_max(20), len(cells) - i)
				store_commit(&s, cells[i:][:n])
				i += n
			}
			store_commit(&s, cells)
			testing.expect_value(t, store_commit(&s, cells), 0)
			got := census(&s)
			if round == 0 {
				want = got
			}
			testing.expect_value(t, got, want)
		}
		free_all(context.temp_allocator)
	}
}

// Every shelf entry's fingerprint equals its row's cells, and rows sit exactly where they say.
@(private)
check_shelf :: proc(t: ^testing.T, s: ^Store) {
	expect := 0
	scan := tree_scan(s, s.cells, KEY_MIN, KEY_MAX)
	last: Id
	for leaf in tree_next(&scan) {
		row := Id{leaf.key[0], leaf.key[1]}
		if row == last {
			continue
		}
		last = row
		places := row_places(s, row)
		expect += places.count
		for k in places.keys[:places.count] {
			v, ok := tree_get(s, s.shelf, k)
			testing.expect(t, ok && v == row_print(s, row))
		}
	}
	testing.expect_value(t, store_range(s, KEY_MIN, KEY_MAX).count, expect)
}

@(test)
store_survives_crashes :: proc(t: ^testing.T) {
	state := seeded(3)
	context.random_generator = rand.default_random_generator(&state)
	m: Memory_Disk
	defer memory_disk_destroy(&m)
	s: Store
	testing.expect(t, store_open(&s, memory_disk(&m)))
	for round in 0 ..< 400 {
		cells: [8]Cell
		for &c in cells {
			c = random_cell(400, 1_000_000)
		}
		store_commit(&s, cells[:])
		switch r := rand.int_max(30); {
		case r < 3:
			testing.expect(t, store_checkpoint(&s))
		case r < 6:
			store_flush(&s)
			want := census(&s)
			store_close(&s)
			testing.expect(t, store_open(&s, memory_disk(&m)))
			testing.expect_value(t, census(&s), want)
		}
		if round % 50 == 0 {
			check_shelf(t, &s)
		}
		free_all(context.temp_allocator)
	}
	store_close(&s)
}

@(test)
torn_tail_is_discarded :: proc(t: ^testing.T) {
	state := seeded(4)
	context.random_generator = rand.default_random_generator(&state)
	m: Memory_Disk
	defer memory_disk_destroy(&m)
	s: Store
	testing.expect(t, store_open(&s, memory_disk(&m)))
	one := random_cell(400, 1000)
	store_commit(&s, {one})
	store_flush(&s)
	want := census(&s)
	two := random_cell(400, 1000)
	two.row = {1 << 32, 999}
	store_commit(&s, {two})
	store_flush(&s)
	store_close(&s)
	seg := &m.log[0]
	resize(seg, len(seg) - 3)
	testing.expect(t, store_open(&s, memory_disk(&m)))
	testing.expect_value(t, census(&s), want)
	// And the store goes on writing where the torn record was.
	store_commit(&s, {two})
	store_flush(&s)
	want = census(&s)
	store_close(&s)
	testing.expect(t, store_open(&s, memory_disk(&m)))
	testing.expect_value(t, census(&s), want)
	store_close(&s)
}

@(test)
waste_is_reclaimed :: proc(t: ^testing.T) {
	state := seeded(5)
	context.random_generator = rand.default_random_generator(&state)
	m: Memory_Disk
	defer memory_disk_destroy(&m)
	s: Store
	testing.expect(t, store_open(&s, memory_disk(&m)))
	body: [SEGMENT / 256]byte
	for i in 0 ..< 3000 { // a dozen segments of overwrites of 32 rows
		body[0] = byte(i)
		c := Cell{{1 << 32 | u64(i % 32), 1}, DATA, .Value, {u64(i) + 1, 0}, body[:]}
		store_commit(&s, {c})
		store_flush(&s)
		if store_wants_checkpoint(&s) {
			store_checkpoint(&s)
		}
	}
	store_checkpoint(&s)
	testing.expect(t, len(m.log) <= 4)
	want := census(&s)
	testing.expect_value(t, want.cells.count, 32)
	store_close(&s)
	testing.expect(t, store_open(&s, memory_disk(&m)))
	testing.expect_value(t, census(&s), want)
	store_close(&s)
}

// A store written in an earlier format, whose pages cannot be read as these are, is made again from its log.
@(test)
older_store_is_made_again :: proc(t: ^testing.T) {
	state := seeded(6)
	context.random_generator = rand.default_random_generator(&state)
	m: Memory_Disk
	defer memory_disk_destroy(&m)
	s: Store
	testing.expect(t, store_open(&s, memory_disk(&m)))
	for _ in 0 ..< 300 {
		cells: [8]Cell
		for &c in cells {
			c = random_cell(400, 1_000_000)
		}
		store_commit(&s, cells[:])
		if rand.int_max(20) == 0 {
			testing.expect(t, store_checkpoint(&s))
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, store_checkpoint(&s))
	want := census(&s)
	store_close(&s)
	// As the last format left it: other magic, and pages laid out otherwise.
	for no, pg in m.pages {
		bytes := ([^]byte)(pg)[:size_of(Page)]
		if no < HEADER_PAGES {
			bytes[7] = '2'
			h := (^Header)(pg)
			h.sum = header_sum(h)
		} else {
			for &b in bytes {
				b = byte(rand.uint32())
			}
		}
	}
	testing.expect(t, store_open(&s, memory_disk(&m)))
	testing.expect_value(t, census(&s), want)
	check_shelf(t, &s)
	testing.expect(t, store_checkpoint(&s))
	store_close(&s)
	testing.expect(t, store_open(&s, memory_disk(&m)))
	testing.expect_value(t, census(&s), want)
	store_close(&s)
}
