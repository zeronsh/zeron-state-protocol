package host

import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:time"
import "../pipe"
import "../third_party/nbio"
import "../zsp"

// Direct links between devices. Those who share a relay swap addresses through it, sealed to each
// other, and then knock on each other's doors at the same moment; those who share a network hear each
// other's beacon and need no relay at all. Links that cross a NAT are let go before the NAT forgets
// them, and knocked for again when there is something to say, so a quiet link costs nothing.

KNOCK_EVERY :: 200 * time.Millisecond
KNOCKS :: 25
RETRY_AFTER :: 15 * time.Second
NAT_IDLE :: 25 * time.Second
CALL_ALIVE :: #config(ZSP_CALL_ALIVE, 15_000) * time.Millisecond // a call is not left waiting on a link that has been quiet for longer
STUN_WAIT :: 400 * time.Millisecond
BEACON_PORT :: 9083
ANNOUNCES :: 4 // at once, then 0.3, 1.2 and 4.8 seconds apart
ANNOUNCE_AFTER :: 300 * time.Millisecond
// What a link that may be to a process gone is given to answer a poke, before another is sought: long enough for a busy
// machine to say something, short enough that a device that started again is reached again soon.
SUSPECT_WAIT :: 3 * time.Second
MAX_CANDIDATES :: 16

@(private)
Udp :: struct {
	open:     bool,
	socket:   net.UDP_Socket, // IPv4
	socket6:  net.UDP_Socket,
	have6:    bool,
	announces: int, // yet to make
	announce: time.Tick, // when the next is due
	beacon:   net.UDP_Socket,
	have_beacon: bool,
	port:     int,
	links:    [dynamic]^Peer,
	ask:      [pipe.STUN_REQUEST]byte,
	asked:    time.Tick,
	asking:   bool,
	outside:  Maybe(pipe.Address),
	no_gso:   bool, // the kernel cannot cut a buffer into datagrams here
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
	knocked:    u64, // the latest knock heard, by the knocker's clock
	address:    pipe.Address, // where it was last heard from
	far:        bool, // beyond a NAT
	used:       time.Tick, // something was sent or heard, last
	answered:   time.Tick, // something was heard, last
	knocks:     int, // left
	next_knock: time.Tick,
	tried:      time.Tick, // when candidates were last sent
	ever_tried: bool,
	heard:      time.Tick, // a beacon, last answered
	owed:       bool, // candidates are to be sent once the outside address is known
	suspect:    time.Tick, // since when the link may be to a process gone (a beacon came while it has a session), if set
	suspect_at: pipe.Address, // where that beacon said the device is
	reknocks:   int, // left, of knocking anew beside a link that did not answer
	next_reknock: time.Tick,
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
	udp_receive_buffer(u.socket)
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
		// Beacons go out by a socket of their own, the only one that may broadcast: so that nothing sent where a peer
		// says, as to a member's candidates, reaches everyone on a network, as its own broadcast address would (as
		// 192.168.1.255, or 127.255.255.255), which only the system knows to refuse. It hears those nearby, at
		// BEACON_PORT, which others on this machine share; or where it cannot, it has a port of its own, and only says.
		if u.beacon, err = nbio.create_udp_socket(.IP4); err == nil {
			nbio.set_socket_option(u.beacon, .Reuse_Address, true)
			port_share(u.beacon)
			if berr := net.bind(u.beacon, {net.IP4_Any, BEACON_PORT}); berr != nil {
				report(.Debug, "cannot listen for those nearby: ", fmt.tprint(berr))
				net.close(u.beacon)
				if u.beacon, err = nbio.create_udp_socket(.IP4); err == nil && net.bind(u.beacon, {net.IP4_Any, 0}) != nil {
					net.close(u.beacon)
					err = .Insufficient_Resources
				}
			}
			if err == nil {
				net.set_blocking(u.beacon, false)
				nbio.set_socket_option(u.beacon, .Broadcast, true)
				u.have_beacon = true
				udp_listen(h, u.beacon) // and what comes to it is heard as any packet is
			}
		}
	}
	u.open = true
	if h.stun != "" {
		// Resolved once, up front; a host without a name server still has its local addresses.
		if ep4, _, rerr := net.resolve(h.stun); rerr == nil && ep4.address != nil {
			u.stun, u.have_stun = ep4, pipe.address_usable(address_from(ep4))
			if !u.have_stun {
				report(.Warning, "the STUN server's address is no one to ask: ", net.endpoint_to_string(ep4, context.temp_allocator))
			}
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
		udp_receive(h, socket)
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
	if len(packet) == 0 || !pipe.address_usable(from) {
		return // from nowhere a packet could be sent back to, as port 0, or everyone: answered by nothing, nor believed
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
				session := p.session
				if pipe.link_input(l, packet, now_us()) {
					peer_heard(p, l, from)
				}
				if p.session != nil && p.session != session {
					report(.Debug, "linked directly ", net.endpoint_to_string(address_to(from), context.temp_allocator))
				}
				return
			}
		}
		return
	}
	if h.relay {
		return // it says where others are, and links to nobody: its spaces come and go
	}
	#partial switch pipe.Type(packet[0]) {
	case .First:
		peer_answer(h, packet, from)
	case BEACON:
		beacon_heard(h, packet, from)
	}
}

