// Reproduces odin-lang/Odin#8647: on Windows, core:nbio's wait of under a millisecond is no wait; the loop spins.
//
// __tick gives GetQueuedCompletionStatusEx the wait as DWORD(d / time.Millisecond), truncated (impl_windows.odin,
// compute_timeout): a wait of under a millisecond, asked of a tick or to a timeout due that soon, is a poll, and the
// loop goes round until it is over. Here a loop is ticked with a wait of half a millisecond for 30 ms, with a timeout
// a second off outstanding; and through twenty timeouts 0.9 ms apart, ticked with no limit. Waiting, it goes round at
// most once for each millisecond, as Windows wakes it on its timer: some 60 and some 40 times at most.
//
// Prints one line and exits 0: "BROKEN: ..." if either went round more than 300 times, or "FIXED: ..." if neither did.
// Anything else (a timeout that never came, a crash) is the repro's own failure. Meaningful on Windows; elsewhere the
// loop waits in nanoseconds, and it says FIXED.
//
// Run by .github/workflows/upstream.yml, not by ./x test; tests/upstream/run.sh runs it. The copy third_party/nbio is
// dropped once a release has this fixed, with odin-lang/Odin#8642, #8644 and #8645.
package odin_8647

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:time"

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}

	waiting := nbio.timeout(time.Second, proc(_: ^nbio.Operation) {})
	short := 0
	start := time.tick_now()
	for time.tick_since(start) < 30 * time.Millisecond {
		nbio.tick(500 * time.Microsecond)
		short += 1
	}
	nbio.remove(waiting)

	left := 20
	next :: proc(_: ^nbio.Operation, left: ^int) {
		left^ -= 1
		if left^ > 0 {
			nbio.timeout_poly(900 * time.Microsecond, left, next)
		}
	}
	nbio.timeout_poly(900 * time.Microsecond, &left, next)
	chained := 0
	start = time.tick_now()
	for left > 0 && time.tick_since(start) < 5 * time.Second {
		nbio.tick()
		chained += 1
	}
	if left > 0 {
		fmt.eprintfln("%d of 20 timeouts never came", left)
		os.exit(2)
	}
	fmt.printfln("%s: ticks of 0.5 ms for 30 ms went round %d times; twenty timeouts of 0.9 ms, %d times",
		"BROKEN" if short > 300 || chained > 300 else "FIXED", short, chained)
}
