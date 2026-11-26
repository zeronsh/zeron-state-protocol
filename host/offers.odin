package host

import "core:encoding/hex"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"
import "../pipe"
import "../zsp"

// What this device offers other devices of its space: ports, to whom, nothing unless it says so.
//
// An offer is a range of ports, a scope, and perhaps one device: whoever may call in that scope (and is that device)
// may reach those ports. With no host they are this machine's, and only those that are listening are listed: a
// device that is watching is kept up as they open and close, which the system tells nobody, so it is looked at
// every few seconds while somebody watches and never otherwise. With a host they are another machine's, as reached
// from here, and all are listed.
//
// A device never offers what it forwards, nor its own listeners: nothing reaches through it what it reaches.

MAX_OFFERS :: 256
MAX_WATCHERS :: 256 // devices kept up, at once
WATCHERS_EACH :: 4
MAX_LEASE :: 600 // seconds a device may be kept up without asking again
SCAN_EVERY :: 2 * time.Second // while anyone is kept up
MAX_LIST :: 60 << 10 // bytes of entries said at once
MAX_HOST_RANGE :: 1024 // ports of another machine in one offer

Offer :: struct {
	lo, hi: u16,
	scope:  zsp.Scope,
	device: zsp.Key32, // only this one, if not zero
	host:   string, // owned; "" for this machine
	name:   string, // owned; what it is, for people
	proxy:  bool, // say who connects before anything else (PROXY protocol v2)
}

// What a device is told it may reach: a port, the scope to call in, and where.
Port_Entry :: struct {
	port:  u16,
	scope: zsp.Scope,
	host:  string,
	name:  string,
}

@(private)
Port_Watch :: struct {
	using handler: Call_Handler,
	ports:  ^Ports,
	call:   u64,
	device: zsp.Key32,
	until:  time.Tick,
	said:   u64, // a hash of what was last said
	owed:   bool, // something has changed that there was no room to say
	ended:  bool, // this side has ended: it is freed when the other has
	once:   bool, // asked with no lease: answered once, and never kept up, whatever it asks after
	heard:  bool, // the other side has ended: freed when this one has
}

offer_destroy :: proc(o: ^Offer) {
	delete(o.host)
	delete(o.name)
	o^ = {}
}

// Reads an offer as people write it: `<port>[-<port>] <scope> [device=<key>] [host=<address>] [name=<name>] [proxy]`.
@(require_results)
offer_parse :: proc(words: []string) -> (o: Offer, ok: bool) {
	if len(words) < 2 {
		return
	}
	lo, _, hi := strings.partition(words[0], "-")
	l, lok := strconv.parse_u64(lo, 10)
	h, hok := l, true
	if hi != "" {
		h, hok = strconv.parse_u64(hi, 10)
	}
	s, sok := strconv.parse_u64(words[1], 10)
	if !lok || !hok || !sok || l == 0 || l > h || h > 65535 || s == 0 || s >= u64(max(zsp.Scope)) {
		return
	}
	o.lo, o.hi, o.scope = u16(l), u16(h), zsp.Scope(s)
	for w in words[2:] {
		key, eq, value := strings.partition(w, "=")
		switch {
		case key == "proxy" && eq == "":
			o.proxy = true
		case key == "device" && eq != "":
			b, err := hex.decode(transmute([]byte)value, context.temp_allocator)
			if !err || len(b) != 32 {
				return
			}
			copy(o.device[:], b)
		case key == "host" && eq != "":
			o.host = value
		case key == "name" && eq != "" && len(value) <= 63:
			o.name = value
		case:
			return
		}
	}
	return o, offer_sound(&o)
}

// Whether an offer could be made: a host is an address, not one of the addresses this space's devices are given,
// and another machine's ports come a few at a time.
@(require_results)
offer_sound :: proc(o: ^Offer) -> bool {
	if o.lo == 0 || o.lo > o.hi || o.scope == 0 || !offer_name_sound(o.name) {
		return false
	}
	if o.host == "" {
		return true
	}
	address := net.parse_address(o.host)
	if address == nil || int(o.hi) - int(o.lo) >= MAX_HOST_RANGE {
		return false
	}
	switch ip in address {
	case net.IP4_Address:
		return ip[0] != 127 && ip != {} // this machine is no host
	case net.IP6_Address:
		a := address_from({ip, 0})
		return ip != net.IP6_Loopback && ip != {} && !pipe.address_is_v4(a) // nor this machine by another name
	}
	return false
}

