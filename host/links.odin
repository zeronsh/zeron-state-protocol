package host

import "core:encoding/endian"
import "core:nbio"
import "core:net"
import "core:time"
import "../pipe"
import "../zsp"

// Direct links between devices. Those who share a relay swap addresses through it, sealed to each
// other, and then knock on each other's doors at the same moment; those who share a network hear each
// other's beacon and need no relay at all. Links that cross a NAT are let go before the NAT forgets
// them, and knocked for again when there is something to say, so a quiet link costs nothing.

KNOCK_EVERY :: 200 * time.Millisecond
KNOCKS :: 25
RETRY_AFTER :: 15 * time.Second
NAT_IDLE :: 25 * time.Second
STUN_WAIT :: 400 * time.Millisecond
BEACON_PORT :: 9083
MAX_CANDIDATES :: 16

@(private)
Udp :: struct {
	open:     bool,
	socket:   net.UDP_Socket, // IPv4
	socket6:  net.UDP_Socket,
	have6:    bool,
	beacon:   net.UDP_Socket,
	have_beacon: bool,
	port:     int,
	links:    [dynamic]^Peer,
	ask:      [pipe.STUN_REQUEST]byte,
	asked:    time.Tick,
	asking:   bool,
	outside:  Maybe(pipe.Address),
	stun:     net.Endpoint,
	have_stun: bool,
}

// What this host knows of reaching one device. Survives the link itself.
@(private)
Peer :: struct {
	space:      ^Space,
	device:     zsp.Key32,
	candidates: [dynamic]pipe.Address,
	link:       ^pipe.Link, // open, or being dialled
	answer:     ^pipe.Link, // answered, not yet confirmed
	session:    ^zsp.Session,
	answered:   time.Tick, // when `answer` was made
	address:    pipe.Address, // where it was last heard from
	far:        bool, // beyond a NAT
	used:       time.Tick,
	knocks:     int, // left
	next_knock: time.Tick,
	tried:      time.Tick, // when candidates were last sent
	ever_tried: bool,
	heard:      time.Tick, // a beacon, and knocked for it
	owed:       bool, // candidates are to be sent once the outside address is known
}

@(private)
udp_open :: proc(h: ^Host, port: int) -> bool {
	u := &h.udp
	err: net.Create_Socket_Error
	u.socket, err = nbio.create_udp_socket(.IP4)
	if err != nil {
		return false
	}
	if berr := net.bind(u.socket, {net.IP4_Any, port}); berr != nil {
		report(.Error, "could not bind a UDP port")
		return false
	}
	net.set_blocking(u.socket, false)
	net.set_option(u.socket, .Broadcast, true)
	net.set_option(u.socket, .Receive_Buffer_Size, i32(1 << 20))
	if at, e := net.bound_endpoint(u.socket); e == nil {
		u.port = at.port
	}
	udp_listen(h, u.socket)
	if u.socket6, err = nbio.create_udp_socket(.IP6); err == nil {
		// Where one socket covers both families this bind fails, harmlessly.
		if net.bind(u.socket6, {net.IP6_Any, u.port}) == nil {
			net.set_blocking(u.socket6, false)
			u.have6 = true
			udp_listen(h, u.socket6)
		} else {
			net.close(u.socket6)
		}
	}
	if !h.relay {
		if u.beacon, err = nbio.create_udp_socket(.IP4); err == nil {
			net.set_option(u.beacon, .Reuse_Address, true)
			when ODIN_OS != .Windows {
				net.set_option(u.beacon, .Reuse_Port, true)
			}
			if net.bind(u.beacon, {net.IP4_Any, BEACON_PORT}) == nil {
				net.set_blocking(u.beacon, false)
				u.have_beacon = true
				udp_listen(h, u.beacon)
			} else {
				net.close(u.beacon)
			}
		}
	}
	u.open = true
	if h.stun != "" {
		// Resolved once, up front; a host without a name server still has its local addresses.
		if ep4, _, rerr := net.resolve(h.stun); rerr == nil {
			u.stun, u.have_stun = ep4, ep4.address != nil
		}
	}
	return true
}

