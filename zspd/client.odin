package main

import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import "../host"
import "../pipe"
import "../zsp"

// zspd's own local client: how a command reaches the node running here, as any local client does (§7, §8). It dials
// the address in `<dir>/address`, upgrades to a WebSocket at "/", greets the node with the token in `<dir>/token`,
// and once it is told what it may do (the open session's Roster), makes calls: each a stream of messages each way
// (§12), credited as they are taken, so that neither end holds more than the other has room for.
//
// One thread, one event loop, as in the host: between events the process is asleep in the kernel. A command hears of
// its calls through host.Call_Handler, as the host's own calls do, and of whatever its threads have to say (input
// read, output written, a signal) through `settle`, after every turn of the loop.

HELLO_WAIT :: 10 * time.Second // for the node to say what this client may do
REACH_WAIT :: 10 * time.Second // for a device to come within reach before it is called all the same
CLIENT_PLAIN :: 60 << 10 // of the session's bytes in one WebSocket message
CLIENT_READ :: 64 << 10 // from the socket, at once

Client :: struct {
	token:       []byte, // owned
	address:     string, // owned
	socket:      net.TCP_Socket,
	phase:       enum {
		Dialling,
		Upgrading, // the request is sent, the response awaited
		Greeting, // open, and waiting to be told what this client may do
		Ready,
		Closed,
	},
	in_buf:      [dynamic]byte, // from the socket: the response's head, then WebSocket frames
	pieces:      [dynamic]byte, // of a message in several frames
	fragmented:  bool,
	stream:      [dynamic]byte, // the session's bytes from the node, not yet whole frames
	said:        [dynamic]byte, // the session's bytes for the node, not yet in messages
	out:         [dynamic]byte, // for the socket
	sent:        int,
	dialling:    ^nbio.Operation,
	recv_op:     ^nbio.Operation,
	send_op:     ^nbio.Operation,
	timer:       ^nbio.Operation, // for the greeting, then for a device to come within reach
	scopes:      [dynamic]Client_Scope, // what this client may do, as the node last said
	reach:       [dynamic]zsp.Key32, // this device first, then every device it can reach
	calls:       [dynamic]Client_Call,
	next_call:   u64,
	failure:     string, // why it stopped, when it failed
	stopping:    bool, // stops once all that is queued is on its way
	// The command's.
	data:        rawptr,
	target:      zsp.Key32, // the device to call
	begin:       proc(c: ^Client), // once the target is within reach, or has had REACH_WAIT to be
	begun:       bool,
	settle:      proc(c: ^Client), // after every turn of the loop
	buf:         [CLIENT_READ]byte,
}

Client_Scope :: struct {
	scope:  zsp.Scope,
	rights: zsp.Rights,
}

Client_Call :: struct {
	id:        u64,
	handler:   ^host.Call_Handler,
	granted:   int, // what this side may send yet
	window:    int, // what the other side may have outstanding
	used:      int, // of it, consumed since the window last grew
	since:     time.Tick,
	ended:     bool, // we said End
	heard_end: bool, // they did
}

// Dials the node running here. False, with the reason in `failure`, if there is none to dial.
client_open :: proc(c: ^Client, dir: string) -> bool {
	address, aerr := os.read_entire_file(in_dir(dir, "address"), context.allocator)
	token, terr := os.read_entire_file(in_dir(dir, "token"), context.allocator)
	if aerr != nil || terr != nil {
		c.failure = "no node has run here: start one with zspd run"
		return false
	}
	c.address, c.token = string(address), token
	endpoint, parsed := net.parse_endpoint(c.address)
	if !parsed {
		c.failure = "the address the node left makes no sense"
		return false
	}
	// As the host does: a ring let go of by a process that has just ended may still count against what may be kept.
	for tries := 0; !host.ring_free() && tries < 40; tries += 1 {
		time.sleep(50 * time.Millisecond)
	}
	if err := nbio.acquire_thread_event_loop(); err != nil {
		c.failure = "the event loop failed"
		return false
	}
	loop_wakes(nbio.current_thread_event_loop())
	c.dialling = nbio.dial_poly(endpoint, c, proc(op: ^nbio.Operation, c: ^Client) {
		c.dialling = nil
		if op.dial.err != nil {
			client_close(c, "no node is running here")
			return
		}
		c.socket = op.dial.socket
		net.set_blocking(c.socket, false)
		net.set_option(c.socket, .TCP_Nodelay, true)
		c.phase = .Upgrading
		append(&c.out, pipe.ws_request(c.address, "/"))
		// Hello: version, no flags, no space or roster to speak of, and the token.
		w := &c.said
		at := zsp.frame_begin(w, .Hello)
		append(w, zsp.VERSION, 0)
		resize(w, len(w) + 32)
		zsp.write_varint(w, 0)
		zsp.write_bytes(w, c.token)
		zsp.frame_end(w, at)
		client_listen(c)
	}, timeout = HELLO_WAIT)
	c.timer = nbio.timeout_poly(HELLO_WAIT, c, proc(op: ^nbio.Operation, c: ^Client) {
		c.timer = nil
		client_close(c, "the node running here does not answer")
	})
	return true
}