// What is known of reaching a device the roster admits; nil for any other, however well it was known before.
@(private)
peer_for :: proc(s: ^Space, device: zsp.Key32) -> ^Peer {
	if !admitted(s, device) {
		return nil
	}
	u := &s.host.udp
	for p in u.links {
		if p.space == s && p.device == device {
			return p
		}
	}
	p := new(Peer)
	p.space, p.device = s, device
	append(&u.links, p)
	return p
}

@(private)
admitted :: proc(s: ^Space, device: zsp.Key32) -> bool {
	m := zsp.roster_member(&s.node.roster, device)
	return m != nil && zsp.member_active(m) && device != s.host.device
}

// The roster has changed: a device it no longer admits is let go of, with all that was on its way to it, but a session,
// which its node ends itself, saying why, and which goes with its link.
@(private)
peers_admitted :: proc(s: ^Space) {
	u := &s.host.udp
	#reverse for p, i in u.links {
		if p.space != s || admitted(s, p.device) || p.session != nil {
			continue
		}
		peer_drop(p)
		delete(p.candidates)
		free(p)
		ordered_remove(&u.links, i)
	}
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
		// A stranger; or a knock heard before, which anyone may have kept. And a live link is not disturbed
		// even by a new one until that proves itself.
		if p == nil || l.channel.began <= p.knocked {
			pipe.link_destroy(&l)
			return
		}
		p.knocked = l.channel.began
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
	p.answered = p.used
	if l.state == .Closed {
		if l == p.link {
			peer_drop(p) // told so: its session ends now, and no call is put on it meanwhile
		}
		return
	}
	peer_opened(p, l)
}

// The link is proven: make it the peer's, and begin a session on it. One that was there before gives way,
// for a device answers only the knock of one that has no link, or thinks so; and only a proven one.
@(private)
peer_opened :: proc(p: ^Peer, l: ^pipe.Link) {
	if l.state != .Open || (p.session != nil && l != p.answer) || !admitted(p.space, p.device) {
		return // and one the roster no longer admits is let go of once links_run sees the roster has changed
	}
	if l == p.answer {
		if p.session != nil {
			session := p.session
			p.session = nil
			session_end(session)
		}
		if p.link != nil {
			pipe.link_destroy(p.link)
			free(p.link)
		}
		p.link, p.answer = p.answer, nil
	}
	p.knocks, p.reknocks, p.suspect = 0, 0, {}
	p.session = zsp.session_open(&p.space.node, .Peer, peer_dials(p), p.device)
	session_link(p.session, p.link)
}

// Lets a session over a link send each call on a stream of its own.
@(private)
session_link :: proc(session: ^zsp.Session, l: ^pipe.Link) {
	session.datagram_data = l
	session.datagram = proc(data: rawptr, frame: []byte) -> bool {
		return pipe.link_datagram((^pipe.Link)(data), frame)
	}
	session.lane_data = l
	session.lane_open = proc(data: rawptr, urgency: u8, after: u64) -> (id: u64, ok: bool) {
		return pipe.link_open((^pipe.Link)(data), urgency, after)
	}
}

// What came on a link's streams: the session's own, or a call's.
@(private)
link_heard :: proc(session: ^zsp.Session, l: ^pipe.Link, id: u64, bytes: []byte, event: pipe.Stream_Event) {
	if id == 0 {
		if event == .Data {
			session.node.now = now_ms()
			zsp.session_input(session, bytes) // its owner closes it, once it has heard why
		}
		return
	}
	switch event {
	case .Data:
		zsp.session_lane_input(session, id, pipe.link_urgency(l, id), bytes)
	case .Fin:
		zsp.session_lane_heard(session, id, false)
	case .Reset:
		zsp.session_lane_heard(session, id, true)
	case .Stopped:
		zsp.session_lane_stopped(session, id)
	}
}

