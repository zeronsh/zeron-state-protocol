#+build !js
package pipe

import "core:encoding/endian"
import "core:testing"

@(private = "file")
query :: proc(name: string, type: u16, edns := false, version: u8 = 0) -> []byte {
	w := make([dynamic]byte, context.temp_allocator)
	append(&w, 0xab, 0xcd, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1 if edns else 0)
	label := 0
	for i in 0 ..= len(name) {
		if i == len(name) || name[i] == '.' {
			append(&w, byte(i - label))
			append(&w, name[label:i])
			label = i + 1
		}
	}
	append(&w, 0, byte(type >> 8), byte(type), 0, 1)
	if edns {
		append(&w, 0, 0, 41, 0x10, 0, 0, version, 0x80, 0, 0, 0) // 4096 bytes, DO set
	}
	return w[:]
}

@(private = "file")
Parsed :: struct {
	id, flags:     u16,
	rcode:         int,
	counts:        [4]u16,
	type:          u16, // of the first answer or authority record
	ttl:           u32,
	data:          []byte,
	opt_size:      u16,
}

@(private = "file")
parse :: proc(t: ^testing.T, reply: []byte, asked: []byte) -> (p: Parsed) {
	p.id = endian.unchecked_get_u16be(reply)
	p.flags = endian.unchecked_get_u16be(reply[2:])
	p.rcode = int(p.flags & 0xf)
	for &c, i in p.counts {
		c = endian.unchecked_get_u16be(reply[4 + 2 * i:])
	}
	// The question comes back exactly as it was asked.
	question := len(asked) - 12 - (11 if asked[11] == 1 else 0)
	testing.expect(t, string(reply[12:12 + question]) == string(asked[12:12 + question]))
	at := 12 + question
	if p.counts[1] + p.counts[2] > 0 {
		if reply[at] == 0xc0 {
			at += 2
		} else {
			for reply[at] != 0 {
				at += int(reply[at]) + 1
			}
			at += 1
		}
		p.type = endian.unchecked_get_u16be(reply[at:])
		p.ttl = endian.unchecked_get_u32be(reply[at + 4:])
		n := int(endian.unchecked_get_u16be(reply[at + 8:]))
		p.data = reply[at + 10:at + 10 + n]
		at += 10 + n
	}
	if p.counts[3] == 1 {
		testing.expect(t, reply[at] == 0 && endian.unchecked_get_u16be(reply[at + 1:]) == DNS_OPT)
		p.opt_size = endian.unchecked_get_u16be(reply[at + 3:])
		p.rcode |= int(reply[at + 5]) << 4
		at += 11
	}
	testing.expect_value(t, at, len(reply))
	return
}

