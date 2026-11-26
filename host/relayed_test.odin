package host

import "core:nbio"
import "core:sync"
import "core:testing"
import "core:time"
import "../pipe"
import "../zsp"

// A device whose own way to its relay is backed up holds its link's packets back, rather than handing them on to be
// dropped: they were lost only on its own doorstep, and the link took that for congestion on the path and slowed
// down, to a sixth of what the path carried, through a relay a fifth of a second away.
@(test)
relayed_holds_back_for_its_own_backlog :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	open_port = u16(e.port)
	w.hosts[2].port_permitted = permit_open_port
	g: Gate
	testing.expect(t, gate_open(&g, &w, u16(e.port)))
	defer gate_close(&g)
	c := Client{port = g.port, send = 8 << 20, read_too = true}
	th := client_start(&c)
	testing.expect(t, world_run(&w, proc(w: ^World, c: rawptr) -> bool {return sync.atomic_load(&(^Client)(c).heard) > 256 << 10}, &c))
	a := world_space(&w, 1)
	testing.expect_value(t, len(a.relayed), 1)
	l := a.relayed[0].link

	// Its pipe to the relay says it is full, for a while: nothing is numbered for the link meanwhile.
	backlog := a.node.host.backlog
	a.node.host.backlog = proc(_: rawptr, _: ^zsp.Session) -> int {return 1 << 30}
	before := l.sent_base + u64(len(l.sent) - l.sent_head)
	world_run(&w, proc(_: ^World, _: rawptr) -> bool {return false}, nil, 300 * time.Millisecond)
	numbered := l.sent_base + u64(len(l.sent) - l.sent_head) - before
	a.node.host.backlog = backlog
	testing.expectf(t, numbered == 0, "%d packets sent while its own pipe was full, and so dropped", numbered)

	// And when it has room again, all of it goes, as it was.
	testing.expect(t, world_run(&w, client_done, &c, 60 * time.Second))
	testing.expectf(t, !c.reset && len(c.got) == len(c.sent) && string(c.got[:]) == string(c.sent[:]), "%d of %d came back", len(c.got), len(c.sent))
	client_destroy(&c, th)
}

// Review, round 1. Held back by its own pipe, with a call going on and CALL_ALIVE since the link last sent: the host
// neither sends nor waits, unless it leaves that deadline out too, as it leaves out the link's. It spun.
@(test)
relayed_held_back_waits :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	open_port = u16(e.port)
	w.hosts[2].port_permitted = permit_open_port
	g: Gate
	testing.expect(t, gate_open(&g, &w, u16(e.port)))
	defer gate_close(&g)
	c := Client{port = g.port, send = 8 << 20, read_too = true}
	th := client_start(&c)
	testing.expect(t, world_run(&w, proc(w: ^World, c: rawptr) -> bool {return sync.atomic_load(&(^Client)(c).heard) > 256 << 10}, &c))
	a := world_space(&w, 1)
	testing.expect_value(t, len(a.relayed), 1)
	r := a.relayed[0]

	backlog := a.node.host.backlog
	a.node.host.backlog = proc(_: rawptr, _: ^zsp.Session) -> int {return 1 << 30}
	r.used = time.tick_add(time.tick_now(), -CALL_ALIVE - time.Millisecond)
	h := &w.hosts[1]
	ticks := 0
	until := time.tick_add(time.tick_now(), 50 * time.Millisecond)
	for time.tick_diff(time.tick_now(), until) > 0 {
		r.used = time.tick_add(time.tick_now(), -CALL_ALIVE - time.Millisecond) // nothing heard from it meanwhile either
		host_settle(h)
		wait := nbio.NO_TIMEOUT
		if due, ok := host_deadline(h); ok {
			wait = max(time.tick_diff(time.tick_now(), due), 0)
		}
		left := time.tick_diff(time.tick_now(), until)
		if wait == nbio.NO_TIMEOUT || wait > left {
			wait = max(left, 0)
		}
		_ = nbio.tick(wait)
		ticks += 1
	}
	a.node.host.backlog = backlog
	// Spinning, it went round some ten thousand times; waiting, it wakes for what the transfer still brings, more often
	// on Windows, where it went round 70 times.
	testing.expectf(t, ticks < 500, "the host went round %d times in 50 ms, held back past CALL_ALIVE", ticks)
	testing.expect(t, world_run(&w, client_done, &c, 60 * time.Second))
	client_destroy(&c, th)
}

// Review, round 11. A link only knocked for, and never heard from over, is no way to the device: a call put on it would
// wait on it for ever, as would every call after it. Another is dialled instead.
@(test)
relayed_reach_passes_over_the_unproven :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	a := world_space(&w, 1)
	b := w.keys[2].device
	via, ok := relay_with(a, b)
	testing.expect(t, ok)
	r := new(Relayed) // as a knock from b leaves it, answered: Waiting, not mine, not proven
	r.space, r.device, r.via = a, b, via
	r.link = new(pipe.Link)
	r.link.state = .Waiting
	relayed_wire(r)
	r.used = time.tick_now()
	append(&a.relayed, r)
	s := relayed_reach(a, b)
	testing.expect(t, s != nil && s != r.session)
}

