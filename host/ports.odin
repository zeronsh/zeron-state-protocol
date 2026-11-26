package host

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:slice"
import "core:strings"
import "core:time"
import "../pipe"
import "../zsp"

// Other devices' ports, here: each device that offers this one anything is listened for at its own address, on
// each port it offers, and whatever connects there is forwarded to it. So any application reaches any device by
// name, as if it were on the network, and two devices may offer the same port.
//
// What a device offers is asked once when it can first be reached, and kept up for as long as anyone here seems
// to want it (its name looked up, a connection made), and no longer: an idle space costs nothing.

SETUP_HINT :: "; see zspd setup" when ODIN_OS == .Darwin else ""
INTEREST :: 60 * time.Second // how long a look or a connection keeps a device's list kept up
MAX_LISTENERS :: 4096

Ports :: struct {
	space:     ^Space,
	// What this device offers: offers.odin.
	offers:    [dynamic]Offer,
	watchers:  [dynamic]^Port_Watch,
	listening: [dynamic]pipe.Address,
	scanned:   time.Tick,
	scan_due:  bool,
	telling:   bool,
	// Other devices, as reached from here.
	remotes:   [dynamic]^Remote,
	reach:     u64, // a hash of who could be reached when last looked
	warned:    bool, // that addresses cannot be listened at
	// What this device exposes to the public: expose.odin.
	exposures: [dynamic]Exposure,
	exposed:   u64, // a count of changes to them
	told:      map[u32]u64, // relay sessions, and the count they were last told
	ever_told: map[u32]bool,
	public:    [dynamic]^Public_In, // connections from the public, under way
}

Remote :: struct {
	using handler: Call_Handler, // of the zsp.ports call
	ports:     ^Ports,
	device:    zsp.Key32,
	call:      u64, // zsp.ports, while under way
	leased:    time.Tick, // until when it was asked to be kept up
	wanted:    time.Tick, // last sign that anyone here wants it
	entries:   [dynamic]Port_Entry, // its strings owned
	known:     bool, // what it offers has been heard since it could be reached
	reachable: bool,
	unserved:  bool, // it does not offer ports at all
	listeners: [dynamic]^Listener,
	forwards:  int,
}

Listener :: struct {
	remote:    ^Remote,
	port:      u16,
	socket:    net.TCP_Socket,
	accepting: ^nbio.Operation,
}

// A device's ports, as reached from here: every space but a relay's.
@(private)
ports_open :: proc(sp: ^Space) {
	p := new(Ports)
	p.space = sp
	sp.ports = p
	offers_load(p)
	exposures_load(p)
}

@(private)
ports_close :: proc(sp: ^Space) {
	p := sp.ports
	if p == nil {
		return
	}
	for len(p.remotes) > 0 {
		remote_drop(pop(&p.remotes))
	}
	for w in p.watchers {
		free(w)
	}
	for &o in p.offers {
		offer_destroy(&o)
	}
	for len(p.public) > 0 {
		public_in_drop(p.public[0])
	}
	for &e in p.exposures {
		exposure_destroy(&e)
	}
	delete(p.exposures)
	delete(p.public)
	delete(p.told)
	delete(p.ever_told)
	delete(p.remotes)
	delete(p.watchers)
	delete(p.offers)
	delete(p.listening)
	free(p)
	sp.ports = nil
}

// Everything that follows from what happened: who can be reached, what is owed, what has lapsed.
@(private)
ports_run :: proc(sp: ^Space, now: time.Tick) {
	p := sp.ports
	if p == nil || sp.node.keys == nil {
		return
	}
	offers_run(p, now)
	exposures_tell(p)
	reach := zsp.node_reach(&sp.node)
	said := hash_bytes(slice.to_bytes(reach))
	if said != p.reach {
		p.reach = said
		ports_reach(p, reach)
	}
	for r in p.remotes {
		if r.call == 0 || time.tick_diff(r.leased, time.tick_add(now, INTEREST / 2)) > 0 {
			continue
		}
		// Kept up, and wanted still: ask for as long again before it lapses.
		if time.tick_diff(r.wanted, now) < INTEREST {
			remote_lease(r, now)
		}
	}
}

