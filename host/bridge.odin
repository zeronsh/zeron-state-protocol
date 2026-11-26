package host

import "core:encoding/endian"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:time"
import "../zsp"

// A call joined to a TCP connection: bytes one way are messages the other, End is a half-close, and a fault or a
// cancel is a reset. Nothing is read from the socket that the call has no credit for, and the call is credited
// only as the socket takes what came, so that a slow end slows the other and nothing piles up between.
//
// zsp.tcp is the method by which a device reaches a TCP port on another's behalf, whether its own or one on its
// network; which ports, for whom, is port_permitted's to say. `forward` is the other end: a connection accepted
// here, joined to a port there.

BRIDGE_READ :: 64 << 10 // at most, at once
INSPECT_MOST :: 16 << 10 // what an inspector may see before it must decide
CONNECT_WAIT :: 15 * time.Second
REJECT_LINGER :: 5 * time.Second // that a rejected connection is drained for, so that its reply is read rather than reset

// What the first message back says, at the start of a zsp.tcp call.
Tcp_Status :: enum u8 {
	Connected   = 0,
	Denied      = 1, // not for this caller
	Not_Offered = 2, // nobody offers that port here
	Refused     = 3, // nothing listens there
	Unreachable = 4,
	Timed_Out   = 5,
}

// How a forward went: Connected once the port is reached, before anything from it is written; then how it ended.
Forward_Status :: enum u8 {
	Connected,
	Closed, // as it should, both ways
	Denied,
	Not_Offered,
	Refused,
	Unreachable,
	Timed_Out,
	Lost, // the call failed, or was cancelled
	Rejected, // by the inspector
}

Inspection :: enum u8 {
	More, // show me more
	Pass, // let it all through, and stop showing me
	Reject, // end it
}

Bridge :: struct {
	using handler: Call_Handler,
	sp:          ^Space,
	call:        u64,
	socket:      net.TCP_Socket,
	connected:   bool, // has a socket
	dialling:    ^nbio.Operation,
	recv_op:     ^nbio.Operation,
	send_op:     ^nbio.Operation,
	prelude:     [dynamic]byte, // for the socket before anything from the call
	pending:     [dynamic]byte, // from the call, for the socket, not yet credited
	written:     int, // of pending
	refused:     bool, // the call was answered with a failure, and waits to be over
	abandoned:   bool, // over while dialling: the dial is left to finish, and the bridge freed then
	eof:         bool, // the socket said all it will, and so has the call
	heard_end:   bool, // the call said all it will
	shut:        bool, // and the socket has been told
	over:        bool,
	// The end that served zsp.tcp.
	inbound:     bool,
	caller:      zsp.Key32,
	who:         string, // owned
	scope:       zsp.Scope,
	port:        u16,
	target:      string, // owned
	// The end that forwards.
	waiting:     bool, // for the status
	done:        proc(data: rawptr, status: Forward_Status),
	done_data:   rawptr,
	status:      Forward_Status,
	inspect:     proc(data: rawptr, first: []byte) -> Inspection,
	held:        [dynamic]byte, // shown to the inspector, or given early, not yet sent
	early:       int, // of held, given early, not for the inspector
	reply:       []byte, // owned; written before the end, on rejection
	draining:    ^nbio.Operation, // a rejected connection's last read, or its time running out
	dial6:       net.Endpoint, // where to try next, if the first address refuses
	bytes_in, bytes_out: u64, // from the socket, to it
}

Forward :: Bridge

// Joins a call this host is an end of to a connected socket, which the bridge then owns. `prelude` is written to the
// socket before anything else.
bridge :: proc(sp: ^Space, call: u64, socket: net.TCP_Socket, prelude: []byte = nil) -> ^Bridge {
	b := bridge_new(sp, call)
	if c := host_call_find(sp, call); c != nil {
		c.handler = &b.handler
		b.heard_end = c.heard_end // the other side may have said all it will already
	}
	bridge_attach(b, socket, prelude)
	return b
}

