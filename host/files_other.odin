#+build !windows
package host

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// The whole of a file, or false if there is none.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	err: os.Error
	data, err = os.read_entire_file(path, allocator)
	return data, err == nil
}

// Puts one file in another's place, whole: which a rename does here, whoever has either open.
@(private)
replace_file :: proc(from, to: string) -> bool {
	return os.rename(from, to) == nil
}

// Holds a file's lock against every other process that takes it, until let go of: blocking until it is free.
@(private)
File_Lock :: distinct posix.FD

@(private)
file_lock :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(name, {.RDWR, .CREAT, .CLOEXEC}, posix.mode_t{.IRUSR, .IWUSR})
	if fd < 0 {
		return
	}
	if posix.lockf(fd, .LOCK, 0) != .OK {
		posix.close(fd)
		return
	}
	return File_Lock(fd), true
}

@(private)
file_unlock :: proc(lock: File_Lock) {
	posix.close(posix.FD(lock)) // which lets go of the lock
}

// A name for a file to be written whole before it replaces another: this process's, and this write's.
@(private)
file_staging :: proc(path: string, n: u64) -> string {
	return fmt.tprintf("%s.%d.%d.new", path, posix.getpid(), n)
}