// One word of at most 63 bytes, as a device keeps it in its offers file: no space of any kind, nor what is not UTF-8
// or is a control.
@(require_results)
offer_name_sound :: proc(name: string) -> bool {
	if len(name) > 63 || !utf8.valid_string(name) {
		return false
	}
	for r in name {
		if unicode.is_space(r) || unicode.is_control(r) {
			return false
		}
	}
	return true
}

// As offer_parse reads it.
@(require_results)
offer_text :: proc(o: ^Offer, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_uint(&b, uint(o.lo))
	if o.hi != o.lo {
		strings.write_byte(&b, '-')
		strings.write_uint(&b, uint(o.hi))
	}
	strings.write_byte(&b, ' ')
	strings.write_uint(&b, uint(o.scope))
	if o.device != {} {
		device := o.device
		strings.write_string(&b, " device=")
		strings.write_string(&b, string(hex.encode(device[:], context.temp_allocator)))
	}
	if o.host != "" {
		strings.write_string(&b, " host=")
		strings.write_string(&b, o.host)
	}
	if o.name != "" {
		strings.write_string(&b, " name=")
		strings.write_string(&b, o.name)
	}
	if o.proxy {
		strings.write_string(&b, " proxy")
	}
	return strings.to_string(b)
}

// The wire form, as zsp.offers says it: lo (2) ‖ hi (2) ‖ scope varint ‖ device (32) ‖ host bytes ‖ name bytes ‖ flags (1: 1 proxy).
offer_put :: proc(w: ^[dynamic]byte, o: ^Offer) {
	device := o.device
	append(w, byte(o.lo >> 8), byte(o.lo), byte(o.hi >> 8), byte(o.hi))
	zsp.write_varint(w, u64(o.scope))
	append(w, ..device[:])
	zsp.write_bytes(w, transmute([]byte)o.host)
	zsp.write_bytes(w, transmute([]byte)o.name)
	append(w, 1 if o.proxy else 0)
}

@(require_results)
offer_read :: proc(r: ^zsp.Reader) -> (o: Offer, ok: bool) {
	pair := zsp.read_take(r, 4)
	scope := zsp.read_varint(r)
	copy(o.device[:], zsp.read_take(r, 32))
	o.host = string(zsp.read_bytes(r))
	o.name = string(zsp.read_bytes(r))
	flags := zsp.read_u8(r)
	if r.bad || flags > 1 || scope >= u64(max(zsp.Scope)) {
		return
	}
	o.lo, o.hi, o.scope, o.proxy = u16(pair[0]) << 8 | u16(pair[1]), u16(pair[2]) << 8 | u16(pair[3]), zsp.Scope(scope), flags == 1
	return o, offer_sound(&o)
}

@(private)
offers_load :: proc(p: ^Ports) {
	data, err := os.read_entire_file(file_in(p.space.dir, "offers"), context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	for whole in strings.split_lines_iterator(&text) {
		line := strings.trim_space(whole)
		if line == "" || line[0] == '#' {
			continue
		}
		o, ok := offer_parse(strings.fields(line, context.temp_allocator))
		if !ok || len(p.offers) >= MAX_OFFERS {
			report(.Warning, "an offer makes no sense, and is not made: ", line)
			continue
		}
		o.host, o.name = strings.clone(o.host), strings.clone(o.name)
		append(&p.offers, o)
	}
}

@(private)
offers_save :: proc(p: ^Ports) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# What this device offers others of its space: see zspd offer.\n")
	for &o in p.offers {
		strings.write_string(&b, offer_text(&o))
		strings.write_byte(&b, '\n')
	}
	file_disk_make(&p.space.disk)
	return save(file_in(p.space.dir, "offers"), b.buf[:])
}

