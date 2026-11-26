package host

import "core:slice"
import "core:time"
import "../pipe"
import "../zsp"

// Links that relays carry: for calls between devices that have no direct link, or none yet. Each is a link like any
// other (§14), with its streams, windows and loss recovery, whose packets travel in signals through a relay both
// devices are present at. The relay keeps nothing of them and may drop any, as a router would, when one of them has
// more waiting than it can take; the link sends it again and slows. Should the relay go, the link goes on through
// another both are present at, and its calls with it.
//
// Over such a link runs a session for calls alone: everything else the relay already carries. A device begins one
// when it has a call to make and no other way; whoever is called answers. One is let go once its calls have been
// over for a while.

RELAY_PACKET :: 8192 // no path between here and a relay fragments, nor drops for size
RELAY_KNOCK_EVERY :: 500 * time.Millisecond
RELAY_KNOCKS :: 20
RELAY_IDLE :: 30 * time.Second

@(private)
Relayed :: struct {
	space:      ^Space,
	device:     zsp.Key32,
	mine:       bool, // this end dialled
	link:       ^pipe.Link,
	session:    ^zsp.Session,
	via:        u32, // the session with the relay it goes through
	knocks:     int, // left, while dialling
	next_knock: time.Tick,
	used:       time.Tick, // last heard from, or said to
	began:      u64, // the dialler's stamp time of its first message
}

// A session for calls to a device, through a relay: the one there is, or one begun now.
@(private)
relayed_reach :: proc(data: rawptr, device: zsp.Key32) -> ^zsp.Session {
	sp := (^Space)(data)
	for r in sp.relayed {
		if r.device == device && r.session != nil && !r.session.closing && r.link.state != .Closed {
			return r.session
		}
	}
	via, ok := relay_with(sp, device)
	if !ok {
		return nil
	}
	h := sp.host
	r := new(Relayed)
	r.space, r.device, r.mine, r.via = sp, device, true, via
	r.link = new(pipe.Link)
	r.began = zsp.node_stamp(&sp.node).time
	if !pipe.link_dial(r.link, h.secret, device, sp.node.space, r.began) {
		free(r.link)
		free(r)
		return nil
	}
	relayed_wire(r)
	r.knocks = RELAY_KNOCKS
	r.next_knock = time.tick_now()
	r.used = r.next_knock
	append(&sp.relayed, r)
	return r.session
}

// A relay both devices are present at, and dialled by this one.
@(private)
relay_with :: proc(sp: ^Space, device: zsp.Key32) -> (via: u32, ok: bool) {
	for s in sp.node.sessions {
		if s.ready && s.peer_relay && !s.closing && slice.contains(s.online[:], device) {
			return s.id, true
		}
	}
	return
}

@(private)
relayed_wire :: proc(r: ^Relayed) {
	l := r.link
	l.mtu = RELAY_PACKET
	l.path_probes = pipe.MAX_PATH_PROBES // its size is known
	l.data = r
	l.on_stream = proc(l: ^pipe.Link, id: u64, bytes: []byte, event: pipe.Stream_Event) {
		r := (^Relayed)(l.data)
		if r.session != nil {
			link_heard(r.session, l, id, bytes, event)
		}
	}
	r.session = zsp.session_open(&r.space.node, .Calls, r.mine, r.device)
	session_link(r.session, l)
	r.session.datagram = nil // a relay is no faster for them, and they are only hints
}

// A link's packet, from a device, through a relay.
@(private)
relayed_input :: proc(data: rawptr, relay: u32, from: zsp.Key32, packet: []byte) {
	sp := (^Space)(data)
	h := sp.host
	if len(packet) == 0 {
		return
	}
	if pipe.Type(packet[0]) == .First {
		// The same knock again: its answer was lost, or is on its way.
		for r in sp.relayed {
			if !r.mine && r.device == from && pipe.link_answers(r.link, packet) {
				relayed_hello(r)
				return
			}
		}
		l: pipe.Link
		if !pipe.link_answer(&l, h.secret, sp.node.space, packet) {
			return
		}
		if l.channel.peer != from {
			pipe.link_destroy(&l)
			return
		}
		// A knock older than one heard is anyone's to have kept: ignored. A newer one replaces the link it began
		// before, whose calls are lost: its dialler has begun again.
		for r, i in sp.relayed {
			if !r.mine && r.device == from {
				if l.channel.began <= r.began {
					pipe.link_destroy(&l)
					return
				}
				relayed_drop(r)
				ordered_remove(&sp.relayed, i)
				break
			}
		}
		r := new(Relayed)
		r.space, r.device, r.via, r.began = sp, from, relay, l.channel.began
		r.link = new(pipe.Link)
		r.link^ = l
		relayed_wire(r)
		r.used = time.tick_now()
		append(&sp.relayed, r)
		relayed_hello(r)
		return
	}
	id, ok := pipe.packet_receiver(packet)
	if !ok {
		return
	}
	for r in sp.relayed {
		if r.device != from || r.link.local != id {
			continue
		}
		if pipe.link_input(r.link, packet, now_us()) {
			// Newest yet, and genuine: answer by the relay it came through.
			r.via = relay
			r.used = time.tick_now()
			r.knocks = 0
		}
		return
	}
}