@(private)
udp_close :: proc(h: ^Host) {
	u := &h.udp
	if !u.open {
		return
	}
	for len(u.links) > 0 {
		p := pop(&u.links)
		peer_drop(p)
		delete(p.candidates)
		free(p)
	}
	delete(u.links)
	net.close(u.socket)
	if u.have6 {
		net.close(u.socket6)
	}
	if u.have_beacon {
		net.close(u.beacon)
	}
}

@(private)
udp_listen :: proc(h: ^Host, socket: net.UDP_Socket) {
	nbio.poll_poly2(socket, .Receive, h, socket, proc(op: ^nbio.Operation, h: ^Host, socket: net.UDP_Socket) {
		if op.poll.result != .Ready {
			return
		}
		for _ in 0 ..< 256 {
			n, from, err := net.recv_udp(socket, h.shared)
			if err == .Would_Block {
				break
			}
			if err != nil {
				continue // an unreachable peer, reported late; the link will notice
			}
			udp_input(h, h.shared[:n], address_from(from))
		}
		udp_listen(h, socket)
	})
}

@(private)
address_from :: proc(ep: net.Endpoint) -> (a: pipe.Address) {
	a.port = u16(ep.port)
	switch ip in ep.address {
	case net.IP4_Address:
		return pipe.address_v4(ip[0], ip[1], ip[2], ip[3], a.port)
	case net.IP6_Address:
		for part, i in ip {
			endian.unchecked_put_u16be(a.ip[i * 2:], u16(part))
		}
	}
	return
}

@(private)
address_to :: proc(a: pipe.Address) -> net.Endpoint {
	if pipe.address_is_v4(a) {
		return {net.IP4_Address{a.ip[12], a.ip[13], a.ip[14], a.ip[15]}, int(a.port)}
	}
	a := a
	ip: net.IP6_Address
	for &part, i in ip {
		part = u16be(endian.unchecked_get_u16be(a.ip[i * 2:]))
	}
	return {ip, int(a.port)}
}

@(private)
udp_send :: proc(h: ^Host, packet: []byte, to: pipe.Address) {
	u := &h.udp
	if pipe.address_is_v4(to) {
		net.send_udp(u.socket, packet, address_to(to))
	} else if u.have6 {
		net.send_udp(u.socket6, packet, address_to(to))
	}
}

@(private)
udp_input :: proc(h: ^Host, packet: []byte, from: pipe.Address) {
	u := &h.udp
	if len(packet) == 0 {
		return
	}
	if pipe.is_stun(packet) {
		reply: [pipe.STUN_REPLY]byte
		if out := pipe.stun_answer(packet, from, reply[:]); out != nil {
			udp_send(h, out, from)
		} else if a, ok := pipe.stun_address(u.ask[:], packet); ok {
			u.outside = a
			u.asking = false
		}
		return
	}
	if id, ok := pipe.packet_receiver(packet); ok {
		for p in u.links {
			for l in ([]^pipe.Link{p.link, p.answer}) {
				if l == nil || l.local != id {
					continue
				}
				if pipe.link_input(l, packet, now_us()) {
					peer_heard(p, l, from)
				}
				return
			}
		}
		return
	}
	#partial switch pipe.Type(packet[0]) {
	case .First:
		peer_answer(h, packet, from)
	case BEACON:
		beacon_heard(h, packet, from)
	}
}

@(private)
peer_for :: proc(s: ^Space, device: zsp.Key32) -> ^Peer {
	u := &s.host.udp
	for p in u.links {
		if p.space == s && p.device == device {
			return p
		}
	}
	if m := zsp.roster_member(&s.node.roster, device); m == nil || !zsp.member_active(m) || device == s.host.device {
		return nil
	}
	p := new(Peer)
	p.space, p.device = s, device
	append(&u.links, p)
	return p
}

// Of two devices, the one with the lesser key dials.
@(private)
peer_dials :: proc(p: ^Peer) -> bool {
	mine, theirs := p.space.host.device, p.device
	return string(mine[:]) < string(theirs[:])
}

