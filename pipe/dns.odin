package pipe

import "core:encoding/endian"

// The sliver of DNS (RFC 1035, with RFC 6891's EDNS) that an authoritative server of one small zone needs: a
// question read, and an answer of at most one address or name. Queries name nothing by pointer; answers point
// back at the question, which is echoed as it came, case and all (resolvers that mix case check it).

DNS_A :: 1
DNS_NS :: 2
DNS_SOA :: 6
DNS_PTR :: 12
DNS_AAAA :: 28
DNS_OPT :: 41
DNS_ANY :: 255
DNS_UDP :: 1232 // what we say we take, and the most we send, over UDP: what fits any path unfragmented

Dns_Rcode :: enum u8 {
	No_Error = 0,
	Form_Error = 1,
	Server_Failure = 2,
	Name_Error = 3, // no such name
	Not_Implemented = 4,
	Refused = 5,
	Bad_Version = 16, // of EDNS: said in the OPT record's high bits
}

Dns_Query :: struct {
	id:      u16,
	recurse: bool, // RD: echoed
	raw:     []byte, // the question's name as it came, in wire form
	name:    [256]byte, // and in lower case with dots between, no dot at the end
	length:  int,
	type:    u16,
	class:   u16,
	edns:    bool, // an OPT record came, and so goes back
	version: u8, // of EDNS
	size:    int, // the most the asker takes over UDP
}

@(require_results)
dns_name :: proc(q: ^Dns_Query) -> string {
	return string(q.name[:q.length])
}

// Reads a query. Anything else, or anything malformed, is not one: a server answers what it can with Form_Error
// and drops the rest.
@(require_results)
dns_query :: proc(packet: []byte) -> (q: Dns_Query, ok: bool) {
	if len(packet) < 12 {
		return
	}
	q.id = endian.unchecked_get_u16be(packet)
	flags := endian.unchecked_get_u16be(packet[2:])
	q.recurse = flags & 0x0100 != 0
	questions := endian.unchecked_get_u16be(packet[4:])
	answers := endian.unchecked_get_u16be(packet[6:])
	authority := endian.unchecked_get_u16be(packet[8:])
	additional := endian.unchecked_get_u16be(packet[10:])
	q.size = 512
	if flags & 0x8000 != 0 || (flags >> 11) & 0xf != 0 || questions != 1 || answers != 0 || authority != 0 || additional > 1 {
		return
	}
	at := 12
	start := at
	for {
		if at >= len(packet) {
			return
		}
		n := int(packet[at])
		at += 1
		if n == 0 {
			break
		}
		// No pointers in a question: there is nothing before it to point at.
		if n > 63 || at + n > len(packet) || q.length + n + 1 > 254 {
			return
		}
		if q.length > 0 {
			q.name[q.length] = '.'
			q.length += 1
		}
		for c in packet[at:at + n] {
			q.name[q.length] = c + 32 if c >= 'A' && c <= 'Z' else c
			q.length += 1
		}
		at += n
	}
	q.raw = packet[start:at]
	if at + 4 > len(packet) {
		return
	}
	q.type = endian.unchecked_get_u16be(packet[at:])
	q.class = endian.unchecked_get_u16be(packet[at + 2:])
	at += 4
	if additional == 1 {
		// Only an OPT record may be there: the root, its type, the asker's size, extended rcode, version, flags, data.
		if at + 11 > len(packet) || packet[at] != 0 || endian.unchecked_get_u16be(packet[at + 1:]) != DNS_OPT {
			return
		}
		q.edns = true
		q.size = clamp(int(endian.unchecked_get_u16be(packet[at + 3:])), 512, DNS_UDP)
		q.version = packet[at + 6]
		data := int(endian.unchecked_get_u16be(packet[at + 9:]))
		at += 11 + data
		if at > len(packet) {
			return
		}
	}
	return q, at == len(packet)
}

// What there is to say of a question's name: at most one address or name, and when there is no answer, the zone
// whose start of authority says how long that may be remembered.
Dns_Answer :: struct {
	rcode: Dns_Rcode,
	a:     Maybe([4]byte),
	ptr:   string, // a name, with dots between
	zone:  string, // for SOA, in authority when nothing answers and in the answer when it is asked for
	soa:   bool,
	ttl:   u32,
}