@(private)
ports_deadline :: proc(sp: ^Space) -> (due: time.Tick, ok: bool) {
	p := sp.ports
	if p == nil {
		return
	}
	due, ok = offers_deadline(p)
	for r in p.remotes {
		if r.call != 0 && time.tick_diff(r.wanted, time.tick_now()) < INTEREST {
			renew := time.tick_add(r.leased, -INTEREST / 2)
			if !ok || renew._nsec < due._nsec {
				due, ok = renew, true
			}
		}
	}
	return
}

// The roster changed: what is offered may have, both ways, and what was allowed may be no longer.
@(private)
ports_roster :: proc(sp: ^Space) {
	p := sp.ports
	if p == nil {
		return
	}
	forwards_recheck(sp)
	watchers_tell(p)
	p.reach = 0 // look again at everyone
	for r in p.remotes {
		r.unserved = false
	}
}

// Who can be reached has changed: those newly reachable are asked what they offer; those gone are listened for no
// longer, so that whoever connects is told at once.
@(private)
ports_reach :: proc(p: ^Ports, reach: []zsp.Key32) {
	sp := p.space
	for r in p.remotes {
		r.reachable = slice.contains(reach, r.device) && remote_scope(r) != 0
	}
	#reverse for r, i in p.remotes {
		if !r.reachable {
			unordered_remove(&p.remotes, i)
			remote_drop(r)
		}
	}
	for device in reach {
		r := remote_for(p, device)
		if r != nil && !r.known && r.call == 0 && !r.unserved {
			remote_ask(r, 0)
		}
	}
	_ = sp
}

@(private)
remote_for :: proc(p: ^Ports, device: zsp.Key32, make := true) -> ^Remote {
	for r in p.remotes {
		if r.device == device {
			return r
		}
	}
	if !make {
		return nil
	}
	r := new(Remote)
	r.ports, r.device = p, device
	if remote_scope(r) == 0 {
		free(r)
		return nil
	}
	r.reachable = true
	r.on_data = remote_heard
	r.on_end = proc(h: ^Call_Handler, call: u64) {
		r := (^Remote)(h)
		if call == r.call {
			call_end(r.ports.space, call)
			r.call = 0
		}
	}
	r.on_fault = proc(h: ^Call_Handler, call: u64, f: zsp.Call_Fault) {
		r := (^Remote)(h)
		if call == r.call {
			r.call = 0
			r.unserved ||= f == .Unserved || f == .Denied
		}
	}
	append(&p.remotes, r)
	return r
}

// The least scope in which both devices may call, if any: what is asked of it is asked there.
@(private)
remote_scope :: proc(r: ^Remote) -> zsp.Scope {
	sp := r.ports.space
	for s in sp.node.roster.scopes {
		if .Call in zsp.device_rights(&sp.node, sp.host.device, s.id) && .Call in zsp.device_rights(&sp.node, r.device, s.id) {
			return s.id
		}
	}
	return 0
}

// Asks a device what it offers: once, or to be kept up for so many seconds.
@(private)
remote_ask :: proc(r: ^Remote, seconds: u64) {
	sp := r.ports.space
	scope := remote_scope(r)
	if scope == 0 {
		return
	}
	b := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&b, seconds)
	r.call = host_call(sp, r.device, scope, "zsp.ports", b[:], r)
	r.leased = time.tick_add(time.tick_now(), time.Duration(seconds) * time.Second)
}

@(private)
remote_lease :: proc(r: ^Remote, now: time.Tick) {
	if r.call == 0 {
		remote_ask(r, u64(INTEREST / time.Second))
		return
	}
	b := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&b, u64(INTEREST / time.Second))
	if call_send(r.ports.space, r.call, b[:]) {
		r.leased = time.tick_add(now, INTEREST)
	}
}

// Somebody here wants a device: its name was looked up, or a connection made to it. It is kept up for a while.
@(private)
ports_wanted :: proc(sp: ^Space, device: zsp.Key32) {
	p := sp.ports
	if p == nil || device == sp.host.device {
		return
	}
	r := remote_for(p, device, make = slice.contains(zsp.node_reach(&sp.node), device))
	if r == nil || r.unserved {
		return
	}
	now := time.tick_now()
	r.wanted = now
	if r.call == 0 || time.tick_diff(r.leased, time.tick_add(now, INTEREST / 2)) < 0 {
		remote_lease(r, now)
	}
}