// The longest the loop waits without looking at what its threads may have said.
CLIENT_WAIT :: 25 * time.Millisecond

// Runs the loop until the command stops it, or the connection fails. False, with the reason in `failure`, if it failed.
client_run :: proc(c: ^Client) -> bool {
	for {
		if c.settle != nil && c.phase != .Closed {
			c.settle(c)
		}
		client_flush(c)
		if c.phase == .Closed || (c.stopping && client_drained(c)) {
			break
		}
		// Not for ever: what a thread reads, writes or catches for a command wakes the loop by nbio.wake_up, which on
		// Windows wakes it only if it is asleep already, so that one told as it was about to sleep would sleep on.
		if err := nbio.tick(CLIENT_WAIT); err != nil {
			client_close(c, "the event loop failed")
			break
		}
		free_all(context.temp_allocator)
	}
	client_destroy(c)
	return c.failure == ""
}

// Stops the loop once all that is queued for the node is on its way.
client_stop :: proc(c: ^Client) {
	c.stopping = true
}

@(private = "file")
client_drained :: proc(c: ^Client) -> bool {
	return len(c.said) == 0 && len(c.out) == c.sent && c.send_op == nil
}

@(private = "file")
client_destroy :: proc(c: ^Client) {
	for op in ([]^^nbio.Operation{&c.dialling, &c.recv_op, &c.send_op, &c.timer}) {
		if op^ != nil {
			nbio.remove(op^)
			op^ = nil
		}
	}
	if c.phase > .Dialling && c.phase != .Closed {
		net.close(c.socket)
	}
	c.phase = .Closed
	delete(c.in_buf)
	delete(c.pieces)
	delete(c.stream)
	delete(c.said)
	delete(c.out)
	delete(c.scopes)
	delete(c.reach)
	delete(c.calls)
	delete(c.token)
	delete(c.address)
	loop_wakes(nil)
	nbio.release_thread_event_loop()
}

// The connection is over: every call under way is lost, and the loop stops.
@(private = "file")
client_close :: proc(c: ^Client, why: string) {
	if c.phase == .Closed {
		return
	}
	connected := c.phase > .Dialling
	c.phase = .Closed
	if !c.stopping {
		c.failure = why
	}
	for op in ([]^^nbio.Operation{&c.dialling, &c.recv_op, &c.send_op, &c.timer}) {
		if op^ != nil {
			nbio.remove(op^)
			op^ = nil
		}
	}
	if connected {
		net.close(c.socket)
	}
	// One at a time, looking afresh: whoever is told may end other calls.
	for len(c.calls) > 0 {
		x := pop(&c.calls)
		if h := x.handler; h != nil && h.on_fault != nil {
			h.on_fault(h, x.id, .Lost)
		}
	}
}

// ---------------------------------------------------------------- calls

