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
// What a device offers is asked when anyone here seems to want it (its name looked up, a connection made, a client
// asking), and kept up for as long as that lasts, and no longer: an idle space costs nothing.

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
	owed:      bool, // a lease is to be asked for as soon as there is room in the call
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
		// One joined to its port is ended by its bridge, which says so to public_in_bridged, which lets it go.
		if c := p.public[0]; c.forward != nil {
			forward_close(c.forward)
		} else {
			public_in_drop(c)
		}
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
		// Asked again only once less than half the lease is left: time.tick_diff(now, leased) is what is left.
		if r.call == 0 || r.owed || time.tick_diff(now, r.leased) > INTEREST / 2 {
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
		if r.call != 0 && !r.owed && time.tick_diff(r.wanted, time.tick_now()) < INTEREST {
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
	watchers_tell(p) // what it allowed is cut off already, by the host's own look at its forwards
	p.reach = 0 // look again at everyone
	for r in p.remotes {
		r.unserved = false
	}
}

// Who can be reached has changed: those gone are listened for no longer, so that whoever connects is told at once.
// Those newly reachable are asked nothing until anybody here wants them (ports_wanted): a quiet space costs nothing,
// however many devices come and go.
@(private)
ports_reach :: proc(p: ^Ports, reach: []zsp.Key32) {
	for r in p.remotes {
		r.reachable = slice.contains(reach, r.device) && remote_scope(r) != 0
	}
	#reverse for r, i in p.remotes {
		if !r.reachable {
			unordered_remove(&p.remotes, i)
			remote_drop(r)
		}
	}
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
	r.on_room = proc(h: ^Call_Handler, call: u64) {
		r := (^Remote)(h)
		if r.owed && call == r.call {
			remote_lease(r, time.tick_now())
		}
	}
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
	r.owed = !call_send(r.ports.space, r.call, b[:])
	if !r.owed {
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
	if r.call == 0 || time.tick_diff(now, r.leased) <= INTEREST / 2 {
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
	looked:  bool, // the guard has seen what came first
}

@(private)
listener_accepted :: proc(op: ^nbio.Operation, l: ^Listener) {
	l.accepting = nbio.accept_poly(l.socket, l, listener_accepted)
	if op.accept.err != nil {
		return
	}
	local, err := net.bound_endpoint(op.accept.client)
	if err != nil {
		socket_abort(op.accept.client)
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
		socket_abort(socket)
		return
	}
	device := m.device
	r := remote_for(sp.ports, device, make = slice.contains(zsp.node_reach(&sp.node), device))
	if r == nil {
		socket_abort(socket) // it cannot be reached: as if nothing were there
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
	// Told how it went, maybe before forward returns, and then c is gone: so it is kept only if it is a forward.
	if f := forward(sp, device, entry.scope, entry.port, entry.host, socket, connection_done, c, http_guard); f != nil {
		c.forward = f
	}
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
http_guard :: proc(data: rawptr, first: []byte) -> Inspection {
	c := (^Connection)(data)
	request := 0
	verdict, reason := http_verdict(c.sp, c.device, first, first_look = !c.looked, request = &request)
	c.looked = true
	if verdict == .Reject {
		forward_reply(c.forward, http_forbidden(reason))
	} else if verdict == .Pass && request > 0 {
		forward_look_again(c.forward, request) // and the next request on it, as this one
	}
	return verdict
}

// What a forward's socket is told as it is rejected, by an inspector that rejects it. Only that: the bridge rejects it
// once the inspector has returned, for rejecting may end it, and then nothing of it may be touched.
@(private)
forward_reply :: proc(f: ^Forward, reply: []byte) {
	delete(f.reply)
	f.reply = make([]byte, len(reply))
	copy(f.reply, reply)
}

@(private)
http_forbidden :: proc(reason: string) -> []byte {
	return transmute([]byte)fmt.tprintf("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s\n", len(reason) + 1, reason)
}

// Whether the first bytes of a connection are a web request, and if so whether it may pass (SPEC §17). Whatever a
// browser sends begins with a request line, `<method> <target> HTTP/<d>.<d>`, the method any token in any case (fetch
// sends what it is given); so whatever cannot begin so is no browser's, and passes, and whatever can is waited for
// until it is whole. But a browser writes its request's head at once, and these connections come by loopback, where
// what is written at once is read at once: so what came first (`first_look`), if it is a token and nothing after,
// not even a space, is no browser's either. The head is read as the most lenient server would read it (empty lines
// before it, lines that end in LF alone), and anything a server could read two ways is refused: two Hosts or
// Origins, a folded line, a line that is no header. Only the first request is looked at: a browser keeps a
// connection for one origin, the one whose name the first request carries.
@(private)
http_verdict :: proc(sp: ^Space, device: zsp.Key32, first: []byte, first_look := false, request: ^int = nil) -> (Inspection, string) {
	b := first
	for len(b) > 0 && (b[0] == '\r' || b[0] == '\n') {
		b = b[1:]
	}
	// The request line, as far as it has come: method SP target SP HTTP/d.d.
	i := 0
	for i < len(b) && tchar(b[i]) {
		i += 1
	}
	if i == len(b) {
		// A short word and nothing else, the whole of what came first: not a browser's, which says its request's head
		// at once. Anything longer might be the start of one (a read takes so much, and no more).
		if first_look && i > 0 && i <= FIRST_WORD_MOST && len(b) == len(first) {
			return .Pass, ""
		}
		return .More, ""
	}
	// What does not read as a request line passes, being no web request; but not one that begins with a method of
	// HTTP's, nor one that began as a request does (a token, a space) and names HTTP's version on its first line:
	// a server would read either as a request however it went on. That line is waited for, but only so far.
	method := string(b[:i])
	not_a_line :: proc(method: string, b: []byte = nil) -> (Inspection, string) {
		if http_method(method) {
			return .Reject, "a request that could be read two ways"
		}
		if b == nil {
			return .Pass, ""
		}
		line := b
		if lf := strings.index_byte(string(b), '\n'); lf >= 0 {
			line = b[:lf]
		} else if len(b) < LINE_LOOK {
			return .More, ""
		}
		if strings.contains(string(line), "HTTP/") {
			return .Reject, "a request that could be read two ways"
		}
		return .Pass, ""
	}
	if i == 0 || b[i] != ' ' {
		return not_a_line(method, b if i > 0 && b[i] == '\t' else nil) // a tab after a token: as a space would be
	}
	i += 1
	target_start := i
	for i < len(b) && b[i] > ' ' && b[i] < 0x7f {
		i += 1
	}
	if i == len(b) {
		return .More, ""
	}
	if i == target_start || b[i] != ' ' {
		return not_a_line(method, b)
	}
	target := string(b[target_start:i])
	i += 1
	version := "HTTP/d.d"
	for k in 0 ..< len(version) {
		if i + k == len(b) {
			return .More, ""
		}
		c := b[i + k]
		if version[k] == 'd' ? !(c >= '0' && c <= '9') : c != version[k] {
			return not_a_line(method, b)
		}
	}
	i += len(version)
	if i < len(b) && b[i] == '\r' {
		i += 1
	}
	if i == len(b) {
		return .More, ""
	}
	if b[i] != '\n' {
		return not_a_line(method, b)
	}
	// A web request: its head, whole, line by line.
	rest := string(b[i + 1:])
	host, origin, length: Maybe(string)
	whole, unbounded := false, false
	for len(rest) > 0 {
		lf := strings.index_byte(rest, '\n')
		if lf < 0 {
			break
		}
		line := strings.trim_suffix(rest[:lf], "\r")
		rest = rest[lf + 1:]
		if line == "" {
			whole = true
			break
		}
		colon := strings.index_byte(line, ':')
		if line[0] == ' ' || line[0] == '\t' || colon <= 0 {
			return .Reject, "a header that could be read two ways"
		}
		name := line[:colon]
		for c in transmute([]byte)name {
			if !tchar(c) {
				return .Reject, "a header that could be read two ways"
			}
		}
		value := strings.trim(line[colon + 1:], " \t")
		switch {
		case strings.equal_fold(name, "host"):
			if host != nil {
				return .Reject, "two names"
			}
			host = value
		case strings.equal_fold(name, "origin"):
			if origin != nil {
				return .Reject, "two origins"
			}
			origin = value
		case strings.equal_fold(name, "content-length"):
			if length != nil {
				return .Reject, "two lengths"
			}
			length = value
		case strings.equal_fold(name, "transfer-encoding"), strings.equal_fold(name, "upgrade"):
			unbounded = true // its end is not to be found from here: no browser sends it so but to change protocols
		}
	}
	if !whole {
		return .More, ""
	}
	head := len(first) - len(b) + i + 1 + len(b[i + 1:]) - len(rest)
	h, has := host.?
	if !has {
		return .Reject, "a request must say which name it is for"
	}
	if name, ok := http_authority(h); !ok || !names_device(sp, device, name) {
		return .Reject, "this is not that name"
	}
	// A target in absolute form names its host too, and a server may take that over the Host.
	if scheme_end := strings.index(target, "://"); scheme_end > 0 && target[0] != '/' {
		authority := target[scheme_end + 3:]
		if slash := strings.index_any(authority, "/?#"); slash >= 0 {
			authority = authority[:slash]
		}
		if name, ok := http_authority(authority); !ok || !names_device(sp, device, name) {
			return .Reject, "this is not that name"
		}
	}
	if o, has_origin := origin.?; has_origin {
		// As browsers write it: scheme://host[:port], and nothing more. "null", from a page that has no origin to
		// say, is no page of this space.
		scheme, sep, authority := strings.partition(o, "://")
		name, ok := http_authority(authority)
		if sep == "" || (scheme != "http" && scheme != "https") || !ok || !names_space(sp, name) {
			return .Reject, "pages of other places may not reach this"
		}
	}
	// How long the request is, so that the next on the connection is judged too (a page may send its own after one
	// that passed): the head and a body of Content-Length. Not where its end is not to be found, which a browser
	// sends only to change protocols (an upgrade, CONNECT), its own request judged.
	if request != nil && !unbounded && !strings.equal_fold(method, "CONNECT") {
		body := 0
		if l, has_length := length.?; has_length {
			if len(l) == 0 || len(l) > 15 {
				return .Reject, "a length that could be read two ways"
			}
			for c in transmute([]byte)l {
				if c < '0' || c > '9' {
					return .Reject, "a length that could be read two ways"
				}
				body = body * 10 + int(c - '0')
			}
		}
		request^ = head + body
	}
	return .Pass, ""
}

// A request's host and port, as a Host header or an origin writes them: a name or IPv4 address, or an IPv6 one in
// brackets, then a colon and digits, if anything. The host, if it is that and nothing else.
@(private)
http_authority :: proc(a: string) -> (host: string, ok: bool) {
	host = a
	port := ""
	if strings.has_prefix(a, "[") {
		close := strings.index_byte(a, ']')
		if close < 0 {
			return "", false
		}
		host, port = a[:close + 1], a[close + 1:]
	} else if colon := strings.index_byte(a, ':'); colon >= 0 {
		host, port = a[:colon], a[colon:]
	}
	if port != "" {
		if len(port) < 2 || len(port) > 6 || port[0] != ':' {
			return "", false
		}
		for c in transmute([]byte)port[1:] {
			if c < '0' || c > '9' {
				return "", false
			}
		}
	}
	if host == "" {
		return "", false
	}
	if host[0] != '[' {
		for c in transmute([]byte)host {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '.') {
				return "", false
			}
		}
	}
	return host, true
}

FIRST_WORD_MOST :: 64 // the longest word that, coming first and alone, is taken as no browser's
LINE_LOOK :: 2048 // how far a line that began as a request does, and then did not, is waited for to its end

// Whether a method is one of HTTP's own (RFC 9110 §9, RFC 5789), in any case, as fetch sends what it is given.
@(private)
http_method :: proc(m: string) -> bool {
	for known in ([]string{"GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"}) {
		if strings.equal_fold(m, known) {
			return true
		}
	}
	return false
}

// A character of an HTTP token (RFC 9110 §5.6.2).
@(private)
tchar :: proc(c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
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
