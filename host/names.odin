package host

import "core:strconv"
import "core:strings"
import "../pipe"
import "../zsp"

// Every device of a space has a name and an address on this machine, the same for as long as the roster lasts:
//
//   <name>.<suffix>        the name the roster gives it, if any
//   <id>.id.<suffix>       always: the first ten bytes of its key in base32, which nobody can choose to match
//
// and the address is 127.a.b.c, where a.b is the space's loopback prefix and b.c is two more than the device's
// index among the roster's members. Indexes are for ever, so an address never comes to mean another device,
// however long an application has remembered it. This device's own name is 127.0.0.1: what it serves is here.
//
// Nothing here is replicated or said on the wire: each device works it out from the roster alone.

NAMES :: "zsp.internal" // under .internal, which ICANN keeps for private use and will never delegate
NAME_TTL :: 5 // seconds a resolver may remember an answer, or that there is none: names move, with the roster

Naming :: struct {
	suffix:   string, // names are found under this; "" for none
	loopback: [2]byte, // 127.a.b.c: a, and the high byte of b.c's range
}

// A suffix is labels such as a name is, with dots between: short enough that any name and id fit under it.
@(require_results)
suffix_valid :: proc(suffix: string) -> bool {
	if len(suffix) == 0 || len(suffix) > 160 || suffix[0] == '.' || suffix[len(suffix) - 1] == '.' || strings.contains(suffix, "..") {
		return false
	}
	rest := suffix
	for label in strings.split_iterator(&rest, ".") {
		if !zsp.name_valid(label) {
			return false
		}
	}
	return true
}

// The name nobody chose: 80 bits of the device's key, in lower-case base32.
name_id :: zsp.name_id

// The address applications reach a device at, from this one. Not every member has one: those beyond the range,
// and those whose grants have all ended.
@(require_results)
device_address :: proc(sp: ^Space, device: zsp.Key32) -> (ip: [4]byte, ok: bool) {
	if device == sp.host.device {
		return {127, 0, 0, 1}, true
	}
	for &m, i in sp.node.roster.members {
		if m.device == device {
			if !zsp.member_active(&m) {
				return
			}
			return member_address(sp, i)
		}
	}
	return
}

@(private, require_results)
member_address :: proc(sp: ^Space, index: int) -> (ip: [4]byte, ok: bool) {
	v := index + 2
	if v > 0xffff {
		return
	}
	return {127, sp.naming.loopback[0], sp.naming.loopback[1] + byte(v >> 8), byte(v)}, true
}

// The member whose address this is, if any is.
@(require_results)
address_member :: proc(sp: ^Space, ip: [4]byte) -> ^zsp.Member {
	if ip[0] != 127 || ip[1] != sp.naming.loopback[0] || ip[2] < sp.naming.loopback[1] {
		return nil
	}
	v := int(ip[2] - sp.naming.loopback[1]) << 8 | int(ip[3])
	members := sp.node.roster.members
	if v < 2 || v - 2 >= len(members) || !zsp.member_active(&members[v - 2]) || members[v - 2].device == sp.host.device {
		return nil
	}
	return &members[v - 2]
}

// The address the space's own services answer at: names and the proxy.
@(require_results)
naming_address :: proc(n: Naming) -> [4]byte {
	return {127, n.loopback[0], n.loopback[1], 1}
}

// Whose a name is, in lower case and without the suffix: `name` or `id.id`.
@(require_results)
name_member :: proc(sp: ^Space, name: string) -> ^zsp.Member {
	r := &sp.node.roster
	if id, is_id := cut_suffix(name, ".id"); is_id {
		if len(id) != 16 {
			return nil
		}
		for &m in r.members {
			if mid := name_id(m.device); string(mid[:]) == id && zsp.member_active(&m) {
				return &m
			}
		}
		return nil
	}
	m := zsp.roster_named(r, name)
	return m if m != nil && zsp.member_active(m) else nil
}

// The name a device goes by: its own, or else its id.
@(require_results)
member_name_of :: proc(sp: ^Space, m: ^zsp.Member, allocator := context.temp_allocator) -> string {
	if len(m.hostname) > 0 {
		return strings.concatenate({string(m.hostname), ".", sp.naming.suffix}, allocator)
	}
	id := name_id(m.device)
	return strings.concatenate({string(id[:]), ".id.", sp.naming.suffix}, allocator)
}

// What to say of a name, asked of this machine, whichever space's it is.
@(require_results)
names_answer :: proc(h: ^Host, q: ^pipe.Dns_Query) -> (a: pipe.Dns_Answer) {
	a.ttl = NAME_TTL
	name := pipe.dns_name(q)
	for sp in h.spaces {
		suffix := sp.naming.suffix
		if suffix == "" {
			continue
		}
		if name == suffix || name == strings.concatenate({"id.", suffix}, context.temp_allocator) {
			a.zone, a.soa = suffix, name == suffix
			return
		}
		if rest, under := cut_suffix(name, strings.concatenate({".", suffix}, context.temp_allocator)); under {
			a.zone = suffix
			m := name_member(sp, rest)
			if m == nil {
				a.rcode = .Name_Error
				return
			}
			a.a, _ = device_address(sp, m.device)
			if q.type == pipe.DNS_A || q.type == pipe.DNS_ANY {
				ports_wanted(sp, m.device) // whoever looks it up is about to connect
			}
			return
		}
		// The addresses, the other way.
		zone := reverse_zone(sp.naming)
		if name == zone {
			a.zone, a.soa = zone, true
			return
		}
		if rest, under := cut_suffix(name, strings.concatenate({".", zone}, context.temp_allocator)); under {
			a.zone = zone
			parts := strings.split(rest, ".", context.temp_allocator)
			ip := [4]byte{127, sp.naming.loopback[0], 0, 0}
			valid := len(parts) == 2
			for p, i in parts {
				v, digits := strconv.parse_uint(p, 10)
				valid &&= digits && v <= 255 && (len(p) == 1 || p[0] != '0')
				ip[3 - i] = byte(v)
			}
			m := address_member(sp, ip) if valid else nil
			if m == nil {
				a.rcode = .Name_Error
				return
			}
			a.ptr = member_name_of(sp, m)
			return
		}
	}
	a.rcode = .Refused // not ours to say
	return
}

@(private, require_results)
reverse_zone :: proc(n: Naming) -> string {
	buf: [8]byte
	return strings.concatenate({strconv.write_uint(buf[:], u64(n.loopback[0]), 10), ".127.in-addr.arpa"}, context.temp_allocator)
}

@(private, require_results)
cut_suffix :: proc(s, suffix: string) -> (rest: string, ok: bool) {
	if !strings.has_suffix(s, suffix) {
		return s, false
	}
	return s[:len(s) - len(suffix)], true
}
