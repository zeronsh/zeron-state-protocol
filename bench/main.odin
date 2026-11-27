/*
Measures what the design promises, on a real disk: bytes written, memory held, time taken.
*/
package bench

import "core:crypto"
import "core:crypto/ed25519"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "../host"
import "../pipe"
import "../zsp"

ROWS :: #config(ROWS, 1_000_000)
BODY :: 200

proc_value :: proc(file, name: string) -> int {
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil {
		return 0
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, name) {
			fields := strings.fields(line, context.temp_allocator)
			n, _ := strconv.parse_int(fields[1])
			return n
		}
	}
	return 0
}

written :: proc() -> int {
	return proc_value("/proc/self/io", "write_bytes:")
}

// Memory that is this process's own, as opposed to the file cache it maps.
own_kb :: proc() -> int {
	return proc_value("/proc/self/status", "RssAnon:")
}

Bench :: struct {
	node:  zsp.Node,
	keys:  zsp.Keyring,
	disk:  host.File_Disk,
	space: zsp.Key32,
	roster: []byte,
}

start :: proc(b: ^Bench, dir: string) {
	if !host.file_disk_open(&b.disk, dir) || !zsp.node_init(&b.node, host.file_disk(&b.disk), b.space, &b.keys, true) {
		panic("storage")
	}
	zsp.node_adopt(&b.node, b.roster)
	b.node.now = 1_700_000_000_000
}

make_space :: proc(b: ^Bench) {
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
	b.roster, _ = zsp.roster_sign(&b.keys, root, &d)
}

put :: proc(b: ^Bench, list: u64, order: u64, body: []byte) -> zsp.Id {
	place: [24]byte
	tag := zsp.List{1 << 32 | list, 1}
	zsp.put_u64(place[0:], tag[0])
	zsp.put_u64(place[8:], tag[1])
	zsp.put_u64(place[16:], order)
	row := zsp.node_id(&b.node, 1)
	cells := [2]zsp.Cell {
		{row, zsp.PLACE, .Place, zsp.node_stamp(&b.node), place[:]},
		{row, zsp.DATA, .Value, zsp.node_stamp(&b.node), body},
	}
	_ = zsp.node_write(&b.node, cells[:])
	return row
}

per :: proc(t: time.Tick, n: int) -> f64 {
	return time.duration_microseconds(time.tick_since(t)) / f64(n)
}