// Joins a connected socket, accepted here, to a port on a device: a zsp.tcp call in a scope. The forward owns the
// socket, and closes it with a reset if the port cannot be reached. `done` is told how it ended, once.
// `inspect`, if given, sees what the socket sends until it lets it through or rejects it; what comes back flows
// from the start, for some protocols speak first. If the call cannot be made at all, `done` is told so before forward
// returns, and forward returns nil.
forward :: proc(
	sp: ^Space,
	device: zsp.Key32,
	scope: zsp.Scope,
	port: u16,
	target: string,
	socket: net.TCP_Socket,
	done: proc(data: rawptr, status: Forward_Status) = nil,
	data: rawptr = nil,
	inspect: proc(data: rawptr, first: []byte) -> Inspection = nil,
	early: []byte = nil,
) -> ^Forward {
	first := make([]byte, 2 + len(target), context.temp_allocator)
	endian.unchecked_put_u16be(first, port)
	copy(first[2:], target)
	b := bridge_new(sp, 0)
	b.waiting = true
	b.done, b.done_data, b.inspect = done, data, inspect
	b.port, b.scope = port, scope
	b.target = strings.clone(target)
	b.call = host_call(sp, device, scope, "zsp.tcp", first, &b.handler)
	if b.call == 0 {
		b.status = .Unreachable
		socket_abort(socket)
		bridge_free(b)
		if done != nil {
			done(data, .Unreachable)
		}
		return nil
	}
	// What the socket said already goes first, as credit allows; the rest of it waits its turn.
	append(&b.held, ..early)
	b.early = len(early)
	bridge_attach(b, socket, nil)
	return b
}

// Ends a forward at once, with a reset.
forward_close :: proc(f: ^Forward) {
	bridge_abort(f, .Lost)
}

// Rejects what a forward's socket sent: `reply` is written, the connection closed, and what it sends meanwhile
// read and dropped until it closes too, for a reset could take the reply with it.
forward_reject :: proc(f: ^Forward, reply: []byte) {
	if f.over {
		return
	}
	delete(f.reply)
	f.reply = make([]byte, len(reply))
	copy(f.reply, reply)
	bridge_reject(f)
}

@(private)
bridge_reject :: proc(b: ^Bridge) {
	b.over = true
	b.status = .Rejected
	if host_call_find(b.sp, b.call) != nil {
		call_cancel(b.sp, b.call)
	}
	b.call = 0
	if !b.connected {
		bridge_finish(b)
		return
	}
	if b.recv_op != nil {
		nbio.remove(b.recv_op)
		b.recv_op = nil
	}
	if b.send_op != nil {
		nbio.remove(b.send_op)
		b.send_op = nil
	}
	b.draining = nbio.timeout_poly(REJECT_LINGER, b, proc(op: ^nbio.Operation, b: ^Bridge) {
		b.draining = nil
		bridge_finish(b) // it never closed: let it go
	})
	b.written = 0
	bridge_reply(b)
}

// Writes a rejected connection's reply, then closes it and drains it.
@(private)
bridge_reply :: proc(b: ^Bridge) {
	for b.written < len(b.reply) {
		n, err := net.send_tcp(b.socket, b.reply[b.written:])
		b.written += n
		if err == .Would_Block {
			b.send_op = nbio.poll_poly(b.socket, .Send, b, proc(op: ^nbio.Operation, b: ^Bridge) {
				b.send_op = nil
				bridge_reply(b)
			})
			return
		}
		if err != nil {
			break
		}
	}
	net.shutdown(b.socket, .Send)
	bridge_drain(b)
}

// Reads and drops what a rejected connection still sends, until it closes.
@(private)
bridge_drain :: proc(b: ^Bridge) {
	buf: [4096]byte
	for {
		n, err := net.recv_tcp(b.socket, buf[:])
		if err == .Would_Block {
			b.recv_op = nbio.poll_poly(b.socket, .Receive, b, proc(op: ^nbio.Operation, b: ^Bridge) {
				b.recv_op = nil
				bridge_drain(b)
			})
			return
		}
		if err != nil || n == 0 {
			if b.draining != nil {
				nbio.remove(b.draining)
				b.draining = nil
			}
			bridge_finish(b)
			return
		}
	}
}

