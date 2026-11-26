#+build linux
package host

import "core:sys/linux"
import "core:sys/linux/uring"

// Whether the kernel will give this process a ring such as the event loop's, now: one let go of by a process that has
// just ended still counts against what may be kept, a while.
ring_free :: proc() -> bool {
	params := uring.DEFAULT_PARAMS
	params.flags += {.SUBMIT_ALL, .COOP_TASKRUN, .SINGLE_ISSUER}
	ring: uring.Ring
	if uring.init(&ring, &params, 2048) != linux.Errno.NONE {
		return false
	}
	uring.destroy(&ring)
	return true
}
