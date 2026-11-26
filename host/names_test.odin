package host

import "core:strings"
import "core:testing"
import "../pipe"
import "../zsp"

@(private)
Test_Space :: struct {
	host:  Host,
	space: Space,
	disk:  zsp.Memory_Disk,
	keys:  [3]zsp.Keyring, // this device, and two others
	root:  zsp.Key32,
}

// A space of three devices, the first of them this one, not yet running anything.
@(private)
test_space :: proc(t: ^testing.T, ts: ^Test_Space, names: [3]string = {}) {
	for &k, n in ts.keys {
		secret: zsp.Key32
		for i in 0 ..< 32 {
			secret[i] = byte(i * (n + 3) + 1)
		}
		zsp.keyring_init(&k, secret)
	}
	for i in 0 ..< 32 {
		ts.root[i] = byte(i * 5 + 2)
	}
	none: zsp.Roster
	d := zsp.draft_from(&none, 1)
	home := zsp.draft_scope(&d)
	zsp.draft_grant(&d, ts.keys[0].device, ts.keys[0].signer, home, {.Write, .Call}).owner = true
	zsp.draft_grant(&d, ts.keys[1].device, ts.keys[1].signer, home, {.Write, .Call})
	zsp.draft_grant(&d, ts.keys[2].device, ts.keys[2].signer, home, {.Write, .Call})
	for name, i in names {
		if name != "" {
			testing.expect(t, zsp.draft_name(&d, ts.keys[i].device, name))
		}
	}
	roster, ok := zsp.roster_sign(&ts.keys[0], ts.root, &d, context.temp_allocator)
	testing.expect(t, ok)
	ts.host.secret = ts.keys[0].secret
	ts.host.device = ts.keys[0].device
	ts.space.host = &ts.host
	ts.space.naming = {NAMES, {77, 0}}
	testing.expect(t, zsp.node_init(&ts.space.node, zsp.memory_disk(&ts.disk), zsp.ed25519_public(ts.root), &ts.keys[0], true))
	testing.expect(t, zsp.node_adopt(&ts.space.node, roster))
	append(&ts.host.spaces, &ts.space)
}

@(private)
test_space_destroy :: proc(ts: ^Test_Space) {
	zsp.node_destroy(&ts.space.node)
	zsp.memory_disk_destroy(&ts.disk)
	for &k in ts.keys {
		zsp.keyring_destroy(&k)
	}
	delete(ts.host.spaces)
}

@(private = "file")
ask :: proc(h: ^Host, name: string, type: u16 = pipe.DNS_A) -> pipe.Dns_Answer {
	w := make([dynamic]byte, context.temp_allocator)
	append(&w, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0)
	label := 0
	for i in 0 ..= len(name) {
		if i == len(name) || name[i] == '.' {
			append(&w, byte(i - label))
			append(&w, name[label:i])
			label = i + 1
		}
	}
	append(&w, 0, byte(type >> 8), byte(type), 0, 1)
	q, ok := pipe.dns_query(w[:])
	assert(ok)
	return names_answer(h, &q)
}

