package host

import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

// The lock an open file description holds (F_OFD_SETLK, Linux 3.15): of that one opening, and so held against another of
// this process as against any other's; let go of when the file is closed, by whoever, or the process ends. A process's
// own lock (F_SETLK, lockf) would let a second holder in this process through, and be let go of when any file of its on
// the lock file was closed. It is held against SQLite's locks on the same bytes, by which Node holds a store.
@(private)
lock_held :: proc(fd: posix.FD) -> Hold {
	F_OFD_SETLK :: 37
	lock := linux.FLock {
		type   = .WRLCK,
		whence = .SET,
		start  = LOCK_AT,
		len    = LOCK_SIZE,
	}
	for {
		ret: int
		when size_of(int) == 4 {
			ret = int(linux.syscall(linux.SYS_fcntl64, linux.Fd(fd), F_OFD_SETLK, &lock))
		} else {
			ret = int(linux.syscall(linux.SYS_fcntl, linux.Fd(fd), F_OFD_SETLK, &lock))
		}
		#partial switch linux.Errno(-ret) {
		case .NONE:
			return .Held
		case .EINTR:
			continue
		case .EAGAIN, .EACCES:
			return .In_Use
		case:
			return .Failed
		}
	}
}

// Whether what is at a path is on a file system shared with other machines, and what kind, by what its kernel calls it;
// and whether there is anything there to ask of. Those a machine shares with a virtual one are among them (9p, as WSL's
// /mnt/c, and VirtualBox's, VMware's and Parallels' shared folders), as are those of clusters. FUSE is not: what a FUSE
// file system is, is only its daemon's to say.
@(private)
path_remote :: proc(path: string) -> (remote: bool, kind: string, found: bool) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	st: linux.Stat_FS
	for {
		#partial switch linux.statfs(name, &st) {
		case .NONE:
			remote, kind = remote_magic(u32(st.type))
			return remote, kind, true
		case .EINTR:
			continue
		case:
			return
		}
	}
}

// The kind of file system a statfs magic number is, if one shared with other machines. As web/src/volume-node.ts's.
@(private)
remote_magic :: proc(magic: u32) -> (remote: bool, kind: string) {
	switch magic {
	case 0x6969:
		kind = "nfs"
	case 0x517b:
		kind = "smb"
	case 0xff534d42:
		kind = "cifs"
	case 0xfe534d42:
		kind = "smb2"
	case 0x5346414f, 0x6b414653:
		kind = "afs"
	case 0x73757245:
		kind = "coda"
	case 0x564c:
		kind = "ncp"
	case 0x01021997:
		kind = "9p"
	case 0x00c36400:
		kind = "ceph"
	case 0x0bd00bd0:
		kind = "lustre"
	case 0x47504653:
		kind = "gpfs"
	case 0x01161970:
		kind = "gfs2"
	case 0x7461636f:
		kind = "ocfs2"
	case 0xaad7aaea:
		kind = "panfs"
	case 0x19830326:
		kind = "beegfs"
	case 0x20030528:
		kind = "orangefs"
	case 0xbeefdead:
		kind = "snfs"
	case 0x013111a8:
		kind = "ibrix"
	case 0x786f4256:
		kind = "vboxsf"
	case 0xbacbacbc:
		kind = "vmhgfs"
	case 0x7c7c6673:
		kind = "prl_fs"
	case:
		return
	}
	return true, kind
}
