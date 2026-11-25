package host

import "core:encoding/hex"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../pipe"
import "../zsp"

// A session over a WebSocket over TCP, with TLS beneath when dialled so and a Noise channel within
// when the session is a peer's. An idle stream owns no buffers.

OUT_HIGH :: 256 << 10
PING_IDLE :: 45 * time.Second // keeps middleboxes and edges from forgetting a quiet connection
PONG_WAIT :: 15 * time.Second
MAX_PLAIN :: 60 << 10 // per Noise message

Stream :: struct {
	host:      ^Host,
	socket:    net.TCP_Socket,
	dialer:    ^Dialer, // if this end dialled
	tls:       ^pipe.Tls,
	phase:     enum {
		Request, // awaiting the peer's HTTP head
		Noise, // awaiting its handshake message
		Open,
	},
	handshake: ^zsp.Handshake,
	channel:   zsp.Channel,
	space:     ^Space,
	session:   ^zsp.Session,
	role:      zsp.Role,
	in_buf:    [dynamic]byte,
	out:       [dynamic]byte,
	sent:      int,
	recv_op:   ^nbio.Operation,
	send_op:   ^nbio.Operation,
	quiet_at:  time.Tick, // last heard from
	pinged:    bool,
	closing:   bool,
}

@(private)
stream_new :: proc(h: ^Host, socket: net.TCP_Socket) -> ^Stream {
	s := new(Stream)
	s.host = h
	s.socket = socket
	net.set_blocking(socket, false)
	net.set_option(socket, .TCP_Nodelay, true)
	append(&h.streams, s)
	s.quiet_at = time.tick_now()
	stream_listen(s)
	return s
}

@(private)
stream_accepted :: proc(op: ^nbio.Operation) {
	h := nbio_host
	nbio.accept(op.accept.socket, stream_accepted)
	if op.accept.err != nil {
		report(.Warning, "could not accept a connection")
		return
	}
	stream_new(h, op.accept.client)
}

@(private)
stream_listen :: proc(s: ^Stream) {
	s.recv_op = nbio.poll_poly(s.socket, .Receive, s, proc(op: ^nbio.Operation, s: ^Stream) {
		s.recv_op = nil
		stream_readable(s)
	})
}

stream_close :: proc(s: ^Stream) {
	h := s.host
	for x, i in h.streams {
		if x == s {
			unordered_remove(&h.streams, i)
			break
		}
	}
	if s.recv_op != nil {
		nbio.remove(s.recv_op)
	}
	if s.send_op != nil {
		nbio.remove(s.send_op)
	}
	if s.session != nil {
		zsp.session_close(s.session)
	}
	if s.dialer != nil {
		dialer_lost(s.dialer)
	}
	if s.tls != nil {
		pipe.tls_destroy(s.tls)
		free(s.tls)
	}
	free(s.handshake)
	net.close(s.socket)
	delete(s.in_buf)
	delete(s.out)
	free(s)
}

@(private)
stream_readable :: proc(s: ^Stream) {
	for _ in 0 ..< 16 { // then let others have a turn
		n, err := net.recv_tcp(s.socket, s.host.shared)
		if err == .Would_Block {
			break
		}
		if err != nil || n == 0 {
			stream_close(s)
			return
		}
		s.quiet_at = time.tick_now()
		s.pinged = false
		if !stream_input(s, s.host.shared[:n]) {
			if s.session != nil && s.session.closing {
				stream_flush(s) // says why, and closes
			} else {
				stream_close(s)
			}
			return
		}
		if n < len(s.host.shared) {
			break
		}
	}
	stream_listen(s)
}

