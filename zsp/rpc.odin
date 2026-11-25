package zsp

import "core:slice"
import "core:strings"

// Calls between devices.
//
// A call is two streams of messages, one each way, addressed to a device and made within a scope. Each
// node along the way is a router: it knows a call by its two ends and passes messages between them. A
// call takes the direct link to the device when there is one, and otherwise a tunnel through a relay.
// It stays on the path it began on, and fails if that path fails: at most once, never twice.
//
// Between devices without a direct link, a tunnel is one Noise channel per caller and callee, whose
// messages a relay forwards as opaque signals. The relay keeps nothing for it and, since every message
// counts, can neither replay nor reorder what it carries.

CALL_WINDOW :: 256 << 10 // bytes a side may send before the other grants more
MAX_CALLS :: 4096
MAX_METHOD :: 255
MAX_FLOW :: 1024 // of anything but data
MAX_PENDING :: 64 // frames awaiting a tunnel, past which no more calls join them

Flow :: enum u8 {
	Data   = 0, // one message
	End    = 1, // no more messages from this side
	Fault  = 2, // code, text: the call is over
	Cancel = 3, // the caller no longer cares
	Credit = 4, // the other side may send this many more bytes
}

Call_Fault :: enum u8 {
	Denied      = 1, // not permitted, at either end
	Unreachable = 2, // no path to the device
	Unserved    = 3, // nobody there answers this method
	Lost        = 4, // the path failed: it may or may not have happened
	Overrun     = 5, // more was sent than was granted
	Busy        = 6, // too many calls
}

@(private)
CALLER :: 0
@(private)
CALLEE :: 1

@(private)
SELF :: max(u32) // the session of an end that is this node itself

@(private)
End :: struct {
	session: u32,
	tunnel:  u32, // within that session, if not zero
	id:      u64,
	ended:   bool, // has sent its last message
	granted: int, // how much more it may send
}

@(private)
Call :: struct {
	ends:  [2]End,
	scope: Scope,
	own:   bool, // between the nodes themselves
}

@(private)
Serving :: struct {
	session: u32,
	scope:   Scope,
	method:  string, // owned
}

@(private)
Tunnel :: struct {
	id:        u32,
	relay:     u32, // session
	peer:      Key32,
	mine:      bool, // this end dialled, and calls out on it
	open:      bool,
	handshake: Handshake,
	channel:   Channel,
	next:      Channel, // answered but unproven; replaces `channel` when it proves itself
	pending:   [dynamic][dynamic]byte, // frames awaiting the handshake
}

@(private)
Post :: enum u8 {
	Plain  = 0, // sealed to the device, for the host
	First  = 1,
	Second = 2,
	Out    = 3, // tunnel data from whoever dialled it
	Back   = 4, // and to them
}

rpc_destroy :: proc(n: ^Node) {
	for s in n.serving {
		delete(s.method)
	}
	for &t in n.tunnels {
		tunnel_free(&t)
	}
	delete(n.serving)
	delete(n.tunnels)
	delete(n.calls)
}

// ---------------------------------------------------------------- from local clients

// scope, 1 to serve or 0 to cease, method
@(private)
on_serve :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	scope := Scope(read_varint(r))
	on := read_u8(r) == 1
	method := string(read_bytes(r))
	// Whether it may is asked when a call comes: rights come and go.
	if r.bad || s.role != .Open || len(method) > MAX_METHOD || len(n.serving) >= MAX_CALLS {
		r.bad = true
		return
	}
	for x, i in n.serving {
		if x.session == s.id && x.scope == scope && x.method == method {
			delete(x.method)
			unordered_remove(&n.serving, i)
			break
		}
	}
	if on {
		append(&n.serving, Serving{s.id, scope, strings.clone(method)})
	}
}

