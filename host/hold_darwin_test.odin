#+build darwin
package host

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