// Adds an offer, or with `remove` takes back one the same; then tells everyone kept up, and ends whatever is no
// longer offered. The offer's strings are copied.
offers_change :: proc(sp: ^Space, o: Offer, remove: bool) -> bool {
	p := sp.ports
	if p == nil {
		return false
	}
	o := o
	// An offer in a scope this device may not call in could never be taken up: it is refused, not kept for nothing.
	if !offer_sound(&o) || (!remove && .Call not_in zsp.device_rights(&sp.node, sp.host.device, o.scope)) {
		return false
	}
	at := -1
	for &x, i in p.offers {
		if x.lo == o.lo && x.hi == o.hi && x.scope == o.scope && x.device == o.device && x.host == o.host {
			at = i
		}
	}
	switch {
	case remove && at < 0:
		return false
	case remove:
		offer_destroy(&p.offers[at])
		ordered_remove(&p.offers, at)
	case at >= 0:
		p.offers[at].proxy = o.proxy
		delete(p.offers[at].name)
		p.offers[at].name = strings.clone(o.name)
	case len(p.offers) >= MAX_OFFERS:
		return false
	case:
		append(&p.offers, Offer{o.lo, o.hi, o.scope, o.device, strings.clone(o.host), strings.clone(o.name), o.proxy})
	}
	if !offers_save(p) {
		report(.Error, "could not save what this device offers")
	}
	audit(sp, {device = o.device, scope = o.scope, service = "offer", detail = strings.concatenate({"-" if remove else "+", offer_text(&o)}, context.temp_allocator), event = .Change})
	forwards_recheck(sp) // what is no longer offered is cut off
	watchers_tell(p, scan = true)
	return true
}

// Whether a device may reach a port of this one, and whether it is to be told who it is: set as the host's
// port_permitted, which every inbound zsp.tcp asks.
@(private)
port_permitted :: proc(sp: ^Space, caller: zsp.Key32, scope: zsp.Scope, port: u16, target: string) -> (ok: bool, proxy: bool) {
	p := sp.ports
	if p == nil || caller == sp.host.device {
		return
	}
	// Only what is offered in the scope called in: the scope is what was granted, and what is said of the call.
	for &o in p.offers {
		if o.scope != scope || (o.device != {} && o.device != caller) || port < o.lo || port > o.hi || o.host != target {
			continue
		}
		if .Call not_in zsp.device_rights(&sp.node, caller, o.scope) || .Call not_in zsp.device_rights(&sp.node, sp.host.device, o.scope) {
			continue
		}
		if o.host == "" && own_port(sp.host, port) {
			continue
		}
		return true, o.proxy
	}
	return
}

// Whether this machine's port is one of the host's own, which is never offered nor exposed: it would reach through
// this device what this device reaches. Asked of the sockets themselves, as bound, so that one on port 0 is known by
// the port it was given.
@(private, require_results)
own_port :: proc(h: ^Host, port: u16) -> bool {
	is :: proc(socket: net.TCP_Socket, port: u16) -> bool {
		at, err := net.bound_endpoint(socket)
		return err == nil && at.port == int(port)
	}
	return(
		(h.listen != nil && is(h.listener, port)) ||
		(h.proxy_server.open && is(h.proxy_server.socket, port)) ||
		(h.dns_server.open && is(h.dns_server.tcp, port)) ||
		(h.public.have_tls && is(h.public.tls, port)) ||
		(h.public.have_http && is(h.public.http, port)) ||
		catch_port(h) == int(port)
	)
}

// What a device is offered now, in temporary memory, ascending by port; and a hash of it.
@(private)
offered_to :: proc(p: ^Ports, device: zsp.Key32, scope: zsp.Scope = 0) -> (list: []Port_Entry, said: u64) {
	sp := p.space
	out := make([dynamic]Port_Entry, context.temp_allocator)
	taken := make(map[u16]bool, context.temp_allocator)
	size := 0
	add :: proc(out: ^[dynamic]Port_Entry, taken: ^map[u16]bool, size: ^int, e: Port_Entry) {
		if e.port in taken || size^ + 2 + 5 + len(e.host) + len(e.name) + 2 > MAX_LIST {
			return
		}
		taken[e.port] = true
		size^ += 2 + 5 + len(e.host) + len(e.name) + 2
		append(out, e)
	}
	for &o in p.offers {
		if (o.device != {} && o.device != device) || (scope != 0 && o.scope != scope) { // in one scope, if asked
			continue
		}
		if .Call not_in zsp.device_rights(&sp.node, device, o.scope) || .Call not_in zsp.device_rights(&sp.node, sp.host.device, o.scope) {
			continue
		}
		if o.host != "" {
			for port in int(o.lo) ..= int(o.hi) {
				add(&out, &taken, &size, {u16(port), o.scope, o.host, o.name})
			}
			continue
		}
		for a in p.listening {
			if a.port >= o.lo && a.port <= o.hi && reachable_here(a) && !own_port(sp.host, a.port) {
				add(&out, &taken, &size, {a.port, o.scope, "", o.name})
			}
		}
	}
	slice.sort_by(out[:], proc(a, b: Port_Entry) -> bool {
		return a.port < b.port
	})
	w := make([dynamic]byte, context.temp_allocator)
	entries_put(&w, out[:])
	return out[:], hash_bytes(w[:])
}

