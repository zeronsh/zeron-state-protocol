package host

import "core:os"
import "../zsp"

// Fsyncs the loop does not wait for: the log's, when commits are due to be made durable (zsp.Disk.log_sync_start).
// Each is the system's own call, as os.sync makes it, and as strong: here it is only not waited for. On Linux io_uring
// does it, on a kernel worker of its own (fsync_linux.odin); elsewhere a thread of the host's (fsync_other.odin). What
// it said is handed to the store at the next settle, by the token the store gave, and only then does the store count
// on it: an acknowledgement waits for it as it waited for the fsync before.
//
// A file being made durable is not closed until that is done, whoever lets go of it meanwhile (fsync_release): its
// descriptor could otherwise be another file's by the time the fsync is made of it.

@(private)
Fsync :: struct {
	host:  ^Host,
	file:  ^os.File,
	token: u64,
	ok:    bool,
	close: bool, // let go of meanwhile: closed once this is done
	next:  ^Fsync, // of those done, waiting to be handed over (fsync_other.odin)
}

// Begins making a file durable, for the store whose token this is. False if it could not be begun.
@(private)
fsync_start :: proc(h: ^Host, f: ^os.File, token: u64) -> bool {
	fs := new(Fsync)
	fs.host, fs.file, fs.token = h, f, token
	append(&h.fsyncing, fs)
	if f == nil {
		// Nothing to make durable: done, and said so at the next settle, which host_deadline has come at once.
		fs.ok, fs.next, h.fsync_ready = true, h.fsync_ready, fs
		return true
	}
	if !fsync_submit(fs) {
		pop(&h.fsyncing)
		free(fs)
		return false
	}
	return true
}

// Closes a file, or has it closed once it has been made durable, if it is being.
@(private)
fsync_release :: proc(h: ^Host, f: ^os.File) {
	if h != nil {
		for fs in h.fsyncing {
			if fs.file == f {
				fs.close = true
				return
			}
		}
	}
	os.close(f)
}

// Hands each store what the disk said of what it was making durable. On the loop's thread, at the start of a settle.
@(private)
fsync_collect :: proc(h: ^Host) {
	done := fsync_done(h)
	if h.fsync_ready != nil {
		last := h.fsync_ready
		for last.next != nil {
			last = last.next
		}
		last.next, done, h.fsync_ready = done, h.fsync_ready, nil
	}
	for done != nil {
		fs := done
		done = fs.next
		for x, i in h.fsyncing {
			if x == fs {
				unordered_remove(&h.fsyncing, i)
				break
			}
		}
		if fs.close && fs.file != nil {
			os.close(fs.file)
		}
		for s in h.spaces {
			if zsp.store_awaits(&s.node.store, fs.token) {
				zsp.store_disk_synced(&s.node.store, fs.token, fs.ok)
			}
		}
		free(fs)
	}
}

// Waits for every fsync under way, as the host is let go of: none may outlive what it would hand its answer to.
@(private)
fsync_drain :: proc(h: ^Host) {
	for len(h.fsyncing) > 0 {
		if h.fsync_ready == nil {
			fsync_wait(h)
		}
		fsync_collect(h)
	}
	fsync_destroy(h)
	delete(h.fsyncing)
}
