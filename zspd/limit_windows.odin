package main

import "base:runtime"
import "core:sync"
import win32 "core:sys/windows"
import "../host"

raise_file_limit :: proc() {}

stop_signals_held :: proc() {}

@(private)
stopping: ^host.Host // the host a console's signal stops, until it is let go of
@(private)
stopping_lock: sync.Mutex
@(private)
stops: int // atomic: signals heard
@(private)
stopped: win32.HANDLE // an event, set once the host is let go of and what it kept written down

// How long the console's closing, or the system's shutting down, waits for that: less than the five seconds the system
// gives a process before it ends it, by the clock, however long the system's tick makes a wait.
CLOSE_WAIT :: 4500 // milliseconds

// Ctrl+C or Ctrl+Break, or the console closing or the system shutting down: the first wakes the host to stop as it
// should; and for the last two, which end the process once this returns, it is given a few seconds to. A second Ctrl+C
// or Ctrl+Break, should stopping take too long for whoever is waiting, ends it at once.
stop_on_signal :: proc(h: rawptr) {
	sync.guard(&stopping_lock)
	stopping = (^host.Host)(h)
	if stopped == nil {
		stopped = win32.CreateEventW(nil, true, false, nil)
	}
	win32.SetConsoleCtrlHandler(proc "system" (kind: win32.DWORD) -> win32.BOOL {
		context = runtime.default_context()
		return console_signalled(kind, proc() {
			win32.TerminateProcess(win32.GetCurrentProcess(), 1) // and nothing else runs meanwhile, which might wait
		})
	}, true)
}

// What a console's signal does: `exit` ends the process.
@(private)
console_signalled :: proc(kind: win32.DWORD, exit: proc()) -> win32.BOOL {
	closing := kind == win32.CTRL_CLOSE_EVENT || kind == win32.CTRL_SHUTDOWN_EVENT || kind == win32.CTRL_LOGOFF_EVENT
	if sync.atomic_add(&stops, 1) > 0 && !closing {
		exit()
		return true
	}
	stop_host()
	if closing && stopped != nil {
		win32.WaitForSingleObject(stopped, CLOSE_WAIT)
	}
	return true
}

@(private)
stop_host :: proc() {
	sync.guard(&stopping_lock)
	if stopping != nil {
		host.host_stop(stopping)
	}
}

// The host is about to be let go of: a signal from now on stops nothing that is not stopping already.
stop_done :: proc() {
	sync.guard(&stopping_lock)
	stopping = nil
}

// And it is, and what it kept written down.
stop_over :: proc() {
	if stopped != nil {
		win32.SetEvent(stopped)
	}
}
