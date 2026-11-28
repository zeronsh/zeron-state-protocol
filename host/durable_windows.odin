#+build windows
package host

import "core:os"
import win32 "core:sys/windows"

// What every sync made for durability here calls: so that what is said to be kept is kept through a loss of power, as
// SPEC says. FlushFileBuffers, which core:os's sync is, on the handle core:os opened, which asks for no write-through or
// unbuffered I/O (FILE_FLAG_WRITE_THROUGH, FILE_FLAG_NO_BUFFERING), so that nothing but the flush writes the file out:
// its data and what the system knows of it, metadata being cached until the file is flushed, and the drive's own cache
// after, which every drive made for Windows 8 and since writes out when told (FLUSH CACHE).
file_durable :: proc(f: ^os.File) -> bool {
	return os.sync(f) == nil
}

// A directory, kept as it is now: the names made or changed in it. That a flush of a file made or renamed keeps its name
// too is nowhere said; that one of the directory keeps all that is in it, on NTFS, is ([MS-FSA] 2.1.5.7, which other
// file systems take as done). Flushed by a handle of its own, open to be written, as a flush must be.
dir_durable :: proc(dir: string) -> bool {
	name := win32.utf8_to_wstring(dir if dir != "" else ".", context.temp_allocator)
	share := u32(win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE)
	handle := win32.CreateFileW(name, win32.GENERIC_WRITE, share, nil, win32.OPEN_EXISTING, win32.FILE_FLAG_BACKUP_SEMANTICS, nil)
	if handle == win32.INVALID_HANDLE_VALUE {
		return false
	}
	defer win32.CloseHandle(handle)
	return bool(win32.FlushFileBuffers(handle))
}