@(test)
dns_answers :: proc(t: ^testing.T) {
	// A name, asked in mixed case, as resolvers do to make forgery harder: matched without case, echoed with it.
	asked := query("Desk-Top.ZSP.internal", DNS_A)
	q, ok := dns_query(asked)
	testing.expect(t, ok && dns_name(&q) == "desk-top.zsp.internal" && q.type == DNS_A && q.id == 0xabcd && q.recurse && !q.edns)
	w := make([dynamic]byte, context.temp_allocator)
	dns_reply(&w, &q, {a = [4]byte{127, 77, 0, 5}, zone = "zsp.internal", ttl = 5})
	p := parse(t, w[:], asked)
	testing.expect(t, p.id == 0xabcd && p.flags & 0x8000 != 0 && p.flags & 0x0400 != 0 && p.flags & 0x0100 != 0 && p.rcode == 0)
	testing.expect(t, p.counts == {1, 1, 0, 0} && p.type == DNS_A && p.ttl == 5 && string(p.data) == "\x7fM\x00\x05")

	// The same name, asked for what it does not have: nothing, and for how long nothing may be remembered.
	asked = query("desk-top.zsp.internal", DNS_AAAA, edns = true)
	q, ok = dns_query(asked)
	testing.expect(t, ok && q.edns && q.size == DNS_UDP)
	clear(&w)
	dns_reply(&w, &q, {a = [4]byte{127, 77, 0, 5}, zone = "zsp.internal", ttl = 5})
	p = parse(t, w[:], asked)
	testing.expect(t, p.rcode == 0 && p.counts == {1, 0, 1, 1} && p.type == DNS_SOA && p.opt_size == DNS_UDP)
	testing.expect_value(t, endian.unchecked_get_u32be(p.data[len(p.data) - 4:]), 5)

	// No such name.
	asked = query("nobody.zsp.internal", DNS_A)
	q, _ = dns_query(asked)
	clear(&w)
	dns_reply(&w, &q, {rcode = .Name_Error, zone = "zsp.internal", ttl = 5})
	p = parse(t, w[:], asked)
	testing.expect(t, p.rcode == 3 && p.counts == {1, 0, 1, 0} && p.type == DNS_SOA)

	// Not ours to say.
	asked = query("example.com", DNS_A)
	q, _ = dns_query(asked)
	clear(&w)
	dns_reply(&w, &q, {rcode = .Refused})
	p = parse(t, w[:], asked)
	testing.expect(t, p.rcode == 5 && p.counts == {1, 0, 0, 0})

	// An address, asked about.
	asked = query("5.0.77.127.in-addr.arpa", DNS_PTR)
	q, _ = dns_query(asked)
	clear(&w)
	dns_reply(&w, &q, {ptr = "desk-top.zsp.internal", ttl = 5})
	p = parse(t, w[:], asked)
	testing.expect(t, p.rcode == 0 && p.counts == {1, 1, 0, 0} && p.type == DNS_PTR)
	testing.expect_value(t, string(p.data), "\x08desk-top\x03zsp\x08internal\x00")

	// The zone itself.
	asked = query("zsp.internal", DNS_SOA)
	q, _ = dns_query(asked)
	clear(&w)
	dns_reply(&w, &q, {soa = true, zone = "zsp.internal", ttl = 5})
	p = parse(t, w[:], asked)
	testing.expect(t, p.rcode == 0 && p.counts == {1, 1, 0, 0} && p.type == DNS_SOA)

	// An EDNS this does not speak.
	asked = query("desk-top.zsp.internal", DNS_A, edns = true, version = 1)
	q, _ = dns_query(asked)
	clear(&w)
	dns_reply(&w, &q, {a = [4]byte{127, 77, 0, 5}, zone = "zsp.internal", ttl = 5})
	p = parse(t, w[:], asked)
	testing.expect(t, p.rcode == 16 && p.counts == {1, 0, 0, 1})

	// Too long for where it goes: the question alone, marked truncated.
	asked = query("desk-top.zsp.internal", DNS_A)
	q, _ = dns_query(asked)
	clear(&w)
	dns_reply(&w, &q, {a = [4]byte{127, 77, 0, 5}, zone = "zsp.internal", ttl = 5}, room = 40)
	p = parse(t, w[:], asked)
	testing.expect(t, p.flags & 0x0200 != 0 && p.counts == {1, 0, 0, 0})
}

@(test)
dns_refuses_what_is_not_a_query :: proc(t: ^testing.T) {
	good := query("a.zsp.internal", DNS_A)
	_, ok := dns_query(good)
	testing.expect(t, ok)
	for cut in 0 ..< len(good) {
		_, ok = dns_query(good[:cut])
		testing.expect(t, !ok)
	}
	bad := make([]byte, len(good), context.temp_allocator)
	mutate :: proc(bad, good: []byte, at: int, b: byte) -> []byte {
		copy(bad, good)
		bad[at] = b
		return bad
	}
	_, ok = dns_query(mutate(bad, good, 2, 0x81)) // a reply
	testing.expect(t, !ok)
	_, ok = dns_query(mutate(bad, good, 2, 0x29)) // another opcode
	testing.expect(t, !ok)
	_, ok = dns_query(mutate(bad, good, 5, 2)) // two questions
	testing.expect(t, !ok)
	_, ok = dns_query(mutate(bad, good, 12, 0xc0)) // a pointer
	testing.expect(t, !ok)
	_, ok = dns_query(mutate(bad, good, 12, 64)) // a label too long
	testing.expect(t, !ok)
	trailing := make([]byte, len(good) + 1, context.temp_allocator)
	copy(trailing, good)
	_, ok = dns_query(trailing)
	testing.expect(t, !ok)
	// A name longer than any may be.
	long := make([dynamic]byte, context.temp_allocator)
	append(&long, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0)
	for _ in 0 ..< 5 {
		append(&long, 60)
		for _ in 0 ..< 60 {
			append(&long, 'a')
		}
	}
	append(&long, 0, 0, 1, 0, 1)
	_, ok = dns_query(long[:])
	testing.expect(t, !ok)
}
