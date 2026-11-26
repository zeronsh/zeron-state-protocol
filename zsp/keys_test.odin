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
	testing.expect(t, keyring_scope(&a, shown) != nil) // an owner's rights do not end
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

// A scope that is made is had by all who rule, so that they go on ruling.
@(test)
those_who_rule_have_every_scope :: proc(t: ^testing.T) {
	root: Key32
	root[0] = 9
	k, a: Keyring
	one, two: Key32
	one[5], two[5] = 1, 2
	keyring_init(&k, one)
	keyring_init(&a, two)
	defer keyring_destroy(&k)
	defer keyring_destroy(&a)
	none: Roster
	d := draft_from(&none, 100)
	home := draft_scope(&d)
	draft_grant(&d, k.device, k.signer, home, {.Read, .Write}).owner = true
	draft_grant(&d, a.device, a.signer, home, {.Read, .Write}).admin = true
	space := ed25519_public(root)
	first, ok := roster_sign(&k, root, &d, context.temp_allocator)
	testing.expect(t, ok)
	r, sound := roster_parse(first, space)
	testing.expect(t, sound && roster_unwrap(&k, &r))
	d = draft_from(&r, 200)
	_ = draft_scope(&d)
	second, again := roster_sign(&k, root, &d, context.temp_allocator)
	testing.expect(t, again)
	roster_destroy(&r)
	r, sound = roster_parse(second, space)
	testing.expect(t, sound && roster_unwrap(&a, &r))
	d = draft_from(&r, 300)
	_, signed := roster_sign(&a, nil, &d, context.temp_allocator)
	testing.expect(t, signed)
	roster_destroy(&r)
}

// A roster is sent whole, so one that could not be is none.
@(test)
roster_names :: proc(t: ^testing.T) {
	root, space := test_root()
	a, b, c := test_keyring(), test_keyring(), test_keyring()
	defer keyring_destroy(&a)
	defer keyring_destroy(&b)
	defer keyring_destroy(&c)
	none: Roster
	d := draft_from(&none, 100)
	home := draft_scope(&d)
	draft_grant(&d, a.device, a.signer, home, {.Write}).owner = true
	draft_grant(&d, b.device, b.signer, home, {.Write})
	draft_grant(&d, c.device, c.signer, home, {.Write})

	// A roster that names nobody is what it always was, byte for byte.
	plain, signed := roster_sign(&a, root, &d, context.temp_allocator)
	testing.expect(t, signed && string(plain[:6]) == "zsp-r1")

	testing.expect(t, draft_name(&d, b.device, "desk-top"))
	testing.expect(t, draft_name(&d, c.device, "laptop"))
	testing.expect(t, !draft_name(&d, a.device, "laptop")) // another's, while it is in force
	for bad in ([]string{"", "id", "Laptop", "-x", "x-", "a.b", "a b", "\x00", "0123456789012345678901234567890123456789012345678901234567890123"}) {
		testing.expectf(t, !draft_name(&d, a.device, bad) || bad == "", "%q is not a name", bad)
	}
	named, ok := roster_sign(&a, root, &d, context.temp_allocator)
	testing.expect(t, ok && string(named[:6]) == "zsp-r2")
	serial, claimed := roster_claims(named, space)
	testing.expect(t, claimed && serial > 0)
	r, sound := roster_parse(named, space)
	defer roster_destroy(&r)
	testing.expect(t, sound)
	testing.expect_value(t, string(roster_member(&r, b.device).hostname), "desk-top")
	testing.expect_value(t, string(roster_member(&r, c.device).hostname), "laptop")
	testing.expect_value(t, string(roster_member(&r, a.device).hostname), "")
	testing.expect(t, roster_named(&r, "laptop") == roster_member(&r, c.device))
	testing.expect(t, roster_named(&r, "nobody") == nil)

	// Nobody can be named so as to be taken for another, nor by anything a resolver would read otherwise.
	twice := draft_from(&r, 200)
	for &m in twice.members {
		if m.device == a.device {
			m.hostname = transmute([]byte)string("laptop")
		}
	}
	bytes, _ := roster_sign(&a, root, &twice, context.temp_allocator)
	_, parsed := roster_parse(bytes, space)
	testing.expect(t, !parsed)
	upper := draft_from(&r, 200)
	for &m in upper.members {
		if m.device == a.device {
			m.hostname = transmute([]byte)string("Ann")
		}
	}
	bytes, _ = roster_sign(&a, root, &upper, context.temp_allocator)
	_, parsed = roster_parse(bytes, space)
	testing.expect(t, !parsed)

	// A name is let go with its device's last grant, and may then be given to another.
	gone := draft_from(&r, 300)
	draft_revoke(&gone, c.device)
	testing.expect(t, draft_name(&gone, a.device, "laptop"))
	again, _ := roster_sign(&a, root, &gone, context.temp_allocator)
	r2, fine := roster_parse(again, space)
	defer roster_destroy(&r2)
	testing.expect(t, fine)
	testing.expect(t, roster_named(&r2, "laptop") == roster_member(&r2, a.device))
	testing.expect_value(t, string(roster_member(&r2, c.device).hostname), "")
	testing.expect(t, draft_name(&gone, a.device, "")) // and none at all
}

@(test)
rosters_fit_in_a_frame :: proc(t: ^testing.T) {
	secret, root: Key32
	secret[0], root[0] = 1, 2
	k: Keyring
	keyring_init(&k, secret)
	defer keyring_destroy(&k)
	none: Roster
	d := draft_from(&none, 100)
	m := draft_grant(&d, k.device, k.signer, draft_scope(&d), {.Read, .Write})
	m.owner = true
	m.subject = make([]byte, MAX_ROSTER, context.temp_allocator)
	_, big := roster_sign(&k, root, &d, context.temp_allocator)
	testing.expect(t, !big)
	m.subject = m.subject[:MAX_ROSTER - 4096]
	bytes, ok := roster_sign(&k, root, &d, context.temp_allocator)
	testing.expect(t, ok)
	r, sound := roster_parse(bytes, ed25519_public(root))
	testing.expect(t, sound)
	roster_destroy(&r)
	_, sound = roster_parse(make([]byte, MAX_ROSTER + 1, context.temp_allocator), ed25519_public(root))
	testing.expect(t, !sound)
}
