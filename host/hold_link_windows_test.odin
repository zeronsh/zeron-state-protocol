#+build windows
package host

import win32 "core:sys/windows"

// A link at `link` to `target`, for a test: whether it could be made.
@(private)
link_for_test :: proc(target, link: string) -> bool {
	SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE :: 0x2
	return bool(win32.CreateSymbolicLinkW(win32.utf8_to_wstring(link, context.temp_allocator), win32.utf8_to_wstring(target, context.temp_allocator), SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE))
}
