#+build !js
package zsp

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/noise"
import "core:crypto/ed25519"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:time"

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

// A roster is zsp-r1 and nothing else, and its rights are those §3 names: another version, or a right nobody knows,
// is refused however soundly it is signed.
@(test)
rosters_are_what_they_were :: proc(t: ^testing.T) {
	root, space := test_root()
	a, b := test_keyring(), test_keyring()
	defer keyring_destroy(&a)
	defer keyring_destroy(&b)
	none: Roster
	d := draft_from(&none, 100)
	home := draft_scope(&d)
	draft_grant(&d, a.device, a.signer, home, {.Write}).owner = true
	draft_grant(&d, b.device, b.signer, home, {.Write, .Call, .Vouch})
	plain, signed := roster_sign(&a, root, &d, context.temp_allocator)
	testing.expect(t, signed && string(plain[:6]) == "zsp-r1")
	r, sound := roster_parse(plain, space)
	testing.expect(t, sound)
	roster_destroy(&r)

	// The same, signed afresh by the space, under another version.
	resign :: proc(root: Key32, bytes: []byte) -> []byte {
		root := root
		sk: ed25519.Private_Key
		_ = ed25519.private_key_set_bytes(&sk, root[:])
		ed25519.sign(&sk, bytes[:len(bytes) - 64], bytes[len(bytes) - 64:])
		return bytes
	}
	other := slice.clone(plain, context.temp_allocator)
	copy(other, "zsp-r2")
	_, sound = roster_parse(resign(root, other), space)
	testing.expect(t, !sound)
	copy(other, "zsp-r1")
	r, sound = roster_parse(resign(root, other), space)
	testing.expect(t, sound) // and so it is the version alone that was refused
	roster_destroy(&r)

	for bit in ([]u8{16, 32, 64, 128}) {
		odd := draft_from(&none, 100)
		scope := draft_scope(&odd)
		draft_grant(&odd, a.device, a.signer, scope, {.Write}).owner = true
		draft_grant(&odd, b.device, b.signer, scope, transmute(Rights)(transmute(u8)Rights{.Read, .Write} | bit))
		bytes, ok := roster_sign(&a, root, &odd, context.temp_allocator)
		testing.expect(t, ok)
		_, sound = roster_parse(bytes, space)
		testing.expectf(t, !sound, "a grant with right %d is refused", bit)
	}
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

// Points of small order share nothing with any secret, whichever their top bit; and no roster names one where a secret
// is to be shared, as its ephemeral key or a device, for nothing could be wrapped for it, nor any roster signed again.
@(test)
small_order_keys_share_nothing :: proc(t: ^testing.T) {
	near: [3]Key32 // p - 1, p and p + 1
	for &k, i in near {
		k[0] = 0xec + byte(i)
		slice.fill(k[1:31], 0xff)
		k[31] = 0x7f
	}
	small := [?]Key32 {
		{},
		{0 = 1},
		near[0],
		near[1],
		near[2],
		{0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f, 0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00},
		{0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83, 0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57},
	}
	secrets := [3]Keyring{test_keyring(), test_keyring(), test_keyring()}
	defer for &k in secrets {
		keyring_destroy(&k)
	}
	for k in small {
		for top in ([]byte{0, 0x80}) {
			k := k
			k[31] |= top
			testing.expect(t, !x25519_sound(k))
			for &s in secrets {
				_, shared := x25519_shared(s.secret, k)
				testing.expect(t, !shared)
			}
		}
	}
	// And whatever else is of one byte, or one short of these, shares something.
	for first in 0 ..< 256 {
		for k in ([]Key32{{}, near[0]}) {
			k := k
			k[0] = byte(first)
			_, shared := x25519_shared(secrets[0].secret, k)
			testing.expect_value(t, x25519_sound(k), shared)
		}
	}
	for &s in secrets {
		testing.expect(t, x25519_sound(s.device))
	}

	root, space := test_root()
	a := test_keyring()
	defer keyring_destroy(&a)
	none: Roster
	d := draft_from(&none, 100)
	home := draft_scope(&d)
	draft_grant(&d, a.device, a.signer, home, {.Write}).owner = true
	// One with no grant has nothing wrapped for it, and so the roster can be signed.
	append(&d.members, Member{device = {}, signer = secrets[0].signer})
	bytes, signed := roster_sign(&a, root, &d, context.temp_allocator)
	_, sound := roster_parse(bytes, space)
	testing.expect(t, signed && !sound)
}

// The most made at once through it.
@(private)
Largest :: struct {
	backing: mem.Allocator,
	most:    int,
}

@(private)
largest_allocator :: proc(l: ^Largest) -> mem.Allocator {
	return {proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
			l := (^Largest)(data)
			l.most = max(l.most, size)
			return l.backing.procedure(l.backing.data, mode, size, alignment, old, old_size, loc)
		}, l}
}

