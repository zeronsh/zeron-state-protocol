package zsp

import "base:runtime"
import "core:crypto"
import "core:crypto/ed25519"
import "core:hash"
import "core:slice"

// Who may do what, as a document.
//
// A space is named by an Ed25519 public key. Whoever holds the private one owns it, for good: nothing can
// take back a name. Owners sign a charter, which says who are its admins; and any admin may sign the roster,
// which lists scopes and the members granted rights in them, and carries each scope's sealing key wrapped
// for each reader. An admin can be unmade like any other member, by a new charter. A relay can verify and
// enforce it all while unwrapping nothing.
//
// The protocol proves that a peer holds a key and enforces what the roster grants that key. Deciding
// that a key belongs to some person, or that a person may use some relay, is authentication, and is
// the host's: see Host.authenticate.

MAX_ROSTER :: MAX_FRAME - 64 // bytes: it is sent whole

Right :: enum u8 {
	Read,
	Write, // implies Read
	Call, // make and answer calls; needs neither, yet comes with Read, as every grant does
	Vouch, // be believed about whom it writes and calls for: its host knows its users, and is trusted to
}
Rights :: distinct bit_set[Right;u8]
RIGHTS_ALL :: Rights{.Read, .Write, .Call, .Vouch} // a grant with any other bit is invalid

ROSTER_MAGIC :: "zsp-r1"

Grant :: struct {
	scope:  Scope,
	rights: Rights,
	until:  u64, // when revoked, the stamp time past which the member's cells are refused; else zero
}

Member :: struct {
	device:  Key32, // X25519: proves itself to peers, unwraps keys
	signer:  Key32, // Ed25519: signs cells in signed scopes
	owner:   bool, // holds the space's signing key, and keeps it
	admin:   bool, // may sign rosters
	subject: []byte, // whom the host says this is; opaque here
	// In the order given. At most one per scope is in force; the rest say what was once allowed, and so
	// what was rightly written.
	grants:  []Grant,
}

Scope_Flag :: enum u8 {
	// Every cell is signed by its writer. Only such scopes may have members who read but do not
	// write: elsewhere, holding the sealing key is what it means to be a writer.
	Signed,
}
Scope_Flags :: distinct bit_set[Scope_Flag;u8]

Scope_Info :: struct {
	id:    Scope,
	flags: Scope_Flags,
	epoch: u32,
	// When each earlier epoch ended, as stamp times. A key that was given up cannot seal what is later. One that
	// ended no later than the epoch before is void: nothing sealed under it is taken.
	closed: []u64, // owned
	commits: []Key32, // owned; to each epoch's key, so that nobody can be handed another unawares
}

// Whether an epoch, counted from one, is void.
@(require_results)
epoch_void :: proc(info: ^Scope_Info, epoch: int) -> bool {
	if epoch > len(info.closed) {
		return false
	}
	return info.closed[epoch - 1] <= (info.closed[epoch - 2] if epoch > 1 else 0)
}

Relay :: struct {
	key: Key32,
	url: string,
}

// In the charter, so that no admin can leave one out.
Owner :: struct {
	device: Key32,
	signer: Key32,
	wrap:   []byte,
}

Roster :: struct {
	bytes:   []byte, // owned; subjects and urls point into it
	space:   Key32,
	serial:  u64, // the higher wins: see serial_next
	charter: []byte,
	term:    u64, // the charter's
	owners:  []Owner, // owned
	admins:  []Key32, // owned; signers
	scopes:  []Scope_Info, // owned, ascending
	// Never shrinks, so that a signed cell's author is an index that stays valid.
	members: []Member, // owned, as are their grants
	relays:  []Relay, // owned
	eph:     Key32,
	wraps:   []byte,
	history: []byte,
}

Keyring :: struct {
	secret: Key32, // this device's X25519 private key
	device: Key32,
	seed:   Key32, // its Ed25519 seed, derived from the secret
	signer: Key32,
	scopes: [dynamic]Scope_Keys,
	before: [dynamic]Scope_Keys, // as they were under the last roster, while what was sealed then is looked over
	root:   Maybe(Key32), // the space's signing seed, on owners' devices
}

Scope_Keys :: struct {
	scope:    Scope,
	list_key: Key32,
	epochs:   [dynamic]Key32, // sealing keys, by epoch - 1; zero where one was never learnt
	ids:      [dynamic]u32, // what cells call each by: see scope_keys_index
}