@(private)
stream_input :: proc(s: ^Stream, bytes: []byte) -> bool {
	if s.tls != nil {
		was := s.tls.state
		pipe.tls_input(s.tls, bytes, &s.in_buf, &s.out) or_return
		if was != .Open && s.tls.state == .Open {
			stream_request(s)
		}
		if s.tls.state == .Closed {
			return false
		}
	} else {
		append(&s.in_buf, ..bytes)
	}
	used := 0
	defer {
		copy(s.in_buf[:], s.in_buf[used:])
		resize(&s.in_buf, len(s.in_buf) - used)
		if len(s.in_buf) == 0 {
			shrink(&s.in_buf)
		}
	}
	if s.phase == .Request {
		head, ok := pipe.http_head(s.in_buf[:])
		if !ok {
			return len(s.in_buf) < 16 << 10
		}
		stream_greeted(s, &head) or_return
		used += head.size
	}
	for {
		op, payload, n, result := pipe.ws_take(s.in_buf[used:])
		switch result {
		case .More:
			return true
		case .Broken:
			return false
		case .Message:
		}
		used += n
		#partial switch op {
		case .Binary:
			stream_message(s, payload) or_return
		case .Ping:
			stream_put(s, .Pong, payload)
		case .Close:
			return false
		}
	}
}

// Sends the WebSocket request of a stream this end dialled.
@(private)
stream_request :: proc(s: ^Stream) {
	request := pipe.ws_request(s.dialer.url.host, s.dialer.url.path)
	stream_raw(s, transmute([]byte)request)
}

// The HTTP head has come: a response to our request, or a request of us.
@(private)
stream_greeted :: proc(s: ^Stream, head: ^pipe.Http) -> bool {
	h := s.host
	if d := s.dialer; d != nil {
		if !strings.contains(head.first, " 101 ") {
			report(.Warning, d.url.host, ": ", head.first)
			return false
		}
		s.handshake = new(zsp.Handshake)
		first := zsp.handshake_start(s.handshake, h.secret, d.key, d.space.node.space) or_return
		s.space = d.space
		s.phase = .Noise
		stream_put(s, .Binary, first[:])
		return true
	}
	path := pipe.http_path(head) or_return
	if query := strings.index_byte(path, '?'); query >= 0 {
		path = path[:query] // whatever a proxy on the way wanted
	}
	if head.key == "" {
		return false
	}
	if len(path) == 65 {
		id: zsp.Key32
		bytes := hex.decode(transmute([]byte)path[1:], context.temp_allocator) or_return
		copy(id[:], bytes)
		for x in h.spaces {
			if x.node.space == id {
				s.space = x
			}
		}
		if s.space == nil && h.relay {
			s.space = space_open(h, id)
		}
		s.phase = .Noise
	} else {
		// A local client. Browsers announce where a page came from; no page has business here unless
		// the authenticator says so, and it is told nothing it could be fooled by.
		if head.origin != "" || len(h.spaces) == 0 || h.relay {
			return false
		}
		s.space = h.spaces[0]
		s.role = .Open
		s.phase = .Open
	}
	if s.space == nil {
		return false
	}
	stream_raw(s, transmute([]byte)pipe.ws_response(head.key))
	if s.role == .Open {
		stream_session(s, false)
	}
	return true
}

@(private)
stream_session :: proc(s: ^Stream, initiator: bool) {
	credential := transmute([]byte)s.host.credential if initiator else nil
	s.session = zsp.session_open(&s.space.node, s.role, initiator, s.channel.peer, credential)
	s.phase = .Open
}

@(private)
stream_message :: proc(s: ^Stream, payload: []byte) -> bool {
	switch s.phase {
	case .Request:
		return false
	case .Noise:
		if s.handshake != nil {
			s.channel = zsp.handshake_finish(s.handshake, payload, s.dialer.key) or_return
			free(s.handshake)
			s.handshake = nil
			stream_session(s, true)
			return true
		}
		second: [zsp.HANDSHAKE_2]byte
		second, s.channel = zsp.handshake_answer(s.host.secret, s.space.node.space, payload) or_return
		stream_put(s, .Binary, second[:])
		stream_session(s, false)
		return true
	case .Open:
		if s.role == .Open {
			return zsp.session_input(s.session, payload)
		}
		plain := zsp.channel_open(&s.channel, payload) or_return
		return zsp.session_input(s.session, plain)
	}
	return false
}

// Queues bytes for the wire, through TLS when there is TLS.
@(private)
stream_raw :: proc(s: ^Stream, bytes: []byte) {
	if s.tls != nil {
		pipe.tls_write(s.tls, bytes, &s.out)
	} else {
		append(&s.out, ..bytes)
	}
}