@(private)
peer_answer :: proc(h: ^Host, packet: []byte, from: pipe.Address) {
	for p in h.udp.links {
		// The same knock, by another door.
		if p.answer != nil && pipe.link_answers(p.answer, packet) {
			buf: [pipe.PACKET]byte
			udp_send(h, pipe.link_hello(p.answer, buf[:]), from)
			return
		}
	}
	for s in h.spaces {
		l: pipe.Link
		if !pipe.link_answer(&l, h.secret, s.node.space, packet) {
			continue
		}
		p := peer_for(s, l.channel.peer)
		// A stranger; or someone's old knock, over and over. A live link is not disturbed by either: it
		// gives way only when the new one proves itself.
		if p == nil || (p.answer != nil && time.tick_since(p.answered) < time.Second) {
			pipe.link_destroy(&l)
			return
		}
		p.answered = time.tick_now()
		if p.answer == nil {
			p.answer = new(pipe.Link)
		} else {
			pipe.link_destroy(p.answer)
		}
		p.answer^ = l
		peer_wire(p, p.answer)
		buf: [pipe.PACKET]byte
		udp_send(h, pipe.link_hello(p.answer, buf[:]), from)
		return
	}
}

@(private)
peer_heard :: proc(p: ^Peer, l: ^pipe.Link, from: pipe.Address) {
	p.address = from
	p.far = !address_near(p.space.host, from)
	p.used = time.tick_now()
	if l.state == .Closed {
		return // links_run lets it go
	}
	peer_opened(p, l)
}

// The link is proven: make it the peer's, and begin a session on it. One that was there before gives way,
// for a device answers only the knock of one that has no link, or thinks so; and only a proven one.
@(private)
peer_opened :: proc(p: ^Peer, l: ^pipe.Link) {
	if l.state != .Open || (p.session != nil && l != p.answer) {
		return
	}
	if l == p.answer {
		if p.session != nil {
			session := p.session
			p.session = nil
			zsp.session_close(session)
		}
		if p.link != nil {
			pipe.link_destroy(p.link)
			free(p.link)
		}
		p.link, p.answer = p.answer, nil
	}
	p.knocks = 0
	p.session = zsp.session_open(&p.space.node, .Peer, peer_dials(p), p.device)
	p.session.datagram_data = p
	p.session.datagram = proc(data: rawptr, frame: []byte) -> bool {
		return pipe.link_datagram((^Peer)(data).link, frame)
	}
	report(.Debug, "linked directly ", net.endpoint_to_string(address_to(p.address), context.temp_allocator))
}

@(private)
peer_wire :: proc(p: ^Peer, l: ^pipe.Link) {
	l.data = p
	// The packet that proves a link may already carry its first bytes.
	l.on_stream = proc(l: ^pipe.Link, bytes: []byte) {
		p := (^Peer)(l.data)
		peer_opened(p, l)
		if l == p.link && p.session != nil && !zsp.session_input(p.session, bytes) {
			pipe.link_close(l)
		}
	}
	l.on_datagram = proc(l: ^pipe.Link, bytes: []byte) {
		p := (^Peer)(l.data)
		if l == p.link && p.session != nil {
			zsp.session_datagram(p.session, bytes)
		}
	}
}

@(private)
peer_drop :: proc(p: ^Peer) {
	if p.session != nil {
		session := p.session
		p.session = nil
		zsp.session_close(session)
	}
	for l in ([]^pipe.Link{p.link, p.answer}) {
		if l != nil {
			pipe.link_destroy(l)
			free(l)
		}
	}
	p.link, p.answer = nil, nil
}

// On this machine or this network, where nothing in between keeps state that could lapse.
@(private)
address_near :: proc(h: ^Host, a: pipe.Address) -> bool {
	if !pipe.address_is_v4(a) {
		return a.ip[0] == 0xfe || (a.ip[0] & 0xfe) == 0xfc || a.ip == {15 = 1}
	}
	b := [4]byte{a.ip[12], a.ip[13], a.ip[14], a.ip[15]}
	return b[0] == 10 || b[0] == 127 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
}

