package host

import "core:os"
import "core:sync"
import "core:thread"
import "../zsp"

// The disk's work the loop does not wait for: the fsyncs of the log and of the page file (zsp.Disk.log_sync_start,
// page_sync_start). A thread of the host's makes each, by os.sync, the same call as the loop made before, so each is
// as strong as it was: here it is only not waited for.
//
// What each file is asked is done in the order it was asked, one thing at a time (Disk_File.queue). An fsync's answer
// is handed to the store at the next settle, by the token the store gave (disk_collect); one asked of several files, as
// a log's of the segments it went on from and the one it is in, is done once all are, and failed if any failed. One
// that failed fails every fsync of its file after it, whoever asked, the store waiting or not: on Linux an fsync's
// failure is told once, to whichever fsync comes first, and a later one would say all is well of what was lost
// (Disk_File.failed). A file let go of (disk_release) is closed once nothing asked of it is left to do: its handle
// could otherwise be another file's by then.
//
// What waits (disk_drain) is only what must: a sync the store cannot go on without, or the host's end. It waits for
// the thread, never for the loop, whose callbacks would be the store's own work again, under it.

@(private)
Disk_Op :: struct {
	file:  ^Disk_File,
	sync:  bool, // always, until writes are made here too
	bytes: [dynamic]byte,
	token: u64, // from the store
	ok:    bool,
	next:  ^Disk_Op, // of those done, not yet seen to
}

@(private)
Disk_File :: struct {
	file:    ^os.File,
	queue:   [dynamic]^Disk_Op, // in order; the first is the thread's
	failed:  bool, // an fsync of it failed: none after is said to have succeeded
	closing: bool, // let go of: closed once its queue is empty
	id:      u64, // never another's, as a handle's address may be once the handle is closed
}

// What the thread is given, and gives back. Guarded by `lock`, but for `files` and `answers`, the loop's alone.
@(private)
Disk_Queue :: struct {
	thread:   ^thread.Thread,
	lock:     sync.Mutex,
	cond:     sync.Cond,
	todo:     [dynamic]^Disk_Op, // given the thread, in turn
	done:     ^Disk_Op,
	stopping: bool,
	files:    [dynamic]^Disk_File,
	ids:      u64, // the last given a file
	groups:   map[u64]Disk_Group, // syncs asked of several files at once, by token
	answers:  [dynamic]Disk_Answer, // what is to be handed to the stores
	// Where set, what would be given the thread is given this instead, which does it whenever, and says so by
	// disk_done: so that a test decides what is done when, and what power lost leaves (see disk_power_test.odin).
	hook:     proc(h: ^Host, op: ^Disk_Op),
	waiting:  proc(h: ^Host), // and this does something, when the loop must wait
	noted:    proc(h: ^Host, f: ^os.File, at: i64, bytes: []byte, truncated: bool), // told of each write the loop makes
	synced:   proc(h: ^Host, f: ^os.File), // and of each fsync it makes itself
}

// Tells a test what the loop wrote, or cut short, of a file, where one asks.
@(private)
disk_noted :: #force_inline proc(h: ^Host, f: ^os.File, at: i64, bytes: []byte, truncated := false) {
	if h != nil && h.disk.noted != nil {
		h.disk.noted(h, f, at, bytes, truncated)
	}
}

@(private)
Disk_Group :: struct {
	left: int,
	ok:   bool,
}

@(private)
Disk_Answer :: struct {
	token: u64,
	ok:    bool,
}

@(private)
disk_file :: proc(h: ^Host, f: ^os.File) -> ^Disk_File {
	for x in h.disk.files {
		if x.file == f && !x.closing {
			return x
		}
	}
	x := new(Disk_File)
	h.disk.ids += 1
	x.file, x.id = f, h.disk.ids
	append(&h.disk.files, x)
	return x
}

