#+build darwin
package host

import "core:os"
import "core:strings"
import "core:testing"

// What the automounter keeps, which the system does not call local, is taken for a file system other machines share: as
// what NFS, SMB and AFP mount is, which no test here can mount.
@(test)
hold_refuses_what_is_not_local :: proc(t: ^testing.T) {
	AUTOFS :: "/System/Volumes/Data/home" // auto_home
	remote, kind, found := path_remote(AUTOFS)
	testing.expectf(t, found, "%s is not there", AUTOFS)
	testing.expectf(t, remote && kind == "autofs", "%s, of %s, is taken for a disk of this machine's own", AUTOFS, kind)
	_, held, _ := dir_try(AUTOFS + "/zsp-hold")
	testing.expectf(t, held == .Remote, "a store in %s is not refused: %v", AUTOFS, held)
}

// Nor is one whose path only passes through a disk of this machine's own on its way there.
@(test)
hold_refuses_what_is_not_local_by_the_way_round :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-hold-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	real, _ := dir_real(dir)
	up := strings.builder_make(context.temp_allocator)
	strings.write_string(&up, dir)
	strings.write_string(&up, "/none")
	for c in real {
		if c == '/' {
			strings.write_string(&up, "/..")
		}
	}
	strings.write_string(&up, "/..") // from none
	strings.write_string(&up, "/System/Volumes/Data/home/zsp-hold")
	_, held, _ := dir_try(strings.to_string(up))
	testing.expectf(t, held == .Remote, "%s is not refused: %v", strings.to_string(up), held)
	testing.expect(t, !os.exists(file_in(dir, "none")))
}
