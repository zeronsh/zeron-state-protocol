#+build !js
package zsp

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/noise"
import "core:crypto/ed25519"
import "core:testing"

@(private)
test_keyring :: proc() -> (k: Keyring) {
	secret: Key32
	crypto.rand_bytes(secret[:])
	keyring_init(&k, secret)
	return
}

@(private)
test_root :: proc() -> (root, space: Key32) {
	crypto.rand_bytes(root[:])
	sk: ed25519.Private_Key
	assert(ed25519.private_key_set_bytes(&sk, root[:]))
	ed25519.private_key_public_bytes(&sk, space[:])
	return
}

@(private)
test_cell :: proc(scope: Scope) -> Cell {
	body := make([]byte, 30, context.temp_allocator)
	put_u64(body, u64(scope) << 32)
	put_u64(body[8:], 9)
	return {{u64(scope) << 32, 2}, PLACE, .Place, {3, 4}, body}
}

@(private)
test_publish :: proc(t: ^testing.T, k: ^Keyring, root, space: Key32, d: ^Draft) -> (r: Roster) {
	bytes, signed := roster_sign(k, root, d)
	defer delete(bytes)
	testing.expect(t, signed)
	ok: bool
	r, ok = roster_parse(bytes, space)
	testing.expect(t, ok)
	if len(bytes) > 0 {
		bytes[50] ~= 1
		_, forged := roster_parse(bytes, space)
		testing.expect(t, !forged)
	}
	return
}

@(test)
roster_grants_and_revokes :: proc(t: ^testing.T) {
	root, space := test_root()
	a, b, c := test_keyring(), test_keyring(), test_keyring()
	defer keyring_destroy(&a)
	defer keyring_destroy(&b)
	defer keyring_destroy(&c)

	none: Roster
	d := draft_from(&none, 100)
	home := draft_scope(&d)
	shown := draft_scope(&d, {.Signed})
	draft_grant(&d, a.device, a.signer, home, {.Write}).owner = true
	draft_grant(&d, b.device, b.signer, home, {.Write})
	draft_grant(&d, a.device, a.signer, shown, {.Write})
	draft_grant(&d, c.device, c.signer, shown, {.Read}).subject = transmute([]byte)string("user:c")
	r1 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r1)
	testing.expect(t, roster_unwrap(&a, &r1) && roster_unwrap(&b, &r1) && roster_unwrap(&c, &r1))
	testing.expect(t, a.root == root && b.root == nil && c.root == nil)
	testing.expect(t, keyring_scope(&b, shown) == nil && keyring_scope(&c, home) == nil)
	testing.expect_value(t, string(roster_member(&r1, c.device).subject), "user:c")
	testing.expect_value(t, list_tag(keyring_scope(&a, home), "x"), list_tag(keyring_scope(&b, home), "x"))
	testing.expect_value(t, list_scope(list_tag(keyring_scope(&a, home), "x")), home)

	// A read-only member of an unsigned scope would be a lie, and no roster may tell it.
	bad := draft_from(&r1, 100)
	draft_grant(&bad, c.device, c.signer, home, {.Read})
	bytes, signed := roster_sign(&a, root, &bad, context.temp_allocator)
	_, parsed := roster_parse(bytes, space)
	testing.expect(t, signed && !parsed)

	// Sealing: only the granted can open, and nothing in the clear can be altered.
	cell := test_cell(home)
	open := string(cell.body)
	testing.expect(t, cell_seal(&a, &r1, &cell))
	got := cell
	testing.expect(t, cell_open(&b, &r1, &got) && string(got.body) == open)
	got = cell
	testing.expect(t, !cell_open(&c, &r1, &got))
	cell.body[20] ~= 1
	got = cell
	testing.expect(t, !cell_open(&b, &r1, &got))
	cell.body[20] ~= 1

	// Signing: a reader can open, and cannot write, even with a colluding relay.
	post := test_cell(shown)
	testing.expect(t, cell_seal(&a, &r1, &post) && cell_authentic(&r1, &post))
	got = post
	testing.expect(t, cell_open(&c, &r1, &got) && string(got.body) == string(test_cell(shown).body))
	forged := test_cell(shown)
	testing.expect(t, cell_seal(&c, &r1, &forged) && !cell_authentic(&r1, &forged))
	post.stamp.time += 1
	testing.expect(t, !cell_authentic(&r1, &post))
	post.stamp.time -= 1

	// Revocation: b learns nothing sealed afterwards; a still reads the past.
	d = draft_from(&r1, 100)
	draft_revoke(&d, b.device)
	draft_revoke(&d, a.device, shown)
	r2 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r2)
	testing.expect(t, roster_unwrap(&a, &r2) && !roster_unwrap(&b, &r2))
	testing.expect_value(t, len(keyring_scope(&a, home).epochs), 2)
	got = cell
	testing.expect(t, cell_open(&a, &r2, &got))
	later := test_cell(home)
	later.stamp.time = 200
	testing.expect(t, cell_seal(&a, &r2, &later))
	testing.expect(t, !cell_open(&b, &r2, &later))
	// What a wrote before losing the right still stands, and nothing after does.
	testing.expect(t, cell_authentic(&r2, &post))
	testing.expect(t, keyring_scope(&a, shown) == nil)
	testing.expect(t, roster_unwrap(&c, &r2))
	got = post
	testing.expect(t, cell_open(&c, &r2, &got))
}

