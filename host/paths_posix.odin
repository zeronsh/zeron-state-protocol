#+build !windows
package host

import "core:os"
import "core:strings"
import "core:sys/posix"

// Where a path really is, every link followed: in temporary memory.
@(private)
path_real :: proc(path: string) -> (real: string, ok: bool) {
	resolved := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator))
	if resolved == nil {
		return
	}
	defer posix.free(rawptr(resolved))
	return strings.clone(string(resolved), context.temp_allocator), true
}

// Where an open file really is, whatever the path it was opened by has become since: so a link swapped in after a
// path was judged cannot carry anyone out of what is shared.
@(private)
file_real :: proc(f: ^os.File) -> (real: string, ok: bool) {
	when ODIN_OS == .Linux {
		fd := posix.FD(os.fd(f))
		buf: [4096]byte
		link := strings.concatenate({"/proc/self/fd/", u16_text(u16(fd))}, context.temp_allocator)
		if fd > 65535 {
			return
		}
		n := posix.readlink(strings.clone_to_cstring(link, context.temp_allocator), raw_data(buf[:]), len(buf))
		if n <= 0 || int(n) >= len(buf) {
			return
		}
		return strings.clone(string(buf[:n]), context.temp_allocator), true
	} else when ODIN_OS == .Darwin {
		fd := posix.FD(os.fd(f))
		F_GETPATH :: 50
		buf: [1024]byte // MAXPATHLEN
		if posix.fcntl(fd, posix.FCNTL_Cmd(F_GETPATH), raw_data(buf[:])) == -1 {
			return
		}
		return strings.clone(string(cstring(raw_data(buf[:]))), context.temp_allocator), true
	} else {
		return "", false // no way to ask: whoever offers files here goes without them
	}
}

PATH_SEPARATOR :: '/'