// Anyone may bring a roster, made up but for the charter, which is the space's own: until its signature is found to be
// bad, what is made of it is not much larger than it, and nothing is done that takes much longer than reading it.
@(test)
made_up_rosters_cost_little :: proc(t: ^testing.T) {
	root, space := test_root()
	a := test_keyring()
	defer keyring_destroy(&a)
	none: Roster
	d := draft_from(&none, 100)
	draft_grant(&d, a.device, a.signer, draft_scope(&d), {.Write}).owner = true
	genuine, signed := roster_sign(&a, root, &d, context.temp_allocator)
	r, sound := roster_parse(genuine, space)
	testing.expect(t, signed && sound)
	defer roster_destroy(&r)
	Forged :: struct {
		scopes, grants, members, claimed, padding: int,
	}
	forge :: proc(r: ^Roster, f: Forged) -> []byte {
		w := make([dynamic]byte, context.temp_allocator)
		append(&w, ROSTER_MAGIC)
		append(&w, ..r.space[:])
		write_bytes(&w, r.charter)
		write_varint(&w, r.serial + 1)
		write_varint(&w, u64(f.scopes))
		for i in 1 ..= f.scopes {
			write_varint(&w, u64(i))
			append(&w, 0)
			write_varint(&w, 1)
			commit: Key32
			crypto.rand_bytes(commit[:])
			append(&w, ..commit[:])
		}
		write_varint(&w, u64(f.claimed))
		for i in 0 ..< f.members {
			keys: [64]byte
			crypto.rand_bytes(keys[:])
			append(&w, ..keys[:])
			write_bytes(&w, nil)
			grants := f.grants if i == 0 else 0
			write_varint(&w, u64(grants))
			for g in 1 ..= grants {
				write_varint(&w, u64(g))
				append(&w, transmute(u8)Rights{.Read, .Write})
				write_varint(&w, 0)
			}
		}
		for _ in 0 ..< f.padding {
			append(&w, 0)
		}
		write_varint(&w, 0)
		eph: Key32
		crypto.rand_bytes(eph[:])
		append(&w, ..eph[:])
		write_varint(&w, 0)
		resize(&w, len(w) + 64) // no signature
		return w[:]
	}
	// So many members said to be there, as there are bytes.
	big := forge(&r, {claimed = 200_000, padding = 200_000})
	l := Largest{backing = context.allocator}
	{
		context.allocator = largest_allocator(&l)
		_, sound = roster_parse(big, space)
	}
	testing.expect(t, !sound)
	testing.expectf(t, l.most <= 2 * len(big), "made %d bytes at once of a roster of %d", l.most, len(big))
	// A great many members, and a great many scopes each with a grant.
	for f in ([]Forged{{members = 60_000, claimed = 60_000}, {scopes = 60_000, grants = 60_000, members = 1, claimed = 1}}) {
		forged := forge(&r, f)
		began := time.tick_now()
		_, sound = roster_parse(forged, space)
		took := time.tick_since(began)
		testing.expect(t, !sound)
		testing.expectf(t, took < 2 * time.Second, "a made-up roster of %d bytes took %v", len(forged), took)
	}
}

// Taking Call away, or Vouch where cells are nobody's, ends no grant, and the roster that does so extends the one
// before: nothing held is looked at again as if the one had lost to another. What does end a grant is not so taken.
@(test)
call_is_taken_away_in_place :: proc(t: ^testing.T) {
	root, space := test_root()
	a, b := test_keyring(), test_keyring()
	defer keyring_destroy(&a)
	defer keyring_destroy(&b)
	none: Roster
	d := draft_from(&none, 100)
	home := draft_scope(&d)
	shown := draft_scope(&d, {.Signed})
	draft_grant(&d, a.device, a.signer, home, {.Write}).owner = true
	draft_grant(&d, b.device, b.signer, home, {.Write, .Call, .Vouch})
	draft_grant(&d, b.device, b.signer, shown, {.Write, .Call, .Vouch})
	r1 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r1)
	d = draft_from(&r1, 200)
	draft_grant(&d, b.device, b.signer, home, {.Write})
	draft_grant(&d, b.device, b.signer, shown, {.Write, .Vouch})
	r2 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r2)
	testing.expect_value(t, len(roster_member(&r2, b.device).grants), len(roster_member(&r1, b.device).grants))
	testing.expect(t, member_rights(roster_member(&r2, b.device), home) == {.Read, .Write})
	testing.expect(t, roster_extends(&r1, &r2))
	// Vouch in a signed scope ends the grant, and that extends it too.
	d = draft_from(&r2, 300)
	draft_grant(&d, b.device, b.signer, shown, {.Write})
	r3 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r3)
	testing.expect(t, roster_extends(&r2, &r3) && len(roster_member(&r3, b.device).grants) == 3)
	// But not one that took Write, or Vouch where it is signed, away in place, as no draft does.
	for scope in ([]Scope{home, shown}) {
		d = draft_from(&r2, 300)
		for &m in d.members {
			for &g in m.grants {
				if m.device == b.device && g.scope == scope {
					g.rights -= {.Write} if scope == home else {.Vouch}
				}
			}
		}
		bytes, signed := roster_sign(&a, root, &d, context.temp_allocator)
		r, sound := roster_parse(bytes, space)
		if scope == home {
			testing.expect(t, signed && !sound) // and one who may read and not write where it is not signed is none
		} else {
			testing.expect(t, signed && sound && !roster_extends(&r2, &r))
			roster_destroy(&r)
		}
	}
}
