package host

import win32 "core:sys/windows"

// On Windows a file another has open, without having let it be deleted, cannot be replaced; and one being replaced
// cannot be opened for a moment. So what is kept here is read letting it be replaced meanwhile, and a replacement
// waits a while for whoever else has it open (another process reading it, a scanner) rather than failing for them.
FILE_BUSY_WAIT :: 2_000 // milliseconds, at most

@(private)
file_busy :: proc(err: win32.DWORD) -> bool {
	return err == win32.ERROR_ACCESS_DENIED || err == win32.ERROR_SHARING_VIOLATION
}

// The whole of a file, or false if there is none.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	name := win32.utf8_to_wstring(path, context.temp_allocator)
	handle := win32.INVALID_HANDLE_VALUE
	for waited := 0; ; waited += 5 {
		handle = win32.CreateFileW(name, win32.GENERIC_READ, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, nil, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, nil)
		if handle != win32.INVALID_HANDLE_VALUE || !file_busy(win32.GetLastError()) || waited >= FILE_BUSY_WAIT {
			break
		}
		win32.Sleep(5)
	}
	if handle == win32.INVALID_HANDLE_VALUE {
		return
	}
	defer win32.CloseHandle(handle)
	out := make([dynamic]byte, 0, 4096, allocator)
	for {
		if len(out) == cap(out) {
			reserve(&out, 2 * cap(out))
		}
		n: win32.DWORD
		room := out[len(out):cap(out)]
		if !win32.ReadFile(handle, raw_data(room), win32.DWORD(len(room)), &n, nil) {
			delete(out)
			return
		}
		if n == 0 {
			return out[:], true
		}
		non_zero_resize(&out, len(out) + int(n))
	}
}

// Puts one file in another's place, whole.
@(private)
replace_file :: proc(from, to: string) -> bool {
	a := win32.utf8_to_wstring(from, context.temp_allocator)
	b := win32.utf8_to_wstring(to, context.temp_allocator)
	for waited := 0; ; waited += 5 {
		if win32.MoveFileExW(a, b, win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH) {
			return true
		}
		if !file_busy(win32.GetLastError()) || waited >= FILE_BUSY_WAIT {
			return false
		}
		win32.Sleep(5)
	}
}
