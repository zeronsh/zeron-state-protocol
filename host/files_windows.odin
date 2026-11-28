package host

foreign import kernel32 "system:Kernel32.lib"

import win32 "core:sys/windows"
import "core:os"
import "core:path/filepath"
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

File_Lock :: distinct win32.HANDLE

// Holds a file's lock against every other process that takes it, until let go of: blocking until it is free.
@(private)
file_lock :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	name := win32.utf8_to_wstring(path, context.temp_allocator)
	// The link itself, should it be one, which is then refused: never followed to wherever it leads.
	handle := win32.CreateFileW(name, win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, nil, win32.OPEN_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_OPEN_REPARSE_POINT, nil)
	if handle == win32.INVALID_HANDLE_VALUE {
		return
	}
	if !plain_file(handle) {
		win32.CloseHandle(handle)
		return
	}
	over: win32.OVERLAPPED
	if !win32.LockFileEx(handle, win32.LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &over) {
		win32.CloseHandle(handle)
		return
	}
	return File_Lock(handle), true
}

// Whether what a handle has open is a file, and neither a link nor a directory.
@(private)
plain_file :: proc(handle: win32.HANDLE) -> bool {
	info: win32.BY_HANDLE_FILE_INFORMATION
	return bool(win32.GetFileInformationByHandle(handle, &info)) && info.dwFileAttributes & (win32.FILE_ATTRIBUTE_REPARSE_POINT | win32.FILE_ATTRIBUTE_DIRECTORY) == 0
}

// A store's directory held: see hold.odin.
Dir_Lock :: distinct win32.HANDLE

// Holds the lock file of a store's directory, made if there is none, without waiting; or says why not.
@(private)
dir_lock :: proc(path: string) -> (lock: Dir_Lock, held: Hold) {
	lock = Dir_Lock(win32.INVALID_HANDLE_VALUE)
	name := win32.utf8_to_wstring(path, context.temp_allocator)
	// Shared for reading and writing, as SQLite opens it, but never for deleting: a lock file removed while held, and made
	// again, would be held again by another. One someone else has open otherwise, as a scanner may, is waited for a while.
	// Writable, as a lock is held only of a file open to be written: one marked read-only is no longer.
	// Nothing is changed of what is no file, a directory or a link, which is refused as it is.
	if attributes := win32.GetFileAttributesW(name); attributes != win32.INVALID_FILE_ATTRIBUTES {
		if attributes & (win32.FILE_ATTRIBUTE_DIRECTORY | win32.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
			return lock, .Failed
		}
		if attributes & win32.FILE_ATTRIBUTE_READONLY != 0 && !win32.SetFileAttributesW(name, attributes & ~win32.FILE_ATTRIBUTE_READONLY) {
			return lock, .Unwritable
		}
	}
	handle := win32.INVALID_HANDLE_VALUE
	start := time.tick_now()
	for {
		// The link itself, should it be one, which is then refused: never followed to wherever it leads.
		handle = win32.CreateFileW(name, win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, nil, win32.OPEN_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_OPEN_REPARSE_POINT, nil)
		if handle != win32.INVALID_HANDLE_VALUE || !file_busy(win32.GetLastError()) || time.tick_since(start) >= FILE_BUSY_WAIT {
			break
		}
		win32.Sleep(1)
	}
	if handle == win32.INVALID_HANDLE_VALUE {
		return lock, .Unwritable if win32.GetLastError() == win32.ERROR_ACCESS_DENIED else .Failed
	}
	if !plain_file(handle) {
		win32.CloseHandle(handle)
		return lock, .Failed
	}
	over := win32.OVERLAPPED {
		Offset = LOCK_AT,
	}
	if !win32.LockFileEx(handle, win32.LOCKFILE_EXCLUSIVE_LOCK | win32.LOCKFILE_FAIL_IMMEDIATELY, 0, LOCK_SIZE, 0, &over) {
		err := win32.GetLastError()
		win32.CloseHandle(handle)
		return lock, .In_Use if err == win32.ERROR_LOCK_VIOLATION else .Failed
	}
	return Dir_Lock(handle), .Held
}

