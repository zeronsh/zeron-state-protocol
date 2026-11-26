package host

import "core:sync"
import "core:testing"
import "core:time"
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
