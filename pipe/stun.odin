package pipe

import "core:crypto"
import "core:encoding/endian"

// The sliver of RFC 8489 that answers "what address do I have out there?", as asked and as answered.

STUN_MAGIC :: u32(0x2112A442)
STUN_REQUEST :: 20
STUN_REPLY :: 44

Address :: struct {
	ip:   [16]byte, // IPv4 is mapped
	port: u16,
}

@(require_results)
address_v4 :: proc(a, b, c, d: byte, port: u16) -> Address {
	return {{10 = 0xff, 11 = 0xff, 12 = a, 13 = b, 14 = c, 15 = d}, port}
}

@(require_results)
address_is_v4 :: proc(a: Address) -> bool {
	for b, i in a.ip {
		if i < 10 && b != 0 {
			return false
		}
	}
	return a.ip[10] == 0xff && a.ip[11] == 0xff
}

stun_request :: proc() -> (packet: [STUN_REQUEST]byte) {
	packet[1] = 1
	endian.unchecked_put_u32be(packet[4:], STUN_MAGIC)
	crypto.rand_bytes(packet[8:])
	return
}

@(require_results)
is_stun :: proc(packet: []byte) -> bool {
	return len(packet) >= 20 && packet[0] < 0x40 && endian.unchecked_get_u32be(packet[4:]) == STUN_MAGIC
}

// Answers a request with the address it came from.
@(require_results)
stun_answer :: proc(request: []byte, from: Address, into: []byte) -> []byte {
	if !is_stun(request) || request[0] != 0 || request[1] != 1 {
		return nil
	}
	from := from
	v4 := address_is_v4(from)
	n := 12 if v4 else 24
	into[0], into[1], into[2], into[3] = 1, 1, 0, byte(n)
	copy(into[4:20], request[4:20])
	into[20], into[21], into[22], into[23] = 0, 0x20, 0, byte(n - 4)
	into[24], into[25] = 0, 1 if v4 else 2
	endian.unchecked_put_u16be(into[26:], from.port ~ u16(STUN_MAGIC >> 16))
	ip := from.ip
	bytes := ip[12:] if v4 else ip[:]
	for b, i in bytes {
		into[28 + i] = b ~ request[4 + i]
	}
	return into[:20 + n]
}

// The address in a reply to our request.
@(require_results)
stun_address :: proc(request, reply: []byte) -> (a: Address, ok: bool) {
	if !is_stun(reply) || reply[0] != 1 || reply[1] != 1 || string(reply[4:20]) != string(request[4:20]) {
		return
	}
	at := 20
	for at + 4 <= len(reply) {
		type := endian.unchecked_get_u16be(reply[at:])
		n := int(endian.unchecked_get_u16be(reply[at + 2:]))
		at += 4
		if at + n > len(reply) {
			return
		}
		v4 := n == 8
		if type == 0x20 && (v4 || n == 20) {
			a.port = endian.unchecked_get_u16be(reply[at + 2:]) ~ u16(STUN_MAGIC >> 16)
			if v4 {
				a.ip[10], a.ip[11] = 0xff, 0xff
			}
			into := a.ip[12:] if v4 else a.ip[:]
			for &b, i in into {
				b = reply[at + 4 + i] ~ reply[4 + i]
			}
			return a, true
		}
		at += (n + 3) / 4 * 4
	}
	return
}