// Whether what listens there is reached by connecting to this machine's loopback: everything, or loopback.
@(private, require_results)
reachable_here :: proc(a: pipe.Address) -> bool {
	any4 := pipe.address_v4(0, 0, 0, 0, a.port)
	local4 := pipe.address_v4(127, 0, 0, 1, a.port)
	return a.ip == {} || a.ip == {15 = 1} || a.ip == any4.ip || a.ip == local4.ip
}

@(private)
hash_bytes :: proc(b: []byte) -> u64 {
	h := u64(0xcbf29ce484222325)
	for c in b {
		h = (h ~ u64(c)) * 0x100000001b3
	}
	return h
}

// n varint ‖ n × { port (2) ‖ scope varint ‖ host bytes ‖ name bytes }
entries_put :: proc(w: ^[dynamic]byte, list: []Port_Entry) {
	zsp.write_varint(w, u64(len(list)))
	for e in list {
		append(w, byte(e.port >> 8), byte(e.port))
		zsp.write_varint(w, u64(e.scope))
		zsp.write_bytes(w, transmute([]byte)e.host)
		zsp.write_bytes(w, transmute([]byte)e.name)
	}
}

// In temporary memory; the strings point into `b`.
@(require_results)
entries_read :: proc(b: []byte) -> (list: []Port_Entry, ok: bool) {
	// As a device says it (offered_to): so much at most, of ports, names and addresses, else it is not believed.
	r := zsp.Reader{buf = b}
	n := zsp.read_varint(&r)
	if r.bad || n > u64(len(b)) || len(b) > MAX_LIST + 10 {
		return
	}
	out := make([]Port_Entry, n, context.temp_allocator)
	for &e in out {
		port := zsp.read_take(&r, 2)
		scope := zsp.read_varint(&r)
		e.host = string(zsp.read_bytes(&r))
		e.name = string(zsp.read_bytes(&r))
		if r.bad || scope == 0 || scope >= u64(max(zsp.Scope)) || !offer_name_sound(e.name) {
			return
		}
		e.port, e.scope = u16(port[0]) << 8 | u16(port[1]), zsp.Scope(scope)
		if e.port == 0 || e.host != "" && net.parse_address(e.host) == nil {
			return
		}
	}
	return out, zsp.read_done(&r)
}

// ---------------------------------------------------------------- keeping devices up with what they are offered