@(private)
disk_find :: proc(h: ^Host, f: ^os.File) -> ^Disk_File {
	if h != nil {
		for x in h.disk.files {
			if x.file == f && !x.closing {
				return x
			}
		}
	}
	return nil
}

// Asks an fsync of each of these files, after all asked of it before, as one sync for the store whose token this is.
// With none, the sync is done at once, said so at the next settle (host_deadline comes at once).
@(private)
disk_sync_ask :: proc(h: ^Host, token: u64, files: ..^os.File) {
	if len(files) == 0 {
		append(&h.disk.answers, Disk_Answer{token, true})
		return
	}
	if len(files) > 1 {
		h.disk.groups[token] = {left = len(files), ok = true}
	}
	for f in files {
		x := disk_file(h, f)
		op := new(Disk_Op)
		op.file, op.sync, op.token = x, true, token
		disk_ask(h, x, op)
	}
}

@(private)
disk_ask :: proc(h: ^Host, x: ^Disk_File, op: ^Disk_Op) {
	append(&x.queue, op)
	if len(x.queue) == 1 {
		disk_give(h, op)
	}
}

// Gives the thread what a file is to do next.
@(private)
disk_give :: proc(h: ^Host, op: ^Disk_Op) {
	q := &h.disk
	if q.hook != nil {
		q.hook(h, op)
		return
	}
	if q.thread == nil {
		q.thread = thread.create_and_start_with_poly_data(h, disk_work)
	}
	sync.guard(&q.lock)
	append(&q.todo, op)
	sync.cond_broadcast(&q.cond)
}

@(private = "file")
disk_work :: proc(h: ^Host) {
	q := &h.disk
	sync.lock(&q.lock)
	for {
		for len(q.todo) == 0 && !q.stopping {
			sync.cond_wait(&q.cond, &q.lock)
		}
		if len(q.todo) == 0 {
			break
		}
		op := q.todo[0]
		ordered_remove(&q.todo, 0)
		sync.unlock(&q.lock)
		disk_do(op)
		sync.lock(&q.lock)
		op.next, q.done = q.done, op
		sync.cond_broadcast(&q.cond)
		waker_wake(h)
	}
	sync.unlock(&q.lock)
}

// What the thread does: what the loop did before, the same call.
@(private)
disk_do :: proc(op: ^Disk_Op) {
	op.ok = os.sync(op.file.file) == nil
}

// Where a hook does the work: says it is done.
@(private)
disk_done :: proc(h: ^Host, op: ^Disk_Op) {
	q := &h.disk
	sync.guard(&q.lock)
	op.next, q.done = q.done, op
	sync.cond_broadcast(&q.cond)
}

// Sees to what the thread has done: each file's next given it, files let go of closed, and what each sync said put
// by to be handed to the stores. On the loop's thread; nothing here is the store's.
@(private)
disk_advance :: proc(h: ^Host) {
	q := &h.disk
	done: ^Disk_Op
	{
		sync.guard(&q.lock)
		done, q.done = q.done, nil
	}
	// In the order done, which is each file's own order.
	ordered: [dynamic]^Disk_Op
	defer delete(ordered)
	for op := done; op != nil; op = op.next {
		append(&ordered, op)
	}
	#reverse for op in ordered {
		x := op.file
		assert(len(x.queue) > 0 && x.queue[0] == op)
		ordered_remove(&x.queue, 0)
		x.failed ||= !op.ok
		if op.sync && op.token != 0 {
			ok := op.ok && !x.failed
			if g, grouped := &q.groups[op.token]; grouped {
				g.left -= 1
				g.ok &&= ok
				if g.left == 0 {
					append(&q.answers, Disk_Answer{op.token, g.ok})
					delete_key(&q.groups, op.token)
				}
			} else {
				append(&q.answers, Disk_Answer{op.token, ok})
			}
		}
		delete(op.bytes)
		free(op)
		if len(x.queue) > 0 {
			disk_give(h, x.queue[0])
		} else if x.closing {
			os.close(x.file)
			for y, i in q.files {
				if y == x {
					ordered_remove(&q.files, i)
					break
				}
			}
			disk_file_free(x)
		}
	}
}

