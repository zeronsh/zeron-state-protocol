package host

import "core:encoding/hex"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "../pipe"
import "../zsp"

// What a device exposes to the public, outside its space: one port at a time, never unless asked, through each relay
// it is connected to that will (one run with --expose), at a name the relay gives it: https://<label>.<domain>. The
// public comes as a call from the relay, zsp.public, which the device takes only from a relay it dialled and only for
// a label it exposes; taking a port back cuts off whoever is using it. Every change and every connection, with where
// it came from, goes in the audit log.
//
// The relay sees what passes, as any reverse proxy must that holds the certificate: what is private stays between
// devices, end to end; what is exposed is public.

MAX_EXPOSURES :: 16

Exposure :: struct {
	port:   u16,
	prefix: string, // owned: the label's beginning, for people
	nonce:  [zsp.EXPOSE_NONCE]byte,
	proxy:  bool, // say where each connection came from (PROXY protocol v2) before anything else
	label:  string, // owned
	heard:  [dynamic]Exposed, // what each relay said of it
}

Exposed :: struct {
	relay:  zsp.Key32,
	status: u8, // 0 exposed, 1 that relay exposes nothing, 2 the name is another's, 3 too many
	url:    string, // owned
}

@(private)
Public_In :: struct {
	using handler: Call_Handler,
	sp:      ^Space,
	call:    u64,
	label:   string, // owned
	port:    u16,
	from:    pipe.Address,
	early:   [dynamic]byte, // what came before the connection was made
	dialing: ^nbio.Operation,
	forward: ^Forward,
	tried6:  bool,
	prelude: []byte, // owned
	abandoned: bool, // over while dialling: the dial is left to finish, and this freed then
	heard_end: bool, // the public said all it will before the connection was made
}

exposure_destroy :: proc(e: ^Exposure) {
	delete(e.prefix)
	delete(e.label)
	for x in e.heard {
		delete(x.url)
	}
	delete(e.heard)
}

@(private)
exposures_load :: proc(p: ^Ports) {
	data, err := os.read_entire_file(file_in(p.space.dir, "exposures"), context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	for whole in strings.split_lines_iterator(&text) {
		line := strings.trim_space(whole)
		if line == "" || line[0] == '#' {
			continue
		}
		e, ok := exposure_parse(p.space, strings.fields(line, context.temp_allocator))
		if !ok || len(p.exposures) >= MAX_EXPOSURES || own_port(p.space.host, e.port) {
			report(.Warning, "an exposure makes no sense, and is not made: ", line)
			continue
		}
		append(&p.exposures, e)
	}
}

// `<port> nonce=<hex> [name=<prefix>] [proxy]`
@(private)
exposure_parse :: proc(sp: ^Space, words: []string) -> (e: Exposure, ok: bool) {
	if len(words) < 2 {
		return
	}
	port, pok := strconv.parse_u64(words[0], 10)
	if !pok || port == 0 || port > 65535 {
		return
	}
	e.port = u16(port)
	have := false
	prefix := ""
	for w in words[1:] {
		key, eq, value := strings.partition(w, "=")
		switch {
		case key == "proxy" && eq == "":
			e.proxy = true
		case key == "name" && eq != "" && zsp.exposure_prefix_valid(value):
			prefix = value
		case key == "nonce" && eq != "":
			b, decoded := hex.decode(transmute([]byte)value, context.temp_allocator)
			if !decoded || len(b) != zsp.EXPOSE_NONCE {
				return
			}
			copy(e.nonce[:], b)
			have = true
		case:
			return
		}
	}
	if !have {
		return
	}
	e.prefix = strings.clone(prefix)
	e.label = zsp.exposure_label(sp.node.space, sp.host.device, prefix, e.nonce, context.allocator)
	return e, true
}

@(private)
exposures_save :: proc(p: ^Ports) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# What this device exposes to the public, through relays: see zspd expose.\n")
	for &e in p.exposures {
		fmt.sbprintf(&b, "%d nonce=%s", e.port, hex.encode(e.nonce[:], context.temp_allocator))
		if e.prefix != "" {
			fmt.sbprintf(&b, " name=%s", e.prefix)
		}
		if e.proxy {
			strings.write_string(&b, " proxy")
		}
		strings.write_byte(&b, '\n')
	}
	file_disk_make(&p.space.disk)
	return save(file_in(p.space.dir, "exposures"), b.buf[:])
}

