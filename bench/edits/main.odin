// What one edit in the middle of a document costs the index, and where that goes: ./x bench edits
package main

import "core:crypto"
import "core:crypto/ed25519"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:time"
import "../../find"
import "../../zsp"

Counted :: struct {
	pages:  find.Memory_Disk,
	writes: int,
}

counted :: proc(c: ^Counted) -> find.Disk {
	d := find.memory_disk(&c.pages)
	d.write = proc(data: rawptr, no: u32, bytes: []byte) -> bool {
		c := (^Counted)(data)
		c.writes += 1
		pg, ok := c.pages.pages[no]
		if !ok {
			pg = new([find.PAGE_SIZE]byte)
			c.pages.pages[no] = pg
		}
		copy(pg[:], bytes)
		return true
	}
	d.data = c
	return d
}

word :: proc(out: ^[dynamic]byte) {
	v := int(math.pow(100_000, rand.float64())) * 7919 % 1_000_003
	for v > 0 {
		append(out, byte('a' + v % 26))
		v /= 26
	}
	append(out, ' ')
}

us :: proc(t: time.Tick) -> f64 {
	return time.duration_microseconds(time.tick_since(t))
}

main :: proc() {
	fmt.println("µs, the least of forty edits; and what rests on disk, the mean")
	fmt.println("  words  pieces |   open   crdt   read  words   hash |  whole | KB written | KB grown | crdt, kept")
	for shape in ([][2]int{{20, 1}, {200, 1}, {200, 20}, {2000, 1}, {2000, 200}, {20_000, 10}, {20_000, 2000}, {20_000, 8000}, {100_000, 10_000}}) {
		run(shape[0], shape[1])
	}
}

