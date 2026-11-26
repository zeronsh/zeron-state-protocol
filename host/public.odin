package host

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import "../pipe"
import "../zsp"

// A relay's side of exposure: which device exposes which label, while it is connected, and the public's way in at
// https://<label>.<domain>: TLS here, routed by the name the client asks for; or, behind something else that speaks
// TLS, plain HTTP routed by its Host. Each connection is a zsp.public call to the device, and its bytes flow only as
// fast as the slower side takes them: nothing is kept but what is in flight.

MAX_EXPOSED :: 4096 // labels at one relay
PUBLIC_MAX :: 1024 // connections from the public at once
PUBLIC_HEAD_MAX :: 16 << 10
PUBLIC_OUT_MAX :: 256 << 10 // for the public, unwritten: no more is read from it until that has gone
PUBLIC_HELLO :: 10 * time.Second // to say where to, after which it is let go

@(private)
Relay_Public :: struct {
	tls:       net.TCP_Socket,
	have_tls:  bool,
	http:      net.TCP_Socket,
	have_http: bool,
	accepting: [2]^nbio.Operation,
	identity:  pipe.Tls_Identity,
	labels:    [dynamic]Relay_Label,
	conns:     [dynamic]^Public_Out,
}

@(private)
Relay_Label :: struct {
	label:   string, // owned
	space:   ^Space,
	session: u32,
	device:  zsp.Key32,
}

@(private)
Public_Out :: struct {
	using handler: Call_Handler,
	h:         ^Host,
	sp:        ^Space,
	call:      u64,
	socket:    net.TCP_Socket,
	from:      net.Endpoint,
	tls:       ^pipe.Tls_Server, // nil for plain HTTP
	head:      [dynamic]byte, // plain: what came before it was routed
	pending:   [dynamic]byte, // from the public, for the device, awaiting credit
	out:       [dynamic]byte, // for the public
	sent:      int,
	owed:      int, // credit to give once what is in `out` is written
	connected: bool, // the device has said so
	ended_in:  bool, // the public has said all it will
	told_end:  bool, // and the device has been told so
	ended_out: bool, // the device has
	shut:      bool,
	finishing: bool, // closed once what is in `out` is written: an alert, a refusal
	closed:    bool,
	polling:   ^nbio.Operation,
	writing:   ^nbio.Operation,
	hello:     ^nbio.Operation, // until it says where to
}

// Listens for the public, as configured. False if it cannot.
@(private)
public_open :: proc(h: ^Host) -> bool {
	rp := &h.public
	if at, ok := h.https.?; ok {
		chain, cerr := os.read_entire_file(h.tls_cert, context.temp_allocator)
		key, kerr := os.read_entire_file(h.tls_key, context.temp_allocator)
		if cerr != nil || kerr != nil || !pipe.tls_identity_load(&rp.identity, chain, key) {
			report(.Error, "the certificate or its key cannot be read: a chain of PEM certificates, the leaf first, and an ECDSA (P-256, P-384) or RSA key")
			return false
		}
		socket, err := listen_on(at, 512)
		if err != nil {
			report(.Error, "cannot listen for the public at ", net.endpoint_to_string(at, context.temp_allocator), ": ", fmt.tprint(err))
			return false
		}
		rp.tls, rp.have_tls = socket, true
		rp.accepting[0] = nbio.accept_poly2(socket, h, true, public_accepted)
	}
	if at, ok := h.expose_http.?; ok {
		socket, err := listen_on(at, 512)
		if err != nil {
			report(.Error, "cannot listen for the public at ", net.endpoint_to_string(at, context.temp_allocator), ": ", fmt.tprint(err))
			return false
		}
		rp.http, rp.have_http = socket, true
		rp.accepting[1] = nbio.accept_poly2(socket, h, false, public_accepted)
	}
	return true
}

@(private)
public_close :: proc(h: ^Host) {
	rp := &h.public
	for len(rp.conns) > 0 {
		public_out_close(rp.conns[0], reset = true)
	}
	for op in rp.accepting {
		if op != nil {
			nbio.remove(op)
		}
	}
	if rp.have_tls {
		net.close(rp.tls)
	}
	if rp.have_http {
		net.close(rp.http)
	}
	for l in rp.labels {
		delete(l.label)
	}
	delete(rp.labels)
	delete(rp.conns)
	pipe.tls_identity_destroy(&rp.identity)
	rp^ = {}
}