// Hands a link what a session has to say, on its own stream and its calls', as far as the link has room.
@(private)
link_feed :: proc(session: ^zsp.Session, l: ^pipe.Link) {
	if room := pipe.link_room(l, 0); room > 0 {
		out := zsp.session_output(session)
		if n := min(len(out), room); n > 0 {
			pipe.link_write(l, 0, out[:n])
			zsp.session_sent(session, n)
		}
	}
	lanes := zsp.session_lanes(session)
	for i := 0; i < len(lanes); i += 1 {
		lane := lanes[i]
		if !pipe.link_has(l, lane.id) {
			// The link has let it go, so both ends are done with it.
			lane.heard = true
			zsp.session_lane_closed(session, lane)
			lanes = zsp.session_lanes(session)
			i -= 1
			continue
		}
		out := zsp.session_lane_output(session, lane)
		if len(out) > 0 {
			pipe.link_after(l, lane.id, lane.after)
			if n := min(len(out), pipe.link_room(l, lane.id)); n > 0 {
				pipe.link_write(l, lane.id, out[:n])
				zsp.session_lane_sent(session, lane, n)
			}
		}
		if zsp.session_lane_done(session, lane) {
			pipe.link_after(l, lane.id, lane.after)
			pipe.link_finish(l, lane.id)
			zsp.session_lane_closed(session, lane)
			lanes = zsp.session_lanes(session)
			i -= 1
		}
	}
}