// Exposes a port of this machine to the public, under a fresh name; or takes it back, cutting off whoever is using it.
exposure_change :: proc(sp: ^Space, port: u16, prefix: string, proxy: bool, remove: bool) -> bool {
	p := sp.ports
	if p == nil || port == 0 || !zsp.exposure_prefix_valid(prefix) || own_port(sp.host, port) {
		return false
	}
	at := -1
	for &e, i in p.exposures {
		if e.port == port {
			at = i
		}
	}
	switch {
	case remove && at < 0:
		return false
	case remove:
		label := p.exposures[at].label
		#reverse for c in p.public {
			if c.label == label {
				public_in_cut(c)
			}
		}
		exposure_destroy(&p.exposures[at])
		ordered_remove(&p.exposures, at)
	case at >= 0:
		return false // exposed already: take it back first, which is a new name
	case len(p.exposures) >= MAX_EXPOSURES:
		return false
	case:
		e := Exposure{port = port, proxy = proxy, prefix = strings.clone(prefix)}
		node_random(sp, e.nonce[:])
		e.label = zsp.exposure_label(sp.node.space, sp.host.device, prefix, e.nonce, context.allocator)
		append(&p.exposures, e)
	}
	if !exposures_save(p) {
		report(.Error, "could not save what this device exposes")
	}
	audit(sp, {service = "expose", detail = fmt.tprintf("%s%d", "-" if remove else "+", port), event = .Change})
	p.exposed += 1 // every relay is told again
	return true
}

@(private)
node_random :: proc(sp: ^Space, into: []byte) {
	h := &sp.node.host
	if h.random != nil {
		h.random(h.data, into)
	} else {
		crypto_random(into)
	}
}

// Tells each relay that has not heard it what this device exposes there: the whole of it, which replaces what it heard
// before. 40 Expose: n varint ‖ n × { prefix bytes ‖ nonce (16) }.
@(private)
exposures_tell :: proc(p: ^Ports) {
	sp := p.space
	for s in sp.node.sessions {
		if !s.ready || s.role != .Peer || !s.peer_relay {
			continue
		}
		if told, ok := p.told[s.id]; ok && told == p.exposed {
			continue
		}
		p.told[s.id] = p.exposed
		if len(p.exposures) == 0 && !(s.id in p.ever_told) {
			continue // nothing to say, nor to take back
		}
		p.ever_told[s.id] = true
		w := make([dynamic]byte, context.temp_allocator)
		zsp.write_varint(&w, u64(len(p.exposures)))
		for &e in p.exposures {
			zsp.write_bytes(&w, transmute([]byte)e.prefix)
			append(&w, ..e.nonce[:])
		}
		zsp.session_say(s, zsp.EXPOSE, w[:])
	}
	for id in p.told {
		live := false
		for s in sp.node.sessions {
			live ||= s.id == id
		}
		if !live {
			delete_key(&p.told, id)
			delete_key(&p.ever_told, id)
		}
	}
}

// 41 Exposed, from a relay: n varint ‖ n × { label bytes ‖ status (1) ‖ url bytes }.
@(private)
exposures_heard :: proc(sp: ^Space, s: ^zsp.Session, payload: []byte) {
	p := sp.ports
	if p == nil || !s.peer_relay {
		return
	}
	r := zsp.Reader{buf = payload}
	n := zsp.read_varint(&r)
	for _ in 0 ..< min(n, MAX_EXPOSURES) {
		label := string(zsp.read_bytes(&r))
		status := zsp.read_u8(&r)
		url := string(zsp.read_bytes(&r))
		if r.bad {
			return
		}
		for &e in p.exposures {
			if e.label != label {
				continue
			}
			found := false
			for &x in e.heard {
				if x.relay == s.peer {
					delete(x.url)
					x.status, x.url, found = status, strings.clone(url), true
				}
			}
			if !found {
				append(&e.heard, Exposed{s.peer, status, strings.clone(url)})
			}
			if status == 0 {
				report(.Info, "port ", fmt.tprint(e.port), " is exposed at ", url)
			}
		}
	}
}

