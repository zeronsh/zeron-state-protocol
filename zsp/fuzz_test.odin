#+build !js
package zsp

import "core:crypto/ed25519"
import "core:math/rand"
import "core:testing"

// Whatever a peer, a client or a disk may say, nothing here may crash, hang or corrupt.

FUZZ :: #config(ZSP_FUZZ, 12)

@(private)
mangle :: proc(b: []byte) {
	many := 1 + rand.int_max(4)
	for _ in 0 ..< many {
		if len(b) > 0 {
			b[rand.int_max(len(b))] = byte(rand.uint32())
		}
	}
}

// Real conversations with bytes changed in flight, within frames and across them.
@(test)
sessions_survive_noise :: proc(t: ^testing.T) {
	for seed in 0 ..< FUZZ {
		state := seeded(u64(seed) + 7000)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 2, partial = 1, relays = 1, ring = 16)
		for i in 0 ..< 3 {
			sim_link(&s, i, 3)
		}
		sim_link(&s, 0, 1)
		ui := sim_client(&s, s.nodes[1])
		for _ in 0 ..< 60 {
			x := rand.choice(s.nodes[:])
			if !x.relay {
				sim_write(&s, x)
			}
			for l in s.links {
				for pair in ([][2]^Session{{l.a, l.b}, {l.b, l.a}}) {
					out := session_output(pair[0])
					copied := make([]byte, len(out), context.temp_allocator)
					copy(copied, out)
					session_sent(pair[0], len(out))
					if rand.int_max(6) == 0 {
						mangle(copied)
					}
					session_input(pair[1], copied)
				}
			}
			// And a client that says anything at all.
			junk: [dynamic]byte
			at := frame_begin(&junk, Message(3 + rand.int_max(14)))
			n := rand.int_max(80)
			for _ in 0 ..< n {
				append(&junk, byte(rand.uint32()) & (0xff if rand.int_max(2) == 0 else 3))
			}
			frame_end(&junk, at)
			session_input(ui, junk[:])
			delete(junk)
			if ui.closing {
				session_close(ui)
				ui = sim_client(&s, s.nodes[1])
			}
			session_sent(ui, len(session_output(ui)))
			free_all(context.temp_allocator)
		}
		for x in s.nodes {
			check_shelf(t, &x.node.store)
		}
		session_close(ui)
		sim_destroy(&s)
		free_all(context.temp_allocator)
		if testing.failed(t) {
			return
		}
	}
}

@(test)
parsers_survive_noise :: proc(t: ^testing.T) {
	state := seeded(77)
	context.random_generator = rand.default_random_generator(&state)
	root, space := test_root()
	k := test_keyring()
	defer keyring_destroy(&k)
	none: Roster
	d := draft_from(&none, 100)
	draft_grant(&d, k.device, k.signer, draft_scope(&d), {.Write}).owner = true
	good, _ := roster_sign(&k, root, &d)
	defer delete(good)
	for _ in 0 ..< FUZZ * 40 {
		// Rosters whose signature holds and whose content does not.
		b := make([]byte, len(good), context.temp_allocator)
		copy(b, good)
		mangle(b[38:len(b) - 64])
		fake := resign(b, root)
		if r, ok := roster_parse(fake, space); ok {
			other := k
			other.scopes = nil
			_ = roster_unwrap(&other, &r)
			keyring_clear(&other)
			delete(other.scopes)
			roster_destroy(&r)
		}
		// Text of any kind.
		text: Text
		for _ in 0 ..< 6 {
			body := make([]byte, 8 + rand.int_max(40), context.temp_allocator)
			for &x in body {
				x = byte(rand.uint32()) & (0xff if rand.int_max(3) == 0 else 3)
			}
			c := Cell{{1 << 32, 1}, DATA, Kind(3 + rand.int_max(3)), {u64(1 + rand.int_max(9)), 1 + rand.uint64() % 3}, body}
			if rand.int_max(3) == 0 {
				text_live(&text, rand.uint64() % 4, rand.int_max(4), body)
			} else if cell_valid(&c) {
				text_apply(&text, &c)
			}
		}
		n := text_len(&text)
		text_insert(&text, rand.int_max(n + 1), {'x'}, 99)
		testing.expect_value(t, text_len(&text), n + 1)
		text_destroy(&text)
		free_all(context.temp_allocator)
	}
}

// A disk that comes back damaged loses records, not the store.
@(test)
store_survives_damage :: proc(t: ^testing.T) {
	for seed in 0 ..< FUZZ * 3 {
		state := seeded(u64(seed) + 9000)
		context.random_generator = rand.default_random_generator(&state)
		m: Memory_Disk
		s: Store
		testing.expect(t, store_open(&s, memory_disk(&m)))
		records := 0
		for i in 0 ..< 60 {
			c := Cell{{1 << 32, u64(i)}, DATA, .Value, {u64(i) + 1, 1}, {1, 2, 3}}
			records += store_commit(&s, {c})
		}
		store_flush(&s)
		store_close(&s)
		seg := &m.log[0]
		mangle(seg[:])
		testing.expect(t, store_open(&s, memory_disk(&m)))
		check_shelf(t, &s)
		// Each changed byte costs at most the record it fell in.
		testing.expect(t, census(&s).cells.count >= records - 4)
		c := random_cell(40, 1000)
		store_commit(&s, {c})
		store_flush(&s)
		want := census(&s)
		store_close(&s)
		testing.expect(t, store_open(&s, memory_disk(&m)))
		testing.expect_value(t, census(&s), want)
		store_close(&s)
		memory_disk_destroy(&m)
		free_all(context.temp_allocator)
	}
}

@(private)
resign :: proc(b: []byte, root: Key32) -> []byte {
	root := root
	sk: ed25519.Private_Key
	_ = ed25519.private_key_set_bytes(&sk, root[:])
	ed25519.sign(&sk, b[:len(b) - 64], b[len(b) - 64:])
	return b
}