main :: proc() {
	dir := os.args[1] if len(os.args) > 1 else "/tmp/zsp-bench"
	os.remove_all(dir)
	b: Bench
	make_space(&b)
	start(&b, dir)
	body: [BODY]byte
	crypto.rand_bytes(body[:])

	fmt.printfln("%d rows of %d bytes, sealed, in 1000 lists", ROWS, BODY)
	io := written()
	t := time.tick_now()
	for i in 0 ..< ROWS {
		b.node.now += 1
		put(&b, u64(i / 1000), u64(i), body[:])
		if i % 100 == 0 {
			zsp.store_flush(&b.node.store)
			if zsp.store_wants_checkpoint(&b.node.store) {
				zsp.store_checkpoint(&b.node.store)
			}
		}
		free_all(context.temp_allocator)
	}
	zsp.store_checkpoint(&b.node.store)
	total := written() - io
	fmt.printfln("  write         %8.2f µs a row   %.0f bytes to disk a row (%.2fx its %d bytes sealed)", per(t, ROWS), f64(total) / ROWS, f64(total) / ROWS / (BODY + 24 + 2 * 36 + 16 + 4), BODY + 24 + 2 * 36 + 16 + 4)
	fmt.printfln("  memory        %8d KB", own_kb())

	// One small write at a time, made durable each time: the worst case for amplification.
	io = written()
	t = time.tick_now()
	for i in 0 ..< 200 {
		put(&b, 5000, u64(i), body[:40])
		_ = zsp.store_sync(&b.node.store)
	}
	fmt.printfln("  durable write %8.0f µs           %d bytes to disk each", per(t, 200), (written() - io) / 200)

	zsp.node_destroy(&b.node)
	t = time.tick_now()
	start(&b, dir)
	fmt.printfln("open            %8.0f µs           %d KB", per(t, 1), own_kb())

	cells := 0
	t = time.tick_now()
	for i in 0 ..< 1000 {
		list := zsp.List{1 << 32 | u64(i % 1000), 1}
		held := zsp.store_range(&b.node.store, zsp.list_lo(list), zsp.list_hi(list)).count
		lo, _ := zsp.tree_select(&b.node, b.node.shelf, zsp.tree_prefix(&b.node, b.node.shelf, zsp.list_lo(list)).count + held - 50)
		scan := zsp.tree_scan(&b.node, b.node.shelf, lo, zsp.list_hi(list))
		for leaf in zsp.tree_next(&scan) {
			rs := zsp.row_scan(&b.node.store, zsp.key_row(leaf.key))
			for c in zsp.row_next(&b.node.store, &rs) {
				c := c
				cells += 1 if zsp.cell_open(&b.keys, &b.node.roster, &c) else 0
			}
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("page of 50      %8.0f µs           found, read and opened (%d cells)", per(t, 1000), cells)
	fmt.printfln("memory after    %8d KB", own_kb())

	t = time.tick_now()
	sum: zsp.Sum
	for i in 0 ..< 100_000 {
		lo := zsp.Key{1 << 32 | u64(i % 1000), 1, u64(i), 0, 0}
		s := zsp.store_range(&b.node.store, lo, zsp.scope_hi(1))
		sum.count += s.count
	}
	fmt.printfln("range print     %8.2f µs           of up to %d rows", per(t, 100_000), ROWS)

	cell := zsp.Cell{{1 << 32, 1}, zsp.DATA, .Value, {1, 1}, body[:]}
	t = time.tick_now()
	for _ in 0 ..< 100_000 {
		c := cell
		_ = zsp.cell_seal(&b.keys, &b.node.roster, &c)
		free_all(context.temp_allocator)
	}
	fmt.printfln("seal            %8.2f µs           a %d-byte cell", per(t, 100_000), BODY)
	t = time.tick_now()
	for _ in 0 ..< 100_000 {
		_ = zsp.cell_print(&cell)
	}
	fmt.printfln("fingerprint     %8.2f µs", per(t, 100_000))
	zsp.node_destroy(&b.node)

	link()
	os.remove_all(dir)
}

// A link's cost with the network taken away.
link :: proc() {
	a, b: pipe.Link
	sa, sb, space: zsp.Key32
	crypto.rand_bytes(sa[:])
	crypto.rand_bytes(sb[:])
	buf: [pipe.PACKET_MAX]byte
	pipe.link_dial(&a, sa, zsp.x25519_public(sb), space)
	t := time.tick_now()
	pipe.link_answer(&b, sb, space, pipe.link_hello(&a, buf[:]))
	pipe.link_input(&a, pipe.link_hello(&b, buf[:]), 1)
	fmt.printfln("handshake       %8.0f µs           both ends", per(t, 1))
	got := 0
	b.data = &got
	b.on_stream = proc(l: ^pipe.Link, id: u64, bytes: []byte, event: pipe.Stream_Event) {
		if event == .Data {
			(^int)(l.data)^ += len(bytes)
		}
	}
	chunk: [64 << 10]byte
	SIZE :: 256 << 20
	now := pipe.Time(1000)
	t = time.tick_now()
	for got < SIZE {
		for room := pipe.link_room(&a); room > 0; room = pipe.link_room(&a) {
			pipe.link_write(&a, 0, chunk[:min(room, len(chunk))]) // stream 0, which is always open, as a session's is
		}
		now += 50
		for p := pipe.link_output(&a, buf[:], now); p != nil; p = pipe.link_output(&a, buf[:], now) {
			pipe.link_input(&b, p, now)
		}
		now += 50
		for p := pipe.link_output(&b, buf[:], now); p != nil; p = pipe.link_output(&b, buf[:], now) {
			pipe.link_input(&a, p, now)
		}
	}
	seconds := time.duration_seconds(time.tick_since(t))
	fmt.printfln("link            %8.0f MB/s         one core doing both ends", f64(got) / 1e6 / seconds)
}