keyring_init :: proc(k: ^Keyring, secret: Key32) {
	k.secret = secret
	k.device = x25519_public(secret)
	k.seed = derive(secret, "zsp-sign")
	k.signer = ed25519_public(k.seed)
}

keyring_destroy :: proc(k: ^Keyring) {
	keyring_forget(k)
	keyring_clear(k)
	delete(k.scopes)
	crypto.zero_explicit(k, size_of(Keyring))
}

// To be called once the keys are in place.
scope_keys_index :: proc(k: ^Scope_Keys) {
	resize(&k.ids, len(k.epochs))
	for e, i in k.epochs {
		k.ids[i] = key_id(key_commit(e))
	}
}

@(private)
keyring_forget :: proc(k: ^Keyring) {
	old := Keyring{scopes = k.before}
	k.before = {}
	keyring_clear(&old)
	delete(old.scopes)
}

@(private)
keyring_clear :: proc(k: ^Keyring) {
	for &s in k.scopes {
		crypto.zero_explicit(raw_data(s.epochs), len(s.epochs) * size_of(Key32))
		delete(s.epochs)
		delete(s.ids)
	}
	clear(&k.scopes)
}

@(require_results)
keyring_scope :: proc(k: ^Keyring, scope: Scope) -> ^Scope_Keys {
	for &s in k.scopes {
		if s.scope == scope {
			return &s
		}
	}
	return nil
}

@(require_results)
ed25519_public :: proc(seed: Key32) -> (public: Key32) {
	seed := seed
	sk: ed25519.Private_Key
	if ed25519.private_key_set_bytes(&sk, seed[:]) {
		ed25519.private_key_public_bytes(&sk, public[:])
	}
	ed25519.private_key_clear(&sk)
	return
}

@(require_results)
ed25519_verify :: proc(public: Key32, msg, sig: []byte) -> bool {
	public := public
	pk: ed25519.Public_Key
	ed25519.public_key_set_bytes(&pk, public[:]) or_return
	return ed25519.verify(&pk, msg, sig)
}

// The serial a roster claims, unverified: enough to know that it is not news.
@(require_results)
roster_claims :: proc(bytes: []byte, space: Key32) -> (serial: u64, ok: bool) {
	rd := Reader{buf = bytes}
	if string(read_take(&rd, 6)) != ROSTER_MAGIC || read_key32(&rd) != space {
		return
	}
	_ = read_bytes(&rd)
	serial = read_varint(&rd)
	return serial, !rd.bad
}