// A list has come: listen for what is new, and no longer for what is gone.
@(private)
remote_heard :: proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
	r := (^Remote)(h)
	list, ok := entries_read(bytes)
	if !ok {
		call_cancel(r.ports.space, call)
		if call == r.call {
			r.call = 0
		}
		return true
	}
	for &e in r.entries {
		delete(e.host)
		delete(e.name)
	}
	clear(&r.entries)
	for e in list {
		append(&r.entries, Port_Entry{e.port, e.scope, strings.clone(e.host), strings.clone(e.name)})
	}
	r.known = true
	remote_listen(r)
	return true
}

@(private)
remote_listen :: proc(r: ^Remote) {
	sp := r.ports.space
	all_caught := caught(sp.host)
	#reverse for l, i in r.listeners {
		found := false
		for e in r.entries {
			found ||= e.port == l.port
		}
		if !found || all_caught {
			unordered_remove(&r.listeners, i)
			listener_close(l)
		}
	}
	ip, has := device_address(sp, r.device)
	if !has || all_caught {
		return
	}
	// On Linux, a port this machine already listens on everywhere cannot be listened for here, and one listened for
	// here would keep it from this machine's own: those are left alone (zspd setup makes this unnecessary).
	in_use: []pipe.Address
	when ODIN_OS == .Linux {
		in_use, _ = tcp_listening()
	}
	total := 0
	for x in r.ports.remotes {
		total += len(x.listeners)
	}
	next: for e in r.entries {
		for l in r.listeners {
			if l.port == e.port {
				continue next
			}
		}
		if total >= MAX_LISTENERS {
			break
		}
		for a in in_use {
			if a.port == e.port && (a.ip == {} || a.ip == pipe.address_v4(0, 0, 0, 0, 0).ip) {
				continue next
			}
		}
		at := net.Endpoint{net.IP4_Address(ip), int(e.port)}
		socket, err := listen_on(at)
		if err != nil {
			if !r.ports.warned {
				r.ports.warned = true
				report(.Warning, "cannot listen at ", net.endpoint_to_string(at, context.temp_allocator), ": ", fmt.tprint(err), SETUP_HINT)
			}
			continue
		}
		l := new(Listener)
		l.remote, l.port, l.socket = r, e.port, socket
		l.accepting = nbio.accept_poly(socket, l, listener_accepted)
		append(&r.listeners, l)
		total += 1
	}
}

@(private)
listener_close :: proc(l: ^Listener) {
	if l.accepting != nil {
		nbio.remove(l.accepting)
	}
	net.close(l.socket)
	free(l)
}

@(private)
remote_drop :: proc(r: ^Remote) {
	sp := r.ports.space
	for l in r.listeners {
		listener_close(l)
	}
	delete(r.listeners)
	if r.call != 0 {
		call_cancel(sp, r.call)
	}
	for &e in r.entries {
		delete(e.host)
		delete(e.name)
	}
	delete(r.entries)
	free(r)
}

@(private)
Connection :: struct {
	remote:  ^Remote,
	device:  zsp.Key32,
	sp:      ^Space,
	forward: ^Forward,
}

@(private)
listener_accepted :: proc(op: ^nbio.Operation, l: ^Listener) {
	l.accepting = nbio.accept_poly(l.socket, l, listener_accepted)
	if op.accept.err != nil {
		return
	}
	local, err := net.bound_endpoint(op.accept.client)
	if err != nil {
		socket_reset(op.accept.client)
		return
	}
	ports_accept(l.remote.ports.space, op.accept.client, local, op.accept.client_endpoint)
}

// Someone connected to a device's address here, at `local`, from `from`. Nobody but this user may borrow what this
// device may reach, and no web page that was led here by a name of its own.
@(private)
ports_accept :: proc(sp: ^Space, socket: net.TCP_Socket, local, from: net.Endpoint) {
	ip, v4 := local.address.(net.IP4_Address)
	m := address_member(sp, {ip[0], ip[1], ip[2], ip[3]}) if v4 && sp.ports != nil else nil
	if m == nil || (!sp.host.trust_local_users && !tcp_peer_is_mine(address_from(local), address_from(from))) {
		socket_reset(socket)
		return
	}
	device := m.device
	r := remote_for(sp.ports, device, make = slice.contains(zsp.node_reach(&sp.node), device))
	if r == nil {
		socket_reset(socket) // it cannot be reached: as if nothing were there
		return
	}
	// What it said it offers says where to; a port it has not said is asked of it as this machine's, and it decides.
	port := u16(local.port)
	entry := Port_Entry{port, remote_scope(r), "", ""}
	for e in r.entries {
		if e.port == port {
			entry = e
		}
	}
	ports_wanted(sp, device)
	c := new(Connection)
	c.remote, c.device, c.sp = r, device, sp
	r.forwards += 1
	c.forward = forward(sp, device, remote_scope(r), entry.port, entry.host, socket, connection_done, c, http_guard)
}