// Its handshake packet, to go through the relay.
@(private)
relayed_hello :: proc(r: ^Relayed) {
	buf: [pipe.SECOND_SIZE + pipe.FIRST_SIZE]byte
	if hello := pipe.link_hello(r.link, buf[:]); hello != nil {
		zsp.node_post_link(&r.space.node, r.via, r.device, hello)
	}
}

@(private)
relayed_drop :: proc(r: ^Relayed) {
	if r.session != nil {
		session := r.session
		r.session = nil
		session_end(session)
	}
	pipe.link_destroy(r.link)
	free(r.link)
	free(r)
}

@(private)
relayed_close :: proc(sp: ^Space) {
	for r in sp.relayed {
		relayed_drop(r)
	}
	delete(sp.relayed)
}

// What each has to say, said; what is over, let go.
@(private)
relayed_run :: proc(sp: ^Space, now: time.Tick) {
	for i := len(sp.relayed) - 1; i >= 0; i -= 1 {
		r := sp.relayed[i]
		over := r.link.state == .Closed || r.session == nil || (r.session.closing && len(zsp.session_output(r.session)) == 0 && pipe.link_quiet(r.link))
		if r.link.state == .Dialling && r.knocks == 0 && time.tick_diff(r.next_knock, now) >= 0 {
			over = true // nobody answered
		}
		calling := r.session != nil && zsp.node_calling(&sp.node, r.session)
		if !over && !calling && time.tick_diff(r.used, now) >= RELAY_IDLE {
			pipe.link_close(r.link) // said once, below, and then let go
			relayed_flush(r)
			over = true
		}
		if over {
			relayed_drop(r)
			ordered_remove(&sp.relayed, i)
			continue
		}
		// The relay it went through is gone, or the device from it: another both are at, if there is one.
		if s := zsp.node_session(&sp.node, r.via); s == nil || !s.ready || !slice.contains(s.online[:], r.device) {
			if via, ok := relay_with(sp, r.device); ok {
				r.via = via
				pipe.link_poke(r.link) // find out at once whether it goes on
			}
		}
		if calling && time.tick_diff(r.used, now) >= CALL_ALIVE {
			pipe.link_poke(r.link)
		}
		if r.link.state == .Dialling && r.knocks > 0 && time.tick_diff(r.next_knock, now) >= 0 {
			r.knocks -= 1
			r.next_knock = time.tick_add(now, RELAY_KNOCK_EVERY)
			relayed_hello(r)
		}
	}
}

@(private)
relayed_flush :: proc(r: ^Relayed) {
	buf: [RELAY_PACKET]byte
	now := now_us()
	for {
		if r.session != nil && !r.session.closing {
			link_feed(r.session, r.link)
		}
		packet := pipe.link_output(r.link, buf[:], now)
		if packet == nil {
			return
		}
		zsp.node_post_link(&r.space.node, r.via, r.device, packet) // or dropped, as a relay may
		r.used = time.tick_now()
	}
}

@(private)
relayed_deadline :: proc(sp: ^Space) -> (due: pipe.Time) {
	nearer :: proc(due: ^pipe.Time, t: pipe.Time) {
		if t != 0 && (due^ == 0 || t < due^) {
			due^ = t
		}
	}
	at :: proc(t: time.Tick, d: time.Duration) -> pipe.Time {
		return pipe.Time(time.tick_add(t, d)._nsec / 1000)
	}
	for r in sp.relayed {
		nearer(&due, pipe.link_deadline(r.link))
		if r.link.state == .Dialling {
			nearer(&due, at(r.next_knock, 0))
		}
		if r.session != nil && zsp.node_calling(&sp.node, r.session) {
			nearer(&due, at(r.used, CALL_ALIVE))
		} else {
			nearer(&due, at(r.used, RELAY_IDLE))
		}
	}
	return
}

// What a relay's pipe holds for a session, not yet sent: that it may drop links' packets rather than queue them.
@(private)
stream_backlog :: proc(data: rawptr, s: ^zsp.Session) -> int {
	h := (^Space)(data).host
	for st in h.streams {
		if st.session == s {
			return len(st.out) - st.sent
		}
	}
	return 0
}
