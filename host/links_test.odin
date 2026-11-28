package host

import "core:net"
import "core:testing"
import "core:time"
import "../pipe"
import "../third_party/nbio"
import "../zsp"

// A host hears by IPv6 wherever the machine has it, beside IPv4 on the same port: on Linux an IPv6 socket of both
// families was refused that port, and a host there had no IPv6. And what arrives by IPv6 has as much room to wait in
// as what arrives by IPv4, so that a loop slow for a moment drops no more of it.
@(test)
both_families_are_heard :: proc(t: ^testing.T) {
	// Whether this machine has IPv6 at all: its loopback, at a port of its own. A plain socket, for this thread has no
	// event loop to tie one of nbio's to (on Windows nbio asserts it can).
	probe, perr := net.make_bound_udp_socket(net.IP6_Loopback, 0)
	has6 := perr == nil
	if perr == nil {
		net.close(probe)
	}
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	for i in 1 ..= 2 {
		u := &w.hosts[i].udp
		testing.expectf(t, u.have6 == has6, "host %d hears by IPv6: %v, where the machine has it: %v", i, u.have6, has6)
		four, err4, _ := nbio.socket_option(u.socket, .Receive_Buffer_Size)
		testing.expectf(t, err4 == nil, "the IPv4 receive buffer: %v", err4)
		if !u.have6 {
			continue
		}
		only, erro, _ := nbio.socket_option(u.socket6, .IPv6_Only)
		testing.expectf(t, erro == nil && only == true, "the IPv6 socket takes IPv4 too: %v (%v)", only, erro)
		six, err6, _ := nbio.socket_option(u.socket6, .Receive_Buffer_Size)
		testing.expectf(t, err6 == nil && six == four, "the IPv6 receive buffer is %v, the IPv4 one %v (%v)", six, four, err6)
	}
	if !has6 || !w.hosts[1].udp.have6 || !w.hosts[2].udp.have6 {
		return
	}

	// And a peer is reached by it: a link between A and B, turned onto IPv6 loopback at each end, carries a call whole,
	// and stays there.
	testing.expect(t, world_ready(&w, direct = true))
	Turn :: struct {
		at: [3]pipe.Address, // where each of A and B is, by IPv6
	}
	turn: Turn
	for i in 1 ..= 2 {
		turn.at[i] = address_from({net.IP6_Loopback, w.hosts[i].udp.port})
	}
	turned :: proc(w: ^World, turn: ^Turn) -> bool {
		all := true
		for pair in ([2][2]int{{1, 2}, {2, 1}}) {
			for x in w.hosts[pair[0]].udp.links {
				if x.device == w.keys[pair[1]].device && x.address != turn.at[pair[1]] {
					x.address = turn.at[pair[1]]
					all = false
				}
			}
		}
		return all
	}
	// Until nothing still on its way by IPv4, heard, turns either back (peer_heard).
	settled := false
	for _ in 0 ..< 10 {
		if settled = turned(&w, &turn); settled {
			break
		}
		world_run(&w, proc(_: ^World, _: rawptr) -> bool {return false}, nil, 200 * time.Millisecond)
	}
	testing.expect(t, settled, "the link stays turned onto IPv6")
	echo_serve(&w.hosts[2])
	p: Pump
	testing.expect(t, pump_start(&p, &w, 1 << 20))
	testing.expect(t, world_run(&w, pump_done, &p))
	testing.expectf(t, pump_whole(&p), "a call by IPv6 loopback: sent %d, back %d, faulted %v", p.sent, p.got, p.faulted)
	for pair in ([2][2]int{{1, 2}, {2, 1}}) {
		for x in w.hosts[pair[0]].udp.links {
			if x.device == w.keys[pair[1]].device {
				testing.expectf(t, x.address == turn.at[pair[1]] && x.session != nil, "host %d's link to %d went to %v", pair[0], pair[1], net.endpoint_to_string(address_to(x.address), context.temp_allocator))
			}
		}
	}
}