// id, device, scope, method, first message
@(private)
on_call :: proc(s: ^Session, r: ^Reader, tunnel: ^Tunnel = nil) {
	n := s.node
	id := read_varint(r)
	device := read_key32(r)
	scope := Scope(read_varint(r))
	method := string(read_bytes(r))
	body := read_take(r, len(r.buf) - r.pos)
	if r.bad || n.keys == nil {
		r.bad = true
		return
	}
	from := End{session = s.id, tunnel = tunnel.id if tunnel != nil else 0, id = id, granted = CALL_WINDOW}
	refuse :: proc(n: ^Node, from: End, f: Call_Fault) {
		to := from
		call_flow(n, &to, CALLEE, .Fault, {u8(f)})
	}
	for c in n.calls {
		if c.ends[CALLER].session == from.session && c.ends[CALLER].tunnel == from.tunnel && c.ends[CALLER].id == id {
			r.bad = true // an id may be used again only once its call is over
			return
		}
	}
	local := s.role == .Open
	caller := s.peer if tunnel == nil else tunnel.peer
	own := method == ""
	need := Right.Read if own else Right.Call
	allowed := need in (session_rights(s, scope) if local else device_rights(n, caller, scope))
	if local {
		allowed &&= !own && .Call in device_rights(n, n.keys.device, scope) && .Call in device_rights(n, device, scope)
	} else {
		allowed &&= need in device_rights(n, n.keys.device, scope)
	}
	switch {
	case !allowed:
		refuse(n, from, .Denied)
		return
	case len(n.calls) >= MAX_CALLS:
		refuse(n, from, .Busy)
		return
	case len(body) > CALL_WINDOW || len(method) > MAX_METHOD:
		refuse(n, from, .Overrun)
		return
	}
	from.granted -= len(body)
	n.next_call += 1
	c := Call{scope = scope, own = own}
	c.ends[CALLER] = from
	to := &c.ends[CALLEE]
	to.id = n.next_call
	to.granted = CALL_WINDOW

	if own {
		q := &n.host.questions
		if q.called == nil {
			refuse(n, from, .Unserved)
			return
		}
		to.session = SELF
		append(&n.calls, c)
		q.called(q.data, to.id, caller, scope, body)
		return
	}
	if !local || device == n.keys.device {
		server: ^Session
		for x in n.serving {
			if x.scope == scope && x.method == method {
				server = node_session(n, x.session)
			}
		}
		if server == nil || .Call not_in session_rights(server, scope) {
			refuse(n, from, .Unserved)
			return
		}
		to.session = server.id
		append(&n.calls, c)
		call_put(&server.out, server, to.id, caller if !local else n.keys.device, scope, method, body)
		return
	}
	if f, ok := call_out(n, &c, device, method, body).?; ok {
		refuse(n, from, f)
	}
}

// Sends a call on its way to another device.
@(private)
call_out :: proc(n: ^Node, c: ^Call, device: Key32, method: string, body: []byte) -> Maybe(Call_Fault) {
	to := &c.ends[CALLEE]
	for p in n.sessions {
		if p.ready && p.role == .Peer && p.peer == device && !p.peer_relay {
			to.session = p.id
			append(&n.calls, c^)
			call_put(&p.out, p, to.id, device, c.scope, method, body)
			return nil
		}
	}
	t := tunnel_to(n, device)
	if t == nil {
		return .Unreachable
	}
	if len(t.pending) >= MAX_PENDING {
		return .Busy
	}
	to.session, to.tunnel = t.relay, t.id
	append(&n.calls, c^)
	frame: [dynamic]byte
	call_put(&frame, nil, to.id, device, c.scope, method, body)
	tunnel_send(n, t, frame)
	return nil
}

// ---------------------------------------------------------------- between nodes themselves

// Calls the node at another device, by the method with no name. 0 if it cannot be.
node_call :: proc(n: ^Node, device: Key32, scope: Scope, body: []byte) -> u64 {
	if n.keys == nil || len(n.calls) >= MAX_CALLS || len(body) > CALL_WINDOW || device == n.keys.device {
		return 0
	}
	if .Read not_in device_rights(n, n.keys.device, scope) || .Read not_in device_rights(n, device, scope) {
		return 0
	}
	n.next_call += 2
	c := Call{scope = scope, own = true}
	c.ends[CALLER] = {session = SELF, id = n.next_call - 1, granted = CALL_WINDOW - len(body)}
	c.ends[CALLEE] = {id = n.next_call, granted = CALL_WINDOW}
	if _, failed := call_out(n, &c, device, "", body).?; failed {
		return 0
	}
	return n.next_call - 1
}

// Says something in a call this node is an end of.
node_flow :: proc(n: ^Node, call: u64, kind: Flow, payload: []byte = nil) {
	for &c, i in n.calls {
		for e, side in c.ends {
			if e.session == SELF && e.id == call {
				flow_pass(n, i, side, kind, payload)
				return
			}
		}
	}
}