// Asks port_permitted again of every port reached through this device, ending those no longer permitted.
forwards_recheck :: proc(sp: ^Space) {
	permitted := sp.host.port_permitted
	for i := len(sp.bridges) - 1; i >= 0; i -= 1 {
		if i >= len(sp.bridges) {
			continue
		}
		b := sp.bridges[i]
		if !b.inbound || b.over {
			continue
		}
		if ok := permitted != nil && b.port != 0 && bridge_permitted(b); !ok {
			audit(sp, {device = b.caller, scope = b.scope, service = "tcp", detail = bridge_detail(b), event = .Denied, peer = "no longer permitted"})
			call_fault(sp, b.call, .Denied)
			bridge_abort(b, .Denied)
		}
	}
}

@(private)
bridge_permitted :: proc(b: ^Bridge) -> bool {
	ok, _ := b.sp.host.port_permitted(b.sp, b.caller, b.scope, b.port, b.target)
	return ok
}

@(private)
bridge_new :: proc(sp: ^Space, call: u64) -> ^Bridge {
	b := new(Bridge)
	b.sp, b.call = sp, call
	b.data = b
	b.on_data = bridge_on_data
	b.on_end = bridge_on_end
	b.on_fault = bridge_on_fault
	b.on_room = bridge_on_room
	append(&sp.bridges, b)
	return b
}

@(private)
bridge_attach :: proc(b: ^Bridge, socket: net.TCP_Socket, prelude: []byte) {
	b.socket, b.connected = socket, true
	net.set_blocking(socket, false)
	net.set_option(socket, .TCP_Nodelay, true)
	socket_lowat(socket, 32 << 10)
	append(&b.prelude, ..prelude)
	bridge_flush(b)
	if b.waiting {
		// Not before `forward` has returned: an inspector may want what it returns, to reject it.
		b.recv_op = nbio.poll_poly(b.socket, .Receive, b, proc(op: ^nbio.Operation, b: ^Bridge) {
			b.recv_op = nil
			bridge_read(b)
		})
		return
	}
	bridge_read(b)
}

@(private)
bridge_free :: proc(b: ^Bridge) {
	if b.sp != nil {
		for x, i in b.sp.bridges {
			if x == b {
				unordered_remove(&b.sp.bridges, i)
				break
			}
		}
	}
	if b.dialling != nil {
		// A dial taken back may have connected all the same, and then nobody would close what it made: so it is
		// left to finish, and closes what it made itself. Its space may be gone by then, so it lets go of that now.
		b.abandoned = true
		b.sp = nil
		return
	}
	if b.draining != nil {
		nbio.remove(b.draining)
	}
	if b.recv_op != nil {
		nbio.remove(b.recv_op)
	}
	if b.send_op != nil {
		nbio.remove(b.send_op)
	}
	delete(b.pending)
	delete(b.prelude)
	delete(b.held)
	delete(b.reply)
	delete(b.who)
	delete(b.target)
	free(b)
}

// Over, badly: the socket is reset and the call, if it goes on, cancelled.
@(private)
bridge_abort :: proc(b: ^Bridge, status: Forward_Status) {
	if b.over {
		return
	}
	b.over = true
	b.status = status
	if host_call_find(b.sp, b.call) != nil {
		call_cancel(b.sp, b.call)
	}
	if b.connected {
		bridge_unpoll(b)
		socket_abort(b.socket)
		b.connected = false
	}
	bridge_finish(b)
}

// Takes back what waits on the socket, before it is closed: a socket the kernel still has an operation on is not
// closed until that ends, and says nothing to its peer meanwhile.
@(private)
bridge_unpoll :: proc(b: ^Bridge) {
	if b.recv_op != nil {
		nbio.remove(b.recv_op)
		b.recv_op = nil
	}
	if b.send_op != nil {
		nbio.remove(b.send_op)
		b.send_op = nil
	}
}

// Over, well or badly: told once, and let go.
@(private)
bridge_finish :: proc(b: ^Bridge) {
	b.over = true
	if b.inbound {
		audit(b.sp, {device = b.caller, subject = b.who, scope = b.scope, service = "tcp", detail = bridge_detail(b), event = .Close, bytes_in = b.bytes_in, bytes_out = b.bytes_out})
	}
	if b.connected {
		bridge_unpoll(b)
		net.close(b.socket)
		b.connected = false
	}
	if b.done != nil {
		done, data := b.done, b.done_data
		b.done = nil
		done(data, b.status)
	}
	bridge_free(b)
}

