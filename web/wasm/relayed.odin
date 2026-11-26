package web

import "core:slice"
import "core:time"
import "../../pipe"
import "../../zsp"

// Each call on a link on a stream of its own, and links through relays for calls between devices with no link of
// their own: as zspd does it (host/links.odin and host/relayed.odin), on this node's one thread.

@(private)
relayed: [dynamic]^Relayed
@(private)
knocked: map[zsp.Key32]u64 // the newest knock heard from each device through relays: its dialler's stamp time

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

RELAY_PACKET :: 8192 // no path between here and a relay fragments, nor drops for size
RELAY_KNOCK_EVERY :: 500 * time.Millisecond
RELAY_KNOCKS :: 20
RELAY_IDLE :: 30 * time.Second

@(private)
Relayed :: struct {
	device:     zsp.Key32,
	mine:       bool, // this end dialled
	link:       ^pipe.Link,
	session:    ^zsp.Session,
	via:        u32, // the session with the relay it goes through
	knocks:     int, // left, while dialling
	next_knock: time.Tick,
	used:       time.Tick, // last heard from, or said to
	began:      u64, // the dialler's stamp time of its first message
	proven:     bool, // the other end has been heard from over it, genuinely
}

// A session for calls to a device, through a relay: the one there is, or one begun now.
@(private)
relayed_reach :: proc(data: rawptr, device: zsp.Key32) -> ^zsp.Session {
	// One heard from first: beside it there may be one newly knocked for, not yet shown to be anyone's.
	for proven in ([]bool{true, false}) {
		for r in relayed {
			if r.device == device && r.session != nil && !r.session.closing && r.link.state != .Closed && (r.proven || r.mine) == proven {
				return r.session
			}
		}
	}
	via, ok := relay_with(device)
	if !ok {
		return nil
	}
	r := new(Relayed)
	r.device, r.mine, r.via = device, true, via
	r.link = new(pipe.Link)
	r.began = zsp.node_stamp(&node).time
	if !pipe.link_dial(r.link, keys.secret, device, node.space, r.began) {
		free(r.link)
		free(r)
		return nil
	}
	relayed_wire(r)
	r.knocks = RELAY_KNOCKS
	r.next_knock = time.tick_now()
	r.used = r.next_knock
	append(&relayed, r)
	return r.session
}

