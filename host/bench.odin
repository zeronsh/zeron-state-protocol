package host

import "../pipe"
import "../zsp"

// What a bench of real processes asks of a host: see zspd/bench.odin and bench/stalls.py.

// Of every link of a host so far, direct over UDP and through relays: packets sent (all but probes), and of them, lost
// and sent again. Links that have gone took theirs with them.
host_link_packets :: proc(h: ^Host) -> (direct, direct_lost, relayed, relayed_lost: u64) {
	for p in h.udp.links {
		for l in ([]^pipe.Link{p.link, p.answer}) {
			if l != nil {
				direct += l.sent_packets
				direct_lost += l.lost_packets
			}
		}
	}
	for s in h.spaces {
		for r in s.relayed {
			if r.link != nil {
				relayed += r.link.sent_packets
				relayed_lost += r.link.lost_packets
			}
		}
	}
	return
}

// Whether a space has a session with a device, ready, over a direct link.
host_linked :: proc(sp: ^Space, device: zsp.Key32) -> bool {
	for p in sp.host.udp.links {
		if p.space == sp && p.device == device && p.session != nil && p.session.ready {
			return true
		}
	}
	return false
}
