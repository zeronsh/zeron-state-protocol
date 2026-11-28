// Reproduces odin-lang/Odin#8646: on Windows, core:os's open with .Trunc but not .Create always fails, with
// INVALID_PARAMETER (error 87).
//
// core:os asks CreateFileW for TRUNCATE_EXISTING with FILE_GENERIC_READ and FILE_GENERIC_WRITE, and Windows wants the
// GENERIC_WRITE bit itself for TRUNCATE_EXISTING. Here a file of three bytes is opened {.Write, .Trunc} and
// {.Read, .Write, .Trunc}, each expected to succeed and leave it empty, as on Linux and macOS; and, to show the file is
// one that can be so opened, {.Write, .Create, .Trunc}, which works, and CreateFileW with TRUNCATE_EXISTING and
// GENERIC_READ | GENERIC_WRITE, which works too.
//
// Prints one line and exits 0: "BROKEN: ..." if either opening without .Create failed or left the file as it was, or
// "FIXED: ..." if both emptied it. Anything else (a file that could not be written, the ways that work not working)
// is the repro's own failure. Built for Windows only.
//
// Run by .github/workflows/upstream.yml, not by ./x test; tests/upstream/run.sh runs it. ./x check fails on any open so
// here (tests/odin_lint.py), and host/files_test.odin works round it, until a release has this fixed.
#+build windows
package odin_8646

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

// The file, in a directory of its own made for it, which fail and main remove whatever the end.
dir, path: string

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.remove_all(dir)
	os.exit(2)
}

// The file of three bytes, opened so: what open said, and how long the file is after.
opened :: proc(flags: os.File_Flags) -> (err: os.Error, size: i64) {
	if werr := os.write_entire_file(path, []byte{1, 2, 3}); werr != nil {
		fail("the file could not be written:", werr)
	}
	f: ^os.File
	f, err = os.open(path, flags)
	if err == nil {
		os.close(f)
	}
	fi, serr := os.stat(path, context.temp_allocator)
	if serr != nil {
		fail("the file could not be looked at:", serr)
	}
	return err, fi.size
}

main :: proc() {
	derr: os.Error
	dir, derr = os.make_directory_temp("", "odin-8646-*", context.allocator)
	if derr != nil {
		fmt.eprintln("no directory could be made for the file:", derr)
		os.exit(2)
	}
	defer os.remove_all(dir)
	path = fmt.aprintf("%s/file.bin", dir)
	if err, size := opened({.Write, .Create, .Trunc}); err != nil || size != 0 {
		fail(fmt.tprintf("{.Write, .Create, .Trunc}, which works, gave %v and left %d bytes", err, size))
	}
	_ = os.write_entire_file(path, []byte{1, 2, 3})
	h := win.CreateFileW(win.utf8_to_wstring(path), win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.TRUNCATE_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE {
		fail("CreateFileW with TRUNCATE_EXISTING and GENERIC_WRITE, which works, failed:", win.GetLastError())
	}
	win.CloseHandle(h)
	said: [dynamic]string
	broken := false
	for flags in ([]os.File_Flags{{.Write, .Trunc}, {.Read, .Write, .Trunc}}) {
		err, size := opened(flags)
		append(&said, fmt.tprintf("%v gave %v and left %d bytes", flags, err, size))
		broken ||= err != nil || size != 0
	}
	fmt.printfln("%s: %s", "BROKEN" if broken else "FIXED", strings.join(said[:], "; ", context.temp_allocator))
}