// What is already known to be genuine in a roster held need not be proven again.
@(require_results)
roster_parse :: proc(bytes: []byte, space: Key32, held: ^Roster = nil) -> (r: Roster, ok: bool) {
	if len(bytes) < 64 || len(bytes) > MAX_ROSTER {
		return
	}
	defer if !ok {
		roster_destroy(&r)
	}
	r.bytes = slice.clone(bytes)
	body, sig := r.bytes[:len(bytes) - 64], r.bytes[len(bytes) - 64:]
	rd := Reader{buf = r.bytes[:len(body)]}
	if string(read_take(&rd, 6)) != ROSTER_MAGIC || read_key32(&rd) != space {
		return
	}
	r.space = space
	charter := read_bytes(&rd)
	charter_parse(&r, charter, held != nil && held.charter != nil && string(held.charter) == string(charter)) or_return
	r.serial = read_varint(&rd)
	if rd.bad || r.serial >> TERM_SHIFT != r.term {
		return
	}
	history, wraps := 0, 0

	// Whoever brings a roster may have made it up. Until its signature is known to be good, nothing is made larger
	// than a few times the bytes that say what it is, and nothing is done that takes more than a look at each part: what
	// compares parts with one another comes after.
	r.scopes = make([]Scope_Info, read_count(&rd, 35))
	last: Scope
	for &s in r.scopes {
		s.id = Scope(read_varint(&rd))
		s.flags = transmute(Scope_Flags)read_u8(&rd)
		epoch := read_varint(&rd)
		// Each epoch has its commitment, and each but the last a time it was closed.
		if rd.bad || s.id <= last || s.id == max(Scope) || epoch == 0 || epoch > u64(len(rd.buf) - rd.pos + 1) / 33 {
			return
		}
		s.epoch = u32(epoch)
		s.closed = make([]u64, s.epoch - 1)
		for &c, i in s.closed {
			c = read_varint(&rd)
			if i > 0 && c < s.closed[i - 1] {
				return
			}
		}
		if int(s.epoch) > (len(rd.buf) - rd.pos) / 32 {
			return
		}
		s.commits = make([]Key32, s.epoch)
		for &c in s.commits {
			c = read_key32(&rd)
		}
		last = s.id
		history += int(s.epoch - 1)
	}
	r.members = make([]Member, read_count(&rd, 66))
	for &m in r.members {
		m.device = read_key32(&rd)
		m.signer = read_key32(&rd)
		// Nothing could be wrapped for it, and no roster be signed again.
		if !x25519_sound(m.device) {
			return
		}
		m.admin = slice.contains(r.admins, m.signer)
		for &o in r.owners {
			if (o.device == m.device) != (o.signer == m.signer) {
				return
			}
			m.owner ||= o.device == m.device
		}
		m.subject = read_bytes(&rd)
		m.grants = make([]Grant, read_count(&rd, 3))
		for &g in m.grants {
			g.scope = Scope(read_varint(&rd))
			bits := read_u8(&rd)
			g.rights = transmute(Rights)bits
			g.until = read_varint(&rd)
			info := roster_scope(&r, g.scope)
			if rd.bad || info == nil || .Read not_in g.rights || bits & ~transmute(u8)RIGHTS_ALL != 0 {
				return
			}
			if .Write not_in g.rights && .Signed not_in info.flags {
				return
			}
			wraps += 1 if g.until == 0 else 0
		}
	}
	r.relays = make([]Relay, read_count(&rd, 33))
	for &l in r.relays {
		l.key = read_key32(&rd)
		l.url = string(read_bytes(&rd))
	}
	// One of small order shares nothing with anyone: no wrap could be made under it, nor opened.
	r.eph = read_key32(&rd)
	if !x25519_sound(r.eph) {
		return
	}
	r.wraps = read_take(&rd, 48 * wraps)
	r.history = read_take(&rd, 48 * history)
	by := read_varint(&rd)
	if !read_done(&rd) || by > u64(len(r.admins)) {
		return
	}
	ok = ed25519_verify(space if by == 0 else r.admins[by - 1], body, sig) && roster_sound(&r)
	return
}

// What a roster must be that compares its parts with one another, each in about the time it takes to sort them.
@(private)
roster_sound :: proc(r: ^Roster) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	less :: proc(a, b: Key32) -> bool {
		a, b := a, b
		return string(a[:]) < string(b[:])
	}
	// No two epochs' keys are called alike.
	for s in r.scopes {
		ids := make([]u32, len(s.commits), context.temp_allocator)
		for c, i in s.commits {
			ids[i] = key_id(c)
		}
		slice.sort(ids)
		for i in 1 ..< len(ids) {
			if ids[i] == ids[i - 1] {
				return false
			}
		}
	}
	// No two members share a device or a signer.
	keys := make([]Key32, len(r.members), context.temp_allocator)
	for which in 0 ..< 2 {
		for m, i in r.members {
			keys[i] = m.device if which == 0 else m.signer
		}
		slice.sort_by(keys, less)
		for i in 1 ..< len(keys) {
			if keys[i] == keys[i - 1] {
				return false
			}
		}
	}
	// A member has at most one grant in force in a scope.
	scopes := make([dynamic]Scope, context.temp_allocator)
	for m in r.members {
		clear(&scopes)
		for g in m.grants {
			if g.until == 0 {
				append(&scopes, g.scope)
			}
		}
		slice.sort(scopes[:])
		for i in 1 ..< len(scopes) {
			if scopes[i] == scopes[i - 1] {
				return false
			}
		}
	}
	// An owner may read and write everywhere, whoever signs: as every grant's scope is there, and is in force only
	// once, it has as many such grants as there are scopes.
	for &o in r.owners {
		m := roster_member(r, o.device)
		if m == nil {
			return false
		}
		everywhere := 0
		for g in m.grants {
			everywhere += 1 if g.until == 0 && g.rights & {.Read, .Write} == {.Read, .Write} else 0
		}
		if everywhere != len(r.scopes) {
			return false
		}
	}
	return true
}

