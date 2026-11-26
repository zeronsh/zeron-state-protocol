package host

import "core:testing"
import "../pipe"
import "../zsp"

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
}

// A device that starts again, its key the same and its port another, is heard from by beacon while the one that dials
// it still has a session on a link to the process that is gone. The dialler knocks anew, on a link beside the old one;
// a beacon from the port the link already has changes nothing.
@(test)
a_device_started_again_is_dialled_again :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	dialler := 1 if string(w.keys[1].device[:]) < string(w.keys[2].device[:]) else 2
	other := 3 - dialler
	h := &w.hosts[dialler]
	p: ^Peer
	for x in h.udp.links {
		if x.device == w.keys[other].device && x.session != nil {
			p = x
		}
	}
	testing.expect(t, p != nil && p.answer == nil)
	if p == nil {
		return
	}
	same := zsp.beacon_seal(&world_space(&w, other).node, int(p.address.port))
	beacon_heard(h, same, p.address)
	testing.expect(t, p.answer == nil, "a beacon from where the link is knocks for nothing")
	moved := p.address
	moved.port += 1
	again := zsp.beacon_seal(&world_space(&w, other).node, int(moved.port))
	beacon_heard(h, again, moved)
	testing.expect(t, p.answer != nil && p.session != nil, "it knocks anew, and keeps the session it has meanwhile")
}
