package host

import "core:time"
import "../zsp"

// Calls whose end is this host: the methods it serves itself, by names beginning "zsp.", and the calls it makes.
//
// Every call's messages are credited as whoever receives them is done with them, so that nothing is held but
// what the receiver has room for. A window starts at the protocol's 256 KiB and doubles, to 4 MiB, while its
// reader keeps up, which is what a fast long path needs and a slow reader never gets.

WINDOW_MOST :: 16 * zsp.CALL_WINDOW // what the protocol lets a receiver credit ahead
WINDOW_QUICK :: 250 * time.Millisecond // a window used up within this grows

// Who called a method.
Caller :: struct {
	device: zsp.Key32, // the calling device; this device's own for a local client
	local:  ^zsp.Session, // non-nil when a local client of this node called its own device
	who:    []byte, // for whom, as §12 settles it; valid during the answer only
	relay:  bool, // a relay called (zsp.public only)
}

// Whoever answers a method. Returns the handler for the call, or nil to fault it with `fault`.
Host_Method :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (h: ^Call_Handler, fault: zsp.Call_Fault)

// What a call's end is told. Any field may be nil. A handler is its owner's to free, once it has been told that
// the call is over: on_fault, or on_end after call_end was said.
Call_Handler :: struct {
	data:     rawptr,
	// A message. True if it is done with now; false to keep it, and say call_consumed when done with it.
	on_data:  proc(h: ^Call_Handler, call: u64, bytes: []byte) -> (consumed: bool),
	on_end:   proc(h: ^Call_Handler, call: u64), // the other side will say no more
	on_fault: proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault), // it is over: .Cancelled if they cancelled
	on_room:  proc(h: ^Call_Handler, call: u64), // credit came: call_room grew
}

@(private)
Host_Call :: struct {
	call:      u64,
	handler:   ^Call_Handler,
	ended:     bool, // we said End
	heard_end: bool, // they did
	window:    int, // what we let them have outstanding
	used:      int, // of it, consumed since the window last grew
	since:     time.Tick,
}

// Serves a method on every space. A later one for the same method replaces it.
host_serve :: proc(h: ^Host, method: string, answer: Host_Method) {
	assert(zsp.hosted(method), "the host serves only methods beginning zsp.")
	h.methods[method] = answer
}

// Calls a method a device serves itself. Returns 0 if it cannot be called: no right, no path, or too many calls.
host_call :: proc(sp: ^Space, device: zsp.Key32, scope: zsp.Scope, method: string, first: []byte, handler: ^Call_Handler) -> u64 {
	call := zsp.node_call_method(&sp.node, device, scope, method, first)
	if call != 0 {
		append(&sp.calls, Host_Call{call = call, handler = handler, window = zsp.CALL_WINDOW, since = time.tick_now()})
	}
	return call
}

// Sends a message, if credit allows. A message is at most 256 KiB.
call_send :: proc(sp: ^Space, call: u64, bytes: []byte) -> bool {
	c := host_call_find(sp, call)
	if c == nil || c.ended || len(bytes) > call_room(sp, call) || len(bytes) > zsp.CALL_WINDOW {
		return false
	}
	zsp.node_flow(&sp.node, call, .Data, bytes)
	return true
}

// Says this side will send no more.
call_end :: proc(sp: ^Space, call: u64) {
	c := host_call_find(sp, call)
	if c == nil || c.ended {
		return
	}
	c.ended = true
	zsp.node_flow(&sp.node, call, .End)
	if c.heard_end {
		host_call_forget(sp, call)
	}
}

// Ends a call at once, as a failure.
call_fault :: proc(sp: ^Space, call: u64, fault: zsp.Call_Fault) {
	if host_call_find(sp, call) == nil {
		return
	}
	zsp.node_flow(&sp.node, call, .Fault, {u8(fault)})
	host_call_forget(sp, call)
}

// Ends a call at once: this side no longer cares.
call_cancel :: proc(sp: ^Space, call: u64) {
	if host_call_find(sp, call) == nil {
		return
	}
	zsp.node_flow(&sp.node, call, .Cancel)
	host_call_forget(sp, call)
}