// Calls a method a device serves (its host's own begin "zsp."). Returns 0 if it cannot be made yet.
client_call :: proc(c: ^Client, device: zsp.Key32, scope: zsp.Scope, method: string, first: []byte, handler: ^host.Call_Handler) -> u64 {
	if c.phase != .Ready || len(method) == 0 || len(method) > zsp.MAX_METHOD || len(first) > zsp.CALL_WINDOW {
		return 0
	}
	device := device
	c.next_call += 1
	w := &c.said
	at := zsp.frame_begin(w, .Call)
	zsp.write_varint(w, c.next_call)
	append(w, ..device[:])
	zsp.write_varint(w, u64(scope))
	zsp.write_bytes(w, transmute([]byte)method)
	zsp.write_bytes(w, nil) // for whom: the node says, not this client
	append(w, ..first)
	zsp.frame_end(w, at)
	append(&c.calls, Client_Call{id = c.next_call, handler = handler, granted = zsp.CALL_WINDOW - len(first), window = zsp.CALL_WINDOW, since = time.tick_now()})
	return c.next_call
}

// Sends a message, if credit allows. A message is at most 256 KiB.
client_send :: proc(c: ^Client, call: u64, bytes: []byte) -> bool {
	x := client_call_find(c, call)
	if x == nil || x.ended || len(bytes) > x.granted || len(bytes) > zsp.CALL_WINDOW {
		return false
	}
	x.granted -= len(bytes)
	client_flow(c, call, .Data, bytes)
	return true
}

// How many bytes may be sent now, in one message.
client_room :: proc(c: ^Client, call: u64) -> int {
	x := client_call_find(c, call)
	if x == nil || x.ended {
		return 0
	}
	return min(x.granted, zsp.CALL_WINDOW)
}

// Says this side will send no more.
client_end :: proc(c: ^Client, call: u64) {
	x := client_call_find(c, call)
	if x == nil || x.ended {
		return
	}
	x.ended = true
	client_flow(c, call, .End)
	if x.heard_end {
		client_call_forget(c, call)
	}
}

// Ends a call at once: this side no longer cares.
client_cancel :: proc(c: ^Client, call: u64) {
	if client_call_find(c, call) == nil {
		return
	}
	client_flow(c, call, .Cancel)
	client_call_forget(c, call)
}

// Whether a call is under way, and has not been said by the other side to be over.
client_calling :: proc(c: ^Client, call: u64) -> bool {
	return client_call_find(c, call) != nil
}

// Says that bytes kept from on_data are done with: the other side may send as many more. A window used up quickly
// grows, as the host's do, so that a long path is kept full.
client_consumed :: proc(c: ^Client, call: u64, n: int) {
	x := client_call_find(c, call)
	if x == nil || n <= 0 {
		return
	}
	credit := n
	x.used += n
	if x.used >= x.window {
		if time.tick_since(x.since) < host.WINDOW_QUICK && x.window < host.WINDOW_MOST {
			credit += x.window
			x.window *= 2
		}
		x.used = 0
		x.since = time.tick_now()
	}
	w := make([dynamic]byte, 0, 10, context.temp_allocator)
	zsp.write_varint(&w, u64(credit))
	client_flow(c, call, .Credit, w[:])
}

@(private = "file")
client_flow :: proc(c: ^Client, call: u64, kind: zsp.Flow, payload: []byte = nil) {
	w := &c.said
	at := zsp.frame_begin(w, .Flow)
	zsp.write_varint(w, call << 1) // spoken by the caller
	append(w, u8(kind))
	append(w, ..payload)
	zsp.frame_end(w, at)
}

@(private = "file")
client_call_find :: proc(c: ^Client, call: u64) -> ^Client_Call {
	for &x in c.calls {
		if x.id == call {
			return &x
		}
	}
	return nil
}

@(private = "file")
client_call_forget :: proc(c: ^Client, call: u64) {
	for x, i in c.calls {
		if x.id == call {
			unordered_remove(&c.calls, i)
			return
		}
	}
}