// Review, round 11. A link asking after its peer (probing, with what it sent unacknowledged) while a call on it has
// been quiet past CALL_ALIVE: a poke would do nothing, so that deadline is not the host's to wait for, past as it is.
// It spun until the link was given up.
@(test)
relayed_probing_waits :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	open_port = u16(e.port)
	w.hosts[2].port_permitted = permit_open_port
	g: Gate
	testing.expect(t, gate_open(&g, &w, u16(e.port)))
	defer gate_close(&g)
	c := Client{port = g.port, send = 8 << 20, read_too = true}
	th := client_start(&c)
	testing.expect(t, world_run(&w, proc(w: ^World, c: rawptr) -> bool {return sync.atomic_load(&(^Client)(c).heard) > 256 << 10}, &c))
	a := world_space(&w, 1)
	testing.expect_value(t, len(a.relayed), 1)
	r := a.relayed[0]

	// The relay carries nothing more of theirs, for a while: what a sent waits to be acknowledged.
	relay := world_space(&w, 0)
	backlog := relay.node.host.backlog
	relay.node.host.backlog = proc(_: rawptr, _: ^zsp.Session) -> int {return 1 << 30}
	h := &w.hosts[1]
	ticks := 0
	until := time.tick_add(time.tick_now(), 300 * time.Millisecond)
	for time.tick_diff(time.tick_now(), until) > 0 {
		r.used = time.tick_add(time.tick_now(), -CALL_ALIVE - time.Millisecond) // quiet past CALL_ALIVE, all along
		host_settle(h)
		wait := nbio.NO_TIMEOUT
		if due, ok := host_deadline(h); ok {
			wait = max(time.tick_diff(time.tick_now(), due), 0)
		}
		left := time.tick_diff(time.tick_now(), until)
		if wait == nbio.NO_TIMEOUT || wait > left {
			wait = max(left, 0)
		}
		_ = nbio.tick(wait)
		ticks += 1
	}
	relay.node.host.backlog = backlog
	testing.expectf(t, r.link.in_flight > 0, "nothing in flight: %d", r.link.in_flight)
	testing.expectf(t, ticks < 1000, "the host went round %d times in 300 ms, probing past CALL_ALIVE", ticks)
	testing.expect(t, world_run(&w, client_done, &c, 60 * time.Second))
	client_destroy(&c, th)
}

// Review, round 11. A link closed as it sends (given up, or closed) is let go of then, its session with it: not when
// next looked at, seconds later, meanwhile a session that is ready and not closing, on which a call would be lost.
@(test)
closed_links_let_go_at_once :: proc(t: ^testing.T) {
	for direct in ([]bool{false, true}) {
		w: World
		testing.expect(t, world_init(t, &w, udp = direct))
		defer world_destroy(&w)
		testing.expect(t, world_ready(&w, direct = direct))
		e: Echo
		testing.expect(t, echo_start(&e))
		defer echo_stop(&e)
		open_port = u16(e.port)
		w.hosts[2].port_permitted = permit_open_port
		g: Gate
		testing.expect(t, gate_open(&g, &w, u16(e.port)))
		defer gate_close(&g)
		c := Client{port = g.port, send = 64 << 10, read_too = true}
		th := client_start(&c)
		testing.expect(t, world_run(&w, client_done, &c))
		client_destroy(&c, th)
		a := world_space(&w, 1)
		session: ^zsp.Session
		if direct {
			for p in w.hosts[1].udp.links {
				if p.session != nil {
					session = p.session
					pipe.link_close(p.link)
				}
			}
		} else {
			testing.expect_value(t, len(a.relayed), 1)
			session = a.relayed[0].session
			pipe.link_close(a.relayed[0].link)
		}
		testing.expect(t, session != nil)
		id := session.id if session != nil else 0
		host_settle(&w.hosts[1])
		testing.expectf(t, zsp.node_session(&a.node, id) == nil, "direct %v: its session still there once the host has settled", direct)
	}
}

// Review, round 12. Told by the other end that a link a relay carries is closed, a device lets it go then, its session
// with it: not when it next settles, meanwhile a session ready and not closing, on which a call would be lost.
@(test)
relayed_closed_by_the_peer_let_go_at_once :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	open_port = u16(e.port)
	w.hosts[2].port_permitted = permit_open_port
	g: Gate
	testing.expect(t, gate_open(&g, &w, u16(e.port)))
	defer gate_close(&g)
	c := Client{port = g.port, send = 4096, read_too = true}
	th := client_start(&c)
	testing.expect(t, world_run(&w, client_done, &c))
	client_destroy(&c, th)
	a, b := world_space(&w, 1), world_space(&w, 2)
	testing.expect(t, len(a.relayed) == 1 && len(b.relayed) == 1)
	if len(a.relayed) != 1 || len(b.relayed) != 1 {
		return
	}
	id := a.relayed[0].session.id
	pipe.link_close(b.relayed[0].link) // as RELAY_IDLE does
	host_settle(&w.hosts[2])
	// The relay and b go on; a only takes in what comes, and settles nothing.
	heard := false
	for until := time.tick_add(time.tick_now(), 5 * time.Second); !heard && time.tick_diff(time.tick_now(), until) > 0; {
		host_settle(&w.hosts[0])
		host_settle(&w.hosts[2])
		_ = nbio.tick(time.Millisecond)
		heard = len(a.relayed) == 0 || a.relayed[0].link.state == .Closed
	}
	testing.expect(t, heard)
	testing.expectf(t, zsp.node_session(&a.node, id) == nil && len(a.relayed) == 0, "its session still there, told it was closed")
}
