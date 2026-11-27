#+build windows
package main

import "core:sync"
import win32 "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
exits: int // atomic

// A console's first Ctrl+C or Ctrl+Break stops the node politely, and a second ends it at once, as SIGINT and SIGTERM do
// elsewhere. The console's closing, which ends the process once it is answered, waits until the node has stopped, and
// answers then: or before the system's five seconds are up, by the clock, however long its tick makes a wait.
@(test)
console_signals_stop_then_end :: proc(t: ^testing.T) {
	stopped = win32.CreateEventW(nil, true, false, nil)
	defer {
		win32.CloseHandle(stopped)
		stopped = nil
	}
	sync.atomic_store(&stops, 0)
	exit :: proc() {sync.atomic_add(&exits, 1)}
	console_signalled(win32.CTRL_C_EVENT, exit)
	testing.expect(t, sync.atomic_load(&exits) == 0, "the first Ctrl+C ends the process")
	console_signalled(win32.CTRL_BREAK_EVENT, exit)
	testing.expect(t, sync.atomic_load(&exits) == 1, "a second does not")

	start := time.tick_now()
	console_signalled(win32.CTRL_CLOSE_EVENT, exit)
	took := time.tick_since(start)
	// As long as the clock says, within the system's tick, which may end a wait as much early.
	testing.expectf(t, took >= (CLOSE_WAIT - 50) * time.Millisecond && took < 4900 * time.Millisecond, "the console's closing waited %v for a node that did not stop", took)
	testing.expect(t, sync.atomic_load(&exits) == 1, "the console's closing ends the process before the node has stopped")

	later := thread.create_and_start(proc() {
		time.sleep(100 * time.Millisecond)
		stop_over()
	})
	start = time.tick_now()
	console_signalled(win32.CTRL_SHUTDOWN_EVENT, exit)
	took = time.tick_since(start)
	thread.join(later)
	thread.destroy(later)
	testing.expectf(t, took < time.Second, "the system's shutting down waited %v for a node that stopped after 100 ms", took)
}