// How much this node may say in a call yet. 0 when there is no such call.
node_granted :: proc(n: ^Node, call: u64) -> int {
	for &c in n.calls {
		for e in c.ends {
			if e.session == SELF && e.id == call {
				return min(e.granted, CALL_WINDOW)
			}
		}
	}
	return 0
}

// Devices within reach, those linked directly first. Not those linked to and known not to be full replicas.
node_reach :: proc(n: ^Node) -> []Key32 {
	out := make([dynamic]Key32, context.temp_allocator)
	less := make([dynamic]Key32, context.temp_allocator)
	for s in n.sessions {
		if s.ready && s.role == .Peer && !s.peer_relay {
			append(&out if s.peer_full else &less, s.peer)
		}
	}
	for s in n.sessions {
		if !s.ready || s.role != .Peer || !s.peer_relay {
			continue
		}
		for device in s.online {
			if device != n.keys.device && !slice.contains(out[:], device) && !slice.contains(less[:], device) {
				append(&out, device)
			}
		}
	}
	return out[:]
}

@(private)
call_put :: proc(w: ^[dynamic]byte, s: ^Session, id: u64, device: Key32, scope: Scope, method: string, body: []byte) {
	device := device
	if s != nil {
		cells_close(s)
	}
	at := frame_begin(w, .Call)
	write_varint(w, id)
	append(w, ..device[:])
	write_varint(w, u64(scope))
	write_bytes(w, transmute([]byte)method)
	append(w, ..body)
	frame_end(w, at)
}

// What a device may do in a scope.
device_rights :: proc(n: ^Node, device: Key32, scope: Scope) -> Rights {
	m := roster_member(&n.roster, device)
	return member_rights(m, scope) if m != nil else {}
}

// ---------------------------------------------------------------- between the ends

// id and which side speaks, kind, payload
@(private)
on_flow :: proc(s: ^Session, r: ^Reader, tunnel: ^Tunnel = nil) {
	n := s.node
	tag := read_varint(r)
	kind := Flow(read_u8(r))
	payload := read_take(r, len(r.buf) - r.pos)
	if r.bad || (kind != .Data && len(payload) > MAX_FLOW) {
		r.bad = true
		return
	}
	side := int(tag & 1)
	tid := tunnel.id if tunnel != nil else 0
	for &c, i in n.calls {
		from := &c.ends[side]
		if from.session == s.id && from.tunnel == tid && from.id == tag >> 1 {
			flow_pass(n, i, side, kind, payload)
			return
		}
	}
	// Not a call of ours, or no longer: both sides speak until they hear it is over.
}

@(private)
flow_pass :: proc(n: ^Node, i: int, side: int, kind: Flow, payload: []byte) {
	c := &n.calls[i]
	from, to := &c.ends[side], &c.ends[1 - side]
	over := false
	switch kind {
	case .Data:
		if from.ended {
			return
		}
		from.granted -= len(payload)
		if from.granted < 0 || len(payload) > CALL_WINDOW {
			call_flow(n, from, 1 - side, .Fault, {u8(Call_Fault.Overrun)})
			call_flow(n, to, side, .Fault, {u8(Call_Fault.Overrun)})
			unordered_remove(&n.calls, i)
			return
		}
	case .End:
		from.ended = true
		over = to.ended
	case .Fault, .Cancel:
		over = true
	case .Credit:
		credit := Reader{buf = payload}
		to.granted = min(to.granted + int(read_varint(&credit) & 0xff_ffff), 16 * CALL_WINDOW)
	case:
		return
	}
	call_flow(n, to, side, kind, payload)
	if over {
		unordered_remove(&n.calls, i)
	}
}

// Sends to an end what the other side said.
@(private)
call_flow :: proc(n: ^Node, to: ^End, speaker: int, kind: Flow, payload: []byte) {
	if to.session == SELF {
		q := &n.host.questions
		if q.flow != nil {
			q.flow(q.data, to.id, kind, payload)
		}
		return
	}
	s := node_session(n, to.session)
	if s == nil {
		return
	}
	put :: proc(w: ^[dynamic]byte, id: u64, speaker: int, kind: Flow, payload: []byte) {
		at := frame_begin(w, .Flow)
		write_varint(w, id << 1 | u64(speaker))
		write_u8(w, u8(kind))
		append(w, ..payload)
		frame_end(w, at)
	}
	if to.tunnel == 0 {
		cells_close(s)
		put(&s.out, to.id, speaker, kind, payload)
		return
	}
	for &t in n.tunnels {
		if t.id == to.tunnel {
			frame: [dynamic]byte
			put(&frame, to.id, speaker, kind, payload)
			tunnel_send(n, &t, frame)
			return
		}
	}
}

