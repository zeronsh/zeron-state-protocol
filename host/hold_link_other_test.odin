#+build !windows
package host

import "core:os"
import "core:strings"
import "core:sys/posix"

// A link at `link` to `target`, for a test: whether it could be made.
@(private)
link_for_test :: proc(target, link: string) -> bool {
	return os.symlink(target, link) == nil
}

// A file made read-only, for a test, as Unix does: readable by everyone, and writable by nobody.
@(private)
read_only_for_test :: proc(path: string) -> bool {
	return posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), {.IRUSR, .IRGRP, .IROTH}) == .OK
}

// Whether a file is readable and writable by its owner alone.
@(private)
writable_for_test :: proc(path: string) -> bool {
	st: posix.stat_t
	ALL :: posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	return posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK && st.st_mode & ALL == {.IRUSR, .IWUSR}
}

// Whether a file or directory is writable by nobody still; and makes it its owner's to write again.
@(private)
read_only_still_for_test :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK && .IWUSR not_in st.st_mode
}

@(private)
not_read_only_for_test :: proc(path: string) {
	posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
}