// Anyone may have kept an old knock. It neither disturbs a newer one nor stands in its way.
@(test)
knocks_are_heard_once :: proc(t: ^testing.T) {
	mine, theirs, root: zsp.Key32
	for i in 0 ..< 32 {
		mine[i], theirs[i], root[i] = byte(i + 1), byte(i * 3 + 7), byte(i * 5 + 2)
	}
	ours, other: zsp.Keyring
	zsp.keyring_init(&ours, mine)
	zsp.keyring_init(&other, theirs)
	defer zsp.keyring_destroy(&ours)
	defer zsp.keyring_destroy(&other)
	none: zsp.Roster
	d := zsp.draft_from(&none, 1)
	home := zsp.draft_scope(&d)
	zsp.draft_grant(&d, ours.device, ours.signer, home, {.Write}).owner = true
	zsp.draft_grant(&d, other.device, other.signer, home, {.Write})
	roster, ok := zsp.roster_sign(&ours, root, &d, context.temp_allocator)
	testing.expect(t, ok)

	h: Host
	h.secret = mine
	s: Space
	s.host = &h
	m: zsp.Memory_Disk
	defer zsp.memory_disk_destroy(&m)
	testing.expect(t, zsp.node_init(&s.node, zsp.memory_disk(&m), zsp.ed25519_public(root), &ours, true))
	defer zsp.node_destroy(&s.node)
	testing.expect(t, zsp.node_adopt(&s.node, roster))
	append(&h.spaces, &s)
	defer delete(h.spaces)
	defer {
		for p in h.udp.links {
			peer_drop(p)
			delete(p.candidates)
			free(p)
		}
		delete(h.udp.links)
	}

	knock :: proc(t: ^testing.T, h: ^Host, s: ^Space, theirs: zsp.Key32, when_: u64) -> (packet: [pipe.PACKET]byte, size: int) {
		l: pipe.Link
		testing.expect(t, pipe.link_dial(&l, theirs, zsp.x25519_public(h.secret), s.node.space, when_))
		size = len(pipe.link_hello(&l, packet[:]))
		pipe.link_destroy(&l)
		return
	}
	from: pipe.Address
	old, n := knock(t, &h, &s, theirs, 100)
	new, _ := knock(t, &h, &s, theirs, 200)
	peer_answer(&h, old[:n], from)
	testing.expect_value(t, len(h.udp.links), 1)
	p := h.udp.links[0]
	testing.expect(t, p.answer != nil && pipe.link_answers(p.answer, old[:n]))
	// At once, whatever came before it.
	peer_answer(&h, new[:n], from)
	testing.expect(t, pipe.link_answers(p.answer, new[:n]))
	peer_answer(&h, old[:n], from)
	testing.expect(t, pipe.link_answers(p.answer, new[:n]))

	// What a member says of where it is, it is sent to only where that could be it: never port 0, nor everyone.
	h.udp.open = true
	blob: [3 * 18]byte
	for &a, i in ([]pipe.Address{pipe.address_v4(10, 0, 0, 1, 0), pipe.address_v4(255, 255, 255, 255, 9), pipe.address_v4(10, 0, 0, 2, 9)}) {
		copy(blob[i * 18:], a.ip[:])
		blob[i * 18 + 16], blob[i * 18 + 17] = byte(a.port >> 8), byte(a.port)
	}
	links_signalled(&s, other.device, blob[:])
	testing.expectf(t, len(p.candidates) == 1 && p.candidates[0] == pipe.address_v4(10, 0, 0, 2, 9), "candidates %v", p.candidates[:])
	h.udp.open = false

	// A device the roster no longer admits is answered no more, however well it was known: nor is anything kept of it,
	// once the change is seen.
	gone := zsp.draft_from(&s.node.roster, 2)
	zsp.draft_revoke(&gone, other.device, 0)
	revoked, signed := zsp.roster_sign(&ours, root, &gone, context.temp_allocator)
	testing.expect(t, signed && zsp.node_adopt(&s.node, revoked))

	newer, _ := knock(t, &h, &s, theirs, 300)
	peer_answer(&h, newer[:n], from)
	testing.expect(t, !pipe.link_answers(p.answer, newer[:n]), "a revoked device's knock was answered")
	testing.expect(t, peer_for(&s, other.device) == nil, "a revoked device is still a peer")
	peers_admitted(&s)
	testing.expect_value(t, len(h.udp.links), 0)
}