// Both ways are done with: the socket said all it would and heard all it will.
@(private)
bridge_check_over :: proc(b: ^Bridge) {
	if !b.over && b.eof && b.shut && host_call_find(b.sp, b.call) == nil {
		b.status = .Closed
		bridge_finish(b)
	}
}

@(private)
bridge_detail :: proc(b: ^Bridge) -> string {
	return strings.concatenate({b.target if b.target != "" else "localhost", ":", u16_text(b.port)}, context.temp_allocator)
}

@(private)
u16_text :: proc(v: u16) -> string {
	buf := make([]byte, 5, context.temp_allocator)
	n := len(buf)
	v := v
	for {
		n -= 1
		buf[n] = '0' + byte(v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	return string(buf[n:])
}

// ---------------------------------------------------------------- the call's side

@(private)
bridge_on_data :: proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
	b := (^Bridge)(h.data)
	if b.over || b.refused {
		return true
	}
	bytes := bytes
	if b.waiting {
		b.waiting = false
		if len(bytes) == 0 || Tcp_Status(bytes[0]) != .Connected {
			code := Tcp_Status(bytes[0]) if len(bytes) > 0 else .Unreachable
			status := Forward_Status.Unreachable
			#partial switch code {
			case .Denied:
				status = .Denied
			case .Not_Offered:
				status = .Not_Offered
			case .Refused:
				status = .Refused
			case .Timed_Out:
				status = .Timed_Out
			}
			bridge_abort(b, status)
			return true
		}
		if b.done != nil {
			b.done(b.done_data, .Connected) // before anything from the port is written
		}
		return true // the status is not for the socket
	}
	if b.heard_end {
		return true
	}
	b.bytes_out += u64(len(bytes))
	if len(b.pending) == b.written && len(b.prelude) == 0 && b.connected {
		// Straight through, if the socket takes it all.
		n, err := net.send_tcp(b.socket, bytes)
		if err != nil && err != .Would_Block {
			bridge_abort(b, .Lost)
			return true
		}
		if n == len(bytes) {
			return true
		}
		call_consumed(b.sp, b.call, n)
		bytes = bytes[n:]
	}
	append(&b.pending, ..bytes)
	bridge_flush(b)
	return false
}

@(private)
bridge_on_end :: proc(h: ^Call_Handler, call: u64) {
	b := (^Bridge)(h.data)
	b.heard_end = true
	if b.waiting {
		bridge_abort(b, .Unreachable) // ended before saying whether it reached the port
		return
	}
	if b.refused {
		bridge_finish(b) // said its failure, heard the end
		return
	}
	bridge_flush(b)
}

@(private)
bridge_on_fault :: proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {
	b := (^Bridge)(h.data)
	status := Forward_Status.Lost
	if fault == .Denied {
		status = .Denied
	}
	if b.inbound {
		audit(b.sp, {device = b.caller, scope = b.scope, service = "tcp", detail = bridge_detail(b), event = .Close, peer = fault_text(fault), bytes_in = b.bytes_in, bytes_out = b.bytes_out})
		b.inbound = false // said
	}
	b.call = 0
	bridge_abort(b, status)
}

@(private)
bridge_on_room :: proc(h: ^Call_Handler, call: u64) {
	bridge_read((^Bridge)(h.data))
}

@(private)
fault_text :: proc(f: zsp.Call_Fault) -> string {
	switch f {
	case .Cancelled:
		return "cancelled"
	case .Denied:
		return "denied"
	case .Unreachable:
		return "unreachable"
	case .Unserved:
		return "unserved"
	case .Lost:
		return "lost"
	case .Overrun:
		return "overrun"
	case .Busy:
		return "busy"
	}
	return "failed"
}

// ---------------------------------------------------------------- the socket's side

