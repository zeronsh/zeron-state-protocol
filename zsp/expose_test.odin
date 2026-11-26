#+build !js
package zsp

import "core:strings"
import "core:testing"

// A 40 Expose is taken whole or not at all (§17): every prefix valid, every nonce whole, no more than allowed, and
// nothing after the last.
@(test)
expose_frames_sound_throughout :: proc(t: ^testing.T) {
	frame :: proc(prefixes: ..string) -> [dynamic]byte {
		w := make([dynamic]byte, context.temp_allocator)
		write_varint(&w, u64(len(prefixes)))
		for p in prefixes {
			write_bytes(&w, transmute([]byte)p)
			nonce: [EXPOSE_NONCE]byte
			append(&w, ..nonce[:])
		}
		return w
	}
	testing.expect(t, expose_frame_sound(frame()[:], 16))
	testing.expect(t, expose_frame_sound(frame("", "web", "a-b")[:], 16))
	testing.expect(t, !expose_frame_sound(frame("web", "Web")[:], 16))
	testing.expect(t, !expose_frame_sound(frame("web", strings.repeat("x", EXPOSE_PREFIX_MAX + 1, context.temp_allocator))[:], 16))
	testing.expect(t, !expose_frame_sound(frame("a", "b", "c")[:], 2))
	trailing := frame("web")
	append(&trailing, 0)
	testing.expect(t, !expose_frame_sound(trailing[:], 16))
	short := frame("web")
	testing.expect(t, !expose_frame_sound(short[:len(short) - 1], 16))
	testing.expect(t, !expose_frame_sound({}, 16))
}

// A call goes by the newest session to the device, by id, wherever closing has left it in the list or waking has put
// it; and by one that replicates over one only for calls.
@(test)
call_session_newest :: proc(t: ^testing.T) {
	n: Node
	defer delete(n.sessions)
	a, b: Key32
	a[0], b[0] = 1, 2
	stale := Session{id = 4, ready = true, role = .Peer, peer = a}
	live := Session{id = 5, ready = true, role = .Peer, peer = a}
	other := Session{id = 3, ready = true, role = .Peer, peer = b}
	calls := Session{id = 9, ready = true, role = .Calls, peer = a}
	gone := Session{id = 7, ready = true, closing = true, role = .Peer, peer = a}
	append(&n.sessions, &other, &live, &calls, &gone, &stale) // as closing and waking may leave them
	testing.expect(t, call_session(&n, a) == &live)
	testing.expect(t, call_session(&n, b) == &other)
	clear(&n.sessions)
	append(&n.sessions, &calls)
	testing.expect(t, call_session(&n, a) == &calls)
}
