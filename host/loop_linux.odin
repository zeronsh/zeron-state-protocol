#+build linux
package host

import "core:container/queue"
import "../nbio"

// Whether the event loop holds operations back: some it could not give the system yet (io_uring's ring was full),
// and some done already, whose callbacks wait for the next tick. A tick that waits gives the first only once it has
// waited, and calls the second back only after: and it may wait for ever. So it is not to wait.
@(private)
loop_held_back :: proc() -> bool {
	l := nbio.current_thread_event_loop()
	return queue.len(l.unqueued) > 0 || queue.len(l.completed) > 0
}
