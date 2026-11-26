package host

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:strings"
import "../pipe"
import "../zsp"

// For applications that can be told to use a proxy, and where addresses cannot be had (macOS without zspd setup):
// SOCKS 5 and HTTP, at one address of this machine, to this space's devices and nowhere else. Who may use it, and what
// it reaches, is as for the devices' own addresses.

PROXY_GREETING_MAX :: 64 // clients yet to say where to, at once: the longest waiting makes way
PROXY_HEAD_MAX :: 16 << 10

@(private)
Proxy :: struct {
	socket:    net.TCP_Socket,
	open:      bool,
	accepting: ^nbio.Operation,
	waiting:   [dynamic]^Proxy_Client,
}

@(private)
Proxy_Client :: struct {
	host:    ^Host,
	socket:  net.TCP_Socket,
	buf:     [dynamic]byte,
	greeted: bool, // SOCKS: the greeting has been answered
	polling: ^nbio.Operation,
	request: pipe.Proxy_Request,
}

@(private)
proxy_open :: proc(h: ^Host, at: net.Endpoint) {
	p := &h.proxy_server
	socket, err := listen_on(at)
	if err != nil {
		report(.Warning, "cannot be a proxy at ", net.endpoint_to_string(at, context.temp_allocator), ": ", fmt.tprint(err))
		return
	}
	p.socket, p.open = socket, true
	p.accepting = nbio.accept_poly(socket, h, proxy_accepted)
}

@(private)
proxy_close :: proc(h: ^Host) {
	p := &h.proxy_server
	for len(p.waiting) > 0 {
		proxy_client_close(p.waiting[0], reset = true)
	}
	delete(p.waiting)
	if p.accepting != nil {
		nbio.remove(p.accepting)
	}
	if p.open {
		net.close(p.socket)
	}
	p^ = {}
}

@(private)
proxy_accepted :: proc(op: ^nbio.Operation, h: ^Host) {
	p := &h.proxy_server
	p.accepting = nbio.accept_poly(p.socket, h, proxy_accepted)
	if op.accept.err != nil {
		return
	}
	socket := op.accept.client
	local, err := net.bound_endpoint(socket)
	if err != nil || (!h.trust_local_users && !tcp_peer_is_mine(address_from(local), address_from(op.accept.client_endpoint))) {
		socket_abort(socket)
		return
	}
	if len(p.waiting) >= PROXY_GREETING_MAX {
		proxy_client_close(p.waiting[0], reset = true)
	}
	c := new(Proxy_Client)
	c.host, c.socket = h, socket
	net.set_blocking(socket, false)
	append(&p.waiting, c)
	proxy_client_wait(c)
}

@(private)
proxy_client_wait :: proc(c: ^Proxy_Client) {
	c.polling = nbio.poll_poly(c.socket, .Receive, c, proc(op: ^nbio.Operation, c: ^Proxy_Client) {
		c.polling = nil
		if op.poll.result != .Ready {
			proxy_client_close(c, reset = true)
			return
		}
		proxy_client_read(c)
	})
}

@(private)
proxy_client_close :: proc(c: ^Proxy_Client, reset: bool) {
	p := &c.host.proxy_server
	for x, i in p.waiting {
		if x == c {
			ordered_remove(&p.waiting, i)
			break
		}
	}
	if c.polling != nil {
		nbio.remove(c.polling)
	}
	if reset {
		socket_abort(c.socket)
	}
	delete(c.buf)
	free(c)
}

@(private)
proxy_client_read :: proc(c: ^Proxy_Client) {
	h := c.host
	for {
		n, err := net.recv_tcp(c.socket, h.shared[:min(len(h.shared), PROXY_HEAD_MAX + 1 - len(c.buf))])
		if err == .Would_Block {
			break
		}
		if err != nil || n == 0 || len(c.buf) + n > PROXY_HEAD_MAX {
			proxy_client_close(c, reset = true)
			return
		}
		append(&c.buf, ..h.shared[:n])
	}
	if len(c.buf) == 0 {
		proxy_client_wait(c)
		return
	}
	result: pipe.Proxy_Result
	if c.buf[0] == 5 {
		if !c.greeted {
			used: int
			used, result = pipe.socks_greeting(c.buf[:])
			if result == .Done {
				greeted := pipe.SOCKS_GREETED
				net.send_tcp(c.socket, greeted[:])
				remove_range(&c.buf, 0, used)
				c.greeted = true
				result = .More
				if len(c.buf) > 0 {
					c.request, result = pipe.socks_request(c.buf[:])
				}
			}
		} else {
			c.request, result = pipe.socks_request(c.buf[:])
		}
	} else {
		c.request, result = pipe.http_proxy_request(c.buf[:])
	}
	switch result {
	case .More:
		proxy_client_wait(c)
	case .Broken:
		if c.greeted {
			no := pipe.socks_reply(7)
			net.send_tcp(c.socket, no[:])
		}
		proxy_client_close(c, reset = true)
	case .Done:
		proxy_client_go(c)
	}
}

