package host

import "core:os"
import "core:time"
import "../third_party/nbio"

// Here io_uring makes the file durable, on a kernel worker of its own, as fsync(2) does (nbio.Sync): the callback,
// in a tick of the loop, says it is done.
@(private)
Fsyncer :: struct {
	done: ^Fsync,
}

@(private)
fsync_submit :: proc(fs: ^Fsync) -> bool {
	nbio.sync_poly(nbio.Handle(os.fd(fs.file)), fs, proc(op: ^nbio.Operation, fs: ^Fsync) {
		fs.ok = op.sync.err == nil
		fs.next = fs.host.fsyncer.done
		fs.host.fsyncer.done = fs
	})
	return true
}

@(private)
fsync_done :: proc(h: ^Host) -> ^Fsync {
	done := h.fsyncer.done
	h.fsyncer.done = nil
	return done
}

@(private)
fsync_wait :: proc(h: ^Host) {
	for h.fsyncer.done == nil {
		if nbio.tick(10 * time.Millisecond) != nil {
			return
		}
	}
}

@(private)
fsync_destroy :: proc(_: ^Host) {}