@(private)
connection_done :: proc(data: rawptr, status: Forward_Status) {
	if status == .Connected {
		return
	}
	c := (^Connection)(data)
	if p := c.sp.ports; p != nil {
		if r := remote_for(p, c.device, make = false); r != nil && r == c.remote {
			r.forwards -= 1
		}
	}
	free(c)
}

// The first bytes of a connection, if they are a web request: the name it was asked by must be the device's, and a
// page that sent it must be of this space. So a page elsewhere whose own name it has pointed here (DNS rebinding)
// reaches nothing. Anything else passes.
@(private)
http_guard :: proc(data: rawptr, first: []byte) -> Inspect {
	c := (^Connection)(data)
	verdict, reason := http_verdict(c.sp, c.device, first)
	if verdict == .Reject {
		reply := fmt.tprintf("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s\n", len(reason) + 1, reason)
		forward_reject(c.forward, transmute([]byte)reply)
	}
	return verdict
}

@(private)
http_verdict :: proc(sp: ^Space, device: zsp.Key32, first: []byte) -> (Inspect, string) {
	// A method, a space: or it is not HTTP, and none of this applies.
	method := 0
	for method < len(first) && method < 16 && first[method] >= 'A' && first[method] <= 'Z' {
		method += 1
	}
	if method == len(first) && method < 16 {
		return .More, ""
	}
	if method == 0 || method >= 16 || first[method] != ' ' {
		return .Pass, ""
	}
	end := strings.index(string(first), "\r\n\r\n")
	if end < 0 {
		return .More, ""
	}
	head := string(first[:end])
	_, _, rest := strings.partition(head, "\r\n")
	host, origin: Maybe(string)
	for line in strings.split_lines_iterator(&rest) {
		name, colon, value := strings.partition(line, ":")
		if colon == "" {
			continue
		}
		value = strings.trim_space(value)
		switch {
		case strings.equal_fold(name, "host"):
			if host != nil {
				return .Reject, "two names"
			}
			host = value
		case strings.equal_fold(name, "origin"):
			origin = value
		}
	}
	if h, has := host.?; has && !names_device(sp, device, strip_port(h)) {
		return .Reject, "this is not that name"
	}
	if o, has := origin.?; has {
		_, scheme, at := strings.partition(o, "://")
		if scheme == "" || !names_space(sp, strip_port(at)) {
			return .Reject, "pages of other places may not reach this"
		}
	}
	return .Pass, ""
}

@(private)
strip_port :: proc(h: string) -> string {
	if colon := strings.last_index_byte(h, ':'); colon >= 0 && !strings.contains(h[colon:], "]") {
		return h[:colon]
	}
	return h
}

// Whether a name or address, as a web client writes it, is this device's.
@(private)
names_device :: proc(sp: ^Space, device: zsp.Key32, written: string) -> bool {
	name := strings.to_lower(strings.trim_suffix(written, "."), context.temp_allocator)
	if ip, has := device_address(sp, device); has {
		if name == fmt.tprintf("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]) {
			return true
		}
	}
	rest, under := cut_suffix(name, strings.concatenate({".", sp.naming.suffix}, context.temp_allocator))
	m := name_member(sp, rest) if under else nil
	return m != nil && m.device == device
}

// Whether a name or address, as a web client writes it, is any of this space's.
@(private)
names_space :: proc(sp: ^Space, written: string) -> bool {
	name := strings.to_lower(strings.trim_suffix(written, "."), context.temp_allocator)
	if rest, under := cut_suffix(name, strings.concatenate({".", sp.naming.suffix}, context.temp_allocator)); under {
		return name_member(sp, rest) != nil
	}
	if a, ok := net.parse_address(name).(net.IP4_Address); ok {
		return address_member(sp, {a[0], a[1], a[2], a[3]}) != nil
	}
	return false
}
