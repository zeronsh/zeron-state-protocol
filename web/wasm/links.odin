package web

import "core:slice"
import "core:time"
import "../../pipe"
import "../../zsp"

foreign import host "host"

// Direct links between devices, where the host has UDP, as Node does and a browser does not: host/links.odin, with the
// sockets lent. Those who share a relay swap addresses through it, sealed to each other, and knock on each other's doors
// at the same moment; those who share a network hear each other's beacon and need no relay at all. Links that cross a
// NAT are let go before the NAT forgets them, and knocked for again when there is something to say.

@(default_calling_convention = "contextless")
foreign host {
	// A packet to an address: 16 bytes of IPv6, IPv4 mapped, and a port.
	udp_send :: proc(ip: [^]byte, port: u32, ptr: [^]byte, len: int) ---
	// This machine's addresses: for each, 16 bytes of it and 4 of its network's broadcast address, zero for none. Returns how many.
	udp_interfaces :: proc(into: [^]byte, most: int) -> int ---
}

KNOCK_EVERY :: 200 * time.Millisecond
KNOCKS :: 25
RETRY_AFTER :: 15 * time.Second
NAT_IDLE :: 25 * time.Second
CALL_ALIVE :: #config(ZSP_CALL_ALIVE, 15_000) * time.Millisecond
STUN_WAIT :: 400 * time.Millisecond
BEACON_PORT :: 9083
ANNOUNCES :: 4 // at once, then 0.3, 1.2 and 4.8 seconds apart
ANNOUNCE_AFTER :: 300 * time.Millisecond
MAX_CANDIDATES :: 16
BEACON :: pipe.Type(0x44)

@(private)
Udp :: struct {
	open:      bool,
	port:      int,
	announces: int, // yet to make
	announce:  time.Tick, // when the next is due
	links:     [dynamic]^Peer,
	ask:       [pipe.STUN_REQUEST]byte,
	asked:     time.Tick,
	asking:    bool,
	outside:   Maybe(pipe.Address),
	stun:      Maybe(pipe.Address),
	seen:      u64, // events already noticed
	admitted:  u64, // the roster whose members links were last held to: see peers_admitted
}

// What this host knows of reaching one device. Survives the link itself.
@(private)
Peer :: struct {
	device:     zsp.Key32,
	candidates: [dynamic]pipe.Address,
	link:       ^pipe.Link, // open, or being dialled
	answer:     ^pipe.Link, // answered, not yet confirmed
	session:    ^zsp.Session,
	knocked:    u64, // the latest knock heard, by the knocker's clock
	address:    pipe.Address, // where it was last heard from
	far:        bool, // beyond a NAT
	used:       time.Tick,
	knocks:     int, // left
	next_knock: time.Tick,
	tried:      time.Tick, // when candidates were last sent
	ever_tried: bool,
	heard:      time.Tick, // a beacon, last answered
	owed:       bool, // candidates are to be sent once the outside address is known
}

udp: Udp

@(private)
now_us :: proc() -> pipe.Time {
	return pipe.Time(time.tick_now()._nsec / 1000)
}

@(private)
send_to :: proc(packet: []byte, to: pipe.Address) {
	to := to
	udp_send(&to.ip[0], u32(to.port), raw_data(packet), len(packet))
}

// The host has UDP sockets, on this port, and whether it hears beacons on BEACON_PORT; and perhaps a STUN server's
// address (18 bytes) in the buffer. Announces this device to the local network.
@(export)
links_open :: proc "c" (port: int, size: int) {
	context = ctx()
	udp.open = true
	udp.port = port
	if size >= 18 {
		a: pipe.Address
		copy(a.ip[:], message[:16])
		a.port = u16(message[16]) << 8 | u16(message[17])
		udp.stun = a
	}
	node.host.signal = links_signalled
	node.host.presence = proc(_: rawptr, online: []zsp.Key32) {
		links_greet(online)
	}
	links_announce()
}

// Announces this device to the local network again: for when the network has changed.
@(export)
links_announce :: proc "c" () {
	if udp.open {
		udp.announces = ANNOUNCES
		udp.announce = time.tick_now()
	}
}

// A packet lies in the buffer: from (16 bytes of address, and a port, big-endian, 2) and then the packet.
@(export)
packet :: proc "c" (size: int) {
	context = ctx()
	if !udp.open || !started || size <= 18 {
		return
	}
	from: pipe.Address
	copy(from.ip[:], message[:16])
	from.port = u16(message[16]) << 8 | u16(message[17])
	udp_input(message[18:size], from)
}