// Where two polls wait on one socket, Windows completes whichever was made first and leaves the other: so each,
// when it fires, takes the other's part too (see POLLS_MEET).
@(private)
bridge_read :: proc(b: ^Bridge) {
	if b.over || !b.connected || b.eof || b.recv_op != nil || b.dialling != nil {
		return
	}
	if len(b.held) > 0 && (b.inspect == nil || b.early > 0) {
		bridge_send_held(b) // what was given early, or an inspector let through, as credit allows
		if len(b.held) > 0 && b.inspect == nil {
			return
		}
	}
	// Its own buffer, not the host's: this runs within the handling of what came in, which may still be in that.
	buf: [BRIDGE_READ]byte
	for _ in 0 ..< 16 {
		room := call_room(b.sp, b.call)
		if b.inspect != nil {
			room = INSPECT_MOST - (len(b.held) - b.early) + 1
		}
		if room <= 0 {
			return // on_room says when to go on
		}
		n, err := net.recv_tcp(b.socket, buf[:min(room, len(buf), BRIDGE_READ)])
		if err == .Would_Block {
			b.recv_op = nbio.poll_poly(b.socket, .Receive, b, proc(op: ^nbio.Operation, b: ^Bridge) {
				b.recv_op = nil
				when POLLS_MEET {
					if b.send_op != nil {
						nbio.remove(b.send_op)
						b.send_op = nil
						bridge_flush(b)
					}
				}
				bridge_read(b)
			})
			return
		}
		if err != nil {
			bridge_abort(b, .Lost)
			return
		}
		if n == 0 {
			b.eof = true
			if b.inspect != nil {
				bridge_abort(b, .Rejected) // it ended before it could be judged
				return
			}
			call_end(b.sp, b.call)
			bridge_check_over(b)
			return
		}
		b.bytes_in += u64(n)
		if b.inspect != nil {
			append(&b.held, ..buf[:n])
			switch b.inspect(b.done_data, b.held[b.early:]) {
			case .More:
				if len(b.held) - b.early >= INSPECT_MOST {
					bridge_abort(b, .Rejected)
					return
				}
				continue
			case .Reject:
				if !b.over {
					bridge_reject(b) // with what forward_reject said to reply, if it did
				}
				return
			case .Pass:
				b.inspect = nil
				// What was held goes as credit allows; the rest waits in held until then.
				bridge_send_held(b)
				if len(b.held) > 0 {
					return
				}
				continue
			}
		}
		if !call_send(b.sp, b.call, buf[:n]) {
			bridge_abort(b, .Lost)
			return
		}
	}
	// Others have a turn; this goes on at once after.
	b.recv_op = nbio.poll_poly(b.socket, .Receive, b, proc(op: ^nbio.Operation, b: ^Bridge) {
		b.recv_op = nil
		bridge_read(b)
	})
}

@(private)
bridge_send_held :: proc(b: ^Bridge) {
	for len(b.held) > 0 {
		// While an inspector looks, only what was given early may go.
		most := len(b.held) if b.inspect == nil else b.early
		n := min(most, call_room(b.sp, b.call), zsp.CALL_WINDOW)
		if n <= 0 || !call_send(b.sp, b.call, b.held[:n]) {
			return
		}
		remove_range(&b.held, 0, n)
		b.early = max(b.early - n, 0)
	}
}

@(private)
bridge_flush :: proc(b: ^Bridge) {
	if b.over || !b.connected || b.send_op != nil {
		return
	}
	for len(b.prelude) > 0 || b.written < len(b.pending) {
		prelude := len(b.prelude) > 0
		n, err := net.send_tcp(b.socket, b.prelude[:] if prelude else b.pending[b.written:])
		if prelude {
			remove_range(&b.prelude, 0, n)
		} else if n > 0 {
			b.written += n
			call_consumed(b.sp, b.call, n)
		}
		if err == .Would_Block {
			b.send_op = nbio.poll_poly(b.socket, .Send, b, proc(op: ^nbio.Operation, b: ^Bridge) {
				b.send_op = nil
				when POLLS_MEET {
					if b.recv_op != nil {
						nbio.remove(b.recv_op)
						b.recv_op = nil
						bridge_read(b)
					}
				}
				bridge_flush(b)
			})
			return
		}
		if err != nil {
			bridge_abort(b, .Lost)
			return
		}
	}
	clear(&b.pending)
	b.written = 0
	if cap(b.pending) > 64 << 10 {
		shrink(&b.pending)
	}
	if b.heard_end && !b.shut {
		b.shut = true
		net.shutdown(b.socket, .Send)
		bridge_check_over(b)
	}
}

@(private)
bridges_close :: proc(sp: ^Space) {
	for len(sp.bridges) > 0 {
		b := sp.bridges[len(sp.bridges) - 1]
		b.call = 0
		bridge_abort(b, .Lost)
	}
	delete(sp.bridges)
}