// zsp.public, from a relay this device dialled: label bytes ‖ address (16) ‖ port (2), where the connection came from.
@(private)
public_called :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	p := sp.ports
	if p == nil || !from.relay || scope != 0 {
		return nil, .Denied
	}
	r := zsp.Reader{buf = first}
	label := string(zsp.read_bytes(&r))
	address := zsp.read_take(&r, 18)
	if !zsp.read_done(&r) {
		return nil, .Denied
	}
	e: ^Exposure
	for &x in p.exposures {
		if x.label == label {
			e = &x
		}
	}
	a: pipe.Address
	copy(a.ip[:], address)
	a.port = u16(address[16]) << 8 | u16(address[17])
	peer := net.endpoint_to_string(address_to(a), context.temp_allocator)
	if e == nil || own_port(sp.host, e.port) {
		audit(sp, {service = "public", detail = label, event = .Denied, peer = peer})
		return nil, .Denied
	}
	c := new(Public_In)
	c.sp, c.call, c.label, c.port, c.from = sp, call, strings.clone(label), e.port, a
	if e.proxy {
		c.prelude = proxy_header(a, {127, 0, 0, 1}, e.port, nil)
	}
	c.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		c := (^Public_In)(h)
		append(&c.early, ..bytes) // the connection is yet to be made: it waits, within the credit it was given
		return false
	}
	c.on_end = proc(h: ^Call_Handler, call: u64) {
		(^Public_In)(h).heard_end = true // whatever came is written once connected, and then the end of it
	}
	c.on_fault = proc(h: ^Call_Handler, call: u64, _: zsp.Call_Fault) {
		public_in_drop((^Public_In)(h))
	}
	append(&p.public, c)
	audit(sp, {service = "public", detail = fmt.tprintf("%s:%d", label, e.port), event = .Open, peer = peer})
	public_dial(c, false)
	return c, {}
}

@(private)
public_dial :: proc(c: ^Public_In, six: bool) {
	c.tried6 = six
	at := net.Endpoint{net.IP6_Loopback if six else net.IP4_Loopback, int(c.port)}
	c.dialing = nbio.dial_poly(at, c, proc(op: ^nbio.Operation, c: ^Public_In) {
		c.dialing = nil
		if c.abandoned {
			// Taken back meanwhile. Removing a dial that has connected would leak its socket: so it was let finish.
			if op.dial.err == nil {
				socket_abort(op.dial.socket)
			}
			public_in_free(c)
			return
		}
		if op.dial.err != nil {
			if !c.tried6 {
				public_dial(c, true) // some listen on ::1 alone
				return
			}
			w := make([dynamic]byte, context.temp_allocator)
			append(&w, 3)
			append(&w, "refused")
			call_send(c.sp, c.call, w[:])
			call_end(c.sp, c.call)
			public_in_drop(c)
			return
		}
		call_send(c.sp, c.call, {0})
		prelude := make([dynamic]byte, context.temp_allocator)
		append(&prelude, ..c.prelude)
		append(&prelude, ..c.early[:])
		credit := len(c.early)
		c.forward = bridge(c.sp, c.call, op.dial.socket, prelude[:])
		// The bridge is the call's now, and says when it is over: until then this stays, to be cut off by.
		c.forward.done, c.forward.done_data = public_in_bridged, c
		call_consumed(c.sp, c.call, credit)
		clear(&c.early)
		if c.heard_end {
			c.forward.handler.on_end(&c.forward.handler, c.call)
		}
	}, timeout = 10 * time.Second)
}

// Cut off: the exposure was taken back.
@(private)
public_in_cut :: proc(c: ^Public_In) {
	if c.forward != nil {
		forward_close(c.forward) // which says so to public_in_bridged, which lets this go
		return
	}
	call_fault(c.sp, c.call, .Denied)
	public_in_drop(c)
}

// A connection from the public is over: written down, with what passed, and let go.
@(private)
public_in_bridged :: proc(data: rawptr, status: Forward_Status) {
	if status == .Connected {
		return
	}
	c := (^Public_In)(data)
	if b := c.forward; b != nil {
		audit(c.sp, {service = "public", detail = fmt.tprintf("%s:%d", c.label, c.port), event = .Close, peer = net.endpoint_to_string(address_to(c.from), context.temp_allocator), bytes_in = b.bytes_in, bytes_out = b.bytes_out})
	}
	c.forward = nil
	public_in_drop(c)
}

@(private)
public_in_drop :: proc(c: ^Public_In) {
	p := c.sp.ports
	if p != nil {
		for x, i in p.public {
			if x == c {
				unordered_remove(&p.public, i)
				break
			}
		}
	}
	if c.dialing != nil {
		c.abandoned = true // freed when the dial ends
		return
	}
	public_in_free(c)
}