@(private)
udp_input :: proc(packet: []byte, from: pipe.Address) {
	if pipe.is_stun(packet) {
		reply: [pipe.STUN_REPLY]byte
		if out := pipe.stun_answer(packet, from, reply[:]); out != nil {
			send_to(out, from)
		} else if a, ok := pipe.stun_address(udp.ask[:], packet); ok {
			udp.outside = a
			udp.asking = false
		}
		return
	}
	if id, ok := pipe.packet_receiver(packet); ok {
		for p in udp.links {
			for l in ([]^pipe.Link{p.link, p.answer}) {
				if l == nil || l.local != id {
					continue
				}
				session := p.session
				if pipe.link_input(l, packet, now_us()) {
					peer_heard(p, l, from)
				}
				if p.session != nil && p.session != session {
					report(.Debug, "linked directly")
				}
				return
			}
		}
		return
	}
	#partial switch pipe.Type(packet[0]) {
	case .First:
		peer_answer(packet, from)
	case BEACON:
		beacon_heard(packet, from)
	}
}

// What is known of reaching a device the roster admits; nil for any other, however well it was known before.
@(private)
peer_for :: proc(device: zsp.Key32) -> ^Peer {
	if !admitted(device) {
		return nil
	}
	for p in udp.links {
		if p.device == device {
			return p
		}
	}
	p := new(Peer)
	p.device = device
	append(&udp.links, p)
	return p
}

@(private)
admitted :: proc(device: zsp.Key32) -> bool {
	m := zsp.roster_member(&node.roster, device)
	return m != nil && zsp.member_active(m) && device != keys.device
}

// The roster has changed: a device it no longer admits is let go of, with all that was on its way to it, but a session,
// which the node ends itself, saying why, and which goes with its link.
@(private)
peers_admitted :: proc() {
	#reverse for p, i in udp.links {
		if admitted(p.device) || p.session != nil {
			continue
		}
		peer_drop(p)
		delete(p.candidates)
		free(p)
		ordered_remove(&udp.links, i)
	}
}

// Of two devices, the one with the lesser key dials.
@(private)
peer_dials :: proc(p: ^Peer) -> bool {
	return string(keys.device[:]) < string(p.device[:])
}

@(private)
peer_answer :: proc(packet: []byte, from: pipe.Address) {
	for p in udp.links {
		// The same knock, by another door.
		if p.answer != nil && pipe.link_answers(p.answer, packet) {
			buf: [pipe.PACKET]byte
			send_to(pipe.link_hello(p.answer, buf[:]), from)
			return
		}
	}
	l: pipe.Link
	if !pipe.link_answer(&l, keys.secret, node.space, packet) {
		return
	}
	p := peer_for(l.channel.peer)
	// A stranger; or a knock heard before, which anyone may have kept. And a live link is not disturbed even by a new
	// one until that proves itself.
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
	send_to(pipe.link_hello(p.answer, buf[:]), from)
}

@(private)
peer_heard :: proc(p: ^Peer, l: ^pipe.Link, from: pipe.Address) {
	p.address = from
	p.far = !address_near(from)
	p.used = time.tick_now()
	if l.state == .Closed {
		if l == p.link {
			peer_drop(p) // told so: its session ends now, and no call is put on it meanwhile
		}
		return
	}
	peer_opened(p, l)
}