@(test)
channel_round_trip :: proc(t: ^testing.T) {
	_, space := test_root()
	a, b := test_keyring(), test_keyring()
	defer keyring_destroy(&a)
	defer keyring_destroy(&b)
	h: Handshake
	first, _ := handshake_start(&h, a.secret, b.device, space)
	second, cb, ok := handshake_answer(b.secret, space, first[:])
	testing.expect(t, ok && cb.peer == a.device)
	ca, done := handshake_finish(&h, second[:], b.device)
	testing.expect(t, done)
	for i in 0 ..< 3 {
		w: [dynamic]byte
		defer delete(w)
		append(&w, byte(i), 9, 9)
		msg: [dynamic]byte
		defer delete(msg)
		channel_seal(&ca, &msg, w[:])
		plain, opened := channel_open(&cb, msg[:])
		testing.expect(t, opened && string(plain) == string(w[:]))
	}
	_, _, wrong := handshake_answer(b.secret, a.device, first[:])
	testing.expect(t, !wrong)
}

// Byte for byte what core:crypto/noise says, payload and all.
@(test)
handshake_is_noise :: proc(t: ^testing.T) {
	i, r, ie, re, space: Key32
	for n in 0 ..< 32 {
		i[n], r[n], ie[n], re[n], space[n] = byte(n + 1), byte(n * 3 + 5), byte(n * 7 + 2), byte(n * 11 + 9), byte(n)
	}
	h: Handshake
	first, ok := handshake_start(&h, i, x25519_public(r), space, ie, 0x0102030405060708)
	second, answerer, answered := handshake_answer(r, space, first[:], re)
	c, done := handshake_finish(&h, second[:], x25519_public(r))
	testing.expect(t, ok && answered && done)
	testing.expect_value(t, answerer.began, 0x0102030405060708)

	s, e: ecdh.Private_Key
	rs: ecdh.Public_Key
	public := x25519_public(r)
	testing.expect(t, ecdh.private_key_set_bytes(&s, .X25519, i[:]) && ecdh.private_key_set_bytes(&e, .X25519, ie[:]))
	testing.expect(t, ecdh.public_key_set_bytes(&rs, .X25519, public[:]))
	prologue := make([dynamic]byte, context.temp_allocator)
	append(&prologue, "zsp-1")
	append(&prologue, ..space[:])
	state: noise.Handshake_State
	testing.expect_value(t, noise.handshake_init(&state, true, prologue[:], &s, &rs, NOISE, nil, &e), noise.Status.Ok)
	payload := [8]byte{1, 2, 3, 4, 5, 6, 7, 8}
	theirs, _ := noise.handshake_write_message(&state, payload[:], nil, context.temp_allocator)
	testing.expect(t, string(theirs) == string(first[:]))
	_, status := noise.handshake_read_message(&state, second[:], nil, context.temp_allocator)
	testing.expect_value(t, status, noise.Status.Handshake_Complete)
	cs: noise.Cipher_States
	testing.expect_value(t, noise.handshake_split(&state, &cs), noise.Status.Ok)
	wrote, _ := noise.seal_message(&cs, nil, payload[:], nil, context.temp_allocator)
	sealed := make([dynamic]byte, context.temp_allocator)
	channel_seal(&c, &sealed, payload[:])
	testing.expect(t, string(wrote) == string(sealed[:]))
	plain, opened := channel_open(&answerer, sealed[:])
	testing.expect(t, opened && string(plain) == string(payload[:]))
}
