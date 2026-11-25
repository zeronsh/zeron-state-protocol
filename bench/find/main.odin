// What it costs to ask: ./x bench find
package main

import "core:crypto"
import "core:crypto/ed25519"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:time"
import "../../find"
import "../../host"
import "../../zsp"

proc_value :: proc(path, name: string) -> (v: int) {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, name) {
			f := strings.fields(line, context.temp_allocator)
			v, _ = strconv.parse_int(f[1])
		}
	}
	return
}

own_kb :: proc() -> int {
	return proc_value("/proc/self/status", "RssAnon:")
}

number :: proc(v: f64) -> []byte {
	b := make([]byte, 8, context.temp_allocator)
	zsp.put_u64(b, transmute(u64)v)
	return b
}

W :: struct {
	out: [dynamic]byte,
}

col :: proc(w: ^[dynamic]byte, k: find.Kind, slot: u8) {
	append(w, u8(k), slot, 0)
}

Bench :: struct {
	node:  zsp.Node,
	keys:  zsp.Keyring,
	disk:  host.File_Disk,
	file:  host.Pages_File,
	x:     find.Index,
	space: zsp.Key32,
}

ask :: proc(b: ^Bench, name: string, source: []byte, times := 50) {
	source := source
	count, shown := 0, 0
	q, ok := find.query_parse(source, context.allocator)
	if !ok {
		panic(name)
	}
	find.index_follow(&b.x)
	t := time.tick_now()
	find.query_prepare(&b.x, &q)
	worst := 0.0
	for {
		slice := time.tick_now()
		done := find.index_step(&b.x)
		worst = max(worst, time.duration_milliseconds(time.tick_since(slice)))
		if done do break
	}
	built := time.duration_milliseconds(time.tick_since(t))
	s := find.index_scope(&b.x, 1)
	least := max(f64)
	for _ in 0 ..< times {
		t = time.tick_now()
		rows := find.pred_rows(s, &q.where_)
		page := find.query_page(s, &q, &rows)
		_ = find.query_totals(s, &q, &rows)
		least = min(least, f64(time.duration_nanoseconds(time.tick_since(t))) / 1000)
		count, shown = rows.count, len(page)
		find.set_destroy(&rows)
		free_all(context.temp_allocator)
	}
	if built > 1 {
		fmt.printfln("    (built what it needs in %.0f ms, %.1f ms at most at a time; %d KB of memory)", built, worst, own_kb())
	}
	fmt.printfln("  %-62s %10.1f µs   %7d rows, %d shown", name, least, count, shown)
}