// The link is proven: make it the peer's, and begin a session on it. One that was there before gives way, for a device
// answers only the knock of one that has no link, or thinks so; and only a proven one.
@(private)
peer_opened :: proc(p: ^Peer, l: ^pipe.Link) {
	if l.state != .Open || (p.session != nil && l != p.answer) || !admitted(p.device) {
		return // and one the roster no longer admits is let go of once links_run sees the roster has changed
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
	p.session = zsp.session_open(&node, .Peer, peer_dials(p), p.device)
	session_link(p.session, p.link)
}

@(private)
peer_wire :: proc(p: ^Peer, l: ^pipe.Link) {
	l.data = p
	// The packet that proves a link may already carry its first bytes.
	l.on_stream = proc(l: ^pipe.Link, id: u64, bytes: []byte, event: pipe.Stream_Event) {
		p := (^Peer)(l.data)
		peer_opened(p, l)
		if l == p.link && p.session != nil {
			link_heard(p.session, l, id, bytes, event) // links_run closes it, once it has heard why
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
address_near :: proc(a: pipe.Address) -> bool {
	if !pipe.address_is_v4(a) {
		return a.ip[0] == 0xfe || (a.ip[0] & 0xfe) == 0xfc || a.ip == {15 = 1}
	}
	b := [4]byte{a.ip[12], a.ip[13], a.ip[14], a.ip[15]}
	return b[0] == 10 || b[0] == 127 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
}

// ---------------------------------------------------------------- finding each other

@(private)
Interface :: struct {
	address:   pipe.Address,
	broadcast: Maybe(pipe.Address),
}

// Temporary memory.
@(private)
interfaces :: proc() -> []Interface {
	raw := make([]byte, 20 * 64, context.temp_allocator)
	n := udp_interfaces(raw_data(raw), 64)
	out := make([]Interface, n, context.temp_allocator)
	for &i, k in out {
		e := raw[k * 20:]
		copy(i.address.ip[:], e[:16])
		i.address.port = u16(udp.port)
		if e[16] | e[17] | e[18] | e[19] != 0 {
			i.broadcast = pipe.address_v4(e[16], e[17], e[18], e[19], BEACON_PORT)
		}
	}
	return out
}

// Others have come online at a relay.
@(private)
links_greet :: proc(online: []zsp.Key32) {
	if !udp.open {
		return
	}
	for p in udp.links {
		if p.session != nil && !slice.contains(online, p.device) {
			pipe.link_poke(p.link) // gone from there, and perhaps from here
		}
	}
	for device in online {
		if p := peer_for(device); p != nil && p.session == nil {
			peer_offer(p)
		}
	}
}

// Sends our addresses, once the outside one is known or clearly not coming.
@(private)
peer_offer :: proc(p: ^Peer) {
	if p.ever_tried && time.tick_since(p.tried) < RETRY_AFTER {
		return
	}
	p.ever_tried = true
	p.tried = time.tick_now()
	p.owed = true
	if stun, ok := udp.stun.?; ok && !udp.asking {
		// Asked afresh each time: it also opens the NAT's mapping, from the very socket links use.
		udp.ask = pipe.stun_request()
		udp.asking = true
		udp.asked = p.tried
		send_to(udp.ask[:], stun)
	}
}

@(private)
peer_send_candidates :: proc(p: ^Peer) {
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
	if a, ok := udp.outside.?; ok {
		put(&w, a)
	}
	for i in interfaces() {
		a := i.address
		v4 := pipe.address_is_v4(a)
		loopback := (v4 && a.ip[12] == 127) || a.ip == {15 = 1}
		link_local := !v4 && a.ip[0] == 0xfe
		if !loopback && !link_local {
			put(&w, a)
		}
	}
	zsp.node_signal(&node, p.device, w[:])
}

// The other side's addresses have come: knock on all of them, and answer in kind.
@(private)
links_signalled :: proc(_: rawptr, from: zsp.Key32, blob: []byte) {
	if !udp.open {
		return
	}
	p := peer_for(from)
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
		if !pipe.link_dial(p.link, keys.secret, p.device, node.space, zsp.node_stamp(&node).time) {
			free(p.link)
			p.link = nil
			return
		}
		peer_wire(p, p.link)
	}
	p.knocks = KNOCKS
	p.next_knock = time.tick_now()
}

// A beacon tells members nearby where this device is, and others nothing.
@(private)
beacon_send :: proc(to: Maybe(pipe.Address) = nil) {
	packet := zsp.beacon_seal(&node, udp.port)
	if len(packet) == 0 {
		return
	}
	if a, ok := to.?; ok {
		send_to(packet, a)
		return
	}
	send_to(packet, pipe.address_v4(255, 255, 255, 255, BEACON_PORT))
	// And on interfaces that are not the default one.
	for i in interfaces() {
		if all, ok := i.broadcast.?; ok {
			send_to(packet, all)
		}
	}
}

@(private)
beacon_heard :: proc(packet: []byte, from: pipe.Address) {
	device, port, ok := zsp.beacon_open(&node, packet)
	if !ok || device == keys.device {
		return
	}
	p := peer_for(device)
	report(.Debug, "a beacon")
	if p == nil || p.session != nil {
		return
	}
	at := from
	at.port = u16(port)
	if p.knocks > 0 {
		// Heard by another road, which may be the one that works; or again, our answer having been lost.
		new := !slice.contains(p.candidates[:], at)
		if new && len(p.candidates) < MAX_CANDIDATES {
			append(&p.candidates, at)
		}
		if !peer_dials(p) && (new || time.tick_since(p.heard) >= ANNOUNCE_AFTER / 2) {
			p.heard = time.tick_now()
			beacon_send(from)
		}
		return
	}
	p.heard = time.tick_now()
	clear(&p.candidates)
	append(&p.candidates, at)
	if !peer_dials(p) {
		beacon_send(from) // so that it knows to; its own socket, for others may share the port
	}
	peer_knock(p)
}

@(private)
announce_run :: proc(now: time.Tick) {
	if udp.announces == 0 || time.tick_diff(udp.announce, now) < 0 {
		return
	}
	beacon_send()
	udp.announces -= 1
	udp.announce = time.tick_add(now, ANNOUNCE_AFTER << uint(2 * (ANNOUNCES - 1 - udp.announces)))
}

// ---------------------------------------------------------------- running

@(private)
links_run :: proc() {
	if !udp.open || !started {
		return
	}
	now := time.tick_now()
	announce_run(now)
	if udp.asking && time.tick_diff(udp.asked, now) > STUN_WAIT {
		udp.asking = false
	}
	if node.roster.serial != udp.admitted {
		udp.admitted = node.roster.serial
		peers_admitted()
	}
	// Something was written here: worth trying for a direct path to whoever is listening.
	if node.events.next != udp.seen {
		udp.seen = node.events.next
		for session in node.sessions {
			if session.ready && session.peer_relay {
				links_greet(session.online[:])
			}
		}
	}
	for p in udp.links {
		if p.owed && !udp.asking {
			peer_send_candidates(p)
		}
		if p.link != nil && p.link.state == .Closed {
			report(.Debug, "no longer linked")
			peer_drop(p)
		}
		if p.session != nil {
			// Its last word heard, a session that has ended is done with, and what its calls still had on their way.
			if p.session.closing && len(zsp.session_output(p.session)) == 0 && pipe.link_said(p.link) {
				pipe.link_close(p.link)
			}
			if time.tick_diff(p.used, now) >= CALL_ALIVE && zsp.node_calling(&node, p.session) {
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
				send_to(packet, a)
			}
			if p.knocks == 0 {
				peer_drop(p)
			}
		}
	}
}

@(private)
links_flush :: proc() {
	if !udp.open {
		return
	}
	now := now_us()
	buf: [pipe.PACKET_MAX]byte
	for p in udp.links {
		if p.session == nil || p.link == nil {
			continue
		}
		for {
			link_feed(p.session, p.link)
			packet := pipe.link_output(p.link, buf[:], now)
			if packet == nil {
				break
			}
			send_to(packet, p.address)
			p.used = time.tick_now()
		}
		if p.link.state == .Closed {
			peer_drop(p) // given up, or closed, as it sent: let go now, not when next looked at, nor a call put on it meanwhile
		}
	}
}

// How long until links have something to do; ok false for never.
@(private)
links_deadline :: proc() -> (wait: time.Duration, ok: bool) {
	if !udp.open {
		return
	}
	due: pipe.Time
	nearer :: proc(due: ^pipe.Time, t: pipe.Time) {
		if t != 0 && (due^ == 0 || t < due^) {
			due^ = t
		}
	}
	at :: proc(t: time.Tick, d: time.Duration) -> pipe.Time {
		return pipe.Time(time.tick_add(t, d)._nsec / 1000)
	}
	if udp.asking {
		nearer(&due, at(udp.asked, STUN_WAIT + time.Millisecond))
	}
	if udp.announces > 0 {
		nearer(&due, at(udp.announce, time.Millisecond))
	}
	for p in udp.links {
		if p.session != nil {
			nearer(&due, pipe.link_deadline(p.link))
			if zsp.node_calling(&node, p.session) && pipe.link_pokeable(p.link) {
				nearer(&due, at(p.used, CALL_ALIVE)) // else its own deadline is what comes next: a poke would do nothing
			}
			if p.far {
				nearer(&due, at(p.used, NAT_IDLE + time.Millisecond))
			}
		} else if p.knocks > 0 {
			nearer(&due, at(p.next_knock, 0))
		}
	}
	if due == 0 {
		return
	}
	return max(time.Duration(i64(due) - i64(now_us())) * time.Microsecond, 0), true
}

@(private)
links_destroy :: proc() {
	for len(udp.links) > 0 {
		p := pop(&udp.links)
		peer_drop(p)
		delete(p.candidates)
		free(p)
	}
	delete(udp.links)
	udp = {}
}