// The public's address for a label, as this relay serves it.
@(private)
public_url :: proc(h: ^Host, label: string) -> string {
	if at, ok := h.https.?; ok {
		if at.port == 443 {
			return fmt.tprintf("https://%s.%s", label, h.expose)
		}
		return fmt.tprintf("https://%s.%s:%d", label, h.expose, at.port)
	}
	if at, ok := h.expose_http.?; ok {
		return fmt.tprintf("http://%s.%s:%d", label, h.expose, at.port) // behind something that has it otherwise
	}
	return ""
}

// 40 Expose, from a device: all it exposes here, replacing what it said before. Answered with 41 Exposed.
@(private)
public_exposed :: proc(sp: ^Space, s: ^zsp.Session, payload: []byte) {
	h := sp.host
	rp := &h.public
	r := zsp.Reader{buf = payload}
	n := zsp.read_varint(&r)
	if r.bad || n > MAX_EXPOSURES {
		return
	}
	#reverse for l, i in rp.labels {
		if l.space == sp && l.session == s.id {
			delete(l.label)
			unordered_remove(&rp.labels, i)
		}
	}
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&w, n)
	for _ in 0 ..< n {
		prefix := string(zsp.read_bytes(&r))
		nonce_bytes := zsp.read_take(&r, zsp.EXPOSE_NONCE)
		if r.bad || !zsp.exposure_prefix_valid(prefix) {
			return
		}
		nonce: [zsp.EXPOSE_NONCE]byte
		copy(nonce[:], nonce_bytes)
		label := zsp.exposure_label(sp.node.space, s.peer, prefix, nonce)
		status := u8(0)
		switch {
		case h.expose == "" || (!rp.have_tls && !rp.have_http):
			status = 1
		case public_label(h, label) != nil:
			status = 2 // the same nonce from elsewhere: nobody is to have two ways to one name
		case len(rp.labels) >= MAX_EXPOSED:
			status = 3
		case:
			append(&rp.labels, Relay_Label{strings.clone(label), sp, s.id, s.peer})
		}
		zsp.write_bytes(&w, transmute([]byte)label)
		append(&w, status)
		url := public_url(h, label) if status == 0 else ""
		zsp.write_bytes(&w, transmute([]byte)url)
	}
	zsp.session_say(s, zsp.EXPOSE + 1, w[:])
}

@(private)
public_label :: proc(h: ^Host, label: string) -> ^Relay_Label {
	for &l in h.public.labels {
		if l.label == label {
			return &l
		}
	}
	return nil
}

// A device has gone: what it exposed goes with it, and whoever was using it is cut off by the calls' ending.
@(private)
public_session_closed :: proc(h: ^Host, sp: ^Space, session: u32) {
	rp := &h.public
	#reverse for l, i in rp.labels {
		if l.space == sp && l.session == session {
			delete(l.label)
			unordered_remove(&rp.labels, i)
		}
	}
}

// The label a name is for, if it is one of this relay's: <label>.<domain>, in any case.
@(private)
public_name :: proc(h: ^Host, asked: string) -> ^Relay_Label {
	name := strings.to_lower(strings.trim_suffix(asked, "."), context.temp_allocator)
	label, under := cut_suffix(name, strings.concatenate({".", h.expose}, context.temp_allocator))
	if !under || h.expose == "" || strings.contains(label, ".") {
		return nil
	}
	return public_label(h, label)
}

@(private)
public_accepted :: proc(op: ^nbio.Operation, h: ^Host, secure: bool) {
	rp := &h.public
	rp.accepting[0 if secure else 1] = nbio.accept_poly2(rp.tls if secure else rp.http, h, secure, public_accepted)
	if op.accept.err != nil {
		return
	}
	if len(rp.conns) >= PUBLIC_MAX {
		// Full: the longest waiting of those that have not said where to makes room, so that nobody can keep the
		// public out by opening connections and saying nothing; if all have, the newcomer waits its turn elsewhere.
		oldest: ^Public_Out
		for x in rp.conns {
			if x.call == 0 && !x.closed {
				oldest = x
				break
			}
		}
		if oldest == nil {
			socket_abort(op.accept.client)
			return
		}
		public_out_close(oldest, reset = true)
	}
	c := new(Public_Out)
	c.h, c.socket, c.from = h, op.accept.client, op.accept.client_endpoint
	net.set_blocking(c.socket, false)
	net.set_option(c.socket, .TCP_Nodelay, true)
	if secure {
		c.tls = new(pipe.Tls_Server)
	}
	c.on_data = proc(hd: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		c := (^Public_Out)(hd)
		if c.finishing {
			return true
		}
		bytes := bytes
		if !c.connected {
			if len(bytes) == 0 || bytes[0] != 0 {
				public_out_refused(c)
				return true
			}
			c.connected = true
			bytes = bytes[1:]
			public_out_forward(c)
		}
		if c.tls != nil {
			pipe.tls_server_write(c.tls, bytes, &c.out)
		} else {
			append(&c.out, ..bytes)
		}
		c.owed += len(bytes)
		public_out_flush(c)
		return len(bytes) == 0
	}
	c.on_end = proc(hd: ^Call_Handler, call: u64) {
		c := (^Public_Out)(hd)
		c.ended_out = true
		if c.tls != nil {
			pipe.tls_server_close(c.tls, &c.out)
		}
		public_out_flush(c)
	}
	c.on_fault = proc(hd: ^Call_Handler, call: u64, _: zsp.Call_Fault) {
		c := (^Public_Out)(hd)
		c.call = 0
		if c.connected {
			public_out_close(c, reset = true)
		} else {
			public_out_refused(c)
		}
	}
	c.on_room = proc(hd: ^Call_Handler, call: u64) {
		public_out_forward((^Public_Out)(hd))
	}
	append(&rp.conns, c) // oldest first
	c.hello = nbio.timeout_poly(PUBLIC_HELLO, c, proc(op: ^nbio.Operation, c: ^Public_Out) {
		c.hello = nil
		if c.call == 0 {
			public_out_close(c, reset = true)
		}
	})
	public_out_wait(c)
}

