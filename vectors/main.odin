/*
Prints vectors.json: every deterministic thing two implementations must agree on. `./x test` checks that
the file is current and that the other implementations agree with it.
*/
package vectors

import "core:crypto/sha2"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:math/rand"
import "../zsp"

h :: proc(b: []byte) -> string {
	return string(hex.encode(b))
}

key_of :: proc(n: byte) -> (k: zsp.Key32) {
	for &b, i in k {
		b = n + byte(i)
	}
	return
}

main :: proc() {
	state := rand.create(42)
	context.random_generator = rand.default_random_generator(&state)
	fmt.println("{")
	keys()
	cells()
	lists()
	handshake()
	texts()
	links()
	files()
	services()
	fmt.println(`  "version": 1`)
	fmt.println("}")
}

keys :: proc() {
	fmt.println(`  "keys": [`)
	list := zsp.List{7 << 32 | 9, 11}
	all := []zsp.Key{zsp.KEY_MIN, zsp.list_lo(list), zsp.list_hi(list), zsp.place_key(list, 1000, {7 << 32, 5}), zsp.scope_lo(7), zsp.scope_hi(7), zsp.KEY_MAX}
	for k, i in all {
		w: [dynamic]byte
		zsp.write_key(&w, k)
		raw: [40]byte
		for v, j in k {
			zsp.put_u64(raw[j * 8:], v)
		}
		fmt.printfln(`    {{"key": "%s", "wire": "%s"}}%s`, h(raw[:]), h(w[:]), "," if i + 1 < len(all) else "")
	}
	fmt.println("  ],")
}

cells :: proc() {
	k: zsp.Keyring
	zsp.keyring_init(&k, key_of(1))
	sk := zsp.Scope_Keys{scope = 3, list_key = zsp.derive(key_of(50), "zsp-list")}
	append(&sk.epochs, key_of(50))
	zsp.scope_keys_index(&sk)
	append(&k.scopes, sk)
	r: zsp.Roster
	r.scopes = {{id = 3, epoch = 1}, {id = 4, flags = {.Signed}, epoch = 1}}
	signed := zsp.Scope_Keys{scope = 4, list_key = zsp.derive(key_of(90), "zsp-list")}
	append(&signed.epochs, key_of(90))
	zsp.scope_keys_index(&signed)
	append(&k.scopes, signed)
	r.members = {{device = k.device, signer = k.signer, grants = {{4, {.Read, .Write}, 0}}}}

	fmt.printfln(`  "device": {{"secret": "%s", "device": "%s", "signer": "%s"}},`, h(k.secret[:]), h(k.device[:]), h(k.signer[:]))
	fmt.println(`  "cells": [`)
	place: [24]byte
	tag := zsp.list_tag(&k.scopes[0], "chat/1")
	zsp.put_u64(place[0:], tag[0])
	zsp.put_u64(place[8:], tag[1])
	zsp.put_u64(place[16:], 1700000000000)
	bundle: [4 + 32 + 5]byte
	zsp.put_u32(bundle[:], 2)
	zsp.put_u64(bundle[4:], 5)
	zsp.put_u64(bundle[12:], 6)
	zsp.put_u64(bundle[20:], 5)
	zsp.put_u64(bundle[28:], 7)
	row := zsp.Id{3 << 32 | 1700000000, 0x0123456789abcdef}
	all := []zsp.Cell {
		{row, zsp.PLACE, .Place, {1700000000000 << 16, 1}, place[:]},
		{row, zsp.DATA, .Value, {1700000000000 << 16 | 1, 2}, transmute([]byte)string("hello")},
		{row, zsp.DATA + 1, .Piece, {1700000000000 << 16 | 2, 3}, {0, 0, 0, 0, 0, 0, 0, 9, 1, 0, 0, 2, 'h', 'i'}},
		{row, zsp.DATA + 1, .Bundle, {1700000000000 << 16 | 3, 4}, bundle[:]},
		{row, zsp.GRAVE, .Grave, {1700000000000 << 16 | 4, 5}, nil},
		{{4 << 32 | 1700000000, 1}, zsp.DATA, .Value, {1700000000000 << 16 | 5, 6}, transmute([]byte)string("signed")},
		{{4 << 32 | 1700000000, 1}, zsp.DATA, .Value, {1700000000000 << 16 | 6, 7}, transmute([]byte)string("signed for another")},
	}
	for &c, i in all {
		sealing := key_of(50) if i < 5 else key_of(90)
		open := c
		w: [dynamic]byte
		zsp.write_cell(&w, &open, false)
		as := "zoe" if i == 6 else ""
		_ = zsp.cell_seal(&k, &r, &c, 0, transmute([]byte)as)
		s: [dynamic]byte
		zsp.write_cell(&s, &c, false)
		print := zsp.cell_print(&c)
		pb: [16]byte
		zsp.put_u64(pb[:], print[0])
		zsp.put_u64(pb[8:], print[1])
		fmt.printfln(`    {{"key": "%s", "open": "%s", "sealed": "%s", "print": "%s", "as": "%s"}}%s`, h(sealing[:]), h(w[:]), h(s[:]), h(pb[:]), h(transmute([]byte)as), "," if i + 1 < len(all) else "")
	}
	fmt.println("  ],")
}

