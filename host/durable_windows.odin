#+build windows
package host

import "core:os"

// What every sync made for durability here calls: so that what is said to be kept is kept through a loss of power, as
// SPEC says. FlushFileBuffers, which core:os's sync is, on the handle core:os opened, which asks for no write-through or
// unbuffered I/O (FILE_FLAG_WRITE_THROUGH, FILE_FLAG_NO_BUFFERING), so that nothing but the flush writes the file out:
// its data and what the system knows of it, metadata being cached until the file is flushed, and the drive's own cache
// after, which every drive made for Windows 8 and since writes out when told (FLUSH CACHE).
file_durable :: proc(f: ^os.File) -> bool {
	return os.sync(f) == nil
}

// A directory's names, kept: here by the files' own flushes, not the directory's. A flush writes out a file's data and
// what the system holds of it, metadata being cached until the file is flushed or written through ("File Caching");
// a rename is made durable so by MoveFileEx's MOVEFILE_WRITE_THROUGH, which flushes the file moved once it has moved, as
// save does by hand of a file renamed by its handle. A directory's own flush ([MS-FSA] 2.1.5.7) is a whole other
// write, and slow where the disk is (on CI's, it doubled what the end-to-end tests took): nothing said to be durable
// waits on it.
dir_durable :: proc(dir: string) -> bool {
	return true
}