@(private)
peer_wire :: proc(p: ^Peer, l: ^pipe.Link) {
	l.data = p
	// The packet that proves a link may already carry its first bytes.
	l.on_stream = proc(l: ^pipe.Link, id: u64, bytes: []byte, event: pipe.Stream_Event) {
		p := (^Peer)(l.data)
		peer_opened(p, l)
		if l == p.link && p.session != nil {
			link_heard(p.session, l, id, bytes, event)
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
		session_end(session)
	}
	for l in ([]^pipe.Link{p.link, p.answer}) {
		if l != nil {
			pipe.link_destroy(l)
			free(l)
		}
	}
	p.link, p.answer = nil, nil
	p.suspect, p.reknocks = {}, 0
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
	for p in s.host.udp.links {
		if p.space == s && p.session != nil && !slice.contains(online, p.device) {
			pipe.link_poke(p.link) // gone from there, and perhaps from here
		}
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
		if len(w) >= MAX_CANDIDATES * 18 || !pipe.address_usable(a) {
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
		if pipe.address_usable(a) { // nothing is sent where it could reach nobody, or everybody
			append(&p.candidates, a)
		}
	}
	peer_offer(p)
	peer_knock(p)
}

@(private)
peer_knock :: proc(p: ^Peer) {
	if peer_dials(p) && p.link == nil {
		p.link = new(pipe.Link)
		if !pipe.link_dial(p.link, p.space.host.secret, p.device, p.space.node.space, zsp.node_stamp(&p.space.node).time) {
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
	if !u.have_beacon {
		return
	}
	say :: proc(u: ^Udp, packet: []byte, at: net.IP4_Address) {
		_, err := net.send_udp(u.beacon, packet, {at, BEACON_PORT})
		if err != nil {
			report(.Debug, "cannot announce to ", net.address_to_string(at, context.temp_allocator), ": ", fmt.tprint(err))
		}
	}
	say(u, packet, {255, 255, 255, 255})
	// And on interfaces that are not the default one.
	for i in interfaces() {
		if all, ok := i.broadcast.?; ok {
			say(u, packet, all)
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
		report(.Debug, "a beacon from ", net.endpoint_to_string(address_to(from), context.temp_allocator))
		if p == nil {
			return
		}
		at := from
		at.port = u16(port)
		if !pipe.address_usable(at) {
			return // a beacon that says it is nowhere
		}
		if p.session != nil {
			peer_suspect(p, at)
			return
		}
		if p.knocks > 0 {
			// Heard by another road, which may be the one that works; or again, our answer having been lost.
			new := !slice.contains(p.candidates[:], at)
			if new && len(p.candidates) < MAX_CANDIDATES {
				append(&p.candidates, at)
			}
			if !peer_dials(p) && (new || time.tick_since(p.heard) >= ANNOUNCE_AFTER / 2) {
				p.heard = time.tick_now()
				beacon_send(s, at)
			}
			return
		}
		p.heard = time.tick_now()
		clear(&p.candidates)
		append(&p.candidates, at)
		if !peer_dials(p) {
			beacon_send(s, at) // so that it knows to: where it says it is, its own socket, for others may share the port it says from
		}
		peer_knock(p)
		return
	}
}

// A beacon from a device this one has a session with. A device with a session says none but when it starts, or its
// network changes; so it may have started again, and the link here be to a process that is gone, which a quiet link
// would not find out for a long while, nor would the other dial, not being the one to. Or the beacon may be an old one,
// said again by anyone, for none is bound to a time. So nothing is believed of it: the link is poked, and a live peer
// answers that at once, which settles it. Only if nothing comes back on the link for SUSPECT_WAIT is another sought
// (peer_silent), and the link it makes gives way only once it is proven.
@(private)
peer_suspect :: proc(p: ^Peer, at: pipe.Address) {
	if p.suspect != {} || p.link == nil {
		return // being looked into already
	}
	p.suspect, p.suspect_at = time.tick_now(), at
	pipe.link_poke(p.link)
}

// The link did not answer: the dialler knocks anew where the beacon said, beside the old link; the other tells the
// dialler where it is, so that it knocks.
@(private)
peer_silent :: proc(p: ^Peer) {
	report(.Debug, "a link that answered nothing, sought anew at ", net.endpoint_to_string(address_to(p.suspect_at), context.temp_allocator))
	if !peer_dials(p) {
		beacon_send(p.space, p.suspect_at)
		return
	}
	if p.answer == nil {
		l := new(pipe.Link)
		if !pipe.link_dial(l, p.space.host.secret, p.device, p.space.node.space, zsp.node_stamp(&p.space.node).time) {
			free(l)
			return
		}
		p.answer = l
		peer_wire(p, l)
	}
	p.reknocks = KNOCKS
	p.next_reknock = time.tick_now()
}

// Announces this device to the local network. Call at start, and when the network changes. A broadcast may be
// lost and nobody the wiser, so it is said a few times, ever less often, and then no more.
links_announce :: proc(h: ^Host) {
	if h.udp.open && !h.relay {
		h.udp.announces = ANNOUNCES
		h.udp.announce = time.tick_now()
	}
}

@(private)
announce_run :: proc(h: ^Host, now: time.Tick) {
	u := &h.udp
	if u.announces == 0 || time.tick_diff(u.announce, now) < 0 {
		return
	}
	for s in h.spaces {
		beacon_send(s)
	}
	u.announces -= 1
	u.announce = time.tick_add(now, ANNOUNCE_AFTER << uint(2 * (ANNOUNCES - 1 - u.announces)))
}

// ---------------------------------------------------------------- running

@(private)
links_run :: proc(h: ^Host) {
	u := &h.udp
	if !u.open {
		return
	}
	now := time.tick_now()
	announce_run(h, now)
	if u.asking && time.tick_diff(u.asked, now) > STUN_WAIT {
		u.asking = false
	}
	for s in h.spaces {
		if s.node.roster.serial != s.admitted {
			s.admitted = s.node.roster.serial
			peers_admitted(s)
		}
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
			report(.Debug, "no longer linked to ", net.endpoint_to_string(address_to(p.address), context.temp_allocator))
			peer_drop(p)
		}
		if p.session != nil {
			if p.suspect != {} {
				if time.tick_diff(p.suspect, p.answered) >= 0 {
					p.suspect = {} // it answered: alive
				} else if time.tick_diff(p.suspect, now) >= SUSPECT_WAIT {
					p.suspect = {}
					peer_silent(p)
				}
			}
			if p.reknocks > 0 && time.tick_diff(p.next_reknock, now) >= 0 {
				p.reknocks -= 1
				p.next_reknock = time.tick_add(now, KNOCK_EVERY)
				if p.answer != nil && p.answer.state != .Open {
					buf: [pipe.PACKET]byte
					udp_send(h, pipe.link_hello(p.answer, buf[:]), p.suspect_at)
					if p.reknocks == 0 {
						pipe.link_destroy(p.answer) // never answered: let go
						free(p.answer)
						p.answer = nil
					}
				} else {
					p.reknocks = 0
				}
			}
			// Its last word heard, a session that has ended is done with, and what its calls still had on their way.
			if p.session.closing && len(zsp.session_output(p.session)) == 0 && pipe.link_said(p.link) {
				pipe.link_close(p.link)
			}
			if time.tick_diff(p.used, now) >= CALL_ALIVE && zsp.node_calling(&p.space.node, p.session) {
				pipe.link_poke(p.link)
			} else if p.far && time.tick_diff(p.used, now) > NAT_IDLE {
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
	b: Batch
	for p in u.links {
		if p.session == nil || p.link == nil {
			continue
		}
		for {
			link_feed(p.session, p.link)
			packet := pipe.link_output(p.link, b.packets[b.n][:], now)
			if packet == nil {
				break
			}
			b.sizes[b.n] = len(packet)
			b.n += 1
			p.used = time.tick_now()
			if b.n == UDP_BATCH {
				udp_send_batch(h, &b, p.address)
			}
		}
		udp_send_batch(h, &b, p.address)
		if p.link.state == .Closed {
			peer_drop(p) // given up, or closed, as it sent: let go now, not when next looked at, nor a call put on it meanwhile
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
	if u.announces > 0 {
		nearer(&due, at(u.announce, time.Millisecond))
	}
	for p in u.links {
		if p.session != nil {
			nearer(&due, pipe.link_deadline(p.link))
			if zsp.node_calling(&p.space.node, p.session) && pipe.link_pokeable(p.link) {
				nearer(&due, at(p.used, CALL_ALIVE)) // else its own deadline is what comes next: a poke would do nothing
			}
			if p.far {
				nearer(&due, at(p.used, NAT_IDLE + time.Millisecond))
			}
			if p.suspect != {} {
				nearer(&due, at(p.suspect, SUSPECT_WAIT))
			}
			if p.reknocks > 0 {
				nearer(&due, at(p.next_reknock, 0))
			}
		} else if p.knocks > 0 {
			nearer(&due, at(p.next_knock, 0))
		}
	}
	return
}

// Packets to send to one address, together.
UDP_BATCH :: 32

@(private)
Batch :: struct {
	packets: [UDP_BATCH][pipe.PACKET_MAX]byte,
	sizes:   [UDP_BATCH]int,
	n:       int,
}

// What the system may hold for the host's UDP socket of what has come and is not yet read: a burst beyond it is lost
// before the loop sees it, and sent again. Sized to hold, while the loop is away, all a peer's link may send it before
// hearing from it, LINK_WINDOW (1 MiB) of stream data, which is some 750 datagrams of PACKET_MAX, with room over:
// measured, Windows and macOS hold what they are granted in datagrams' bytes (1 MiB held 706 to 723 of them, 2 MiB
// 1413 to 1444), where their defaults (64 KiB, 768 KiB) held 46 and 530. Linux grants twice what it is asked within
// twice net.core.rmem_max (212992 by default, so 425984, some 185 datagrams), which a stalled loop overflows: a reader
// stalled 5 ms of every 50 lost 5.3% of a paced 1 Gbit/s, 10 ms 13.1% (0.0% up to 2 ms; at 300 Mbit/s 0.0% up to 5 ms,
// 10 ms 4.8%), where 2 MiB forced (SO_RCVBUFFORCE, granted 4 MiB) lost none at 10 ms. So it is forced where the host
// may (CAP_NET_ADMIN), and asked within rmem_max where not. What was granted is said once, at debug. core:net's set_option gave it whatever the low bytes of a pointer said (see
// third_party/nbio/socket_option.odin).
UDP_RECEIVE_BUFFER :: 2 << 20

@(private)
udp_receive_buffer :: proc(socket: net.UDP_Socket) {
	// On Linux, beyond net.core.rmem_max where the host may (CAP_NET_ADMIN), else within it.
	forced, _ := nbio.set_socket_option(socket, .Receive_Buffer_Size_Forced, UDP_RECEIVE_BUFFER)
	if forced != nil {
		if err, code := nbio.set_socket_option(socket, .Receive_Buffer_Size, UDP_RECEIVE_BUFFER); err != nil {
			report(.Debug, "the UDP receive buffer could not be set: ", fmt.tprint(err, code))
		}
	}
	if got, err, _ := nbio.socket_option(socket, .Receive_Buffer_Size); err == nil {
		report(.Debug, "the UDP receive buffer, asked for ", fmt.tprint(UDP_RECEIVE_BUFFER), ", is ", fmt.tprint(got))
	}
}
