#+build linux, darwin
package host

import "core:sys/posix"
import "core:time"

// What this process has used so far: CPU, and the most memory resident at once.
@(private)
usage :: proc() -> (u: Usage) {
	ru: posix.rusage
	if posix.getrusage(.SELF, &ru) == .OK {
		tv :: proc(t: posix.timeval) -> time.Duration {
			return time.Duration(t.tv_sec) * time.Second + time.Duration(t.tv_usec) * time.Microsecond
		}
		u.cpu = tv(ru.ru_utime) + tv(ru.ru_stime)
		u.rss = int(ru.ru_maxrss) * (1 if ODIN_OS == .Darwin else 1024) // bytes there, KiB here
	}
	return
}