// Writes the reply to a query. Over UDP, `room` is the most it may take; the reply is short enough never to
// need truncating, but if it would be, it says so and is cut back to the question.
dns_reply :: proc(w: ^[dynamic]byte, q: ^Dns_Query, a: Dns_Answer, room := 65535) {
	start := len(w)
	rcode := a.rcode
	if q.edns && q.version != 0 {
		rcode = .Bad_Version
	}
	be16 :: proc(w: ^[dynamic]byte, v: u16) {
		append(w, byte(v >> 8), byte(v))
	}
	be32 :: proc(w: ^[dynamic]byte, v: u32) {
		append(w, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
	}
	name :: proc(w: ^[dynamic]byte, dotted: string) {
		label := 0
		for i in 0 ..= len(dotted) {
			if i == len(dotted) || dotted[i] == '.' {
				if i > label {
					append(w, byte(i - label))
					append(w, dotted[label:i])
				}
				label = i + 1
			}
		}
		append(w, 0)
	}
	soa :: proc(w: ^[dynamic]byte, zone: string, ttl: u32) {
		name(w, zone)
		be16(w, DNS_SOA)
		be16(w, 1)
		be32(w, ttl)
		at := len(w)
		be16(w, 0)
		append(w, 0) // the primary: nobody, for there is no transfer
		append(w, 0) // and whom to mail
		be32(w, 1) // serial
		be32(w, 3600) // refresh
		be32(w, 600) // retry
		be32(w, 86400) // expire
		be32(w, ttl) // how long an absence may be remembered
		endian.unchecked_put_u16be(w[at:], u16(len(w) - at - 2))
	}
	be16(w, q.id)
	flags := u16(0x8000 | 0x0400 | 0x0080) | u16(rcode) & 0xf // a reply, authoritative, and as good as recursive
	if q.recurse {
		flags |= 0x0100
	}
	be16(w, flags)
	answering := rcode == .No_Error && q.class == 1
	address, has_address := a.a.?
	answers := 0
	if answering {
		switch {
		case has_address && (q.type == DNS_A || q.type == DNS_ANY):
			answers = 1
		case a.ptr != "" && (q.type == DNS_PTR || q.type == DNS_ANY):
			answers = 1
		case a.soa && q.type == DNS_SOA:
			answers = 1
		}
	}
	be16(w, 1)
	be16(w, u16(answers))
	be16(w, 1 if answers == 0 && a.zone != "" && rcode != .Refused && rcode != .Bad_Version else 0)
	be16(w, 1 if q.edns else 0)
	append(w, ..q.raw)
	be16(w, q.type)
	be16(w, q.class)
	if answers == 1 {
		append(w, 0xc0, 12) // the question's name
		switch {
		case has_address && (q.type == DNS_A || q.type == DNS_ANY):
			be16(w, DNS_A)
			be16(w, 1)
			be32(w, a.ttl)
			be16(w, 4)
			append(w, ..address[:])
		case a.ptr != "":
			be16(w, DNS_PTR)
			be16(w, 1)
			be32(w, a.ttl)
			at := len(w)
			be16(w, 0)
			name(w, a.ptr)
			endian.unchecked_put_u16be(w[at:], u16(len(w) - at - 2))
		case:
			resize(w, len(w) - 2)
			soa(w, a.zone, a.ttl)
		}
	} else if a.zone != "" && rcode != .Refused && rcode != .Bad_Version {
		soa(w, a.zone, a.ttl)
	}
	if q.edns {
		append(w, 0)
		be16(w, DNS_OPT)
		be16(w, DNS_UDP)
		append(w, byte(u8(rcode) >> 4), 0)
		be16(w, 0)
		be16(w, 0)
	}
	if len(w) - start > room {
		// Truncated: the question alone, and TC, so that the asker comes again by TCP.
		resize(w, start + 12 + len(q.raw) + 4)
		w[start + 2] |= 0x02
		for i in 6 ..< 12 {
			w[start + i] = 0
		}
	}
}