@(private)
public_in_free :: proc(c: ^Public_In) {
	delete(c.label)
	delete(c.early)
	delete(c.prelude)
	free(c)
}

// The PROXY protocol's second version: where a connection came from, and where to, before anything of it; with what
// else the target should know, as type ‖ length ‖ value. In `allocator`'s memory.
proxy_header :: proc(from: pipe.Address, to: [4]byte, port: u16, extra: []byte, allocator := context.allocator) -> []byte {
	from, to := from, to
	w := make([dynamic]byte, allocator)
	append(&w, "\r\n\r\n\x00\r\nQUIT\n")
	if pipe.address_is_v4(from) {
		append(&w, 0x21, 0x11, 0, 0) // a connection, of TCP over IPv4
		append(&w, ..from.ip[12:])
		append(&w, ..to[:])
	} else {
		append(&w, 0x21, 0x21, 0, 0) // over IPv6
		append(&w, ..from.ip[:])
		mapped := pipe.address_v4(to[0], to[1], to[2], to[3], port)
		append(&w, ..mapped.ip[:])
	}
	append(&w, byte(from.port >> 8), byte(from.port), byte(port >> 8), byte(port))
	append(&w, ..extra)
	n := len(w) - 16
	w[14], w[15] = byte(n >> 8), byte(n)
	return w[:]
}

// What a device's connection through an offer marked proxy says first: PROXY v2, from the device's address here, as any
// application here would see it, to this machine's port; with TLVs 0xE0, the device's key, and 0xE1, its name. In
// temporary memory.
port_proxy_header :: proc(sp: ^Space, caller: zsp.Key32, port: u16) -> []byte {
	caller := caller
	ip, _ := device_address(sp, caller)
	extra := make([dynamic]byte, context.temp_allocator)
	append(&extra, 0xe0, 0, 32)
	append(&extra, ..caller[:])
	if m := zsp.roster_member(&sp.node.roster, caller); m != nil && sp.naming.suffix != "" {
		name := member_name_of(sp, m)
		append(&extra, 0xe1, byte(len(name) >> 8), byte(len(name)))
		append(&extra, name)
	}
	return proxy_header(pipe.address_v4(ip[0], ip[1], ip[2], ip[3], 0), {127, 0, 0, 1}, port, extra[:], context.temp_allocator)
}

// zsp.expose, for a local client: 0 to list, 1 ‖ port (2) ‖ prefix bytes ‖ flags (1: 1 proxy) to expose a port, 2 ‖ port (2)
// to take it back. Answered with n varint ‖ n × { port (2) ‖ prefix bytes ‖ flags (1) ‖ label bytes ‖ m varint ‖ m × {
// relay (32) ‖ status (1) ‖ url bytes } }.
@(private)
expose_called :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	if from.local == nil || sp.ports == nil {
		return nil, .Denied
	}
	r := zsp.Reader{buf = first}
	op := zsp.read_u8(&r)
	if op != 0 {
		if !may_configure(sp, from.local) {
			return nil, .Denied
		}
		pb := zsp.read_take(&r, 2)
		prefix, flags := "", u8(0)
		if op == 1 {
			prefix = string(zsp.read_bytes(&r))
			flags = zsp.read_u8(&r)
		}
		if !zsp.read_done(&r) || op > 2 || flags > 1 || !exposure_change(sp, u16(pb[0]) << 8 | u16(pb[1]), prefix, flags == 1, op == 2) {
			return nil, .Denied
		}
	} else if !zsp.read_done(&r) {
		return nil, .Denied
	}
	b := make([dynamic]byte, context.temp_allocator)
	exposures_put(sp.ports, &b)
	return call_answer(sp, call, b[:]), {}
}

@(private)
exposures_put :: proc(p: ^Ports, w: ^[dynamic]byte) {
	zsp.write_varint(w, u64(len(p.exposures)))
	for &e in p.exposures {
		append(w, byte(e.port >> 8), byte(e.port))
		zsp.write_bytes(w, transmute([]byte)e.prefix)
		append(w, 1 if e.proxy else 0)
		zsp.write_bytes(w, transmute([]byte)e.label)
		zsp.write_varint(w, u64(len(e.heard)))
		for &x in e.heard {
			append(w, ..x.relay[:])
			append(w, x.status)
			zsp.write_bytes(w, transmute([]byte)x.url)
		}
	}
}