// What the callee said: id, which side spoke, kind, payload.
@(private = "file")
client_heard :: proc(c: ^Client, payload: []byte) -> bool {
	r := zsp.Reader{buf = payload}
	tag := zsp.read_varint(&r)
	kind := zsp.Flow(zsp.read_u8(&r))
	body := payload[min(r.pos, len(payload)):]
	if r.bad || tag & 1 != 1 {
		return false
	}
	call := tag >> 1
	x := client_call_find(c, call)
	if x == nil {
		return true // over, here, already
	}
	h := x.handler
	switch kind {
	case .Data:
		if h == nil || h.on_data == nil || h.on_data(h, call, body) {
			client_consumed(c, call, len(body))
		}
	case .End:
		x.heard_end = true
		if x.ended {
			client_call_forget(c, call)
		}
		if h != nil && h.on_end != nil {
			h.on_end(h, call)
		}
	case .Fault, .Cancel:
		client_call_forget(c, call)
		fault := zsp.Call_Fault.Cancelled
		if kind == .Fault && len(body) > 0 {
			fault = zsp.Call_Fault(body[0])
		}
		if h != nil && h.on_fault != nil {
			h.on_fault(h, call, fault)
		}
	case .Credit:
		credit := zsp.Reader{buf = body}
		x.granted = min(x.granted + int(zsp.read_varint(&credit) & 0xff_ffff), 16 * zsp.CALL_WINDOW)
		if h != nil && h.on_room != nil {
			h.on_room(h, call)
		}
	case:
	}
	return true
}

// ---------------------------------------------------------------- what the node says

@(private = "file")
client_frame :: proc(c: ^Client, type: zsp.Message, payload: []byte) -> bool {
	#partial switch type {
	case .Roster:
		// clock (8), then what this client may do in each scope
		if len(payload) < 8 {
			return false
		}
		r := zsp.Reader{buf = payload[8:]}
		clear(&c.scopes)
		for r.pos < len(r.buf) {
			scope := zsp.Scope(zsp.read_varint(&r))
			rights := transmute(zsp.Rights)(zsp.read_u8(&r) & 0x7f)
			_ = zsp.read_take(&r, 32) // the scope's list key, which no command here needs
			if r.bad {
				return false
			}
			append(&c.scopes, Client_Scope{scope, rights})
		}
		if c.phase == .Greeting {
			c.phase = .Ready
			if c.timer != nil {
				nbio.remove(c.timer)
				c.timer = nil
			}
			client_reach_check(c)
			if !c.begun && c.timer == nil {
				c.timer = nbio.timeout_poly(REACH_WAIT, c, proc(op: ^nbio.Operation, c: ^Client) {
					c.timer = nil
					client_begin(c) // it may yet answer; if not, the call says so
				})
			}
		}
	case .Presence:
		// n × { device (32), subject bytes }: this device first
		r := zsp.Reader{buf = payload}
		clear(&c.reach)
		for r.pos < len(r.buf) {
			key := zsp.read_take(&r, 32)
			_ = zsp.read_bytes(&r)
			if r.bad {
				return false
			}
			device: zsp.Key32
			copy(device[:], key)
			append(&c.reach, device)
		}
		client_reach_check(c)
	case .Flow:
		return client_heard(c, payload)
	case .Error:
		code := payload[0] if len(payload) > 0 else 0
		switch code {
		case 2:
			client_close(c, "the node running here turned this client away: the token is not its own")
		case 3:
			client_close(c, "the node running here speaks another version")
		case 5:
			client_close(c, "this machine's clock is far out")
		case:
			client_close(c, "the node running here ended the session")
		}
		return true
	}
	// Hello, and what a client that watches nothing and serves nothing is not sent.
	return true
}

@(private = "file")
client_reach_check :: proc(c: ^Client) {
	if c.phase != .Ready || c.begun {
		return
	}
	for d in c.reach {
		if d == c.target {
			client_begin(c)
			return
		}
	}
}

@(private = "file")
client_begin :: proc(c: ^Client) {
	if c.begun || c.phase != .Ready {
		return
	}
	c.begun = true
	if c.timer != nil {
		nbio.remove(c.timer)
		c.timer = nil
	}
	if c.begin != nil {
		c.begin(c)
	}
}

// ---------------------------------------------------------------- the socket

@(private = "file")
client_listen :: proc(c: ^Client) {
	c.recv_op = nbio.poll_poly(c.socket, .Receive, c, proc(op: ^nbio.Operation, c: ^Client) {
		c.recv_op = nil
		when host.POLLS_MEET {
			if c.send_op != nil {
				nbio.remove(c.send_op)
				c.send_op = nil // what is yet to be sent is tried again
			}
		}
		client_readable(c)
	})
}

