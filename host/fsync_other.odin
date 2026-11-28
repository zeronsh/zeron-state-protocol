#+build !linux
package host

import "core:os"
import "core:sync"
import "core:thread"

// No system here makes a file durable without the caller waiting: a thread of the host's does, by os.sync, as the
// loop did before, and wakes the loop when it has (waker_wake, which is never lost).
@(private)
Fsyncer :: struct {
	thread:   ^thread.Thread,
	lock:     sync.Mutex,
	cond:     sync.Cond,
	queue:    [dynamic]^Fsync, // to be made durable, in turn
	done:     ^Fsync,
	stopping: bool,
}

@(private)
fsync_submit :: proc(fs: ^Fsync) -> bool {
	h := fs.host
	y := &h.fsyncer
	if y.thread == nil {
		y.thread = thread.create_and_start_with_poly_data(h, fsync_work)
		if y.thread == nil {
			return false
		}
	}
	sync.guard(&y.lock)
	append(&y.queue, fs)
	sync.cond_broadcast(&y.cond)
	return true
}

@(private = "file")
fsync_work :: proc(h: ^Host) {
	y := &h.fsyncer
	sync.lock(&y.lock)
	for {
		for len(y.queue) == 0 && !y.stopping {
			sync.cond_wait(&y.cond, &y.lock)
		}
		if len(y.queue) == 0 {
			break
		}
		fs := y.queue[0]
		ordered_remove(&y.queue, 0)
		sync.unlock(&y.lock)
		ok := os.sync(fs.file) == nil
		sync.lock(&y.lock)
		fs.ok = ok
		fs.next = y.done
		y.done = fs
		sync.cond_broadcast(&y.cond)
		waker_wake(h)
	}
	sync.unlock(&y.lock)
}

@(private)
fsync_done :: proc(h: ^Host) -> ^Fsync {
	y := &h.fsyncer
	sync.guard(&y.lock)
	done := y.done
	y.done = nil
	return done
}

@(private)
fsync_wait :: proc(h: ^Host) {
	y := &h.fsyncer
	sync.guard(&y.lock)
	for y.done == nil { // and one is under way, or this would not be asked
		sync.cond_wait(&y.cond, &y.lock)
	}
}

@(private)
fsync_destroy :: proc(h: ^Host) {
	y := &h.fsyncer
	if y.thread == nil {
		return
	}
	sync.lock(&y.lock)
	y.stopping = true
	sync.cond_broadcast(&y.cond)
	sync.unlock(&y.lock)
	thread.join(y.thread)
	thread.destroy(y.thread)
	delete(y.queue)
	y^ = {}
}
