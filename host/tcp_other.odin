#+build !linux
#+build !darwin
#+build !windows
package host

import "../pipe"

// Where the system's account of its sockets is not read, nothing is found listening, and nobody who connects can be
// told from another user: so forwards here refuse them all, unless whoever runs this says the machine's users are
// one (Config.trust_local_users).

@(private, require_results)
tcp_listening :: proc() -> (list: []pipe.Address, ok: bool) {
	return nil, false
}

@(private, require_results)
tcp_peer_is_mine :: proc(local, remote: pipe.Address) -> bool {
	return false
}
