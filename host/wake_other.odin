#+build !windows
package host

import "../nbio"

// What wakes the host's loop, from any thread: here core:nbio's own, an eventfd's count or a kqueue event, which is
// kept until the loop next waits, and ends that wait. From the loop's own thread it does nothing, and need not: the
// loop looks at whether it is stopping before it waits.
@(private)
Waker :: struct {}

@(private)
waker_init :: proc(_: ^Host) -> bool {
	return true
}

@(private)
waker_wake :: proc(h: ^Host) {
	nbio.wake_up(h.loop)
}

@(private)
waker_destroy :: proc(_: ^Host) {}
