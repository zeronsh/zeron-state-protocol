package zsp

import "core:slice"
import "core:strings"

// Calls between devices.
//
// A call is two streams of messages, one each way, addressed to a device and made within a scope. Each
// node along the way is a router: it knows a call by its two ends and passes messages between them. A
// call takes a direct session with the device when there is one, and otherwise one the host makes for
// calls alone, over a link that a relay carries (Host.reach). It stays on the session it began on, and
// fails if that fails: at most once, never twice.

CALL_WINDOW :: 256 << 10 // bytes a side may send before the other grants more
MAX_CALLS :: 4096
MAX_METHOD :: 255
MAX_FLOW :: 1024 // of anything but data

Flow :: enum u8 {
	Data   = 0, // one message
	End    = 1, // no more messages from this side
	Fault  = 2, // code, text: the call is over
	Cancel = 3, // the caller no longer cares
	Credit = 4, // the other side may send this many more bytes
}

Call_Fault :: enum u8 {
	Cancelled   = 0, // the other side no longer cares: told to whoever is an end, never sent as a fault
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
	host:    bool, // an end that is this node's host, as a method's server or as a caller
	session: u32,
	lane:    u64, // within that session, if not zero
	id:      u64,
	ended:   bool, // has sent its last message
	granted: int, // how much more it may send
}

@(private)
Call :: struct {
	ends:    [2]End,
	scope:   Scope,
	own:     bool, // between the nodes themselves
	public:  bool, // a relay's, for something a device makes public, which no grant governs
	urgency: u8, // of the lanes it takes
}

@(private)
Serving :: struct {
	session: u32,
	scope:   Scope,
	method:  string, // owned
}

// What a Signal carries, by its first byte.
@(private)
Post :: enum u8 {
	Plain = 0, // sealed to the device, for its host
	Link  = 7, // a packet of a link the relay carries (§14), which it may drop
}