// A path has failed: every call on it is lost.
@(private)
calls_lost :: proc(n: ^Node, session: u32, tunnel: u32 = 0) {
	#reverse for &c, i in n.calls {
		for &e, side in c.ends {
			if e.session == session && (tunnel == 0 || e.tunnel == tunnel) {
				call_flow(n, &c.ends[1 - side], side, .Fault, {u8(Call_Fault.Lost)})
				unordered_remove(&n.calls, i)
				break
			}
		}
	}
}

// A session has closed: what it served, carried and called goes with it.
@(private)
rpc_session_closed :: proc(n: ^Node, s: ^Session) {
	#reverse for x, i in n.serving {
		if x.session == s.id {
			delete(x.method)
			unordered_remove(&n.serving, i)
		}
	}
	calls_lost(n, s.id)
	#reverse for &t, i in n.tunnels {
		if t.relay == s.id {
			tunnel_free(&t)
			unordered_remove(&n.tunnels, i)
		}
	}
}

// Grants have changed: calls that could no longer be made are ended.
@(private)
rpc_roster_changed :: proc(n: ^Node) {
	if n.keys == nil {
		return
	}
	#reverse for &c, i in n.calls {
		need := Right.Read if c.own else Right.Call
		allowed := need in device_rights(n, n.keys.device, c.scope)
		for e in c.ends {
			s := node_session(n, e.session)
			if s == nil || s.role == .Open {
				continue
			}
			device := s.peer
			for t in n.tunnels {
				if t.id == e.tunnel {
					device = t.peer
				}
			}
			allowed &&= need in device_rights(n, device, c.scope)
		}
		if !allowed {
			for &e, side in c.ends {
				call_flow(n, &e, 1 - side, .Fault, {u8(Call_Fault.Denied)})
			}
			unordered_remove(&n.calls, i)
		}
	}
}

// ---------------------------------------------------------------- tunnels

@(private)
tunnel_free :: proc(t: ^Tunnel) {
	for p in t.pending {
		delete(p)
	}
	delete(t.pending)
	t^ = {}
}

@(private)
tunnel_new :: proc(n: ^Node, relay: u32, peer: Key32, mine: bool) -> ^Tunnel {
	n.next_tunnel += 1
	append(&n.tunnels, Tunnel{id = n.next_tunnel, relay = relay, peer = peer, mine = mine})
	return &n.tunnels[len(n.tunnels) - 1]
}

@(private)
tunnel_to :: proc(n: ^Node, device: Key32) -> ^Tunnel {
	for &t in n.tunnels {
		if t.mine && t.peer == device {
			return &t
		}
	}
	for s in n.sessions {
		if !s.ready || !s.peer_relay || !slice.contains(s.online[:], device) {
			continue
		}
		t := tunnel_new(n, s.id, device, true)
		eph: Key32
		node_random(n, eph[:])
		first, ok := handshake_start(&t.handshake, n.keys.secret, device, n.space, eph)
		if !ok {
			pop(&n.tunnels)
			return nil
		}
		post(s, device, .First, first[:])
		return t
	}
	return nil
}

// Takes ownership of the frame.
@(private)
tunnel_send :: proc(n: ^Node, t: ^Tunnel, frame: [dynamic]byte) {
	if !t.open {
		append(&t.pending, frame)
		return
	}
	frame := frame
	defer delete(frame)
	s := node_session(n, t.relay)
	if s == nil {
		return
	}
	w := make([dynamic]byte, context.temp_allocator)
	write_u64(&w, t.channel.send_n)
	channel_seal(&t.channel, &w, frame[:])
	post(s, t.peer, .Out if t.mine else .Back, w[:])
}

