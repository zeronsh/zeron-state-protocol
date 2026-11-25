/*
Prints vectors.json: every deterministic thing two implementations must agree on. `./x test` checks that
the file is current and that the other implementations agree with it.
*/
package vectors

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
	append(&k.scopes, sk)
	r: zsp.Roster
	r.scopes = {{3, {}, 1}, {4, {.Signed}, 1}}
	signed := zsp.Scope_Keys{scope = 4, list_key = zsp.derive(key_of(90), "zsp-list")}
	append(&signed.epochs, key_of(90))
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
	}
	for &c, i in all {
		sealing := key_of(50) if i < 5 else key_of(90)
		open := c
		w: [dynamic]byte
		zsp.write_cell(&w, &open, false)
		_ = zsp.cell_seal(&k, &r, &c)
		s: [dynamic]byte
		zsp.write_cell(&s, &c, false)
		print := zsp.cell_print(&c)
		pb: [16]byte
		zsp.put_u64(pb[:], print[0])
		zsp.put_u64(pb[8:], print[1])
		fmt.printfln(`    {{"key": "%s", "open": "%s", "sealed": "%s", "print": "%s"}}%s`, h(sealing[:]), h(w[:]), h(s[:]), h(pb[:]), "," if i + 1 < len(all) else "")
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
	first, _ := zsp.handshake_start(&hs, i, zsp.x25519_public(r), space, ie)
	second, _, _ := zsp.handshake_answer(r, space, first[:], re)
	c, _ := zsp.handshake_finish(&hs, second[:], zsp.x25519_public(r))
	fmt.printfln(
		`  "handshake": {{"initiator": "%s", "responder": "%s", "initiator_ephemeral": "%s", "responder_ephemeral": "%s", "space": "%s", "first": "%s", "second": "%s", "send": "%s", "recv": "%s"}},`,
		h(i[:]), h(r[:]), h(ie[:]), h(re[:]), h(space[:]), h(first[:]), h(second[:]), h(c.send[:]), h(c.recv[:]),
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