run :: proc(words, pieces: int) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	secret, root, space: zsp.Key32
	crypto.rand_bytes(secret[:])
	crypto.rand_bytes(root[:])
	keys: zsp.Keyring
	zsp.keyring_init(&keys, secret)
	sk: ed25519.Private_Key
	_ = ed25519.private_key_set_bytes(&sk, root[:])
	ed25519.private_key_public_bytes(&sk, space[:])
	none: zsp.Roster
	d := zsp.draft_from(&none, 100)
	zsp.draft_grant(&d, keys.device, keys.signer, zsp.draft_scope(&d), {.Read, .Write}).owner = true
	roster, _ := zsp.roster_sign(&keys, root, &d)
	disk: zsp.Memory_Disk
	node: zsp.Node
	if !zsp.node_init(&node, zsp.memory_disk(&disk), space, &keys, true) {
		panic("node")
	}
	zsp.node_adopt(&node, roster)
	node.now = 1_700_000_000_000
	row := zsp.node_id(&node, 1)
	place: [24]byte
	zsp.put_u64(place[0:], 1 << 32 | 1)
	zsp.put_u64(place[8:], 1)
	_ = zsp.node_write(&node, {{row, 1, .Place, zsp.node_stamp(&node), place[:]}})

	// Others, so that the index is not all this one.
	text := make([dynamic]byte)
	for i in 0 ..< 20_000 {
		node.now += 10
		clear(&text)
		for _ in 0 ..< 20 {
			word(&text)
		}
		r := zsp.node_id(&node, 1)
		zsp.put_u64(place[16:], u64(i + 1))
		_ = zsp.node_write(&node, {{r, 1, .Place, zsp.node_stamp(&node), place[:]}, {r, 20, .Value, zsp.node_stamp(&node), text[:]}})
		free_all(context.temp_allocator)
	}

	doc: zsp.Text
	edit :: proc(node: ^zsp.Node, row: zsp.Id, doc: ^zsp.Text, at: int, bytes: []byte) -> []byte {
		node.now += 1000
		zsp.text_insert(doc, at, bytes, rand.uint64() | 1)
		stamp := zsp.node_stamp(node)
		body, ok := zsp.text_close(doc, stamp)
		if !ok {
			panic("close")
		}
		if !zsp.node_write(node, {{row, 20, .Piece, stamp, body}}) {
			panic("write")
		}
		return body
	}
	length := 0
	for i in 0 ..< pieces {
		clear(&text)
		n := words / pieces + (1 if i < words % pieces else 0)
		for _ in 0 ..< n {
			word(&text)
		}
		// Most writing goes on from where it left off; some is put in anywhere.
		for lo := 0; lo < len(text); lo += 30_000 {
			part := text[lo:min(lo + 30_000, len(text))]
			at := length if rand.int_max(5) > 0 else rand.int_max(length + 1)
			_ = edit(&node, row, &doc, at, part)
			length += len(part)
		}
		free_all(context.temp_allocator)
	}

	c: Counted
	x: find.Index
	find.index_open(&x, &node, counted(&c), secret)
	q, ok := find.query_parse({1, 10, 6, 20, 0, 0, 0, 4, 'b', 'a', 'n', 'd', 0, 0, 0, 50, 0}, context.allocator)
	if !ok {
		panic("question")
	}
	find.index_follow(&x)
	find.query_prepare(&x, &q)
	find.index_finish(&x)
	zsp.store_sync(&node.store)
	find.index_save(&x)
	size := int(x.next) - len(x.free)

	EDITS :: 40
	kept: zsp.Text // as it would be held by what had read it once
	{
		scan := zsp.row_scan(&node.store, row, 20, 20)
		for cell in zsp.row_next(&node.store, &scan) {
			cell := cell
			_ = zsp.cell_open(&keys, &node.roster, &cell)
			zsp.text_apply(&kept, &cell)
		}
	}
	whole, opened, crdt, read, tokens, hashed, few := max(f64), max(f64), max(f64), max(f64), max(f64), max(f64), max(f64)
	writes := 0
	for _ in 0 ..< EDITS {
		clear(&text)
		word(&text)
		body := edit(&node, row, &doc, length / 2 + rand.int_max(length / 4 + 1), text[:])
		length += len(text)
		last: zsp.Stamp
		{
			scan := zsp.row_scan(&node.store, row, 20, 20)
			for leaf in zsp.tree_next(&scan) {
				last = {leaf.key[3], leaf.key[4]}
			}
		}
		// All of it, as it is.
		c.writes = 0
		t := time.tick_now()
		find.index_finish(&x)
		whole = min(whole, us(t))
		zsp.store_sync(&node.store)
		if !find.index_save(&x) {
			panic("save")
		}
		writes += c.writes

		// Its parts.
		t = time.tick_now()
		cells := make([dynamic]zsp.Cell)
		scan := zsp.row_scan(&node.store, row, 20, 20)
		for cell in zsp.row_next(&node.store, &scan) {
			cell := cell
			_ = zsp.cell_open(&keys, &node.roster, &cell)
			append(&cells, cell)
		}
		opened = min(opened, us(t))
		t = time.tick_now()
		fresh: zsp.Text
		for &cell in cells {
			zsp.text_apply(&fresh, &cell)
		}
		crdt = min(crdt, us(t))
		t = time.tick_now()
		out := make([dynamic]byte)
		zsp.text_read(&fresh, &out)
		read = min(read, us(t))
		t = time.tick_now()
		all := make([dynamic]find.Key)
		it := find.words(out[:])
		for w in find.words_next(&it) {
			w := w
			k, _ := find.bytes_key(w.bytes[:w.len])
			append(&all, k)
		}
		slice.sort_by(all[:], proc(a, b: find.Key) -> bool {return a.hi < b.hi || (a.hi == b.hi && a.lo < b.lo)})
		tokens = min(tokens, us(t))
		t = time.tick_now()
		_ = zsp.sha256(out[:])
		hashed = min(hashed, us(t))

		// What it might be: the one piece put into what is held, and the words about it made and unmade.
		t = time.tick_now()
		cell := zsp.Cell{row = row, slot = 20, kind = .Piece, stamp = last, body = body}
		zsp.text_apply(&kept, &cell)
		few = min(few, us(t))

		zsp.text_destroy(&fresh)
		delete(all)
		delete(out)
		delete(cells)
		free_all(context.temp_allocator)
	}
	fmt.printfln("%7d %7d | %6.0f %6.0f %6.0f %6.0f %6.0f | %6.0f | %10.0f | %8.1f | %6.0f", words, pieces, opened, crdt, read, tokens, hashed, whole, f64(writes) / EDITS * 4, f64(int(x.next) - len(x.free) - size) / EDITS * 4, few)
}
