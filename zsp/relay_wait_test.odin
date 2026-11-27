#+build !js
package zsp

import "core:testing"

// A relay that knows no roster yet cannot say who belongs, and so says nothing yet: a device that has joined, with no
// roster either, waits there until a member brings one, and is admitted the moment it comes. Turned away instead, it
// would ask again only after a while that grows each time, however soon the roster came.
@(test)
review_relay_without_roster_waits :: proc(t: ^testing.T) {
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
	defer sim_destroy(&s)
	a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	testing.expect(t, relay.node.roster.serial == 0, "the relay knows a roster already")
	// b has joined: it has its own keys, and nothing of the space but its id.
	node_destroy(&b.node)
	memory_disk_destroy(&b.disk)
	b.disk = {}
	delete(b.roster)
	delete(b.roster_old)
	delete(b.kept)
	b.roster, b.roster_old, b.kept = nil, nil, nil
	keyring_destroy(&b.keys)
	keyring_init(&b.keys, b.secret)
	b.bare = true
	sim_boot(&s, b)
	testing.expect(t, b.node.roster.serial == 0)

	sim_link(&s, 1, 2) // b dials the relay, before anyone who has the roster does
	sim_settle(&s)
	to_b := s.links[0].b
	testing.expectf(t, to_b.fault == .None && !to_b.closing, "the relay turned b away: %v", to_b.fault)
	testing.expect(t, !to_b.ready, "the relay took b for a member with no roster to say so")

	sim_link(&s, 0, 2) // a brings the roster
	sim_settle(&s)
	testing.expect(t, to_b.ready && to_b.fault == .None, "b was not admitted when the roster came")
	testing.expectf(t, b.node.roster.serial == a.node.roster.serial, "b has roster %x, not %x", b.node.roster.serial, a.node.roster.serial)
	testing.expect(t, node_member(&b.node), "b is not a member by it")
}