lists :: proc() {
	fmt.println(`  "lists": [`)
	s := zsp.Scope_Keys{scope = 258, list_key = key_of(7)}
	names := []string{"", "chat", "chat/8f2c", "ünïcode"}
	for name, i in names {
		tag := zsp.list_tag(&s, name)
		b: [16]byte
		zsp.put_u64(b[:], tag[0])
		zsp.put_u64(b[8:], tag[1])
		fmt.printfln(`    {{"scope": 258, "list_key": "%s", "name": "%s", "tag": "%s"}}%s`, h(s.list_key[:]), name, h(b[:]), "," if i + 1 < len(names) else "")
	}
	fmt.println("  ],")
}

handshake :: proc() {
	hs: zsp.Handshake
	i, r, ie, re, space := key_of(1), key_of(40), key_of(80), key_of(120), key_of(200)
	first, _ := zsp.handshake_start(&hs, i, zsp.x25519_public(r), space, ie, 1700000000000 << 16)
	second, _, _ := zsp.handshake_answer(r, space, first[:], re)
	said: [8]byte
	zsp.put_u64(said[:], 1700000000000 << 16)
	c, _ := zsp.handshake_finish(&hs, second[:], zsp.x25519_public(r))
	fmt.printfln(
		`  "handshake": {{"initiator": "%s", "responder": "%s", "initiator_ephemeral": "%s", "responder_ephemeral": "%s", "space": "%s", "when": "%s", "first": "%s", "second": "%s", "send": "%s", "recv": "%s"}},`,
		h(i[:]), h(r[:]), h(ie[:]), h(re[:]), h(space[:]), h(said[:]), h(first[:]), h(second[:]), h(c.send[:]), h(c.recv[:]),
	)
}

