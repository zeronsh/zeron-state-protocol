package host

import win32 "core:sys/windows"
import "core:time"

// On Windows a file another has open, without having let it be deleted, cannot be replaced; and one being replaced
// cannot be opened for a moment. So what is kept here is read letting it be replaced meanwhile, and a replacement
// waits a while for whoever else has it open (another process reading it, a scanner) rather than failing for them.
FILE_BUSY_WAIT :: 2 * time.Second // at most, as the clock says

// As FILE_BUSY_WAIT, but for a test, which holds a wait to the clock in less time than it takes.
@(private)
file_busy_wait := FILE_BUSY_WAIT

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
		if handle != win32.INVALID_HANDLE_VALUE || !file_busy(win32.GetLastError()) || time.tick_since(start) >= file_busy_wait {
			break
		}
		win32.Sleep(1)
	}
	if handle == win32.INVALID_HANDLE_VALUE {
		return
	}
	defer win32.CloseHandle(handle)
	size: win32.LARGE_INTEGER
	if !win32.GetFileSizeEx(handle, &size) || size < 0 {
		return
	}
	// Room for all of it and a byte more, made once: a read that fills the room finds out whether there is more, as
	// there is of a file that grew since, which is then given room too. One that shrank ends where it ends now.
	out := make([dynamic]byte, allocator)
	if non_zero_reserve(&out, int(size) + 1) != nil {
		return
	}
	for {
		if len(out) == cap(out) && non_zero_reserve(&out, 2 * cap(out)) != nil {
			delete(out)
			return
		}
		n: win32.DWORD
		room := min(cap(out) - len(out), 1 << 30)
		// Into what is reserved past the end, which slicing `out` would refuse: it holds only what is read so far.
		if !win32.ReadFile(handle, &raw_data(out)[len(out)], win32.DWORD(room), &n, nil) {
			delete(out)
			return
		}
		if n == 0 {
			return out[:], true
		}
		non_zero_resize(&out, len(out) + int(n))
	}
}

// Saves bytes as a file, whole or not at all: written to a staging file of its own (see staging.odin), flushed, and put
// in its place. From its making to its renaming the staging file is held by one handle, which lets nobody else open it
// nor delete it: so that staging_clear removes none a save is writing, and what is renamed is what was written.
save :: proc(path: string, bytes: []byte) -> bool {
	whole := full_path(path) or_return // as a rename by handle takes it
	s := staging_make(path) or_return
	if write_file(s.handle, bytes) && win32.FlushFileBuffers(s.handle) && rename_file(s.handle, whole) {
		win32.CloseHandle(s.handle)
		return true
	}
	staging_drop(s)
	return false
}

// A staging file, made and held, until it is let go of: by its handle's being closed.
@(private)
Staging :: struct {
	handle: win32.HANDLE,
}

@(private)
staging_make :: proc(path: string) -> (s: Staging, ok: bool) {
	for _ in 0 ..< STAGING_TRIES {
		name := win32.utf8_to_wstring(staging_name(path), context.temp_allocator)
		s.handle = win32.CreateFileW(name, win32.GENERIC_WRITE | win32.DELETE, 0, nil, win32.CREATE_NEW, win32.FILE_ATTRIBUTE_NORMAL, nil)
		if s.handle != win32.INVALID_HANDLE_VALUE {
			return s, true
		}
		if err := win32.GetLastError(); err != win32.ERROR_FILE_EXISTS && err != win32.ERROR_ALREADY_EXISTS {
			return
		}
		// taken, though it was all but certain not to be
	}
	return
}

// Lets go of a staging file, and of what was written to it.
@(private)
staging_drop :: proc(s: Staging) {
	gone := File_Disposition_Info{delete = true}
	win32.SetFileInformationByHandle(s.handle, .FileDispositionInfo, &gone, size_of(gone))
	win32.CloseHandle(s.handle)
}

// Removes a staging file unless a save holds it, which lets nobody delete it.
@(private)
staging_remove_unheld :: proc(path: string) {
	win32.DeleteFileW(win32.utf8_to_wstring(path, context.temp_allocator))
}

@(private = "file")
File_Disposition_Info :: struct {
	delete: win32.BOOLEAN,
}

@(private = "file")
File_Rename_Info :: struct {
	replace: win32.DWORD, // ReplaceIfExists, a BOOLEAN that shares its place with flags
	root:    win32.HANDLE,
	size:    win32.DWORD, // of the name, in bytes
	name:    [1]u16,
}

@(private = "file")
full_path :: proc(path: string) -> (whole: []u16, ok: bool) {
	name := win32.utf8_to_wstring(path, context.temp_allocator)
	n := win32.GetFullPathNameW(name, 0, nil, nil)
	if n == 0 {
		return
	}
	whole = make([]u16, n, context.temp_allocator)
	got := win32.GetFullPathNameW(name, n, cstring16(raw_data(whole)), nil)
	if got == 0 || got >= n {
		return
	}
	return whole[:got], true
}

@(private = "file")
write_file :: proc(handle: win32.HANDLE, bytes: []byte) -> bool {
	for at := 0; at < len(bytes); {
		n: win32.DWORD
		if !win32.WriteFile(handle, raw_data(bytes[at:]), win32.DWORD(min(len(bytes) - at, 1 << 30)), &n, nil) {
			return false
		}
		at += int(n)
	}
	return true
}

// Puts the file a handle has open in another's place, whole: waiting a while, as long as the clock says, for whoever
// else has that open and does not let it be deleted. Whoever has it open letting it be deleted, as read_file does, keeps
// what they have open, where the system can (NTFS, since Windows 10 1709), as a rename does elsewhere; and is waited for
// where it cannot.
@(private = "file")
rename_file :: proc(handle: win32.HANDLE, to: []u16) -> bool {
	FileRenameInfoEx :: win32.FILE_INFO_BY_HANDLE_CLASS(22)
	REPLACE_IF_EXISTS :: 0x1
	POSIX_SEMANTICS :: 0x2
	room := make([]u64, (size_of(File_Rename_Info) + len(to) * 2 + 7) / 8, context.temp_allocator)
	info := (^File_Rename_Info)(raw_data(room))
	info.size = win32.DWORD(len(to) * 2)
	copy(([^]u16)(&info.name)[:len(to)], to)
	posix := true
	start := time.tick_now()
	for {
		renamed: win32.BOOL
		if posix {
			info.replace = REPLACE_IF_EXISTS | POSIX_SEMANTICS
			renamed = win32.SetFileInformationByHandle(handle, FileRenameInfoEx, info, win32.DWORD(len(room) * 8))
		} else {
			info.replace = 1 // ReplaceIfExists
			renamed = win32.SetFileInformationByHandle(handle, .FileRenameInfo, info, win32.DWORD(len(room) * 8))
		}
		if renamed {
			return true
		}
		err := win32.GetLastError()
		if posix && (err == win32.ERROR_INVALID_PARAMETER || err == win32.ERROR_NOT_SUPPORTED || err == win32.ERROR_INVALID_FUNCTION) {
			posix = false // not on this system or file system: as Windows always did, then
			continue
		}
		if !file_busy(err) || time.tick_since(start) >= file_busy_wait {
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