// A relay both devices are present at, and dialled by this one.
@(private)
relay_with :: proc(device: zsp.Key32) -> (via: u32, ok: bool) {
	for s in node.sessions {
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
	r.session = zsp.session_open(&node, .Calls, r.mine, r.device)
	session_link(r.session, l)
	r.session.datagram = nil // a relay is no faster for them, and they are only hints
}

// A link's packet, from a device, through a relay.
@(private)
relayed_input :: proc(data: rawptr, relay: u32, from: zsp.Key32, packet: []byte) {
	if len(packet) == 0 {
		return
	}
	if pipe.Type(packet[0]) == .First {
		// The same knock again: its answer was lost, or is on its way; it goes back the way this one came.
		for r in relayed {
			if !r.mine && r.device == from && pipe.link_answers(r.link, packet) {
				r.via = relay
				relayed_hello(r)
				return
			}
		}
		l: pipe.Link
		if !pipe.link_answer(&l, keys.secret, node.space, packet) {
			return
		}
		if l.channel.peer != from {
			pipe.link_destroy(&l)
			return
		}
		// A knock no newer than the newest heard from that device, however long ago, is anyone's to have kept:
		// ignored. A newer one is answered with a link beside any there is, which goes on until the new one proves
		// itself: a knock alone proves nothing, for one kept back may be played later.
		if began, heard := knocked[from]; heard && l.channel.began <= began {
			pipe.link_destroy(&l)
			return
		}
		knocked[from] = l.channel.began
		r := new(Relayed)
		r.device, r.via, r.began = from, relay, l.channel.began
		r.link = new(pipe.Link)
		r.link^ = l
		relayed_wire(r)
		r.used = time.tick_now()
		append(&relayed, r)
		relayed_hello(r)
		return
	}
	id, ok := pipe.packet_receiver(packet)
	if !ok {
		return
	}
	for r in relayed {
		if r.device != from || r.link.local != id {
			continue
		}
		if pipe.link_input(r.link, packet, now_us()) {
			// Newest yet, and genuine: answer by the relay it came through.
			r.via = relay
			r.used = time.tick_now()
			r.knocks = 0
			if !r.proven {
				r.proven = true
				relayed_supersede(r)
			}
		}
		return
	}
}

// A link the other end has now spoken over replaces any it knocked for before, whose calls are lost: it began again.
@(private)
relayed_supersede :: proc(r: ^Relayed) {
	for i := len(relayed) - 1; i >= 0; i -= 1 {
		x := relayed[i]
		if x != r && !x.mine && !r.mine && x.device == r.device && x.began < r.began {
			ordered_remove(&relayed, i)
			relayed_drop(x)
		}
	}
}

// Its handshake packet, to go through the relay.
@(private)
relayed_hello :: proc(r: ^Relayed) {
	buf: [pipe.SECOND_SIZE + pipe.FIRST_SIZE]byte
	if hello := pipe.link_hello(r.link, buf[:]); hello != nil {
		zsp.node_post_link(&node, r.via, r.device, hello)
	}
}

@(private)
relayed_drop :: proc(r: ^Relayed) {
	if r.session != nil {
		session := r.session
		r.session = nil
		zsp.session_close(session)
	}
	pipe.link_destroy(r.link)
	free(r.link)
	free(r)
}

@(private)
relayed_close :: proc() {
	for r in relayed {
		relayed_drop(r)
	}
	delete(relayed)
	relayed = nil
	delete(knocked)
	knocked = nil
}

// What each has to say, said; what is over, let go.
@(private)
relayed_run :: proc(now: time.Tick) {
	for i := len(relayed) - 1; i >= 0; i -= 1 {
		r := relayed[i]
		over := r.link.state == .Closed || r.session == nil || (r.session.closing && len(zsp.session_output(r.session)) == 0 && pipe.link_quiet(r.link))
		if r.link.state == .Dialling && r.knocks == 0 && time.tick_diff(r.next_knock, now) >= 0 {
			over = true // nobody answered
		}
		calling := r.session != nil && zsp.node_calling(&node, r.session)
		if !over && !calling && time.tick_diff(r.used, now) >= RELAY_IDLE {
			pipe.link_close(r.link) // said once, below, and then let go
			relayed_flush(r)
			over = true
		}
		if over {
			relayed_drop(r)
			ordered_remove(&relayed, i)
			continue
		}
		// The relay it went through is gone, or the device from it: another both are at, if there is one.
		if s := zsp.node_session(&node, r.via); s == nil || !s.ready || !slice.contains(s.online[:], r.device) {
			if via, ok := relay_with(r.device); ok {
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
		zsp.node_post_link(&node, r.via, r.device, packet) // or dropped, as a relay may
		r.used = time.tick_now()
	}
}

@(private)
relayed_deadline :: proc() -> (due: pipe.Time) {
	nearer :: proc(due: ^pipe.Time, t: pipe.Time) {
		if t != 0 && (due^ == 0 || t < due^) {
			due^ = t
		}
	}
	at :: proc(t: time.Tick, d: time.Duration) -> pipe.Time {
		return pipe.Time(time.tick_add(t, d)._nsec / 1000)
	}
	for r in relayed {
		nearer(&due, pipe.link_deadline(r.link))
		if r.link.state == .Dialling {
			nearer(&due, at(r.next_knock, 0))
		}
		if r.session != nil && zsp.node_calling(&node, r.session) {
			nearer(&due, at(r.used, CALL_ALIVE))
		} else {
			nearer(&due, at(r.used, RELAY_IDLE))
		}
	}
	return
}