@(private)
charter_parse :: proc(r: ^Roster, bytes: []byte, proven: bool) -> bool {
	if len(bytes) < 64 {
		return false
	}
	body, sig := bytes[:len(bytes) - 64], bytes[len(bytes) - 64:]
	if !proven && !ed25519_verify(r.space, charter_signed(r.space, body), sig) {
		return false
	}
	rd := Reader{buf = body}
	r.charter = bytes
	r.term = read_varint(&rd)
	sound := x25519_sound(read_key32(&rd))
	r.owners = make([]Owner, read_count(&rd, 112))
	for &o in r.owners {
		o.device = read_key32(&rd)
		o.signer = read_key32(&rd)
		o.wrap = read_take(&rd, 48)
		sound &&= x25519_sound(o.device)
	}
	r.admins = make([]Key32, read_count(&rd, 32))
	for &a in r.admins {
		a = read_key32(&rd)
	}
	return read_done(&rd) && r.term > 0 && sound
}

@(private)
charter_signed :: proc(space: Key32, body: []byte) -> []byte {
	space := space
	m := make([dynamic]byte, context.temp_allocator)
	append(&m, "zsp-charter")
	append(&m, ..space[:])
	append(&m, ..body)
	return m[:]
}

TERM_SHIFT :: 44
COUNT_SHIFT :: 20

// The charter's term, then a count, then chance: of two rosters drawn up at once, all agree which it is.
@(private)
serial_next :: proc(d: ^Draft, term: u64) -> (serial: u64, ok: bool) {
	last := d.last
	salt: [4]byte
	draft_random(d, salt[:])
	count := (last >> COUNT_SHIFT) & (1 << (TERM_SHIFT - COUNT_SHIFT) - 1) if last >> TERM_SHIFT == term else 0
	count += 1
	serial = term << TERM_SHIFT | count << COUNT_SHIFT | u64(get_u32(salt[:])) >> (32 - COUNT_SHIFT)
	return serial, term > 0 && term < 1 << (64 - TERM_SHIFT) && count < 1 << (TERM_SHIFT - COUNT_SHIFT)
}

roster_destroy :: proc(r: ^Roster) {
	for m in r.members {
		delete(m.grants)
	}
	for s in r.scopes {
		delete(s.closed)
		delete(s.commits)
	}
	delete(r.bytes)
	delete(r.scopes)
	delete(r.members)
	delete(r.relays)
	delete(r.owners)
	delete(r.admins)
	r^ = {}
}

