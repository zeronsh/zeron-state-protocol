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
stopped: bool // atomic: it is, and what it kept written down

// Ctrl+C or Ctrl+Break, or the console closing or the system shutting down: the host is woken to stop as it should, and
// for the last two, which end the process once this returns, given a few seconds to.
stop_on_signal :: proc(h: rawptr) {
	sync.guard(&stopping_lock)
	stopping = (^host.Host)(h)
	win32.SetConsoleCtrlHandler(proc "system" (kind: win32.DWORD) -> win32.BOOL {
		context = runtime.default_context()
		{
			sync.guard(&stopping_lock)
			if stopping != nil {
				host.host_stop(stopping)
			}
		}
		if kind == win32.CTRL_CLOSE_EVENT || kind == win32.CTRL_SHUTDOWN_EVENT || kind == win32.CTRL_LOGOFF_EVENT {
			for waited := 0; waited < 4500 && !sync.atomic_load(&stopped); waited += 10 {
				win32.Sleep(10)
			}
		}
		return true
	}, true)
}

// The host is about to be let go of: a signal from now on stops nothing that is not stopping already.
stop_done :: proc() {
	sync.guard(&stopping_lock)
	stopping = nil
}

// And it is, and what it kept written down.
stop_over :: proc() {
	sync.atomic_store(&stopped, true)
}
