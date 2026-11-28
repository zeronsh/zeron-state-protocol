#+build windows
package host

import win32 "core:sys/windows"

// A link at `link` to `target`, for a test: whether it could be made.
@(private)
link_for_test :: proc(target, link: string) -> bool {
	SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE :: 0x2
	return bool(win32.CreateSymbolicLinkW(win32.utf8_to_wstring(link, context.temp_allocator), win32.utf8_to_wstring(target, context.temp_allocator), SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE))
}

// A file made read-only, for a test, as Windows marks one: whether it could be.
@(private)
read_only_for_test :: proc(path: string) -> bool {
	name := win32.utf8_to_wstring(path, context.temp_allocator)
	return bool(win32.SetFileAttributesW(name, win32.GetFileAttributesW(name) | win32.FILE_ATTRIBUTE_READONLY))
}

// Whether a file is writable by its owner.
@(private)
writable_for_test :: proc(path: string) -> bool {
	return win32.GetFileAttributesW(win32.utf8_to_wstring(path, context.temp_allocator)) & win32.FILE_ATTRIBUTE_READONLY == 0
}
