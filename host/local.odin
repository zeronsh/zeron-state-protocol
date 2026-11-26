package host

import "core:slice"
import "../zsp"

// What a local client may ask its own device's host, as calls to zsp.* methods of its own device: who the other
// devices are and what they offer, and what this one offers. No new frames: any client that can call can ask.
//
// Changing what this device offers, or exposes, is for whoever runs it: a local client the host accepted for every
// scope (as zspd does its token's), or as Config.may_configure says.

// zsp.nodes, answered once: n varint ‖ n × { device (32) ‖ name bytes ‖ address (4) ‖ flags (1: 1 this device, 2 reachable,
// 4 linked directly) ‖ subject bytes ‖ entries, as zsp.ports gives them, of what it offers this one }.
@(private)
nodes_called :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	if from.local == nil {
		return nil, .Denied
	}
	b := make([dynamic]byte, context.temp_allocator)
	nodes_put(sp, &b)
	return call_answer(sp, call, b[:]), {}
}

@(private)
nodes_put :: proc(sp: ^Space, w: ^[dynamic]byte) {
	reach := zsp.node_reach(&sp.node)
	members := sp.node.roster.members
	count := 0
	for &m in members {
		count += 1 if zsp.member_active(&m) else 0
	}
	zsp.write_varint(w, u64(count))
	for &m in members {
		if !zsp.member_active(&m) {
			continue
		}
		device := m.device
		append(w, ..device[:])
		zsp.write_bytes(w, transmute([]byte)member_name_of(sp, &m) if sp.naming.suffix != "" else nil)
		ip, _ := device_address(sp, m.device)
		append(w, ..ip[:])
		flags: byte
		if m.device == sp.host.device {
			flags |= 1
		}
		if slice.contains(reach, m.device) {
			flags |= 2
		}
		for s in sp.node.sessions {
			if s.ready && s.role == .Peer && !s.peer_relay && s.peer == m.device {
				flags |= 4
			}
		}
		append(w, flags)
		zsp.write_bytes(w, m.subject)
		r := remote_for(sp.ports, m.device, make = false) if sp.ports != nil else nil
		entries_put(w, r.entries[:] if r != nil else nil)
	}
}

// zsp.offers: 0 to list what this device offers, 1 ‖ offer to add one, 2 ‖ offer to take one back. Answered with the
// list as it then is: n varint ‖ n × offer.
@(private)
offers_called :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	if from.local == nil || sp.ports == nil {
		return nil, .Denied
	}
	r := zsp.Reader{buf = first}
	op := zsp.read_u8(&r)
	if op != 0 {
		if !may_configure(sp, from.local) {
			return nil, .Denied
		}
		o, ok := offer_read(&r)
		if !ok || !zsp.read_done(&r) || op > 2 || !offers_change(sp, o, op == 2) {
			return nil, .Denied
		}
	} else if !zsp.read_done(&r) {
		return nil, .Denied
	}
	b := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&b, u64(len(sp.ports.offers)))
	for &o in sp.ports.offers {
		offer_put(&b, &o)
	}
	return call_answer(sp, call, b[:]), {}
}

@(private)
may_configure :: proc(sp: ^Space, s: ^zsp.Session) -> bool {
	h := sp.host
	if h.may_configure != nil {
		return h.may_configure(h.data, s)
	}
	for g in s.grants {
		if g.scope == 0 && g.until == 0 && .Call in g.rights {
			return true
		}
	}
	return false
}

// Says one message in a call and ends it, once the method that answers it has returned its handler, which it is
// given to return: nothing more is heard of the call.
@(private)
call_answer :: proc(sp: ^Space, call: u64, b: []byte) -> ^Call_Handler {
	append(&sp.host.later, Later{sp, call, slice.clone(b)})
	return &answered
}

// Something to do once whatever is under way has returned: said in host_settle, straight after the events of a tick.
@(private)
Later :: struct {
	sp:   ^Space,
	call: u64,
	say:  []byte, // owned: said in the call, which then ends
}

@(private)
later_run :: proc(h: ^Host) {
	for len(h.later) > 0 {
		todo := h.later
		h.later = nil
		for l in todo {
			call_send(l.sp, l.call, l.say)
			call_end(l.sp, l.call)
			delete(l.say)
		}
		delete(todo)
	}
}

@(private)
answered: Call_Handler
