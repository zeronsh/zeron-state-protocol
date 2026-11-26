#+build windows
package host

import "core:os"
import "core:path/filepath"
import win "core:sys/windows"

// A folder within a share, held open while a file is written in it (see share_dir_posix.odin). Windows names files by
// path alone, so every folder on the way is held open, without leave to delete it, from the share down: none can be
// moved or swapped for another while held. None may be a link or junction, nor the file written.

@(private)
Share_Dir :: struct {
	path:    string, // owned
	handles: [dynamic]win.HANDLE,
}

@(private)
share_dir_open :: proc(root: string, parts: []string, make: bool) -> (d: Share_Dir, status: Status) {
	path := root
	at := -1
	for {
		w := win.utf8_to_wstring(path, context.temp_allocator)
		if w == nil {
			share_dir_close(&d)
			return {}, .Denied
		}
		h := win.CreateFileW(w, win.FILE_LIST_DIRECTORY | win.FILE_TRAVERSE | win.FILE_READ_ATTRIBUTES, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT, nil)
		if h == win.INVALID_HANDLE_VALUE && make && at >= 0 {
			e := win.GetLastError()
			if e == win.ERROR_FILE_NOT_FOUND || e == win.ERROR_PATH_NOT_FOUND {
				if win.CreateDirectoryW(w, nil) || win.GetLastError() == win.ERROR_ALREADY_EXISTS {
					h = win.CreateFileW(w, win.FILE_LIST_DIRECTORY | win.FILE_TRAVERSE | win.FILE_READ_ATTRIBUTES, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT, nil)
				}
			}
		}
		if h == win.INVALID_HANDLE_VALUE {
			e := win.GetLastError()
			share_dir_close(&d)
			return {}, .Not_Found if e == win.ERROR_FILE_NOT_FOUND || e == win.ERROR_PATH_NOT_FOUND else .Denied
		}
		append(&d.handles, h)
		info: win.BY_HANDLE_FILE_INFORMATION
		if !win.GetFileInformationByHandle(h, &info) || info.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 || info.dwFileAttributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			share_dir_close(&d)
			return {}, .Denied if at >= 0 else .Not_Found
		}
		at += 1
		if at == len(parts) {
			break
		}
		path, _ = filepath.join({path, parts[at]}, context.temp_allocator)
	}
	d.path, _ = filepath.join({path}, context.allocator)
	return d, .Ok
}

@(private)
share_dir_close :: proc(d: ^Share_Dir) {
	for h in d.handles {
		win.CloseHandle(h)
	}
	delete(d.handles)
	delete(d.path)
	d^ = {}
}

@(private)
share_in :: proc(d: Share_Dir, name: string) -> win.wstring {
	full, _ := filepath.join({d.path, name}, context.temp_allocator)
	return win.utf8_to_wstring(full, context.temp_allocator)
}

@(private)
share_file_open :: proc(d: Share_Dir, name: string, create := false, truncate := false) -> (f: ^os.File, status: Status) {
	w := share_in(d, name)
	if w == nil {
		return nil, .Denied
	}
	h := win.CreateFileW(w, win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_ALWAYS if create else win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_OPEN_REPARSE_POINT, nil)
	if h == win.INVALID_HANDLE_VALUE {
		e := win.GetLastError()
		return nil, .Not_Found if e == win.ERROR_FILE_NOT_FOUND || e == win.ERROR_PATH_NOT_FOUND else .Denied
	}
	info: win.BY_HANDLE_FILE_INFORMATION
	if win.GetFileType(h) != win.FILE_TYPE_DISK || !win.GetFileInformationByHandle(h, &info) || info.dwFileAttributes & (win.FILE_ATTRIBUTE_DIRECTORY | win.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
		win.CloseHandle(h)
		return nil, .Denied
	}
	if truncate && !win.SetEndOfFile(h) {
		win.CloseHandle(h)
		return nil, .Failed
	}
	return os.new_file(uintptr(h), name), .Ok
}

@(private)
share_kind :: proc(d: Share_Dir, name: string) -> (exists, regular: bool) {
	w := share_in(d, name)
	if w == nil {
		return false, false
	}
	attrs := win.GetFileAttributesW(w)
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		return false, false
	}
	return true, attrs & (win.FILE_ATTRIBUTE_DIRECTORY | win.FILE_ATTRIBUTE_REPARSE_POINT) == 0
}

@(private)
share_rename :: proc(d: Share_Dir, from, to: string) -> bool {
	a, b := share_in(d, from), share_in(d, to)
	return a != nil && b != nil && bool(win.MoveFileExW(a, b, win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH))
}

@(private)
share_remove :: proc(d: Share_Dir, name: string) {
	if w := share_in(d, name); w != nil {
		win.DeleteFileW(w)
	}
}

// A file or folder in a share, opened by its path to read: only one on a disk, as nothing else there is a file.
@(private)
share_open_read :: proc(path: string) -> (f: ^os.File, status: Status) {
	err: os.Error
	f, err = os.open(path, {.Read})
	if err != nil {
		return nil, .Not_Found
	}
	if win.GetFileType(win.HANDLE(os.fd(f))) != win.FILE_TYPE_DISK {
		os.close(f)
		return nil, .Not_Found
	}
	return f, .Ok
}