rpc_destroy :: proc(n: ^Node) {
	for s in n.serving {
		delete(s.method)
	}
	delete(n.serving)
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
	if r.bad || s.role != .Open || len(method) == 0 || len(method) > MAX_METHOD || len(n.serving) >= MAX_CALLS {
		r.bad = true
		return
	}
	if hosted(method) {
		return // the host's own, which no client may stand in for
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

// id, device, scope, method, for whom, first message
@(private)
on_call :: proc(s: ^Session, r: ^Reader, lane: ^Lane = nil) {
	n := s.node
	id := read_varint(r)
	device := read_key32(r)
	scope := Scope(read_varint(r))
	method := string(read_bytes(r))
	who := read_bytes(r)
	body := read_take(r, len(r.buf) - r.pos)
	if r.bad || n.keys == nil || len(who) > MAX_AS {
		r.bad = true
		return
	}
	from := End{session = s.id, lane = lane.id if lane != nil else 0, id = id, granted = CALL_WINDOW}
	if lane != nil {
		lane.calls += 1
	}
	refuse :: proc(n: ^Node, from: End, f: Call_Fault) {
		to := from
		call_flow(n, &to, CALLEE, .Fault, {u8(f)})
		end_release(n, from)
	}
	for c in n.calls {
		if c.ends[CALLER].session == from.session && c.ends[CALLER].id == id {
			r.bad = true // an id may be used again only once its call is over
			return
		}
	}
	local := s.role == .Open
	caller := s.peer
	own := method == ""
	need := Right.Read if own else Right.Call
	allowed := need in (session_rights(s, scope) if local else device_rights(n, caller, scope))
	// A relay this device dialled may call it for what it makes public, and for nothing else.
	public := method == PUBLIC && scope == 0 && !local && s.peer_relay
	if public {
		allowed = true
	} else if local {
		allowed &&= !own && .Call in device_rights(n, n.keys.device, scope) && .Call in device_rights(n, device, scope)
		// A client is for whom the host says it is, and not for whom it says.
		may: bool
		who, may = session_as(s, scope, call = true)
		allowed &&= may
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
	c := Call{scope = scope, own = own, public = public, urgency = lane.urgency if lane != nil else method_urgency(method)}
	c.ends[CALLER] = from
	to := &c.ends[CALLEE]
	to.id = n.next_call
	to.granted = CALL_WINDOW

	if hosted(method) && (!local || device == n.keys.device) {
		if n.host.method == nil {
			refuse(n, from, .Unserved)
			return
		}
		to.session, to.host = SELF, true
		if public {
			who = nil
		} else if caller = caller if !local else n.keys.device; len(who) == 0 || !device_vouches(n, caller, scope) {
			m := roster_member(&n.roster, caller)
			who = m.subject if m != nil else nil
		}
		append(&n.calls, c)
		info := Caller_Info{device = caller, local = s if local else nil, who = who, relay = public}
		if f, refused := n.host.method(n.host.data, to.id, info, scope, method, body).?; refused {
			// Taken back, unless what the host said in the meantime already ended it.
			for x, i in n.calls {
				if x.ends[CALLEE].session == SELF && x.ends[CALLEE].id == to.id {
					unordered_remove(&n.calls, i)
					refuse(n, from, f)
					break
				}
			}
		}
		return
	}

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
		if caller = caller if !local else n.keys.device; len(who) == 0 || !device_vouches(n, caller, scope) {
			m := roster_member(&n.roster, caller)
			who = m.subject if m != nil else nil
		}
		call_put(&server.out, server, to.id, caller, scope, method, who, body)
		return
	}
	if f, ok := call_out(n, &c, device, method, who, body).?; ok {
		refuse(n, from, f)
	}
}

// Sends a call on its way to another device.
@(private)
call_out :: proc(n: ^Node, c: ^Call, device: Key32, method: string, who, body: []byte) -> Maybe(Call_Fault) {
	to := &c.ends[CALLEE]
	// A direct session, and of those one that replicates rather than one only for calls.
	direct: ^Session
	for p in n.sessions {
		if p.ready && p.role != .Open && p.peer == device && !p.peer_relay && (direct == nil || direct.role == .Calls) {
			direct = p
		}
	}
	if direct == nil && n.host.reach != nil {
		// None yet: the host begins one for calls, through a relay; what is said waits until it is open.
		direct = n.host.reach(n.host.data, device)
	}
	p := direct
	if p == nil || p.closing {
		return .Unreachable
	}
	to.session = p.id
	flush_changes(p) // it may be about them
	cells_close(p)
	w := &p.out
	if l := lane_open(p, c.urgency); l != nil {
		to.lane = l.id
		l.calls += 1
		w = lane_out(p, l)
	}
	append(&n.calls, c^)
	call_put(w, nil, to.id, device, c.scope, method, who, body)
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
	c := Call{scope = scope, own = true, urgency = method_urgency("")}
	c.ends[CALLER] = {session = SELF, id = n.next_call - 1, granted = CALL_WINDOW - len(body)}
	c.ends[CALLEE] = {id = n.next_call, granted = CALL_WINDOW}
	if _, failed := call_out(n, &c, device, "", nil, body).?; failed {
		return 0
	}
	return n.next_call - 1
}

// Calls a device by a method its host serves (names beginning "zsp."), as this node's host. 0 if it cannot be.
// What is said back goes to Host.flow. A relay may call a device it serves, by PUBLIC in scope 0, and by nothing else.
node_call_method :: proc(n: ^Node, device: Key32, scope: Scope, method: string, body: []byte) -> u64 {
	if !hosted(method) || len(method) > MAX_METHOD || len(n.calls) >= MAX_CALLS || len(body) > CALL_WINDOW {
		return 0
	}
	public := n.keys == nil
	if public {
		if method != PUBLIC || scope != 0 {
			return 0
		}
	} else if device == n.keys.device || .Call not_in device_rights(n, n.keys.device, scope) || .Call not_in device_rights(n, device, scope) {
		return 0
	}
	n.next_call += 2
	c := Call{scope = scope, public = public, urgency = method_urgency(method)}
	c.ends[CALLER] = {host = true, session = SELF, id = n.next_call - 1, granted = CALL_WINDOW - len(body)}
	c.ends[CALLEE] = {id = n.next_call, granted = CALL_WINDOW}
	if _, failed := call_out(n, &c, device, method, nil, body).?; failed {
		return 0
	}
	return n.next_call - 1
}

// Whether the host serves a method itself.
hosted :: proc(method: string) -> bool {
	return strings.has_prefix(method, "zsp.")
}

// By which a relay reaches what a device makes public.
PUBLIC :: "zsp.public"

// Who called a method the host serves.
Caller_Info :: struct {
	device: Key32, // the calling device; this one's own for a local client
	local:  ^Session, // when a local client of this node called its own device
	who:    []byte, // for whom, as §12 settles it
	relay:  bool, // a relay called, for something made public
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

// Whether any call is under way on a session.
node_calling :: proc(n: ^Node, s: ^Session) -> bool {
	for &c in n.calls {
		for e in c.ends {
			if e.session == s.id {
				return true
			}
		}
	}
	return false
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
call_put :: proc(w: ^[dynamic]byte, s: ^Session, id: u64, device: Key32, scope: Scope, method: string, who, body: []byte) {
	device := device
	if s != nil {
		flush_changes(s) // it may be about them
		cells_close(s)
	}
	at := frame_begin(w, .Call)
	write_varint(w, id)
	append(w, ..device[:])
	write_varint(w, u64(scope))
	write_bytes(w, transmute([]byte)method)
	write_bytes(w, who)
	append(w, ..body)
	frame_end(w, at)
}

// Whether a device is believed about whom it calls for.
@(private)
device_vouches :: proc(n: ^Node, device: Key32, scope: Scope) -> bool {
	return .Vouch in device_rights(n, device, scope)
}

// What a device may do in a scope.
device_rights :: proc(n: ^Node, device: Key32, scope: Scope) -> Rights {
	m := roster_member(&n.roster, device)
	return member_rights(m, scope) if m != nil else {}
}

// ---------------------------------------------------------------- between the ends

// id and which side speaks, kind, payload
@(private)
on_flow :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	tag := read_varint(r)
	kind := Flow(read_u8(r))
	payload := read_take(r, len(r.buf) - r.pos)
	if r.bad || (kind != .Data && len(payload) > MAX_FLOW) {
		r.bad = true
		return
	}
	side := int(tag & 1)
	for &c, i in n.calls {
		from := &c.ends[side]
		if from.session == s.id && from.id == tag >> 1 {
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
			ends := c.ends
			call_end_now(n, i)
			call_flow(n, &ends[side], 1 - side, .Fault, {u8(Call_Fault.Overrun)})
			call_flow(n, &ends[1 - side], side, .Fault, {u8(Call_Fault.Overrun)})
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
	// Whoever is told may at once say more, in this call or another, and end calls: so the call is done with first.
	told := to^
	if over {
		call_end_now(n, i)
	}
	call_flow(n, &told, side, kind, payload)
}

// Lets a call go, its lanes with it, before anyone is told.
@(private)
call_end_now :: proc(n: ^Node, i: int) {
	c := n.calls[i]
	unordered_remove(&n.calls, i)
	call_over(n, &c)
}

// Sends to an end what the other side said.
@(private)
call_flow :: proc(n: ^Node, to: ^End, speaker: int, kind: Flow, payload: []byte) {
	if to.session == SELF {
		if to.host {
			if n.host.flow != nil {
				n.host.flow(n.host.data, to.id, kind, payload)
			}
			return
		}
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
	if to.lane != 0 {
		if l := lane_find(s, to.lane); l != nil && !l.ended {
			put(lane_out(s, l), to.id, speaker, kind, payload)
		}
		return
	}
	cells_close(s)
	put(&s.out, to.id, speaker, kind, payload)
}

// A path has failed: every call on it is lost.
@(private)
calls_lost :: proc(n: ^Node, session: u32, lane: u64 = 0) {
	// One at a time, looking afresh: whoever is told may end other calls, or begin them.
	outer: for {
		for c, i in n.calls {
			for e, side in c.ends {
				if e.session == session && (lane == 0 || e.lane == lane) {
					other := c.ends[1 - side]
					call_end_now(n, i)
					call_flow(n, &other, side, .Fault, {u8(Call_Fault.Lost)})
					continue outer
				}
			}
		}
		return
	}
}

// A call is over: the lanes its ends took are ended once what is on them has been sent.
@(private)
call_over :: proc(n: ^Node, c: ^Call) {
	for e in c.ends {
		end_release(n, e)
	}
}

@(private)
end_release :: proc(n: ^Node, e: End) {
	if e.lane == 0 {
		return
	}
	if s := node_session(n, e.session); s != nil {
		if l := lane_find(s, e.lane); l != nil {
			l.calls -= 1
			if l.calls <= 0 {
				l.over = true
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
}

// Grants have changed: calls that could no longer be made are ended.
@(private)
rpc_roster_changed :: proc(n: ^Node) {
	if n.keys == nil {
		return
	}
	// One at a time, looking afresh: whoever is told may end other calls, or begin them.
	Caller_Key :: struct {
		session: u32,
		id:      u64,
	}
	still := make([dynamic]Caller_Key, context.temp_allocator) // looked at, and still allowed
	outer: for {
		for &c, i in n.calls {
			key := Caller_Key{c.ends[CALLER].session, c.ends[CALLER].id}
			if c.public || slice.contains(still[:], key) {
				continue // no grant governs it, or it was looked at
			}
			need := Right.Read if c.own else Right.Call
			allowed := need in device_rights(n, n.keys.device, c.scope)
			for e in c.ends {
				s := node_session(n, e.session)
				if s == nil || s.role == .Open {
					continue
				}
				allowed &&= need in device_rights(n, s.peer, c.scope)
			}
			if !allowed {
				ends := c.ends
				call_end_now(n, i)
				for &e, side in ends {
					call_flow(n, &e, 1 - side, .Fault, {u8(Call_Fault.Denied)})
				}
				continue outer
			}
			append(&still, key)
		}
		return
	}
}

// ---------------------------------------------------------------- links through relays

// Hands a relay a packet of a link to another device present there, by the session with it. False if there
// is no such session, or it has so much to send already that the packet would only wait: as though lost.
node_post_link :: proc(n: ^Node, relay: u32, device: Key32, packet: []byte) -> bool {
	s := node_session(n, relay)
	if s == nil || !s.ready || !s.peer_relay || s.closing || session_backlog(s) > LINK_QUEUE {
		return false
	}
	post(s, device, .Link, packet)
	return true
}

// What a relay holds of signals for a device, beyond which it drops them: enough to keep a fast path full, little
// enough that what is urgent does not wait long behind it. Loss recovery, end to end, makes up the rest.
LINK_QUEUE :: 256 << 10

// A signal's blob, at most: a link's packet through a relay (8192), and what goes with it.
MAX_SIGNAL :: 16 << 10

// What is queued for a session's peer and not yet on its way: here, and in its host's pipe.
@(private)
session_backlog :: proc(s: ^Session) -> int {
	queued := len(s.out) - s.sent
	if n := s.node; n.host.backlog != nil {
		queued += n.host.backlog(n.host.data, s)
	}
	return queued
}

@(private)
post :: proc(s: ^Session, to: Key32, kind: Post, blob: []byte) {
	to := to
	flush_changes(s)
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
