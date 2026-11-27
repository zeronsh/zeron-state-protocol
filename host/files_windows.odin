package host

import "core:fmt"
import win32 "core:sys/windows"
import "core:time"

// On Windows a file another has open, without having let it be deleted, cannot be replaced; and one being replaced
// cannot be opened for a moment. So what is kept here is read letting it be replaced meanwhile, and a replacement
// waits a while for whoever else has it open (another process reading it, a scanner) rather than failing for them.
FILE_BUSY_WAIT :: 2 * time.Second // at most, as the clock says

@(private)
file_busy :: proc(err: win32.DWORD) -> bool {
	return err == win32.ERROR_ACCESS_DENIED || err == win32.ERROR_SHARING_VIOLATION
}

// The whole of a file, or false if there is none.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	name := win32.utf8_to_wstring(path, context.temp_allocator)
	handle := win32.INVALID_HANDLE_VALUE
	start := time.tick_now()
	for {
		handle = win32.CreateFileW(name, win32.GENERIC_READ, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, nil, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, nil)
		if handle != win32.INVALID_HANDLE_VALUE || !file_busy(win32.GetLastError()) || time.tick_since(start) >= FILE_BUSY_WAIT {
			break
		}
		win32.Sleep(1)
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
	start := time.tick_now()
	for {
		if win32.MoveFileExW(a, b, win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH) {
			return true
		}
		if !file_busy(win32.GetLastError()) || time.tick_since(start) >= FILE_BUSY_WAIT {
			return false
		}
		win32.Sleep(1) // which the system's tick may make longer: the time waited is what is counted
	}
}

@(private)
File_Lock :: distinct win32.HANDLE

// Holds a file's lock against every other process that takes it, until let go of: blocking until it is free.
@(private)
file_lock :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	name := win32.utf8_to_wstring(path, context.temp_allocator)
	handle := win32.CreateFileW(name, win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, nil, win32.OPEN_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, nil)
	if handle == win32.INVALID_HANDLE_VALUE {
		return
	}
	over: win32.OVERLAPPED
	if !win32.LockFileEx(handle, win32.LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &over) {
		win32.CloseHandle(handle)
		return
	}
	return File_Lock(handle), true
}

@(private)
file_unlock :: proc(lock: File_Lock) {
	over: win32.OVERLAPPED
	win32.UnlockFileEx(win32.HANDLE(lock), 0, 1, 0, &over)
	win32.CloseHandle(win32.HANDLE(lock))
}

// A name for a file to be written whole before it replaces another: this process's, and this write's.
@(private)
file_staging :: proc(path: string, n: u64) -> string {
	return fmt.tprintf("%s.%d.%d.new", path, win32.GetCurrentProcessId(), n)
}