@(private)
stream_put :: proc(s: ^Stream, op: pipe.Opcode, payload: []byte) {
	if s.tls == nil {
		pipe.ws_put(&s.out, op, payload, s.dialer != nil)
		return
	}
	w := make([dynamic]byte, 0, len(payload) + 14, context.temp_allocator)
	pipe.ws_put(&w, op, payload, s.dialer != nil)
	pipe.tls_write(s.tls, w[:], &s.out)
}

// Draws what the session has to say into the socket, for as long as the socket takes it.
@(private)
stream_flush :: proc(s: ^Stream) {
	for s.send_op == nil && !s.closing {
		if s.session != nil {
			for len(s.out) - s.sent < OUT_HIGH {
				out := zsp.session_output(s.session)
				if len(out) == 0 {
					break
				}
				n := min(len(out), MAX_PLAIN)
				if s.role == .Open {
					stream_put(s, .Binary, out[:n])
				} else if s.tls == nil {
					client := s.dialer != nil
					at := pipe.ws_begin(&s.out, .Binary, n + zsp.TAG, client)
					zsp.channel_seal(&s.channel, &s.out, out[:n])
					pipe.ws_end(&s.out, at, client)
				} else {
					sealed := make([dynamic]byte, 0, n + zsp.TAG, context.temp_allocator)
					zsp.channel_seal(&s.channel, &sealed, out[:n])
					stream_put(s, .Binary, sealed[:])
				}
				zsp.session_sent(s.session, n)
			}
			if s.session.closing {
				s.closing = true
			}
		}
		if len(s.out) == s.sent {
			break
		}
		if !stream_flush_bytes(s) {
			stream_close(s)
			return
		}
	}
	if s.closing && s.send_op == nil {
		stream_close(s)
	}
}

@(private)
stream_flush_bytes :: proc(s: ^Stream) -> bool {
	for s.sent < len(s.out) {
		n, err := net.send_tcp(s.socket, s.out[s.sent:])
		s.sent += n
		if err == .Would_Block {
			if s.send_op == nil {
				s.send_op = nbio.poll_poly(s.socket, .Send, s, proc(op: ^nbio.Operation, s: ^Stream) {
					s.send_op = nil
				})
			}
			return true
		}
		if err != nil {
			return false
		}
	}
	s.sent = 0
	clear(&s.out)
	if cap(s.out) > 4096 {
		shrink(&s.out)
	}
	return true
}

// ---------------------------------------------------------------- dialling relays

Dialer :: struct {
	host:     ^Host,
	space:    ^Space,
	key:      zsp.Key32,
	source:   string, // owned
	url:      pipe.Url,
	stream:   ^Stream,
	failures: int,
	due:      time.Tick, // when to try again
	state:    enum {
		Waiting,
		Resolving,
		Dialling,
		Up,
	},
	pinned:   bool, // named by the embedder rather than the roster
	dropped:  bool, // no longer in the roster

	// Names are resolved on a thread of their own, for no system resolves them without blocking.
	thread:   ^thread.Thread,
	endpoint: net.Endpoint,
	found:    bool,
	answered: bool, // atomic
	loop:     ^nbio.Event_Loop,
}

// Brings the dialers level with what the rosters name.
@(private)
dialers_refresh :: proc(h: ^Host) {
	if h.relay {
		return
	}
	for s in h.spaces {
		for r in s.node.roster.relays {
			dial(h, s, r.key, r.url, false)
		}
	}
	for d in h.dialers {
		d.dropped = !d.pinned
		for r in d.space.node.roster.relays {
			if d.key == r.key && d.source == r.url {
				d.dropped = false
			}
		}
	}
}

// Keeps a session with a relay, whether or not the roster names it: how a new device reaches the
// first one it was told of.
dial :: proc(h: ^Host, s: ^Space, key: zsp.Key32, url: string, pinned := true) {
	for d in h.dialers {
		if d.space == s && d.key == key && d.source == url {
			d.pinned ||= pinned
			return
		}
	}
	source := strings.clone(url)
	parsed, ok := pipe.url_parse(source)
	if !ok {
		report(.Warning, "a relay's address makes no sense")
		delete(source)
		return
	}
	d := new(Dialer)
	d.host, d.space, d.key, d.source, d.url, d.pinned = h, s, key, source, parsed, pinned
	d.due = time.tick_now()
	append(&h.dialers, d)
}

