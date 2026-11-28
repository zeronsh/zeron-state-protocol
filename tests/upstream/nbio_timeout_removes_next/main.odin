// Reproduces core:nbio freeing a timeout under its own walk of them (no upstream issue).
// Platform: windows
// Crash: BROKEN
// Ours: FIXED
//
// check_timeouts walks the tree of timeouts due with an iterator that holds the next node while it completes one: a
// callback that removes the next timeout frees that node under the iterator, which goes on from freed memory. Here
// three timeouts are due together, the first removing the second.
//
// Prints one line and exits 0: "BROKEN: ..." if the removed one came all the same, or "FIXED: ..." if it did not and
// the others came. A crash, as stock core:nbio ends with (STATUS_ILLEGAL_INSTRUCTION, no output), is BROKEN too. Run by
// .github/workflows/upstream.yml, through tests/upstream/run.sh, against stock core:nbio and against ours.
package nbio_timeout_removes_next

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:time"

Timeouts :: struct {
	later:             ^nbio.Operation,
	first, last, gone: bool,
}

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}
	o: Timeouts
	o.later = nbio.timeout_poly(30 * time.Millisecond, &o, proc(_: ^nbio.Operation, o: ^Timeouts) { o.gone = true })
	nbio.timeout_poly(60 * time.Millisecond, &o, proc(_: ^nbio.Operation, o: ^Timeouts) { o.last = true })
	nbio.timeout_poly(time.Millisecond, &o, proc(_: ^nbio.Operation, o: ^Timeouts) {
		o.first = true
		nbio.remove(o.later)
	})
	time.sleep(100 * time.Millisecond) // all three due when the loop is next ticked, found in the order they are due
	start := time.tick_now()
	for !o.last && time.tick_since(start) < 5 * time.Second {
		nbio.tick(10 * time.Millisecond)
	}
	if !o.first || !o.last {
		fmt.eprintfln("the first came %v, the last %v", o.first, o.last)
		os.exit(2)
	}
	fmt.printfln("%s: of three timeouts due together, the first removing the second, the second came %v",
		"BROKEN" if o.gone else "FIXED", o.gone)
}