// Whether what is at a path is on a file system shared with other machines, and what kind; and whether there is
// anything there to ask of.
@(private)
path_remote :: proc(path: string) -> (remote: bool, kind: string, found: bool) {
	name := win32.utf8_to_wstring(path, context.temp_allocator)
	handle := win32.CreateFileW(name, win32.FILE_READ_ATTRIBUTES, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, nil, win32.OPEN_EXISTING, win32.FILE_FLAG_BACKUP_SEMANTICS, nil)
	if handle == win32.INVALID_HANDLE_VALUE {
		return
	}
	defer win32.CloseHandle(handle)
	return file_remote(name, handle), "a network share", true
}

// Where a directory is, as the system takes its path: where `..` is only ever taken as written, as it is by the system
// (GetFullPathNameW). For this turn.
dir_real :: proc(dir: string) -> (real: string, ok: bool) {
	if dir == "" {
		return // no path, which would be wherever the process happens to be, is no directory
	}
	whole, err := filepath.abs(dir, context.temp_allocator)
	return whole, err == nil
}

// The names in a directory, for this turn: as the system lists them, with nothing more asked of each.
@(private)
dir_names :: proc(dir: string) -> []string {
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return nil
	}
	names := make([]string, len(files), context.temp_allocator)
	for f, i in files {
		names[i] = f.name
	}
	return names
}

// Lets go of a store's directory, its files being closed already.
dir_unlock :: proc(lock: Dir_Lock) {
	over := win32.OVERLAPPED {
		Offset = LOCK_AT,
	}
	win32.UnlockFileEx(win32.HANDLE(lock), 0, LOCK_SIZE, 0, &over)
	win32.CloseHandle(win32.HANDLE(lock))
}

// Whether a file is of another machine's: as the system says of the drive its path is on, a mapped one or a share; or as
// Node's fs.realpathSync.native finds it, by the path the system has for what was opened, through every link, which is a
// share's (\\?\UNC\server\share\...) for a file of another machine's.
@(private)
file_remote :: proc(name: cstring16, handle: win32.HANDLE) -> bool {
	DRIVE_REMOTE :: 4
	VOLUME_NAME_DOS :: 0
	n := win32.GetFinalPathNameByHandleW(handle, nil, 0, VOLUME_NAME_DOS)
	if n > 0 {
		final := make([]u16, n, context.temp_allocator)
		got := win32.GetFinalPathNameByHandleW(handle, cstring16(raw_data(final)), n, VOLUME_NAME_DOS)
		if got > 0 && got < n && unc(final[:got]) {
			return true
		}
	}
	room: [win32.MAX_PATH + 1]u16
	return bool(GetVolumePathNameW(name, cstring16(raw_data(room[:])), len(room))) && GetDriveTypeW(cstring16(raw_data(room[:]))) == DRIVE_REMOTE
}

@(private = "file")
unc :: proc(path: []u16) -> bool {
	UNC :: `\\?\UNC\`
	if len(path) < len(UNC) {
		return false
	}
	for c, i in transmute([]u8)string(UNC) {
		upper := path[i] - 32 if path[i] >= 'a' && path[i] <= 'z' else path[i]
		if upper != u16(c) {
			return false
		}
	}
	return true
}

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	GetVolumePathNameW :: proc(lpszFileName: cstring16, lpszVolumePathName: cstring16, cchBufferLength: win32.DWORD) -> win32.BOOL ---
	GetDriveTypeW :: proc(lpRootPathName: cstring16) -> win32.UINT ---
}

@(private)
file_unlock :: proc(lock: File_Lock) {
	over: win32.OVERLAPPED
	win32.UnlockFileEx(win32.HANDLE(lock), 0, 1, 0, &over)
	win32.CloseHandle(win32.HANDLE(lock))
}