// ---------------------------------------------------------------- finding each other

// Others have come online at a relay.
@(private)
links_greet :: proc(s: ^Space, online: []zsp.Key32) {
	if !s.host.udp.open {
		return
	}
	for device in online {
		if p := peer_for(s, device); p != nil && p.session == nil {
			peer_offer(p)
		}
	}
}

// Sends our addresses, once the outside one is known or clearly not coming.
@(private)
peer_offer :: proc(p: ^Peer) {
	h := p.space.host
	u := &h.udp
	if p.ever_tried && time.tick_since(p.tried) < RETRY_AFTER {
		return
	}
	p.ever_tried = true
	p.tried = time.tick_now()
	p.owed = true
	if u.have_stun && !u.asking {
		// Asked afresh each time: it also opens the NAT's mapping, from the very socket links use.
		u.ask = pipe.stun_request()
		u.asking = true
		u.asked = p.tried
		net.send_udp(u.socket, u.ask[:], u.stun)
	}
}

@(private)
peer_send_candidates :: proc(p: ^Peer) {
	h := p.space.host
	u := &h.udp
	p.owed = false
	w := make([dynamic]byte, context.temp_allocator)
	put :: proc(w: ^[dynamic]byte, a: pipe.Address) {
		a := a
		if len(w) >= MAX_CANDIDATES * 18 {
			return
		}
		append(w, ..a.ip[:])
		append(w, byte(a.port >> 8), byte(a.port))
	}
	if a, ok := u.outside.?; ok {
		put(&w, a)
	}
	for i in interfaces() {
		a := address_from({i.address, u.port})
		v4 := pipe.address_is_v4(a)
		loopback := (v4 && a.ip[12] == 127) || a.ip == {15 = 1}
		link_local := !v4 && a.ip[0] == 0xfe
		if !loopback && !link_local && (v4 || u.have6) {
			put(&w, a)
		}
	}
	zsp.node_signal(&p.space.node, p.device, w[:])
}

// The other side's addresses have come: knock on all of them, and answer in kind.
@(private)
links_signalled :: proc(data: rawptr, from: zsp.Key32, blob: []byte) {
	s := (^Space)(data)
	if !s.host.udp.open {
		return
	}
	p := peer_for(s, from)
	if p == nil || p.session != nil {
		return
	}
	clear(&p.candidates)
	for at := 0; at + 18 <= len(blob) && len(p.candidates) < MAX_CANDIDATES; at += 18 {
		a: pipe.Address
		copy(a.ip[:], blob[at:])
		a.port = u16(blob[at + 16]) << 8 | u16(blob[at + 17])
		append(&p.candidates, a)
	}
	peer_offer(p)
	peer_knock(p)
}

@(private)
peer_knock :: proc(p: ^Peer) {
	if peer_dials(p) && p.link == nil {
		p.link = new(pipe.Link)
		if !pipe.link_dial(p.link, p.space.host.secret, p.device, p.space.node.space) {
			free(p.link)
			p.link = nil
			return
		}
		peer_wire(p, p.link)
	}
	p.knocks = KNOCKS
	p.next_knock = time.tick_now()
}

BEACON :: pipe.Type(0x44)
BEACON_SIZE :: 1 + 8 + 32 + 2 + 16

// A beacon tells members nearby where this device is, and others nothing.
@(private)
beacon_send :: proc(s: ^Space, to: Maybe(pipe.Address) = nil) {
	u := &s.host.udp
	packet := zsp.beacon_seal(&s.node, u.port)
	if len(packet) == 0 {
		return
	}
	if a, ok := to.?; ok {
		udp_send(s.host, packet, a)
		return
	}
	net.send_udp(u.socket, packet, {net.IP4_Address{255, 255, 255, 255}, BEACON_PORT})
	// And on interfaces that are not the default one.
	for i in interfaces() {
		if all, ok := i.broadcast.?; ok {
			net.send_udp(u.socket, packet, {all, BEACON_PORT})
		}
	}
}