// Documents by three writers who see each other late, as their pieces and what they come to.
texts :: proc() {
	DOCS :: 40
	fmt.println(`  "texts": [`)
	for doc in 0 ..< DOCS {
		writers: [3]zsp.Text
		all: [dynamic]zsp.Cell
		clock: u64
		for _ in 0 ..< 120 {
			t := &writers[rand.int_max(3)]
			n := zsp.text_len(t)
			switch r := rand.int_max(10); {
			case r < 5:
				word: [4]byte
				for &b in word {
					b = 'a' + byte(rand.int_max(26))
				}
				zsp.text_insert(t, rand.int_max(n + 1), word[:1 + rand.int_max(4)], rand.uint64() | 1)
			case r < 6:
				if n > 0 {
					pos := rand.int_max(n)
					zsp.text_delete(t, pos, min(1 + rand.int_max(5), n - pos), rand.uint64() | 1)
				}
			case r < 7:
				piece, offset, bytes := zsp.text_flush(t)
				for &o in writers {
					if &o != t && piece != 0 && rand.int_max(2) == 0 {
						zsp.text_live(&o, piece, offset, bytes)
					}
				}
			case r < 8:
				clock += 1
				stamp := zsp.Stamp{clock, rand.uint64()}
				if body, ok := zsp.text_close(t, stamp); ok {
					append(&all, zsp.Cell{{1, 1}, zsp.DATA, .Piece, stamp, body})
				}
			case:
				if len(all) > 0 {
					c := rand.choice(all[:])
					zsp.text_apply(t, &c)
				}
			}
		}
		for &t in writers {
			clock += 1
			stamp := zsp.Stamp{clock, rand.uint64()}
			if body, ok := zsp.text_close(&t, stamp); ok {
				append(&all, zsp.Cell{{1, 1}, zsp.DATA, .Piece, stamp, body})
			}
		}
		if doc % 3 == 0 {
			// Pieces by someone who minds nothing: neighbours in any order, and of any piece. They come to the
			// same in any order.
			ids: [dynamic]u64
			for c in all {
				append(&ids, zsp.get_u64(c.body))
			}
			so_far: zsp.Text
			for &c in all {
				zsp.text_apply(&so_far, &c)
			}
			for _ in 0 ..< 40 {
				clock += 1
				id := rand.uint64() | 1
				w: [dynamic]byte
				zsp.write_u64(&w, id)
				for _ in 0 ..< 2 {
					append(&w, 1) // insert, between two of whatever there is
					for _ in 0 ..< 2 {
						append(&w, 2)
						zsp.write_u64(&w, rand.choice(ids[:]))
						zsp.write_varint(&w, u64(rand.int_max(3)))
					}
					zsp.write_bytes(&w, {'A' + byte(rand.int_max(26)), 'Z'})
				}
				c := zsp.Cell{{1, 1}, zsp.DATA, .Piece, {clock, rand.uint64()}, w[:]}
				if zsp.text_apply(&so_far, &c) != .Changed {
					zsp.text_destroy(&so_far) // it speaks of what there is not: begin again without it
					for &d in all {
						zsp.text_apply(&so_far, &d)
					}
					continue
				}
				append(&all, c)
				append(&ids, id)
			}
		}
		if doc == DOCS - 1 {
			// And a tree as deep and as wide as someone cares to make it: each before the last, or after the first.
			clear(&all)
			first, last: u64
			for i in 0 ..< 400 {
				clock += 1
				id := rand.uint64() | 1
				w: [dynamic]byte
				zsp.write_u64(&w, id)
				append(&w, 1)
				ref :: proc(w: ^[dynamic]byte, id: u64) {
					append(w, 2)
					zsp.write_u64(w, id)
					zsp.write_varint(w, 0)
				}
				switch {
				case i == 0:
					append(&w, 0, 0)
					first = id
				case i % 2 == 0:
					append(&w, 0)
					ref(&w, last)
				case:
					ref(&w, first)
					append(&w, 0)
				}
				zsp.write_bytes(&w, {'a' + byte(rand.int_max(26))})
				append(&all, zsp.Cell{{1, 1}, zsp.DATA, .Piece, {clock, rand.uint64()}, w[:]})
				if i % 2 == 0 {
					last = id
				}
			}
		}
		if doc % 2 == 0 && len(all) > 4 {
			n := len(all) / 2
			bundle := zsp.text_bundle(all[:n])
			clock += 1
			bundle.stamp = {clock, rand.uint64()}
			remove_range(&all, 0, n)
			append(&all, bundle)
		}
		result: zsp.Text
		for &c in all {
			zsp.text_apply(&result, &c)
		}
		w: [dynamic]byte
		zsp.text_read(&result, &w)
		fmt.print(`    {"cells": [`)
		for c, i in all {
			s: [16]byte
			zsp.put_u64(s[:], c.stamp.time)
			zsp.put_u64(s[8:], c.stamp.salt)
			fmt.printf(`%s{{"kind": %d, "stamp": "%s", "body": "%s"}}`, ", " if i > 0 else "", int(c.kind), h(s[:]), h(c.body))
		}
		fmt.printfln(`], "text": "%s"}}%s`, string(w[:]), "," if doc + 1 < DOCS else "")
	}
	fmt.println("  ],")
}

