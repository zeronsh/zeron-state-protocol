#+build darwin, freebsd, openbsd, netbsd
package host

import "core:container/queue"
import "core:nbio"

// Whether the event loop holds changes back that did not fit what it gives kqueue at once. It gives them only once
// kqueue has answered, and kqueue may wait for ever for what it has not been given: so it is not to wait.
@(private)
loop_held_back :: proc() -> bool {
	return queue.len(nbio.current_thread_event_loop().overflow) > 0
}