@(private)
beacon_heard :: proc(h: ^Host, packet: []byte, from: pipe.Address) {
	for s in h.spaces {
		device, port, ok := zsp.beacon_open(&s.node, packet)
		if !ok || device == h.device {
			continue
		}
		p := peer_for(s, device)
		if p == nil || p.session != nil || p.knocks > 0 || (p.heard != {} && time.tick_since(p.heard) < RETRY_AFTER) {
			return
		}
		p.heard = time.tick_now()
		at := from
		at.port = u16(port)
		clear(&p.candidates)
		append(&p.candidates, at)
		if !peer_dials(p) {
			beacon_send(s, from) // so that it knows to; its own socket, for others may share the port
		}
		peer_knock(p)
		return
	}
}

// Announces this device to the local network. Call at start, and when the network changes.
links_announce :: proc(h: ^Host) {
	if h.udp.open && !h.relay {
		for s in h.spaces {
			beacon_send(s)
		}
	}
}

// ---------------------------------------------------------------- running

@(private)
links_run :: proc(h: ^Host) {
	u := &h.udp
	if !u.open {
		return
	}
	now := time.tick_now()
	if u.asking && time.tick_diff(u.asked, now) > STUN_WAIT {
		u.asking = false
	}
	for s in h.spaces {
		// Something was written here: worth trying for a direct path to whoever is listening.
		if s.node.events.next != s.seen {
			s.seen = s.node.events.next
			for session in s.node.sessions {
				if session.ready && session.peer_relay {
					links_greet(s, session.online[:])
				}
			}
		}
	}
	for p in u.links {
		if p.owed && !u.asking {
			peer_send_candidates(p)
		}
		if p.link != nil && p.link.state == .Closed {
			peer_drop(p)
		}
		if p.session != nil {
			if p.session.closing {
				pipe.link_close(p.link)
			}
			if p.far && time.tick_diff(p.used, now) > NAT_IDLE {
				pipe.link_close(p.link)
			}
		} else if p.knocks > 0 && time.tick_diff(p.next_knock, now) >= 0 {
			p.knocks -= 1
			p.next_knock = time.tick_add(now, KNOCK_EVERY)
			buf: [pipe.PACKET]byte
			packet := []byte{byte(pipe.Type.Punch)}
			if p.link != nil {
				packet = pipe.link_hello(p.link, buf[:])
			}
			for a in p.candidates {
				udp_send(h, packet, a)
			}
			if p.knocks == 0 {
				peer_drop(p)
			}
		}
	}
}

@(private)
links_flush :: proc(h: ^Host) {
	u := &h.udp
	if !u.open {
		return
	}
	now := now_us()
	buf: [pipe.PACKET_MAX]byte
	for p in u.links {
		if p.session == nil || p.link == nil {
			continue
		}
		for {
			room := pipe.link_room(p.link)
			if room > 0 {
				out := zsp.session_output(p.session)
				n := min(len(out), room)
				if n > 0 {
					pipe.link_write(p.link, out[:n])
					zsp.session_sent(p.session, n)
				}
			}
			packet := pipe.link_output(p.link, buf[:], now)
			if packet == nil {
				break
			}
			udp_send(h, packet, p.address)
			p.used = time.tick_now()
		}
	}
}

// In microseconds; zero for never.
@(private)
links_deadline :: proc(h: ^Host) -> (due: pipe.Time) {
	u := &h.udp
	if !u.open {
		return
	}
	nearer :: proc(due: ^pipe.Time, t: pipe.Time) {
		if t != 0 && (due^ == 0 || t < due^) {
			due^ = t
		}
	}
	at :: proc(t: time.Tick, d: time.Duration) -> pipe.Time {
		return pipe.Time(time.tick_add(t, d)._nsec / 1000)
	}
	if u.asking {
		nearer(&due, at(u.asked, STUN_WAIT + time.Millisecond))
	}
	for p in u.links {
		if p.session != nil {
			nearer(&due, pipe.link_deadline(p.link))
			if p.far {
				nearer(&due, at(p.used, NAT_IDLE + time.Millisecond))
			}
		} else if p.knocks > 0 {
			nearer(&due, at(p.next_knock, 0))
		}
	}
	return
}