@(private)
public_out_wait :: proc(c: ^Public_Out) {
	if c.polling != nil || c.closed || c.ended_in || c.finishing || len(c.out) - c.sent >= PUBLIC_OUT_MAX {
		return
	}
	// Read only while what was read can be passed on: the public is held back as the device is.
	if c.call != 0 && (!c.connected || len(c.pending) >= max(call_room(c.sp, c.call), 1)) {
		return
	}
	when POLLS_MEET {
		if c.writing != nil {
			return // the write's completion looks again
		}
	}
	c.polling = nbio.poll_poly(c.socket, .Receive, c, proc(op: ^nbio.Operation, c: ^Public_Out) {
		c.polling = nil
		if op.poll.result != .Ready {
			public_out_close(c, reset = true)
			return
		}
		public_out_read(c)
	})
}

@(private)
public_out_read :: proc(c: ^Public_Out) {
	h := c.h
	for !c.closed {
		n, err := net.recv_tcp(c.socket, h.shared)
		if err == .Would_Block {
			break
		}
		if err != nil {
			public_out_close(c, reset = true)
			return
		}
		if n == 0 {
			c.ended_in = true
			if c.call == 0 {
				public_out_close(c, reset = false) // gone before it said where to
				return
			}
			break
		}
		bytes := h.shared[:n]
		if c.tls != nil {
			plain := make([dynamic]byte, context.temp_allocator)
			ok := pipe.tls_accept(c.tls, bytes, &plain, &c.out, public_identity, h)
			c.finishing = !ok // its alert written, if any, and that is all
			public_out_flush(c)
			if !ok {
				return
			}
			if c.call == 0 && c.tls.state == .Open && !public_out_route(c, pipe.tls_server_name(c.tls)) {
				return
			}
			append(&c.pending, ..plain[:])
		} else if c.call == 0 {
			append(&c.head, ..bytes)
			end := strings.index(string(c.head[:]), "\r\n\r\n")
			if end < 0 {
				if len(c.head) > PUBLIC_HEAD_MAX {
					public_out_close(c, reset = true)
					return
				}
				continue
			}
			host := ""
			_, _, rest := strings.partition(string(c.head[:end]), "\r\n")
			for line in strings.split_lines_iterator(&rest) {
				name, colon, value := strings.partition(line, ":")
				if colon != "" && strings.equal_fold(name, "host") {
					host = strip_port(strings.trim_space(value))
				}
			}
			if !public_out_route(c, host) {
				return
			}
			append(&c.pending, ..c.head[:])
			clear(&c.head)
		} else {
			append(&c.pending, ..bytes)
		}
		if len(c.pending) >= 256 << 10 {
			break // enough waiting: no more is read until it has gone
		}
	}
	if c.closed {
		return
	}
	public_out_forward(c)
	public_out_wait(c)
}

// The identity this relay proves for a name: one of its exposed labels.
@(private)
public_identity :: proc(data: rawptr, name: string) -> ^pipe.Tls_Identity {
	h := (^Host)(data)
	return &h.public.identity if public_name(h, name) != nil else nil
}