@(test)
names_resolve :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts, {"", "desk", ""})
	defer test_space_destroy(&ts)
	h := &ts.host

	// By the name the roster gives, in any case, and by the id nobody chose: an address of its own, for each.
	a := ask(h, "desk.zsp.internal")
	testing.expect(t, a.rcode == .No_Error && a.a.? == [4]byte{127, 77, 0, 3} && a.zone == "zsp.internal" && a.ttl == NAME_TTL)
	testing.expect(t, ask(h, "DESK.Zsp.Internal").a.? == [4]byte{127, 77, 0, 3})
	id := name_id(ts.keys[2].device)
	a = ask(h, cat(string(id[:]), ".id.zsp.internal"))
	testing.expect(t, a.rcode == .No_Error && a.a.? == [4]byte{127, 77, 0, 4})
	// This device is here.
	mine := name_id(ts.keys[0].device)
	testing.expect(t, ask(h, cat(string(mine[:]), ".id.zsp.internal")).a.? == [4]byte{127, 0, 0, 1})
	// And the other way.
	a = ask(h, "3.0.77.127.in-addr.arpa", pipe.DNS_PTR)
	testing.expect(t, a.rcode == .No_Error && a.ptr == "desk.zsp.internal")
	a = ask(h, "4.0.77.127.in-addr.arpa", pipe.DNS_PTR)
	testing.expect(t, a.rcode == .No_Error && a.ptr == cat(string(id[:]), ".id.zsp.internal"))

	// Nothing else is anybody's.
	testing.expect(t, ask(h, "nobody.zsp.internal").rcode == .Name_Error)
	testing.expect(t, ask(h, "a.desk.zsp.internal").rcode == .Name_Error)
	testing.expect(t, ask(h, "aaaaaaaaaaaaaaaa.id.zsp.internal").rcode == .Name_Error)
	testing.expect(t, ask(h, cat(string(id[:15]), ".id.zsp.internal")).rcode == .Name_Error)
	testing.expect(t, ask(h, "9.0.77.127.in-addr.arpa", pipe.DNS_PTR).rcode == .Name_Error)
	testing.expect(t, ask(h, "2.0.77.127.in-addr.arpa", pipe.DNS_PTR).rcode == .Name_Error) // this device's index is not an address
	testing.expect(t, ask(h, "03.0.77.127.in-addr.arpa", pipe.DNS_PTR).rcode == .Name_Error)
	for odd in ([]string{"1.2.3.4.5.77.127.in-addr.arpa", "1.2.3.0.77.127.in-addr.arpa", "a.b.c.d.e.f.g.0.77.127.in-addr.arpa"}) {
		testing.expectf(t, ask(h, odd, pipe.DNS_PTR).rcode == .Name_Error, "%s", odd)
	}
	testing.expect(t, ask(h, "zsp.internal", pipe.DNS_SOA).soa)
	testing.expect(t, ask(h, "example.com").rcode == .Refused)
	testing.expect(t, ask(h, "internal").rcode == .Refused)
	testing.expect(t, ask(h, "xzsp.internal").rcode == .Refused)

	// A device whose grants have ended has no name, nor address: whoever remembers one reaches nobody.
	d := zsp.draft_from(&ts.space.node.roster, 1000)
	zsp.draft_revoke(&d, ts.keys[1].device)
	roster, ok := zsp.roster_sign(&ts.keys[0], ts.root, &d, context.temp_allocator)
	testing.expect(t, ok && zsp.node_adopt(&ts.space.node, roster))
	testing.expect(t, ask(h, "desk.zsp.internal").rcode == .Name_Error)
	testing.expect(t, ask(h, "3.0.77.127.in-addr.arpa", pipe.DNS_PTR).rcode == .Name_Error)
	_, has := device_address(&ts.space, ts.keys[1].device)
	testing.expect(t, !has)
	testing.expect(t, ask(h, cat(string(id[:]), ".id.zsp.internal")).a.? == [4]byte{127, 77, 0, 4}) // the others are where they were
}

@(test)
suffixes :: proc(t: ^testing.T) {
	for good in ([]string{"zsp.internal", "internal", "a-b.c1.home.arpa", "tunnel.example.id", "id.example.com"}) {
		testing.expectf(t, suffix_valid(good), "%q is a suffix", good)
	}
	for bad in ([]string{"", ".", "zsp.", ".zsp", "zsp..internal", "Zsp.internal", "-a.b", "a b"}) {
		testing.expectf(t, !suffix_valid(bad), "%q is no suffix", bad)
	}
}

@(test)
ids_are_base32 :: proc(t: ^testing.T) {
	k: zsp.Key32
	for i in 0 ..< 10 {
		k[i] = byte(i * 37 + 11)
	}
	id := name_id(k) // RFC 4648 of 0b 30 55 7a 9f c4 e9 0e 33 58: as a reference implementation has it
	testing.expect_value(t, string(id[:]), "bmyfk6u7ytuq4m2y")
}

@(private = "file")
cat :: proc(a, b: string) -> string {
	return strings.concatenate({a, b}, context.temp_allocator)
}

// Every address a device is given is within the space's range, 127.a.b.2 to 127.a.255.255, whatever b is: past the
// end there is none, not one that wraps round to another's.
@(test)
addresses_stay_in_range :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts)
	defer test_space_destroy(&ts)
	ts.space.naming = {NAMES, {77, 1}}
	ip, ok := member_address(&ts.space, 0)
	testing.expect(t, ok && ip == {127, 77, 1, 2})
	ip, ok = member_address(&ts.space, 254 * 256 + 253)
	testing.expect(t, ok && ip == {127, 77, 255, 255})
	ip, ok = member_address(&ts.space, 254 * 256 + 254)
	testing.expectf(t, !ok, "%v", ip)
}

// A member past the space's range of addresses has its name, and no address: not 0.0.0.0, which is this machine.
@(test)
names_past_the_range :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts)
	defer test_space_destroy(&ts)
	ts.space.naming = {NAMES, {77, 255}} // room for 254
	d := zsp.draft_from(&ts.space.node.roster, 1000)
	last: zsp.Key32
	for n in 0 ..< 260 {
		k: zsp.Keyring
		secret: zsp.Key32
		secret[0], secret[1], secret[2] = 0xa5, byte(n), byte(n >> 8)
		zsp.keyring_init(&k, secret)
		zsp.draft_grant(&d, k.device, k.signer, 1, {.Write, .Call})
		last = k.device
		zsp.keyring_destroy(&k)
	}
	testing.expect(t, zsp.draft_name(&d, last, "far"))
	roster, ok := zsp.roster_sign(&ts.keys[0], ts.root, &d, context.temp_allocator)
	testing.expect(t, ok && zsp.node_adopt(&ts.space.node, roster))
	a := ask(&ts.host, "far.zsp.internal")
	_, has := a.a.?
	testing.expectf(t, a.rcode == .No_Error && !has, "%v %v", a.rcode, a.a)
}