main :: proc() {
	rows := 1_000_000
	dir := "/tmp/zsp-bench-find"
	if len(os.args) > 1 {
		rows, _ = strconv.parse_int(os.args[1])
	}
	os.remove_all(dir)
	b: Bench
	secret, root: zsp.Key32
	crypto.rand_bytes(secret[:])
	crypto.rand_bytes(root[:])
	zsp.keyring_init(&b.keys, secret)
	sk: ed25519.Private_Key
	_ = ed25519.private_key_set_bytes(&sk, root[:])
	ed25519.private_key_public_bytes(&sk, b.space[:])
	none: zsp.Roster
	d := zsp.draft_from(&none, 100)
	zsp.draft_grant(&d, b.keys.device, b.keys.signer, zsp.draft_scope(&d), {.Read, .Write, .Call})
	roster, _ := zsp.roster_sign(&b.keys, root, &d)
	if !host.file_disk_open(&b.disk, dir) || !zsp.node_init(&b.node, host.file_disk(&b.disk), b.space, &b.keys, true) {
		panic("storage")
	}
	zsp.node_adopt(&b.node, roster)
	b.node.now = 1_700_000_000_000
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)

	// Rows like messages: who, how urgent, whether done, and twenty words of 100,000, some much commoner.
	names := make([]string, 5000)
	for &n, i in names {
		n = fmt.aprintf("person-%04d", i)
	}
	t := time.tick_now()
	text := make([dynamic]byte)
	size := 0
	for i in 0 ..< rows {
		b.node.now += 1000
		clear(&text)
		for _ in 0 ..< 20 {
			word := int(math.pow(100_000, rand.float64()))
			v := word * 7919 % 1_000_003
			for v > 0 {
				append(&text, byte('a' + v % 26))
				v /= 26
			}
			append(&text, ' ')
		}
		size += len(text)
		place: [24]byte
		zsp.put_u64(place[0:], 1 << 32 | u64(i % 100))
		zsp.put_u64(place[8:], 1)
		zsp.put_u64(place[16:], u64(i))
		row := zsp.node_id(&b.node, 1)
		done := []byte{1 if rand.int_max(3) > 0 else 0}
		_ = zsp.node_write(&b.node, {
			{row, zsp.PLACE, .Place, zsp.node_stamp(&b.node), place[:]},
			{row, 16, .Value, zsp.node_stamp(&b.node), transmute([]byte)rand.choice(names)},
			{row, 17, .Value, zsp.node_stamp(&b.node), number(math.floor(rand.float64() * 100000))},
			{row, 18, .Value, zsp.node_stamp(&b.node), done},
			{row, 20, .Value, zsp.node_stamp(&b.node), text[:]},
		})
		if i % 100 == 0 {
			zsp.store_flush(&b.node.store)
			if zsp.store_wants_checkpoint(&b.node.store) {
				zsp.store_checkpoint(&b.node.store)
			}
		}
		free_all(context.temp_allocator)
	}
	zsp.store_checkpoint(&b.node.store)
	fmt.printfln("%d rows, each a name, a number, a flag and a text of %d bytes; written in %.1f s", rows, size / rows, time.duration_seconds(time.tick_since(t)))
	key := zsp.derive(secret, "zsp-find")
	find.index_open(&b.x, &b.node, host.pages_file(&b.file, dir), key)
	fmt.printfln("memory before an index %d KB", own_kb())

	w: [dynamic]byte
	tail :: proc(w: ^[dynamic]byte, order: []byte, limit: int) {
		append(w, ..order)
		append(w, 0, 0)
		zsp.write_varint(w, u64(limit))
		append(w, 0)
	}
	NEWEST := []byte{1, 2, 1}
	by_number := []byte{1, 0, 1, 3, 17, 0}
	zsp.write_varint(&w, 1); append(&w, 0); tail(&w, NEWEST, 50)
	ask(&b, "everything, newest first", w[:]); clear(&w)
	zsp.write_varint(&w, 1); append(&w, 0); tail(&w, by_number, 50)
	ask(&b, "everything, by number", w[:]); clear(&w)
	range :: proc(w: ^[dynamic]byte, lo, hi: f64) {
		append(w, 4); col(w, .Number, 17); append(w, 15, 8); append(w, ..number(lo)); append(w, 8); append(w, ..number(hi))
	}
	equal :: proc(w: ^[dynamic]byte, k: find.Kind, slot: u8, v: []byte) {
		append(w, 4); col(w, k, slot); append(w, 15); zsp.write_bytes(w, v); zsp.write_bytes(w, v)
	}
	zsp.write_varint(&w, 1); range(&w, 5000, 5099); tail(&w, NEWEST, 50)
	ask(&b, "a number in a narrow range, newest first", w[:]); clear(&w)
	zsp.write_varint(&w, 1); range(&w, 20000, 80000); tail(&w, NEWEST, 50)
	ask(&b, "a number in a wide range, newest first", w[:]); clear(&w)
	zsp.write_varint(&w, 1); equal(&w, .Bytes, 16, transmute([]byte)string("person-0042")); tail(&w, NEWEST, 50)
	ask(&b, "a name, newest first", w[:]); clear(&w)
	zsp.write_varint(&w, 1); append(&w, 1, 3); equal(&w, .Bytes, 16, transmute([]byte)string("person-0042")); range(&w, 20000, 80000); equal(&w, .Bool, 18, []byte{0}); tail(&w, by_number, 50)
	ask(&b, "a name, a wide range and a flag, by number", w[:]); clear(&w)
	zsp.write_varint(&w, 1); append(&w, 1, 2); range(&w, 20000, 80000); append(&w, 3); equal(&w, .Bool, 18, []byte{1}); tail(&w, by_number, 50)
	ask(&b, "a wide range and not a flag, by number", w[:]); clear(&w)
	zsp.write_varint(&w, 1); append(&w, 6); col(&w, .Fold, 16); zsp.write_bytes(&w, transmute([]byte)string("PERSON-00")); tail(&w, NEWEST, 50)
	ask(&b, "names that begin so, whatever the case", w[:]); clear(&w)
	match :: proc(w: ^[dynamic]byte, mode, flags: u8, s: string) {
		append(w, 10); col(w, .Words, 20); append(w, mode, flags); zsp.write_bytes(w, transmute([]byte)s)
	}
	spell :: proc(words: ..int) -> string {
		out: strings.Builder
		for word, i in words {
			if i > 0 do strings.write_byte(&out, ' ')
			v := word * 7919 % 1_000_003
			for v > 0 {
				strings.write_byte(&out, byte('a' + v % 26))
				v /= 26
			}
		}
		return strings.to_string(out)
	}
	zsp.write_varint(&w, 1); match(&w, 0, 0, spell(50_000)); tail(&w, NEWEST, 50)
	ask(&b, "a rare word, newest first", w[:]); clear(&w)
	zsp.write_varint(&w, 1); match(&w, 0, 0, spell(3)); tail(&w, NEWEST, 50)
	ask(&b, "a very common word, newest first", w[:], 10); clear(&w)
	zsp.write_varint(&w, 1); match(&w, 0, 0, spell(3, 40)); tail(&w, NEWEST, 50)
	ask(&b, "two common words together, newest first", w[:], 10); clear(&w)
	zsp.write_varint(&w, 1); match(&w, 0, 0, spell(3, 5000)); tail(&w, NEWEST, 50)
	ask(&b, "a common word and a rare one, newest first", w[:], 10); clear(&w)
	zsp.write_varint(&w, 1); match(&w, 0, 0, spell(400, 900)); tail(&w, []byte{1, 1, 0}, 50)
	ask(&b, "two words, best first", w[:], 10); clear(&w)
	zsp.write_varint(&w, 1); match(&w, 2, 0, spell(30, 60)); tail(&w, NEWEST, 50)
	ask(&b, "a phrase", w[:], 10); clear(&w)
	zsp.write_varint(&w, 1); match(&w, 0, 1, spell(777)[:3]); tail(&w, NEWEST, 50)
	ask(&b, "words that begin with three letters", w[:], 10); clear(&w)
	zsp.write_varint(&w, 1); match(&w, 0, 4, spell(77_777)); tail(&w, NEWEST, 50)
	ask(&b, "a word with a letter wrong", w[:], 10); clear(&w)
	zsp.write_varint(&w, 1); match(&w, 0, 2, spell(77_777)[1:]); tail(&w, NEWEST, 50)
	ask(&b, "part of a word", w[:], 10); clear(&w)
	zsp.write_varint(&w, 1); append(&w, 0); append(&w, ..NEWEST); append(&w, 0, 0, 0, 2); append(&w, 1); col(&w, .Number, 17); append(&w, 0); append(&w, 3); col(&w, .Number, 17); append(&w, 0)
	ask(&b, "the sum and most of every number", w[:]); clear(&w)
	zsp.write_varint(&w, 1); equal(&w, .Bool, 18, []byte{0}); append(&w, ..NEWEST); append(&w, 0, 0, 0, 1, 5); col(&w, .Bytes, 16); append(&w, 10)
	ask(&b, "the ten commonest names among a third of the rows", w[:], 10); clear(&w)

	zsp.store_sync(&b.node.store)
	t = time.tick_now()
	find.index_save(&b.x)
	st, _ := os.stat(fmt.tprintf("%s/find", dir), context.temp_allocator)
	fmt.printfln("saved in %.0f ms: %d bytes a row; memory %d KB", time.duration_milliseconds(time.tick_since(t)), int(st.size) / rows, own_kb())
	for c in b.x.scopes[0].columns {
		fmt.printfln("    %v %v", c.kind, c.slot)
	}
	// One change, as it is followed.
	t = time.tick_now()
	for i in 0 ..< 200 {
		b.node.now += 1
		place: [24]byte
		zsp.put_u64(place[0:], 1 << 32 | 1)
		zsp.put_u64(place[8:], 1)
		row := zsp.node_id(&b.node, 1)
		_ = zsp.node_write(&b.node, {
			{row, zsp.PLACE, .Place, zsp.node_stamp(&b.node), place[:]},
			{row, 16, .Value, zsp.node_stamp(&b.node), transmute([]byte)rand.choice(names)},
			{row, 17, .Value, zsp.node_stamp(&b.node), number(f64(i))},
			{row, 18, .Value, zsp.node_stamp(&b.node), []byte{1}},
			{row, 20, .Value, zsp.node_stamp(&b.node), text[:]},
		})
		find.index_follow(&b.x)
		free_all(context.temp_allocator)
	}
	fmt.printfln("a new row followed at once, in every column: %.0f µs", time.duration_microseconds(time.tick_since(t)) / 200)
	t = time.tick_now()
	find.index_close(&b.x)
	find.index_open(&b.x, &b.node, host.pages_file(&b.file, dir), key)
	fmt.printfln("opened again in %.1f ms", time.duration_milliseconds(time.tick_since(t)))
}