// A link's data frames, each with what it encodes (§14), one sealed packet carrying them, and the header that begins a stream.
links :: proc() {
	Frame :: struct {
		name:  string,
		bytes: []byte,
	}
	f :: proc(parts: ..[]byte) -> []byte {
		w: [dynamic]byte
		for p in parts {
			append(&w, ..p)
		}
		return w[:]
	}
	v :: proc(n: u64) -> []byte {
		w: [dynamic]byte
		zsp.write_varint(&w, n)
		return w[:]
	}
	b :: proc(bytes: string) -> []byte {
		w: [dynamic]byte
		zsp.write_bytes(&w, transmute([]byte)bytes)
		return w[:]
	}
	frames := []Frame {
		{"ping", {1}},
		// Packets 100 and 98…99 seen, 40 µs after 100 came; 97 not, nor 95…96 seen: gap 1, run 2, then the end.
		{"ack 100, 98-99 behind a gap of none; then 95-96 after a gap of 1; delay 40", f({2}, v(100), v(40), v(3), v(1), v(2), v(0))},
		{"stream 4 at 1000: hello", f({3}, v(4), v(1000), b("hello"))},
		{"datagram: hi", f({4}, b("hi"))},
		{"close", {5}},
		{"fin 3 at 7: bye", f({6}, v(3), v(7), b("bye"))},
		{"reset 4 at 4096", f({7}, v(4), v(4096))},
		{"stop 5", f({8}, v(5))},
		{"window 0 to 524288", f({9}, v(0), v(524288))},
		{"limit 2097152, 300 streams", f({10}, v(2097152), v(300))},
		{"header: urgency 1, after 300", f({1}, v(300))},
	}
	fmt.println(`  "link_frames": [`)
	for fr, i in frames {
		fmt.printfln(`    {{"frame": "%s", "bytes": "%s"}}%s`, fr.name, h(fr.bytes), "," if i + 1 < len(frames) else "")
	}
	fmt.println("  ],")
	// The packet: type, receiver (little-endian), counter (little-endian), then the frames sealed with that counter as
	// the nonce, the 13 bytes before them associated data.
	c: zsp.Channel
	c.send = key_of(60)
	plain := f(frames[2].bytes, frames[0].bytes)
	packet := make([]byte, 13 + len(plain) + zsp.TAG)
	packet[0] = 0x43
	endian.unchecked_put_u32le(packet[1:], 0xdecafbad)
	endian.unchecked_put_u64le(packet[5:], 77)
	copy(packet[13:], plain)
	zsp.channel_seal_in_place(&c, 77, packet[13:], packet[:13])
	fmt.printfln(`  "link_packet": {{"key": "%s", "receiver": "decafbad", "counter": 77, "frames": "%s", "packet": "%s"}},`, h(c.send[:]), h(plain), h(packet))
}

// Files hashed in chunks (§16): each chunk of a MiB by SHA-256, the file by SHA-256 of the chunks' hashes. The content of
// each is byte i = i * 7 + i / 251, mod 256.
files :: proc() {
	CHUNK :: 1 << 20
	sizes := []int{0, 1, CHUNK - 1, CHUNK, CHUNK + 1, 2 * CHUNK + CHUNK / 2}
	fmt.println(`  "files": [`)
	for size, n in sizes {
		data := make([]byte, size)
		for &x, i in data {
			x = byte(i * 7 + i / 251)
		}
		file: sha2.Context_256
		sha2.init_256(&file)
		fmt.printf(`    {{"size": %d, "chunks": [`, size)
		for at, k := 0, 0; at < size; at, k = at + CHUNK, k + 1 {
			chunk: [32]byte
			one: sha2.Context_256
			sha2.init_256(&one)
			sha2.update(&one, data[at:min(at + CHUNK, size)])
			sha2.final(&one, chunk[:])
			sha2.update(&file, chunk[:])
			fmt.printf(`%s"%s"`, ", " if k > 0 else "", h(chunk[:]))
		}
		whole: [32]byte
		sha2.final(&file, whole[:])
		fmt.printfln(`], "file": "%s"}}%s`, h(whole[:]), "," if n + 1 < len(sizes) else "")
	}
	fmt.println("  ],")
}