// Halving, as every roster's scopes are in order: one made up may have a great many. Of a few, as most have, one
// after another is quicker.
@(require_results)
roster_scope :: proc(r: ^Roster, scope: Scope) -> ^Scope_Info {
	if len(r.scopes) <= 8 {
		for &s in r.scopes {
			if s.id == scope {
				return &s
			}
		}
		return nil
	}
	lo, hi := 0, len(r.scopes)
	for lo < hi {
		mid := (lo + hi) / 2
		if r.scopes[mid].id < scope {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return &r.scopes[lo] if lo < len(r.scopes) && r.scopes[lo].id == scope else nil
}

// Of whom a member goes by and whom it is believed about: another, if that is another.
@(require_results)
member_name :: proc(m: ^Member) -> u64 {
	h := hash.fnv64a(m.subject, hash.fnv64a(m.device[:]))
	for g in m.grants {
		if .Vouch in g.rights {
			h = (h * 31 + u64(g.scope)) * 31 + g.until
		}
	}
	return h
}

@(require_results)
roster_member :: proc(r: ^Roster, device: Key32) -> ^Member {
	for &m in r.members {
		if m.device == device {
			return &m
		}
	}
	return nil
}

// Whether a roster only adds to another, as one drawn up from it does.
@(private, require_results)
roster_extends :: proc(old, new: ^Roster) -> bool {
	for &was in old.scopes {
		info := roster_scope(new, was.id)
		if info == nil || info.flags != was.flags || len(info.commits) < len(was.commits) {
			return false
		}
		for c, i in was.commits {
			if info.commits[i] != c {
				return false
			}
		}
		for c, i in was.closed {
			if info.closed[i] != c {
				return false
			}
		}
	}
	if len(new.members) < len(old.members) {
		return false
	}
	for &was, i in old.members {
		m := &new.members[i]
		if m.device != was.device || m.signer != was.signer || len(m.grants) < len(was.grants) {
			return false
		}
		for g, j in was.grants {
			now := m.grants[j]
			// Call, and Vouch where cells are nobody's, are taken away without ending the grant: nothing written
			// hangs on them.
			info := roster_scope(old, g.scope)
			kept := Rights{.Read, .Write, .Vouch} if info != nil && .Signed in info.flags else Rights{.Read, .Write}
			if now.scope != g.scope || (now.until != g.until && g.until != 0) || (g.rights - now.rights) & kept != {} {
				return false
			}
		}
	}
	return true
}

@(require_results)
member_rights :: proc(m: ^Member, scope: Scope) -> Rights {
	for g in m.grants {
		if g.scope == scope && g.until == 0 {
			return g.rights
		}
	}
	return {}
}

@(require_results)
member_active :: proc(m: ^Member) -> bool {
	if m.owner || m.admin {
		return true
	}
	for g in m.grants {
		if g.until == 0 {
			return true
		}
	}
	return false
}

// What an admin intends the next roster to say.
Draft :: struct {
	last:    u64, // the serial it follows
	space:   Key32,
	charter: []byte, // the one in force, while nothing about it changes
	term:    u64,
	owners:  []Owner,
	admins:  []Key32,
	now:     u64, // stamp time at which this takes effect
	random:  proc(into: []byte), // defaults to the operating system
	scopes:  [dynamic]Draft_Scope,
	members: [dynamic]Member,
	relays:  [dynamic]Relay,
}

Draft_Scope :: struct {
	id:     Scope,
	flags:  Scope_Flags,
	rotate: bool, // draw a new sealing key
	closed: []u64,
	commits: []Key32,
	known:  bool, // there is one already
	keys:   []Key32, // by epoch, as far as the signer has them
}

// The current roster as a draft, in temporary memory. `now` should be no less than any stamp the admin
// has seen: what others wrote before then stands.
@(require_results)
draft_from :: proc(r: ^Roster, now: u64, allocator := context.temp_allocator) -> (d: Draft) {
	d.space, d.last, d.charter, d.term, d.owners, d.admins = r.space, r.serial, r.charter, r.term, r.owners, r.admins
	d.now = max(now, 1)
	d.scopes = make([dynamic]Draft_Scope, allocator)
	d.members = make([dynamic]Member, allocator)
	d.relays = make([dynamic]Relay, allocator)
	for s in r.scopes {
		append(&d.scopes, Draft_Scope{id = s.id, flags = s.flags, closed = s.closed, commits = s.commits, known = true})
	}
	for m in r.members {
		m := m
		m.grants = slice.clone(m.grants, allocator)
		append(&d.members, m)
	}
	for o in r.owners {
		if roster_member(r, o.device) == nil {
			append(&d.members, Member{device = o.device, signer = o.signer, owner = true})
		}
	}
	append(&d.relays, ..r.relays)
	return
}

draft_scope :: proc(d: ^Draft, flags: Scope_Flags = {}) -> (id: Scope) {
	for s in d.scopes {
		id = max(id, s.id)
	}
	id += 1
	append(&d.scopes, Draft_Scope{id = id, flags = flags})
	// Whoever draws up rosters must hold every scope.
	for m in d.members {
		if m.owner || m.admin {
			draft_grant(d, m.device, m.signer, id, {.Read, .Write})
		}
	}
	return
}

// Gives a device rights in a scope, admitting it to the space if need be.
draft_grant :: proc(d: ^Draft, device, signer: Key32, scope: Scope, rights: Rights, allocator := context.temp_allocator) -> ^Member {
	m: ^Member
	for &x in d.members {
		if x.device == device {
			m = &x
		}
	}
	if m == nil {
		append(&d.members, Member{device = device, signer = signer})
		m = &d.members[len(d.members) - 1]
	}
	rights := rights
	if m.owner {
		rights += {.Read, .Write}
	}
	for &g in m.grants {
		if g.scope != scope || g.until != 0 {
			continue
		}
		if card((g.rights & {.Write, .Vouch}) - rights) > 0 && (.Write not_in rights || draft_signed(d, scope)) {
			g.until = d.now // ended, not unmade: what it allowed stays allowed
			break
		}
		g.rights = rights + {.Read}
		return m
	}
	grants := make([dynamic]Grant, 0, len(m.grants) + 1, allocator)
	append(&grants, ..m.grants)
	append(&grants, Grant{scope, rights + {.Read}, 0})
	m.grants = grants[:]
	return m
}

@(private)
draft_signed :: proc(d: ^Draft, scope: Scope) -> bool {
	for s in d.scopes {
		if s.id == scope {
			return .Signed in s.flags
		}
	}
	return false
}

// Ends a device's rights in a scope, or everywhere, and rotates what it could read. An owner's do not end; and an admin
// whose rights end anywhere is one no longer, for whoever draws up rosters must hold every scope's keys.
draft_revoke :: proc(d: ^Draft, device: Key32, scope: Scope = 0) {
	for &m in d.members {
		if m.device != device || m.owner {
			continue
		}
		ended := false
		for &g in m.grants {
			if g.until != 0 || (scope != 0 && g.scope != scope) {
				continue
			}
			g.until = d.now
			ended = true
			for &s in d.scopes {
				if s.id == g.scope {
					s.rotate = true
				}
			}
		}
		if scope == 0 || ended {
			m.admin = false
		}
	}
}

// Whether these keys may sign the next roster after this one.
@(require_results)
keyring_rules :: proc(k: ^Keyring, r: ^Roster) -> bool {
	return k.root != nil || slice.contains(r.admins, k.signer)
}

// Signs a draft: as an owner, given the space's seed, and otherwise as an admin. Only an owner may change
// who are owners and admins. An admin must hold every existing scope's keys. An owner need not: an epoch whose
// key was kept from it is declared void, and those who can open what was sealed under it seal that again.
@(require_results)
roster_sign :: proc(k: ^Keyring, root: Maybe(Key32), d: ^Draft, allocator := context.allocator) -> (bytes: []byte, ok: bool) {
	seed, owner := root.?
	for &s in d.scopes {
		if !s.known {
			continue
		}
		held := keyring_scope(k, s.id)
		keys := make([]Key32, len(s.closed) + 1, context.temp_allocator)
		if held != nil {
			copy(keys, held.epochs[:])
		}
		s.closed = slice.clone(s.closed, context.temp_allocator)
		last: u64
		for key, i in keys {
			if key != {} {
				last = s.closed[i] if i < len(s.closed) else last
				continue
			}
			if !owner {
				return
			}
			if i < len(s.closed) {
				s.closed[i] = last
			} else {
				closed := make([]u64, i + 1, context.temp_allocator)
				copy(closed, s.closed)
				closed[i] = last
				s.closed = closed
			}
		}
		s.keys = keys
	}
	for i in 0 ..< len(d.members) {
		if d.members[i].owner {
			for s in d.scopes {
				draft_grant(d, d.members[i].device, d.members[i].signer, s.id, member_rights(&d.members[i], s.id))
			}
		}
	}
	if !owner {
		seed = k.seed
	}
	sk: ed25519.Private_Key
	ed25519.private_key_set_bytes(&sk, seed[:]) or_return
	defer ed25519.private_key_clear(&sk)
	space, signer, eph_secret: Key32
	ed25519.private_key_public_bytes(&sk, signer[:])
	draft_random(d, eph_secret[:])
	defer crypto.zero_explicit(&eph_secret, 32)
	eph := x25519_public(eph_secret)

	charter, admins := d.charter, d.admins
	term := d.term
	if draft_recharters(d) {
		if !owner {
			return
		}
		term += 1
		charter, admins = charter_sign(&sk, signer, seed, d, term) or_return
	}
	by: u64
	if owner {
		space = signer
	} else {
		i := slice.linear_search(admins, signer) or_return
		by = u64(i) + 1
		space = d.space
	}
	serial := serial_next(d, term) or_return

	current := make(map[Scope]Key32, context.temp_allocator)
	w := make([dynamic]byte, allocator)
	defer if !ok {
		delete(w)
	}
	append(&w, ROSTER_MAGIC)
	append(&w, ..space[:])
	write_bytes(&w, charter)
	write_varint(&w, serial)
	write_varint(&w, u64(len(d.scopes)))
	for s in d.scopes {
		epochs := len(s.keys)
		if epochs == 0 || s.rotate || len(s.closed) == epochs {
			fresh: Key32
			draft_random(d, fresh[:])
			current[s.id] = fresh
			epochs += 1
		} else {
			current[s.id] = s.keys[epochs - 1]
		}
		write_varint(&w, u64(s.id))
		write_u8(&w, transmute(u8)s.flags)
		write_varint(&w, u64(epochs))
		last: u64
		for c in s.closed {
			write_varint(&w, c)
			last = c
		}
		if len(s.closed) < epochs - 1 {
			write_varint(&w, max(d.now, last + 1))
		}
		for i in 0 ..< epochs {
			commit := s.commits[i] if i < len(s.commits) else key_commit(current[s.id])
			append(&w, ..commit[:])
		}
	}
	write_varint(&w, u64(len(d.members)))
	for m in d.members {
		device, theirs := m.device, m.signer
		append(&w, ..device[:])
		append(&w, ..theirs[:])
		write_bytes(&w, m.subject)
		write_varint(&w, u64(len(m.grants)))
		for g in m.grants {
			write_varint(&w, u64(g.scope))
			write_u8(&w, transmute(u8)g.rights)
			write_varint(&w, g.until)
		}
	}
	write_varint(&w, u64(len(d.relays)))
	for l in d.relays {
		key := l.key
		append(&w, ..key[:])
		write_bytes(&w, transmute([]byte)l.url)
	}
	append(&w, ..eph[:])
	for m in d.members {
		if len(m.grants) == 0 {
			continue
		}
		wrap := wrap_key(eph_secret, m.device, eph, m.device) or_return
		for g in m.grants {
			if g.until == 0 {
				append_sealed(&w, wrap, u64(g.scope), current[g.scope])
			}
		}
	}
	for s in d.scopes {
		key := history_key(current[s.id])
		for old, i in s.keys {
			if old != current[s.id] {
				append_sealed(&w, key, u64(i), old)
			}
		}
	}
	write_varint(&w, by)
	sig: [64]byte
	ed25519.sign(&sk, w[:], sig[:])
	append(&w, ..sig[:])
	if len(w) > MAX_ROSTER {
		delete(w)
		return nil, false
	}
	return w[:], true
}

@(private)
draft_random :: proc(d: ^Draft, into: []byte) {
	if d.random != nil {
		d.random(into)
	} else {
		crypto.rand_bytes(into)
	}
}

@(private)
draft_recharters :: proc(d: ^Draft) -> bool {
	owners, admins := 0, 0
	for m in d.members {
		if m.owner {
			owners += 1
			was := false
			for o in d.owners {
				was ||= o.device == m.device
			}
			if !was {
				return true
			}
		}
		if m.admin {
			admins += 1
			if !slice.contains(d.admins, m.signer) {
				return true
			}
		}
	}
	return d.charter == nil || owners != len(d.owners) || admins != len(d.admins)
}

@(private)
charter_sign :: proc(sk: ^ed25519.Private_Key, space, root: Key32, d: ^Draft, term: u64) -> (bytes: []byte, admins: []Key32, ok: bool) {
	eph_secret: Key32
	draft_random(d, eph_secret[:])
	defer crypto.zero_explicit(&eph_secret, 32)
	eph := x25519_public(eph_secret)
	w := make([dynamic]byte, context.temp_allocator)
	list := make([dynamic]Key32, context.temp_allocator)
	write_varint(&w, term)
	append(&w, ..eph[:])
	count: u64
	for m in d.members {
		count += 1 if m.owner else 0
	}
	write_varint(&w, count)
	for m in d.members {
		if !m.owner {
			continue
		}
		device, signer := m.device, m.signer
		append(&w, ..device[:])
		append(&w, ..signer[:])
		append_sealed(&w, wrap_key(eph_secret, device, eph, device) or_return, 0, root)
	}
	for m in d.members {
		if m.admin {
			append(&list, m.signer)
		}
	}
	write_varint(&w, u64(len(list)))
	for &a in list {
		append(&w, ..a[:])
	}
	sig: [64]byte
	ed25519.sign(sk, charter_signed(space, w[:]), sig[:])
	append(&w, ..sig[:])
	return w[:], list[:], true
}

// Recovers this device's keys from a verified roster. False if it is no longer a member.
@(require_results)
roster_unwrap :: proc(k: ^Keyring, r: ^Roster) -> bool {
	// Ownership does not hang on membership, so that no admin can end it.
	k.root = nil
	for o in r.owners {
		if o.device == k.device {
			rd := Reader{buf = r.charter}
			_ = read_varint(&rd)
			eph := read_key32(&rd)
			wrap, _ := wrap_key(k.secret, eph, eph, k.device)
			if root, opened := open_key(wrap, 0, o.wrap); opened {
				k.root = root
			}
		}
	}
	me := roster_member(r, k.device)
	if me == nil || !member_active(me) {
		return false
	}
	// A wrap that cannot be made, like one that does not open, is garbled, and takes nothing away.
	wrap, _ := wrap_key(k.secret, r.eph, r.eph, k.device)
	at := 0
	for &m in r.members {
		if &m == me {
			break
		}
		for g in m.grants {
			at += 48 if g.until == 0 else 0
		}
	}
	// What was learnt before is not unlearnt because someone garbles it now.
	keyring_forget(k)
	before := k.scopes
	k.before = before
	k.scopes = {}
	for g in me.grants {
		if g.until != 0 {
			continue
		}
		wrapped := r.wraps[at:][:48]
		at += 48
		sealed := 0
		for s in r.scopes {
			if s.id != g.scope {
				sealed += 48 * int(s.epoch - 1)
				continue
			}
			keys := Scope_Keys{scope = s.id}
			resize(&keys.epochs, int(s.epoch))
			for old in before {
				if old.scope != s.id {
					continue
				}
				keys.list_key = old.list_key
				for e, i in old.epochs {
					if i < int(s.epoch) && e != {} && key_commit(e) == s.commits[i] {
						keys.epochs[i] = e
					}
				}
			}
			last := int(s.epoch) - 1
			if current, ok := open_key(wrap, u64(g.scope), wrapped); ok && key_commit(current) == s.commits[last] {
				keys.epochs[last] = current
			}
			if keys.epochs[last] != {} {
				key := history_key(keys.epochs[last])
				for &e, i in keys.epochs[:last] {
					if e == {} {
						old, ok := open_key(key, u64(i), r.history[sealed + i * 48:][:48])
						if ok && key_commit(old) == s.commits[i] {
							e = old
						}
					}
				}
			}
			// List tags outlive rotation: they hang off the first epoch.
			if keys.epochs[0] != {} {
				keys.list_key = derive(keys.epochs[0], "zsp-list")
			}
			scope_keys_index(&keys)
			append(&k.scopes, keys)
			break
		}
	}
	return true
}

// What a device has learnt, sealed for itself alone: rosters may be lost, or garbled by an admin gone bad.
// Temporary memory.
@(require_results)
keyring_save :: proc(k: ^Keyring) -> []byte {
	w := make([dynamic]byte, context.temp_allocator)
	for &s in k.scopes {
		write_varint(&w, u64(s.scope))
		append(&w, ..s.list_key[:])
		write_varint(&w, u64(len(s.epochs)))
		for &e in s.epochs {
			append(&w, ..e[:])
		}
	}
	iv: [24]byte
	crypto.rand_bytes(iv[:])
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, ..iv[:])
	aead_append(&out, derive(k.secret, "zsp-keep"), &iv, nil, w[:])
	crypto.zero_explicit(raw_data(w), len(w))
	return out[:]
}

// Before any roster is adopted.
keyring_load :: proc(k: ^Keyring, bytes: []byte) -> bool {
	if len(bytes) < 24 {
		return false
	}
	iv: [24]byte
	copy(iv[:], bytes)
	plain := make([dynamic]byte, context.temp_allocator)
	aead_open(&plain, derive(k.secret, "zsp-keep"), &iv, nil, bytes[24:]) or_return
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	r := Reader{buf = plain[:]}
	for r.pos < len(r.buf) && !r.bad {
		s: Scope_Keys
		s.scope = Scope(read_varint(&r))
		s.list_key = read_key32(&r)
		epochs := read_count(&r, 32) // once: a range's end is found anew at each turn
		for _ in 0 ..< epochs {
			append(&s.epochs, read_key32(&r))
		}
		scope_keys_index(&s)
		append(&k.scopes, s)
	}
	return !r.bad
}

key_commit :: proc(key: Key32) -> Key32 {
	return derive(key, "zsp-commit")
}

@(private)
read_key32 :: proc(r: ^Reader) -> (k: Key32) {
	copy(k[:], read_take(r, 32))
	return
}
