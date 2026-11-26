#+build windows
package host

import "core:os"
import "core:strings"
import win "core:sys/windows"

// Where a path really is, every link followed: in temporary memory.
@(private)
path_real :: proc(path: string) -> (real: string, ok: bool) {
	f, err := os.open(path, {.Read})
	if err != nil {
		return
	}
	defer os.close(f)
	return file_real(f)
}

// Where an open file really is, whatever the path it was opened by has become since.
@(private)
file_real :: proc(f: ^os.File) -> (real: string, ok: bool) {
	h := win.HANDLE(os.fd(f))
	buf: [1024]u16
	n := win.GetFinalPathNameByHandleW(h, cstring16(raw_data(buf[:])), u32(len(buf)), 0)
	if n == 0 || int(n) >= len(buf) {
		return
	}
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil {
		return
	}
	// \\?\C:\x is C:\x, and \\?\UNC\server\share is \\server\share.
	switch {
	case strings.has_prefix(s, `\\?\UNC\`):
		s = strings.concatenate({`\\`, s[8:]}, context.temp_allocator)
	case strings.has_prefix(s, `\\?\`):
		s = s[4:]
	}
	return s, true
}

PATH_SEPARATOR :: '\\'