// How many bytes may be sent now.
call_room :: proc(sp: ^Space, call: u64) -> int {
	return zsp.node_granted(&sp.node, call)
}

// Says that bytes kept from on_data are done with: the other side may send as many more.
call_consumed :: proc(sp: ^Space, call: u64, n: int) {
	c := host_call_find(sp, call)
	if c == nil || n <= 0 {
		return
	}
	credit := n
	c.used += n
	if c.used >= c.window {
		// A reader that keeps up gets a longer window, so that a long path is kept full.
		if time.tick_since(c.since) < WINDOW_QUICK && c.window < WINDOW_MOST {
			credit += c.window
			c.window *= 2
		}
		c.used = 0
		c.since = time.tick_now()
	}
	w: [10]byte
	zsp.node_flow(&sp.node, call, .Credit, w[:varint_put(w[:], u64(credit))])
}

@(private)
varint_put :: proc(into: []byte, v: u64) -> int {
	v := v
	n := 0
	for v >= 0x80 {
		into[n] = byte(v) | 0x80
		v >>= 7
		n += 1
	}
	into[n] = byte(v)
	return n + 1
}

@(private)
host_call_find :: proc(sp: ^Space, call: u64) -> ^Host_Call {
	for &c in sp.calls {
		if c.call == call {
			return &c
		}
	}
	return nil
}

@(private)
host_call_forget :: proc(sp: ^Space, call: u64) {
	for c, i in sp.calls {
		if c.call == call {
			unordered_remove(&sp.calls, i)
			return
		}
	}
}

// ---------------------------------------------------------------- from the node

@(private)
host_method :: proc(data: rawptr, call: u64, from: zsp.Caller_Info, scope: zsp.Scope, method: string, first: []byte) -> Maybe(zsp.Call_Fault) {
	sp := (^Space)(data)
	answer, served := sp.host.methods[method]
	if !served {
		return .Unserved
	}
	// Recorded first: whatever the answer says at once is said within the call.
	append(&sp.calls, Host_Call{call = call, window = zsp.CALL_WINDOW, since = time.tick_now()})
	handler, fault := answer(sp, call, {from.device, from.local, from.who, from.relay}, scope, first)
	c := host_call_find(sp, call)
	if handler == nil {
		if c != nil {
			host_call_forget(sp, call)
			return fault if fault != .Cancelled else .Unserved
		}
		return nil // it ended itself already
	}
	if c != nil {
		c.handler = handler
		call_consumed(sp, call, len(first)) // the first message is always taken
	}
	return nil
}

@(private)
host_flow :: proc(data: rawptr, call: u64, kind: zsp.Flow, payload: []byte) {
	sp := (^Space)(data)
	c := host_call_find(sp, call)
	if c == nil {
		return
	}
	h := c.handler
	switch kind {
	case .Data:
		if h == nil || h.on_data == nil || h.on_data(h, call, payload) {
			call_consumed(sp, call, len(payload))
		}
	case .End:
		c.heard_end = true
		if c.ended {
			host_call_forget(sp, call)
		}
		if h != nil && h.on_end != nil {
			h.on_end(h, call)
		}
	case .Fault, .Cancel:
		host_call_forget(sp, call)
		fault := zsp.Call_Fault.Cancelled
		if kind == .Fault && len(payload) > 0 {
			fault = zsp.Call_Fault(payload[0])
		}
		if h != nil && h.on_fault != nil {
			h.on_fault(h, call, fault)
		}
	case .Credit:
		if h != nil && h.on_room != nil {
			h.on_room(h, call)
		}
	}
}

// The calls of a space that is closing are over.
@(private)
calls_close :: proc(sp: ^Space) {
	for len(sp.calls) > 0 {
		c := pop(&sp.calls)
		if h := c.handler; h != nil && h.on_fault != nil {
			h.on_fault(h, c.call, .Lost)
		}
	}
	delete(sp.calls)
}