@(private)
dialer_free :: proc(d: ^Dialer) {
	if d.thread != nil {
		thread.join(d.thread)
		thread.destroy(d.thread)
	}
	delete(d.source)
	free(d)
}

@(private)
dialer_deadline :: proc(d: ^Dialer) -> (t: time.Tick, ok: bool) {
	switch d.state {
	case .Waiting:
		return d.due, !d.dropped
	case .Up:
		wait := PONG_WAIT if d.stream.pinged else PING_IDLE
		return time.tick_add(d.stream.quiet_at, wait), true
	case .Resolving, .Dialling:
	}
	return
}

@(private)
dialers_run :: proc(h: ^Host, now: time.Tick) {
	for d in h.dialers {
		switch d.state {
		case .Waiting:
			if !d.dropped && time.tick_diff(d.due, now) >= 0 {
				dialer_resolve(d)
			}
		case .Resolving:
			if sync.atomic_load(&d.answered) {
				thread.join(d.thread)
				thread.destroy(d.thread)
				d.thread = nil
				dialer_resolved(d)
			}
		case .Up:
			if d.stream.session != nil && d.stream.session.ready {
				d.failures = 0 // admitted, not merely answered
			}
			if d.dropped {
				d.stream.closing = true
				continue
			}
			quiet := time.tick_diff(d.stream.quiet_at, now)
			if d.stream.pinged && quiet >= PONG_WAIT {
				d.stream.closing = true
			} else if !d.stream.pinged && quiet >= PING_IDLE {
				d.stream.pinged = true
				d.stream.quiet_at = now
				stream_put(d.stream, .Ping, nil)
			}
		case .Dialling:
		}
	}
}

@(private)
dialer_resolve :: proc(d: ^Dialer) {
	if a := net.parse_address(d.url.name); a != nil {
		d.endpoint, d.found = {a, d.url.port}, true
		dialer_resolved(d)
		return
	}
	d.state = .Resolving
	d.answered = false
	d.loop = nbio.current_thread_event_loop()
	d.thread = thread.create_and_start_with_poly_data(d, proc(d: ^Dialer) {
		ep, err := net.resolve_ip4(d.url.name)
		if err != nil {
			ep, err = net.resolve_ip6(d.url.name)
		}
		d.endpoint = {ep.address, d.url.port}
		d.found = err == nil
		// Said before waking the loop: a thread is not done until after its last word, and a loop that
		// looked too soon would sleep on it for ever.
		sync.atomic_store(&d.answered, true)
		nbio.wake_up(d.loop)
	})
}

@(private)
dialer_resolved :: proc(d: ^Dialer) {
	if !d.found {
		dialer_failed(d)
		return
	}
	d.state = .Dialling
	nbio.dial_poly(d.endpoint, d, proc(op: ^nbio.Operation, d: ^Dialer) {
		if op.dial.err != nil {
			dialer_failed(d)
			return
		}
		s := stream_new(d.host, op.dial.socket)
		s.dialer = d
		d.stream = s
		d.state = .Up
		if d.url.secure {
			s.tls = new(pipe.Tls)
			pipe.tls_start(s.tls, d.url.name, &s.out)
		} else {
			stream_request(s)
		}
	}, timeout = 15 * time.Second)
}

// Tries again, soon at first and then ever less often.
@(private)
dialer_failed :: proc(d: ^Dialer) {
	wait := 200 * time.Millisecond << uint(min(d.failures, 8))
	d.failures += 1
	d.state = .Waiting
	d.due = time.tick_add(time.tick_now(), wait + wait * time.Duration(time.tick_now()._nsec % 64) / 128)
}

@(private)
dialer_lost :: proc(d: ^Dialer) {
	d.stream = nil
	dialer_failed(d)
}