// ---------------------------------------------------------------- zsp.tcp

// port (2, big-endian) ‖ host: a TCP connection to that port, there or, if the host is empty, here.
@(private)
serve_tcp :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	// Not for relays, nor for the device's own clients: what they would reach here they reach already, or are not let.
	if len(first) < 2 || from.relay || from.local != nil {
		return nil, .Denied
	}
	port := endian.unchecked_get_u16be(first)
	target := string(first[2:])
	b := bridge_new(sp, call)
	b.inbound = true
	b.caller, b.scope, b.port = from.device, scope, port
	b.who = strings.clone(string(from.who))
	b.target = strings.clone(target)
	status := Tcp_Status.Connected
	ok, proxy := false, false
	if sp.host.port_permitted != nil && port != 0 {
		ok, proxy = sp.host.port_permitted(sp, from.device, scope, port, target)
	}
	at: net.Endpoint
	switch {
	case !ok:
		status = .Not_Offered if sp.host.port_permitted != nil else .Denied
	case target == "" || target == "localhost":
		at = {net.IP4_Loopback, int(port)}
		b.dial6 = {net.IP6_Loopback, int(port)} // where plenty listen only
	case:
		if address := net.parse_address(target); address != nil {
			at = {address, int(port)}
		} else {
			status = .Unreachable // a name: whoever offers it says where it is, as an address
		}
	}
	if status != .Connected {
		audit(sp, {device = from.device, subject = b.who, scope = scope, service = "tcp", detail = bridge_detail(b), event = .Denied})
		w := [1]byte{u8(status)}
		b.inbound = false
		b.refused = true
		call_send(sp, call, w[:])
		call_end(sp, call)
		return &b.handler, .Cancelled
	}
	audit(sp, {device = from.device, subject = b.who, scope = scope, service = "tcp", detail = bridge_detail(b), event = .Open})
	prelude: []byte
	if proxy && sp.host.proxy_prelude != nil {
		prelude = sp.host.proxy_prelude(sp, from, port, target)
	}
	append(&b.prelude, ..prelude)
	bridge_dial(b, at)
	return &b.handler, .Cancelled
}

@(private)
bridge_dial :: proc(b: ^Bridge, at: net.Endpoint) {
	b.dialling = nbio.dial_poly(at, b, proc(op: ^nbio.Operation, b: ^Bridge) {
		b.dialling = nil
		if b.abandoned {
			if op.dial.err == nil {
				socket_abort(op.dial.socket)
			}
			bridge_free(b)
			return
		}
		if op.dial.err != nil {
			status := Tcp_Status.Refused
			#partial switch e in op.dial.err {
			case net.Dial_Error:
				#partial switch e {
				case .Timeout:
					status = .Timed_Out
				case .Network_Unreachable, .Host_Unreachable:
					status = .Unreachable
				}
			}
			if status == .Refused && b.dial6.port != 0 {
				next := b.dial6
				b.dial6 = {}
				bridge_dial(b, next)
				return
			}
			audit(b.sp, {device = b.caller, subject = b.who, scope = b.scope, service = "tcp", detail = bridge_detail(b), event = .Close, peer = "could not connect"})
			w := [1]byte{u8(status)}
			b.inbound = false
			b.refused = true
			call_send(b.sp, b.call, w[:])
			call_end(b.sp, b.call)
			if b.heard_end {
				bridge_finish(b)
			}
			return
		}
		w := [1]byte{u8(Tcp_Status.Connected)}
		call_send(b.sp, b.call, w[:])
		bridge_attach(b, op.dial.socket, nil)
	}, timeout = CONNECT_WAIT)
}

host_serve_builtin :: proc(h: ^Host) {
	host_serve(h, "zsp.tcp", serve_tcp)
	host_serve(h, "zsp.services", serve_services)
	host_serve(h, "zsp.share", serve_shares)
	host_serve(h, "zsp.list", serve_list)
	host_serve(h, "zsp.get", serve_get)
	host_serve(h, "zsp.put", serve_put)
	host_serve(h, "zsp.exec", serve_exec)
	host_serve(h, "zsp.pty", serve_pty)
}
