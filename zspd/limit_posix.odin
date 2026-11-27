#+build !windows
package main

import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "../host"

// As many open files as the system lets this process have, not the few a shell gives by default (256 on macOS): a
// relay holds a socket for everyone it serves. macOS refuses more than OPEN_MAX however high the hard limit is: then
// 10240, unless what it had was more.
raise_file_limit :: proc() {
	r: posix.rlimit
	if posix.getrlimit(.NOFILE, &r) != .OK || r.rlim_cur >= r.rlim_max {
		return
	}
	had := r.rlim_cur
	r.rlim_cur = r.rlim_max
	if posix.setrlimit(.NOFILE, &r) != .OK && had < 10240 && r.rlim_max > 10240 {
		r.rlim_cur = 10240
		posix.setrlimit(.NOFILE, &r)
	}
}

@(private)
stopping: ^host.Host // the host a signal stops, until it is let go of
@(private)
stopping_lock: sync.Mutex

@(private)
stop_set :: proc() -> (set: posix.sigset_t) {
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	return
}

// Keeps SIGINT and SIGTERM from ending the process where it stands: called first, before there is another thread to
// take them instead.
stop_signals_held :: proc() {
	set := stop_set()
	posix.pthread_sigmask(.BLOCK, &set, nil)
}

// And then hears them, on a thread of its own, which wakes the host to stop as it should: the first lets it finish what
// it is doing and write down what it keeps; a second, should that take too long for whoever is waiting, ends it.
stop_on_signal :: proc(h: rawptr) {
	sync.guard(&stopping_lock)
	stopping = (^host.Host)(h)
	thread.create_and_start(proc() {
		set := stop_set()
		for stops := 0; ; stops += 1 {
			sig: posix.Signal
			if posix.sigwait(&set, &sig) != .NONE {
				continue
			}
			if stops > 0 {
				os.exit(1)
			}
			sync.guard(&stopping_lock)
			if stopping != nil {
				host.host_stop(stopping)
			}
		}
	})
}

// The host is about to be let go of: a signal from now on stops nothing that is not stopping already.
stop_done :: proc() {
	sync.guard(&stopping_lock)
	stopping = nil
}

// And it is, and what it kept written down: nothing waits on that here.
stop_over :: proc() {}