// Hands each store what the disk said of what it was making durable. At the start of a settle.
@(private)
disk_collect :: proc(h: ^Host) {
	disk_advance(h)
	q := &h.disk
	for len(q.answers) > 0 {
		a := q.answers[0]
		ordered_remove(&q.answers, 0)
		for s in h.spaces {
			if zsp.store_awaits(&s.node.store, a.token) {
				zsp.store_disk_synced(&s.node.store, a.token, a.ok) // which may ask more, answered later
			}
		}
	}
}

@(private)
disk_file_free :: proc(x: ^Disk_File) {
	delete(x.queue)
	free(x)
}

// Closes a file once all asked of it is done; at once if nothing is. What it is known by until then, or 0 if closed.
@(private)
disk_release :: proc(h: ^Host, f: ^os.File) -> (pending: u64) {
	if x := disk_find(h, f); x != nil {
		if len(x.queue) > 0 {
			x.closing = true
			return x.id
		}
		for y, i in h.disk.files {
			if y == x {
				ordered_remove(&h.disk.files, i)
				break
			}
		}
		disk_file_free(x)
	}
	os.close(f)
	return 0
}

// Waits until all asked of a file is done: for a sync that must be had now, which is made after it. False if any of it
// failed, or ever did. What the syncs said is handed over at the next settle, not now, under whatever the store does.
@(private)
disk_drain :: proc(h: ^Host, f: ^os.File) -> bool {
	x := disk_find(h, f)
	if x == nil {
		return true
	}
	for len(x.queue) > 0 {
		disk_wait(h)
		disk_advance(h)
	}
	return !x.failed
}

// Until the thread has done something more.
@(private)
disk_wait :: proc(h: ^Host) {
	q := &h.disk
	if q.waiting != nil {
		q.waiting(h)
		return
	}
	sync.guard(&q.lock)
	for q.done == nil {
		sync.cond_wait(&q.cond, &q.lock)
	}
}

// Waits until nothing asked is left to do of a file let go of, and so it is closed: before the file is removed, which on
// Windows fails while a handle of it is open, and elsewhere would leave a sync of it to make of nothing.
@(private)
disk_drain_closing :: proc(h: ^Host, id: u64) {
	for disk_known(h, id) {
		disk_wait(h)
		disk_advance(h)
	}
}

// Whether a file let go of, by what disk_release said it is known by, is still to be closed.
@(private)
disk_known :: proc(h: ^Host, id: u64) -> bool {
	if h != nil && id != 0 {
		for x in h.disk.files {
			if x.id == id {
				return true
			}
		}
	}
	return false
}

// Whether anything is still to be done of a file.
@(private)
disk_busy :: proc(h: ^Host, f: ^os.File) -> bool {
	x := disk_find(h, f)
	return x != nil && len(x.queue) > 0
}

// Waits for everything asked, as the host is let go of: none may outlive what it would hand its answer to.
@(private)
disk_end :: proc(h: ^Host) {
	q := &h.disk
	for len(q.files) > 0 {
		busy := false
		for x in q.files {
			busy ||= len(x.queue) > 0
		}
		if !busy {
			break
		}
		disk_wait(h)
		disk_advance(h)
	}
	for x in q.files {
		if x.closing {
			os.close(x.file)
		}
		disk_file_free(x)
	}
	delete(q.files)
	delete(q.groups)
	delete(q.answers)
	if q.thread != nil {
		sync.lock(&q.lock)
		q.stopping = true
		sync.cond_broadcast(&q.cond)
		sync.unlock(&q.lock)
		thread.join(q.thread)
		thread.destroy(q.thread)
	}
	delete(q.todo)
	q^ = {}
}