// A beacon from a device while a session with it stands: a live peer answers the poke it brings, and nothing more is
// sent, though the beacon say it is elsewhere (it may be an old one, said again by anyone). One that answers nothing,
// as a process gone does, is sought anew where the beacon said: the dialler knocks there, beside its link, and the other
// tells the dialler where it is.
@(test)
a_device_started_again_is_found_again :: proc(t: ^testing.T) {
	for silent in ([]bool{false, true}) {
		for dial in ([]bool{true, false}) {
			w: World
			testing.expect(t, world_init(t, &w))
			defer world_destroy(&w)
			testing.expect(t, world_ready(&w, direct = true))
			dialler := 1 if string(w.keys[1].device[:]) < string(w.keys[2].device[:]) else 2
			here := dialler if dial else 3 - dialler
			there := 3 - here
			// Where the beacon says it is: a socket of the test's own, to see what is sent there.
			watch, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
			testing.expect(t, err == nil)
			defer net.close(watch)
			nbio.set_socket_option(watch, .Receive_Timeout, time.Duration(200 * time.Millisecond))
			bound, _ := net.bound_endpoint(watch)
			// As a process gone without a word looks from here: what the link sends goes to a socket nobody reads, and
			// nothing comes back on it. Both ends are turned away, for the other is still running, and anything it sent
			// that arrived would be taken for an answer and turn this end back to it (peer_heard). Until nothing still on
			// its way between them has undone either.
			void, verr := net.make_bound_udp_socket(net.IP4_Loopback, 0)
			testing.expect(t, verr == nil)
			defer net.close(void)
			if silent {
				gone, _ := net.bound_endpoint(void)
				turned := false
				for _ in 0 ..< 10 {
					turned = true
					for pair in ([2][2]int{{here, there}, {there, here}}) {
						for x in w.hosts[pair[0]].udp.links {
							if x.device == w.keys[pair[1]].device && x.address != address_from(gone) {
								x.address = address_from(gone)
								turned = false
							}
						}
					}
					if turned {
						break
					}
					world_run(&w, proc(_: ^World, _: rawptr) -> bool {return false}, nil, 200 * time.Millisecond) // what is on its way, heard
				}
				testing.expect(t, turned, "the link stays turned away")
				// The other says something now, as a running process may at any time: it is not heard here.
				for x in w.hosts[there].udp.links {
					if x.device == w.keys[here].device && x.link != nil {
						pipe.link_poke(x.link)
					}
				}
			}
			beacon := zsp.beacon_seal(&world_space(&w, there).node, bound.port)
			beacon_heard(&w.hosts[here], beacon, address_from(net.Endpoint{net.IP4_Loopback, 9}))
			heard := make([dynamic]byte, context.temp_allocator)
			until := time.tick_add(time.tick_now(), SUSPECT_WAIT + time.Second)
			for time.tick_diff(time.tick_now(), until) > 0 && len(heard) == 0 {
				world_run(&w, proc(_: ^World, _: rawptr) -> bool {return false}, nil, 50 * time.Millisecond)
				buf: [2048]byte
				if n, _, rerr := net.recv_udp(watch, buf[:]); rerr == nil && n > 0 {
					append(&heard, buf[0])
				}
			}
			p: ^Peer
			for x in w.hosts[here].udp.links {
				if x.device == w.keys[there].device {
					p = x
				}
			}
			switch {
			case !silent:
				testing.expectf(t, len(heard) == 0, "a live peer, dialler %v: %v sent where the beacon said", dial, heard[:])
				testing.expect(t, p != nil && p.session != nil && p.answer == nil)
			case dial:
				testing.expectf(t, len(heard) > 0 && heard[0] == byte(pipe.Type.First), "dialler: %v", heard[:])
				testing.expect(t, p != nil && p.session != nil && p.answer != nil, "it keeps its session meanwhile")
			case:
				testing.expectf(t, len(heard) > 0 && heard[0] == byte(BEACON), "the other: %v", heard[:])
			}
		}
	}
}