// A signal for a tunnel. They travel in order, so a message that is not newer than the last is a replay.
@(private)
tunnel_input :: proc(s: ^Session, from: Key32, kind: Post, blob: []byte) {
	n := s.node
	m := roster_member(&n.roster, from)
	if m == nil || !member_active(m) {
		return
	}
	mine := kind == .Second || kind == .Back
	t: ^Tunnel
	for &x in n.tunnels {
		if x.peer == from && x.mine == mine && (x.relay == s.id || !x.open) {
			t = &x
		}
	}
	switch kind {
	case .Plain:
	case .First:
		eph: Key32
		node_random(n, eph[:])
		second, channel, ok := handshake_answer(n.keys.secret, n.space, blob, eph)
		if !ok || channel.peer != from {
			return
		}
		if t == nil {
			t = tunnel_new(n, s.id, from, false)
		}
		t.next = channel
		post(s, from, .Second, second[:])
	case .Second:
		if t == nil || t.open {
			return
		}
		channel, ok := handshake_finish(&t.handshake, blob, from)
		if !ok {
			return
		}
		t.channel, t.open = channel, true
		pending := t.pending
		t.pending = nil
		for p in pending {
			tunnel_send(n, t, p)
		}
		delete(pending)
	case .Out, .Back:
		if t == nil || len(blob) < 8 {
			return
		}
		number := get_u64(blob)
		plain: []byte
		ok: bool
		if t.open {
			plain, ok = tunnel_open(&t.channel, number, blob[8:])
		}
		if !ok && t.next.recv != {} {
			fresh := t.next
			if plain, ok = tunnel_open(&fresh, number, blob[8:]); ok {
				// The caller began again; whatever it had in flight before is gone.
				if t.open {
					calls_lost(n, t.relay, t.id)
				}
				t.channel, t.next, t.open, t.relay = fresh, {}, true, s.id
			}
		}
		if !ok {
			return
		}
		r := Reader{buf = plain}
		frame := read_bytes(&r)
		if r.bad || len(frame) == 0 {
			return
		}
		tid := t.id
		inner := Reader{buf = frame[1:]}
		for &x in n.tunnels {
			if x.id == tid {
				#partial switch Message(frame[0]) {
				case .Call:
					on_call(s, &inner, &x)
				case .Flow:
					on_flow(s, &inner, &x)
				}
				return
			}
		}
	}
}

@(private)
tunnel_open :: proc(c: ^Channel, number: u64, sealed: []byte) -> (plain: []byte, ok: bool) {
	if number < c.recv_n {
		return
	}
	copied := slice.clone(sealed, context.temp_allocator) // a failed open must leave it for another try
	plain = channel_open_at(c, number, copied, nil) or_return
	c.recv_n = number + 1
	return plain, true
}

// Devices have gone from a relay, and their tunnels with them.
@(private)
tunnels_prune :: proc(s: ^Session) {
	n := s.node
	#reverse for &t, i in n.tunnels {
		if t.relay == s.id && !slice.contains(s.online[:], t.peer) {
			calls_lost(n, s.id, t.id)
			tunnel_free(&t)
			unordered_remove(&n.tunnels, i)
		}
	}
}

@(private)
post :: proc(s: ^Session, to: Key32, kind: Post, blob: []byte) {
	to := to
	cells_close(s)
	at := frame_begin(&s.out, .Signal)
	append(&s.out, ..to[:])
	write_u8(&s.out, u8(kind))
	append(&s.out, ..blob)
	frame_end(&s.out, at)
}

// Tells local clients which devices can be reached: this one first, then the rest, each with whom
// the roster says it belongs to.
@(private)
reach_tell :: proc(n: ^Node, only: ^Session = nil) {
	if n.keys == nil {
		return
	}
	for to in n.sessions {
		if to.role != .Open || !to.ready || (only != nil && to != only) {
			continue
		}
		cells_close(to)
		at := frame_begin(&to.out, .Presence)
		put :: proc(n: ^Node, w: ^[dynamic]byte, device: Key32) {
			device := device
			append(w, ..device[:])
			m := roster_member(&n.roster, device)
			write_bytes(w, m.subject if m != nil else nil)
		}
		put(n, &to.out, n.keys.device)
		seen := make([dynamic]Key32, context.temp_allocator)
		for s in n.sessions {
			if !s.ready || s.role != .Peer {
				continue
			}
			if !s.peer_relay && !slice.contains(seen[:], s.peer) {
				append(&seen, s.peer)
			}
			for device in s.online {
				if !slice.contains(seen[:], device) {
					append(&seen, device)
				}
			}
		}
		for device in seen {
			put(n, &to.out, device)
		}
		frame_end(&to.out, at)
	}
}