// It has said where to: if that is a device of this space, forward to it.
@(private)
proxy_client_go :: proc(c: ^Proxy_Client) {
	h := c.host
	r := c.request
	sp: ^Space
	m: ^zsp.Member
	name := strings.to_lower(strings.trim_suffix(r.host, "."), context.temp_allocator)
	for s in h.spaces {
		if s.naming.suffix == "" || s.ports == nil {
			continue
		}
		if rest, under := cut_suffix(name, strings.concatenate({".", s.naming.suffix}, context.temp_allocator)); under {
			m = name_member(s, rest)
		} else if a, ok := net.parse_address(name).(net.IP4_Address); ok {
			m = address_member(s, {a[0], a[1], a[2], a[3]})
		}
		if m != nil {
			sp = s
			break
		}
	}
	if m == nil || m.device == h.device {
		switch r.reply {
		case .Socks:
			no := pipe.socks_reply(2)
			net.send_tcp(c.socket, no[:])
		case .Connect, .Absolute:
			net.send_tcp(c.socket, transmute([]byte)string("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
		}
		socket := c.socket // closed here, plainly: proxy_client_close frees c
		proxy_client_close(c, reset = false)
		net.close(socket)
		return
	}
	// What came after the request, and for an absolute request the request itself, goes first.
	early := make([dynamic]byte, context.temp_allocator)
	append(&early, ..r.head)
	append(&early, ..c.buf[r.used:])
	device := m.device
	rem := remote_for(sp.ports, device, make = true)
	if rem == nil {
		proxy_refuse(c)
		return
	}
	entry := Port_Entry{r.port, remote_scope(rem), "", ""}
	for e in rem.entries {
		if e.port == r.port {
			entry = e
		}
	}
	// A web request made through the proxy is held to what one made to the device's address is (http_verdict):
	// what came with the request is judged here, being sent before anything could judge it there; what comes after
	// it, by the forward's inspector. Until what came is enough to judge, more is waited for.
	inspect: proc(data: rawptr, first: []byte) -> Inspection = proxied_guard
	if len(early) > 0 {
		// Not as what came first: it came with the request, written at once with it, however short.
		verdict, reason := http_verdict(sp, device, early[:])
		switch verdict {
		case .Reject:
			proxy_say_no(c, reason)
			return
		case .More:
			if len(c.buf) >= PROXY_HEAD_MAX {
				proxy_say_no(c, "too long a request")
				return
			}
			proxy_client_wait(c) // read again from the start, with more
			return
		case .Pass:
			inspect = nil
		}
	}
	ports_wanted(sp, device)
	pc := new(Proxied)
	pc^ = {sp, device, rem, r.reply, c.socket, nil, len(early) > 0}
	// The forward has the socket now.
	p := &h.proxy_server
	for x, i in p.waiting {
		if x == c {
			ordered_remove(&p.waiting, i)
			break
		}
	}
	socket := c.socket
	delete(c.buf)
	free(c)
	rem.forwards += 1
	// Told how it went, maybe before forward returns, and then pc is gone: so it is kept only if it is a forward.
	if f := forward(sp, device, entry.scope, entry.port, entry.host, socket, proxied_done, pc, inspect, early[:]); f != nil {
		pc.forward = f
	}
}

// A web request that may not pass: refused as the proxy refuses anything, and closed.
@(private)
proxy_say_no :: proc(c: ^Proxy_Client, reason: string) {
	switch c.request.reply {
	case .Socks:
		no := pipe.socks_reply(2) // not allowed
		net.send_tcp(c.socket, no[:])
	case .Connect, .Absolute:
		net.send_tcp(c.socket, http_forbidden(reason))
	}
	socket := c.socket
	proxy_client_close(c, reset = false)
	net.close(socket)
}

@(private)
proxied_guard :: proc(data: rawptr, first: []byte) -> Inspection {
	pc := (^Proxied)(data)
	verdict, reason := http_verdict(pc.sp, pc.device, first, first_look = !pc.looked)
	pc.looked = true
	if verdict == .Reject {
		forward_reject(pc.forward, http_forbidden(reason))
	}
	return verdict
}

@(private)
proxy_refuse :: proc(c: ^Proxy_Client) {
	if c.request.reply == .Socks {
		no := pipe.socks_reply(4)
		net.send_tcp(c.socket, no[:])
	}
	proxy_client_close(c, reset = true)
}

@(private)
Proxied :: struct {
	sp:     ^Space,
	device: zsp.Key32,
	remote: ^Remote,
	reply:  type_of(pipe.Proxy_Request{}.reply),
	socket: net.TCP_Socket,
	forward: ^Forward,
	looked:  bool, // the guard has seen what came first
}

// The device has connected, or would not: the application is told so, as its proxy would tell it.
@(private)
proxied_done :: proc(data: rawptr, status: Forward_Status) {
	pc := (^Proxied)(data)
	if status == .Connected {
		switch pc.reply {
		case .Socks:
			yes := pipe.socks_reply(0)
			net.send_tcp(pc.socket, yes[:])
		case .Connect:
			net.send_tcp(pc.socket, transmute([]byte)string("HTTP/1.1 200 Connection established\r\n\r\n"))
		case .Absolute:
		}
		return
	}
	if p := pc.sp.ports; p != nil {
		if r := remote_for(p, pc.device, make = false); r != nil && r == pc.remote {
			r.forwards -= 1
		}
	}
	free(pc)
}