// Calls the device whose label the name is. False, and closed, if it is nobody's.
@(private)
public_out_route :: proc(c: ^Public_Out, name: string) -> bool {
	h := c.h
	l := public_name(h, name)
	if l == nil {
		if c.tls != nil {
			public_out_close(c, reset = true)
		} else {
			public_out_finish(c, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		}
		return false
	}
	first := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&first, transmute([]byte)l.label)
	from := address_from(c.from)
	append(&first, ..from.ip[:])
	append(&first, byte(from.port >> 8), byte(from.port))
	c.sp = l.space
	if c.hello != nil {
		nbio.remove(c.hello)
		c.hello = nil
	}
	c.call = host_call(l.space, l.device, 0, "zsp.public", first[:], c)
	if c.call == 0 {
		public_out_refused(c)
		return false
	}
	return true
}

// Passes on what the public has said, as far as the device's credit goes.
@(private)
public_out_forward :: proc(c: ^Public_Out) {
	if c.closed || c.call == 0 || !c.connected {
		return
	}
	for len(c.pending) > 0 {
		n := min(len(c.pending), call_room(c.sp, c.call), 60 << 10)
		if n <= 0 {
			break
		}
		call_send(c.sp, c.call, c.pending[:n])
		remove_range(&c.pending, 0, n)
	}
	if c.ended_in && !c.told_end && len(c.pending) == 0 && c.call != 0 {
		c.told_end = true
		call_end(c.sp, c.call) // the public has said all; the device may yet answer
		if c.shut {
			public_out_close(c, reset = false)
			return
		}
	}
	if len(c.pending) == 0 && cap(c.pending) > 64 << 10 {
		shrink(&c.pending)
	}
	public_out_wait(c)
}

@(private)
public_out_flush :: proc(c: ^Public_Out) {
	if c.closed || c.writing != nil {
		return
	}
	for c.sent < len(c.out) {
		n, err := net.send_tcp(c.socket, c.out[c.sent:])
		c.sent += n
		if err == .Would_Block {
			when POLLS_MEET {
				if c.polling != nil {
					nbio.remove(c.polling)
					c.polling = nil
				}
			}
			c.writing = nbio.poll_poly(c.socket, .Send, c, proc(op: ^nbio.Operation, c: ^Public_Out) {
				c.writing = nil
				public_out_flush(c)
				public_out_wait(c)
			})
			return
		}
		if err != nil {
			public_out_close(c, reset = true)
			return
		}
	}
	clear(&c.out)
	c.sent = 0
	if c.finishing {
		public_out_close(c, reset = false)
		return
	}
	if c.owed > 0 && c.call != 0 {
		call_consumed(c.sp, c.call, c.owed) // written: the device may send as much again
		c.owed = 0
	}
	if c.ended_out && !c.shut {
		c.shut = true
		net.shutdown(c.socket, .Send) // the device has said all: the public may yet go on
	}
	if c.shut && c.told_end {
		public_out_close(c, reset = false)
	}
}

// The device would not have it: the public is told plainly, where it speaks HTTP.
@(private)
public_out_refused :: proc(c: ^Public_Out) {
	if c.closed {
		return
	}
	public_out_finish(c, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
}

// Says one last thing to the public, and closes once it is written, however slowly it reads.
@(private)
public_out_finish :: proc(c: ^Public_Out, say: string) {
	if c.finishing {
		return
	}
	c.finishing = true
	if c.polling != nil {
		nbio.remove(c.polling)
		c.polling = nil
	}
	if c.call != 0 {
		call_cancel(c.sp, c.call)
		c.call = 0
	}
	if c.tls == nil {
		append(&c.out, say)
	} else if c.tls.state == .Open {
		pipe.tls_server_write(c.tls, transmute([]byte)say, &c.out)
		pipe.tls_server_close(c.tls, &c.out)
	}
	public_out_flush(c)
}

@(private)
public_out_close :: proc(c: ^Public_Out, reset: bool) {
	if c.closed {
		return
	}
	c.closed = true
	rp := &c.h.public
	for x, i in rp.conns {
		if x == c {
			unordered_remove(&rp.conns, i)
			break
		}
	}
	if c.polling != nil {
		nbio.remove(c.polling)
	}
	if c.writing != nil {
		nbio.remove(c.writing)
	}
	if c.hello != nil {
		nbio.remove(c.hello)
	}
	if c.call != 0 {
		call_cancel(c.sp, c.call)
	}
	if reset {
		socket_abort(c.socket)
	} else {
		net.close(c.socket)
	}
	if c.tls != nil {
		pipe.tls_server_destroy(c.tls)
		free(c.tls)
	}
	delete(c.head)
	delete(c.pending)
	delete(c.out)
	append(&c.h.public_dead, c) // freed once the tick is over
}