// What services say (§16), byte for byte.
services :: proc() {
	Message :: struct {
		name:  string,
		bytes: []byte,
	}
	w :: proc() -> [dynamic]byte {return {}}
	strs :: proc(w: ^[dynamic]byte, s: ..string) {
		zsp.write_varint(w, u64(len(s)))
		for x in s {
			zsp.write_bytes(w, transmute([]byte)x)
		}
	}
	exec := w()
	append(&exec, 0)
	strs(&exec, "ls", "-l", "/tmp")
	strs(&exec, "LANG=C", "HOME")
	zsp.write_bytes(&exec, transmute([]byte)string("/srv"))
	pty := w()
	append(&pty, 0, 24, 0, 80)
	zsp.write_bytes(&pty, transmute([]byte)string("xterm-256color"))
	strs(&pty)
	strs(&pty, "COLORTERM=truecolor")
	zsp.write_bytes(&pty, nil)
	get := w()
	zsp.write_bytes(&get, transmute([]byte)string("docs/report.pdf"))
	zsp.write_varint(&get, 3 << 20)
	zsp.write_bytes(&get, {0xaa, 0xbb, 0xcc})
	put := w()
	zsp.write_bytes(&put, transmute([]byte)string("docs/new/report.pdf"))
	zsp.write_varint(&put, 2621440)
	zsp.write_varint(&put, 1700000000123)
	zsp.write_bytes(&put, {1, 2, 3, 4})
	append(&put, 3)
	list := w()
	zsp.write_bytes(&list, transmute([]byte)string("docs/sub"))
	entry := w()
	append(&entry, 1)
	zsp.write_bytes(&entry, transmute([]byte)string("a.txt"))
	zsp.write_varint(&entry, 1234)
	zsp.write_varint(&entry, 1700000000000)
	listed := w()
	append(&listed, 0, 1, 3, 2, 3)
	zsp.write_bytes(&listed, transmute([]byte)string("docs"))
	append(&listed, 3, 0, 22)
	zsp.write_bytes(&listed, nil)
	zsp.write_bytes(&listed, transmute([]byte)string("ssh"))
	exit := w()
	append(&exit, 3)
	zsp.write_varint(&exit, 1)
	append(&exit, 0)
	killed := w()
	append(&killed, 3)
	zsp.write_varint(&killed, 0)
	append(&killed, 9)
	got := w()
	append(&got, 0)
	zsp.write_varint(&got, 2621440)
	zsp.write_varint(&got, 1700000000123)
	zsp.write_bytes(&got, {0xaa, 0xbb, 0xcc})
	zsp.write_varint(&got, 1 << 20)
	from := w()
	append(&from, 0)
	zsp.write_varint(&from, 2 << 20)
	denied := w()
	append(&denied, 1)
	append(&denied, "not shared with you")
	messages := []Message {
		{"zsp.tcp to port 22 of 127.0.0.1", {0, 22, '1', '2', '7', '.', '0', '.', '0', '.', '1'}},
		{"zsp.exec ls -l /tmp, LANG=C and without HOME, in /srv", exec[:]},
		{"zsp.pty 24 rows by 80, xterm-256color, the user's shell, COLORTERM=truecolor", pty[:]},
		{"zsp.get docs/report.pdf from 3 MiB, as it was", get[:]},
		{"zsp.put docs/new/report.pdf of 2.5 MiB, replacing, making folders", put[:]},
		{"zsp.list docs/sub", list[:]},
		{"an entry: a.txt, 1234 bytes", entry[:]},
		{"zsp.services: terminals and commands, docs to read and write, port 22 as ssh", listed[:]},
		{"status: ok", {0}},
		{"status: denied, with a reason", denied[:]},
		{"zsp.get answered: 2.5 MiB, from 1 MiB", got[:]},
		{"zsp.put answered: from 2 MiB", from[:]},
		{"input: ls", {0, 'l', 's', '\n'}},
		{"signal: interrupt", {1, 2}},
		{"resize: 50 rows by 132", {2, 0, 50, 0, 132}},
		{"output: hi", {1, 'h', 'i'}},
		{"errors: no", {2, 'n', 'o'}},
		{"exited 1", exit[:]},
		{"killed by 9", killed[:]},
		{"a chunk's hash follows its bytes", {2, 0x5e, 0x88, 0x48, 0x98, 0xda, 0x28, 0x04, 0x71, 0x51, 0xd0, 0xe5, 0x6f, 0x8d, 0xc6, 0x29, 0x27, 0x73, 0x60, 0x3d, 0x0d, 0x6a, 0xab, 0xbd, 0xd6, 0x2a, 0x11, 0xef, 0x72, 0x1d, 0x15, 0x42, 0xd8}},
		{"the end of a file sent whole, with its hash", {3, 0, 0x5e, 0x88, 0x48, 0x98, 0xda, 0x28, 0x04, 0x71, 0x51, 0xd0, 0xe5, 0x6f, 0x8d, 0xc6, 0x29, 0x27, 0x73, 0x60, 0x3d, 0x0d, 0x6a, 0xab, 0xbd, 0xd6, 0x2a, 0x11, 0xef, 0x72, 0x1d, 0x15, 0x42, 0xd8}},
	}
	fmt.println(`  "services": [`)
	for m, i in messages {
		fmt.printfln(`    {{"message": "%s", "bytes": "%s"}}%s`, m.name, h(m.bytes), "," if i + 1 < len(messages) else "")
	}
	fmt.println("  ],")
}