// zsp.ports: what this device offers the caller. The first message is how many seconds to keep it up (0: say it
// once); each message back is the whole list, again whenever it changes, until then. Another message from the
// caller asks for as long again.
@(private)
ports_called :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	p := sp.ports
	if p == nil || from.local != nil || from.relay {
		return nil, .Denied
	}
	r := zsp.Reader{buf = first}
	lease := zsp.read_varint(&r)
	if !zsp.read_done(&r) {
		return nil, .Denied
	}
	each := 0
	for w in p.watchers {
		each += 1 if w.device == from.device else 0
	}
	if lease > 0 && (len(p.watchers) >= MAX_WATCHERS || each >= WATCHERS_EACH) {
		return nil, .Busy
	}
	w := new(Port_Watch)
	w.ports, w.call, w.device, w.once = p, call, from.device, lease == 0
	w.until = time.tick_add(time.tick_now(), time.Duration(min(lease, MAX_LEASE)) * time.Second)
	w.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		w := (^Port_Watch)(h)
		if w.once {
			return true // not counted among those kept up, so never one of them
		}
		r := zsp.Reader{buf = bytes}
		lease := zsp.read_varint(&r)
		if zsp.read_done(&r) {
			w.until = time.tick_add(time.tick_now(), time.Duration(min(lease, MAX_LEASE)) * time.Second)
		}
		return true
	}
	w.on_end = proc(h: ^Call_Handler, call: u64) {
		w := (^Port_Watch)(h)
		if w.once && !w.ended {
			w.heard = true // asked once, and said all it will as it asked: answered all the same, then over
			return
		}
		if !w.ended {
			call_end(w.ports.space, w.call)
			watcher_drop(w)
		}
		free(w) // the call is over both ways
	}
	w.on_fault = proc(h: ^Call_Handler, call: u64, _: zsp.Call_Fault) {
		w := (^Port_Watch)(h)
		if !w.ended {
			watcher_drop(w)
		}
		free(w)
	}
	w.on_room = proc(h: ^Call_Handler, call: u64) {
		w := (^Port_Watch)(h)
		if w.owed {
			watcher_tell(w)
			if w.once && !w.owed {
				w.ports.telling = true // said at last: over, as soon as the host next looks
			}
		}
	}
	append(&p.watchers, w)
	// Said once the call is the host's to speak in, which it is when this returns: on the next tick.
	if len(p.watchers) == 1 || time.tick_diff(p.scanned, time.tick_now()) > SCAN_EVERY {
		p.scan_due = true
	}
	w.owed = true
	p.telling = true
	return w, {}
}

// No longer kept up; the watch itself is freed when its call is over.
@(private)
watcher_drop :: proc(w: ^Port_Watch) {
	p := w.ports
	w.ended = true
	for x, i in p.watchers {
		if x == w {
			unordered_remove(&p.watchers, i)
			break
		}
	}
}

// Says the list again to whoever is kept up, if it differs; first looks again at what is listening, if asked.
@(private)
watchers_tell :: proc(p: ^Ports, scan := false) {
	if scan && len(p.watchers) > 0 {
		ports_scan(p)
	}
	for w in p.watchers {
		w.owed = true
	}
	p.telling = true
}

@(private)
watcher_tell :: proc(w: ^Port_Watch) {
	sp := w.ports.space
	list, said := offered_to(w.ports, w.device)
	if said == w.said && w.said != 0 {
		w.owed = false
		return
	}
	b := make([dynamic]byte, context.temp_allocator)
	entries_put(&b, list)
	if !call_send(sp, w.call, b[:]) {
		w.owed = true // when there is room
		return
	}
	w.said, w.owed = said, false
}

@(private)
ports_scan :: proc(p: ^Ports) {
	p.scanned = time.tick_now()
	p.scan_due = false
	found, ok := tcp_listening()
	if !ok {
		return // as it was
	}
	clear(&p.listening)
	for a in found {
		if !slice.contains(p.listening[:], a) {
			append(&p.listening, a)
		}
	}
}

// Everything due: scans while anybody is kept up, what is owed them, and the end of their leases.
@(private)
offers_run :: proc(p: ^Ports, now: time.Tick) {
	if len(p.watchers) > 0 && (p.scan_due || time.tick_diff(p.scanned, now) >= SCAN_EVERY) {
		before := len(p.listening)
		said := hash_bytes(slice.to_bytes(p.listening[:]))
		ports_scan(p)
		if len(p.listening) != before || hash_bytes(slice.to_bytes(p.listening[:])) != said {
			for w in p.watchers {
				w.owed = true
			}
			p.telling = true
		}
	}
	if p.telling {
		p.telling = false
		#reverse for w in p.watchers {
			if w.owed {
				watcher_tell(w)
			}
		}
	}
	#reverse for w in p.watchers {
		if time.tick_diff(w.until, now) >= 0 && !(w.once && w.owed) {
			call_end(p.space, w.call) // a lease of 0 ends here, once said
			watcher_drop(w)
			if w.heard {
				free(w) // over both ways
			}
		}
	}
}

@(private)
offers_deadline :: proc(p: ^Ports) -> (due: time.Tick, ok: bool) {
	if len(p.watchers) == 0 {
		return
	}
	if p.telling || p.scan_due {
		return time.tick_now(), true
	}
	due = time.tick_add(p.scanned, SCAN_EVERY)
	for w in p.watchers {
		if w.until._nsec < due._nsec {
			due = w.until
		}
	}
	return due, true
}