@(private = "file")
client_readable :: proc(c: ^Client) {
	for _ in 0 ..< 16 { // then let others have a turn
		n, err := net.recv_tcp(c.socket, c.buf[:])
		if err == .Would_Block {
			break
		}
		if err != nil || n == 0 {
			client_close(c, "the node running here closed the connection")
			return
		}
		if !client_input(c, c.buf[:n]) {
			client_close(c, "the node running here said what makes no sense")
			return
		}
		if c.phase == .Closed {
			return
		}
		if n < len(c.buf) {
			break
		}
	}
	client_listen(c)
}

@(private = "file")
client_input :: proc(c: ^Client, bytes: []byte) -> bool {
	append(&c.in_buf, ..bytes)
	used := 0
	defer {
		copy(c.in_buf[:], c.in_buf[used:])
		resize(&c.in_buf, len(c.in_buf) - used)
	}
	if c.phase == .Upgrading {
		head, ok := pipe.http_head(c.in_buf[:])
		if !ok {
			return len(c.in_buf) < 16 << 10
		}
		if !strings.contains(head.first, " 101 ") {
			return false
		}
		used += head.size
		c.phase = .Greeting
	}
	for c.phase != .Closed {
		op, payload, n, fin, result := pipe.ws_take(c.in_buf[used:])
		switch result {
		case .More:
			return true
		case .Broken:
			return false
		case .Message:
		}
		used += n
		#partial switch op {
		case .Binary, .Continue:
			if (op == .Continue) != c.fragmented || len(c.pieces) + len(payload) > pipe.MAX_MESSAGE {
				return false
			}
			if fin && op == .Binary {
				append(&c.stream, ..payload)
			} else {
				append(&c.pieces, ..payload)
				c.fragmented = !fin
				if fin {
					append(&c.stream, ..c.pieces[:])
					clear(&c.pieces)
				}
			}
			client_frames(c) or_return
		case .Ping:
			pipe.ws_put(&c.out, .Pong, payload, true)
		case .Close:
			client_close(c, "the node running here closed the connection")
			return true
		}
	}
	return true
}

// Takes every whole frame off the session's bytes.
@(private = "file")
client_frames :: proc(c: ^Client) -> bool {
	used := 0
	defer {
		copy(c.stream[:], c.stream[used:])
		resize(&c.stream, len(c.stream) - used)
	}
	for c.phase != .Closed {
		r := zsp.Reader{buf = c.stream[used:]}
		size := zsp.read_varint(&r)
		if r.bad {
			return len(r.buf) < 10 // a length not yet whole, or none at all
		}
		if size == 0 || size > zsp.MAX_FRAME {
			return false
		}
		if u64(len(r.buf) - r.pos) < size {
			return true
		}
		frame := r.buf[r.pos:][:size]
		used += r.pos + int(size)
		client_frame(c, zsp.Message(frame[0]), frame[1:]) or_return
	}
	return true
}

// Draws what has been said into the socket, as messages, for as long as the socket takes it.
@(private = "file")
client_flush :: proc(c: ^Client) {
	if c.phase == .Dialling || c.phase == .Closed {
		return
	}
	for c.send_op == nil {
		at := 0
		for at < len(c.said) && len(c.out) - c.sent < host.OUT_HIGH {
			n := min(len(c.said) - at, CLIENT_PLAIN)
			pipe.ws_put(&c.out, .Binary, c.said[at:][:n], true)
			at += n
		}
		remove_range(&c.said, 0, at)
		if len(c.out) == c.sent {
			break
		}
		for c.sent < len(c.out) {
			n, err := net.send_tcp(c.socket, c.out[c.sent:])
			c.sent += n
			if err == .Would_Block {
				c.send_op = nbio.poll_poly(c.socket, .Send, c, proc(op: ^nbio.Operation, c: ^Client) {
					c.send_op = nil
					when host.POLLS_MEET {
						if c.recv_op != nil {
							nbio.remove(c.recv_op)
							c.recv_op = nil
							client_readable(c)
						}
					}
				})
				return
			}
			if err != nil {
				client_close(c, "the node running here closed the connection")
				return
			}
		}
		c.sent = 0
		clear(&c.out)
	}
}
