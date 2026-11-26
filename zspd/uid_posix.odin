#+build !windows
package main

import "core:sys/posix"

linux_getuid :: proc() -> u32 {
	return u32(posix.getuid())
}

darwin_getuid :: linux_getuid

// As many open files as the system lets this process have, not the few a shell gives by default (256 on macOS): a
// relay holds a socket for everyone it serves. macOS refuses more than OPEN_MAX however high the hard limit is.
raise_file_limit :: proc() {
	r: posix.rlimit
	if posix.getrlimit(.NOFILE, &r) != .OK || r.rlim_cur >= r.rlim_max {
		return
	}
	want := r.rlim_max
	r.rlim_cur = want
	if posix.setrlimit(.NOFILE, &r) != .OK && want > 10240 {
		r.rlim_cur = 10240
		posix.setrlimit(.NOFILE, &r)
	}
}
