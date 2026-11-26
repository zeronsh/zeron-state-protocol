package main

import "base:runtime"
import "core:nbio"
import "core:net"
import "core:sync"
import "core:thread"

// This process's own standard input and output, for commands that join them to a call: read only as fast as the call
// has credit for, written only as fast as they take it, and never polled. Input is waited for where the system can
// say it is ready (a pipe, a socket, a terminal: console_pollable), or else read by a thread that reads only when asked
// and wakes the loop when it has; output is written by a thread of its own, which says as it goes how much has been
// written, so that the call is credited only for that. The platform's part is in console_posix.odin and
// console_windows.odin.

INPUT_READ :: 64 << 10 // at most, at once
INPUT_FAILED :: -1 // what console_read says of a read that failed
INPUT_AGAIN :: -2 // and of one that found nothing after all

Input :: struct {
	data:     rawptr,
	room:     proc(data: rawptr) -> int, // how much may be read now
	take:     proc(data: rawptr, bytes: []byte), // what was read
	ended:    proc(data: rawptr), // there is no more
	terminal: bool, // keys, and a window's size, rather than bytes (Windows' console)
	started:  bool,
	over:     bool,
	asked:    bool, // a read is under way, or waited for
	poll:     ^nbio.Operation,
	thread:   ^thread.Thread,
	ask:      sync.Sema, // the thread may read
	want:     int, // as much as this
	got:      int, // what it read: bytes, 0 at the end, -1 a failure
	came:     bool, // atomic: got is there
	buf:      [INPUT_READ]byte,
}

// Begins: nothing is read until input_resume finds room.
input_start :: proc(i: ^Input, terminal := false) {
	i.terminal = terminal
	i.started = true
	if console_pollable() {
		return
	}
	i.thread = thread.create_and_start_with_poly_data(i, proc(i: ^Input) {
		for {
			sync.sema_wait(&i.ask)
			i.got = console_read(i, i.buf[:i.want])
			got := i.got
			// Said before waking the loop, which may look as soon as it wakes.
			sync.atomic_store(&i.came, true)
			loop_wake()
			if got == 0 || got == INPUT_FAILED {
				return
			}
		}
	})
}

// Reads, if there is room and nothing is being read already. Said whenever room may have grown.
input_resume :: proc(i: ^Input) {
	if i.over || i.asked || !i.started {
		return
	}
	n := min(i.room(i.data), INPUT_READ)
	if n <= 0 {
		return
	}
	i.asked = true
	if i.thread != nil {
		i.want = n
		sync.sema_post(&i.ask)
		return
	}
	i.poll = nbio.poll_poly(net.TCP_Socket(console_stdin()), .Receive, i, proc(op: ^nbio.Operation, i: ^Input) {
		i.poll = nil
		i.asked = false
		if i.over {
			return
		}
		n := min(i.room(i.data), INPUT_READ)
		if n <= 0 {
			return // resumed when there is room
		}
		// Ready: one read takes what there is, and does not wait.
		input_came(i, console_read(i, i.buf[:n]))
	})
}

// What the thread read, if it has: said after every turn of the loop.
input_settle :: proc(i: ^Input) {
	if i.thread == nil || !sync.atomic_load(&i.came) {
		return
	}
	sync.atomic_store(&i.came, false)
	i.asked = false
	input_came(i, i.got)
}

// Reads no more.
input_stop :: proc(i: ^Input) {
	i.over = true
	if i.poll != nil {
		nbio.remove(i.poll)
		i.poll = nil
	}
}

@(private = "file")
input_came :: proc(i: ^Input, n: int) {
	if n == INPUT_AGAIN {
		input_resume(i) // nothing lost: waited for again
		return
	}
	if n <= 0 {
		i.over = true
		i.ended(i.data)
		return
	}
	i.take(i.data, i.buf[:n])
	input_resume(i)
}

Output_Stream :: enum u8 {
	Stdout,
	Stderr,
}

Output :: struct {
	thread:  ^thread.Thread,
	mutex:   sync.Mutex,
	cond:    sync.Cond, // there is something to write
	drained: sync.Cond, // all there was is written
	queue:   [dynamic]Output_Piece, // guarded by mutex
	owed:    int, // atomic: credit for what has been written, not yet taken
	pending: int, // atomic: pieces not yet written
	broken:  bool, // atomic: a write failed, and nothing more is written
	closed:  bool, // standard output has been closed, or will be once what is queued is written
}

Output_Piece :: struct {
	stream: Output_Stream,
	bytes:  []byte, // owned
	credit: int, // to give back once it is written
	close:  bool, // standard output, after
}

output_start :: proc(o: ^Output) {
	o.queue = make([dynamic]Output_Piece, runtime.heap_allocator())
	o.thread = thread.create_and_start_with_poly_data(o, proc(o: ^Output) {
		for {
			sync.mutex_lock(&o.mutex)
			for len(o.queue) == 0 {
				sync.cond_wait(&o.cond, &o.mutex)
			}
			piece := o.queue[0]
			ordered_remove(&o.queue, 0)
			sync.mutex_unlock(&o.mutex)
			if !sync.atomic_load(&o.broken) && !console_write(piece.stream, piece.bytes) {
				sync.atomic_store(&o.broken, true)
			}
			if piece.close {
				console_close_stdout()
			}
			delete(piece.bytes, runtime.heap_allocator())
			sync.atomic_add(&o.owed, piece.credit)
			sync.mutex_lock(&o.mutex)
			if sync.atomic_sub(&o.pending, 1) == 1 {
				sync.cond_broadcast(&o.drained)
			}
			sync.mutex_unlock(&o.mutex)
			loop_wake()
		}
	})
}

// Waits until all that was queued has been written: for the end, when there is nothing else to wait for.
output_drain :: proc(o: ^Output) {
	if o.thread == nil {
		return
	}
	sync.mutex_lock(&o.mutex)
	for sync.atomic_load(&o.pending) > 0 {
		sync.cond_wait(&o.drained, &o.mutex)
	}
	sync.mutex_unlock(&o.mutex)
}

// Writes bytes, in turn; `credit` is owed back once they are.
output_put :: proc(o: ^Output, stream: Output_Stream, bytes: []byte, credit: int) {
	if o.closed && stream == .Stdout {
		return
	}
	piece := Output_Piece{stream = stream, credit = credit}
	piece.bytes = make([]byte, len(bytes), runtime.heap_allocator())
	copy(piece.bytes, bytes)
	output_queue(o, piece)
}

// Closes standard output once all queued for it is written.
output_close :: proc(o: ^Output) {
	if o.closed {
		return
	}
	o.closed = true
	output_queue(o, {close = true})
}

// Credit for what has been written since this was last asked.
output_owed :: proc(o: ^Output) -> int {
	return sync.atomic_exchange(&o.owed, 0)
}

// Whether all that was queued has been written.
output_idle :: proc(o: ^Output) -> bool {
	return sync.atomic_load(&o.pending) == 0
}

output_broken :: proc(o: ^Output) -> bool {
	return sync.atomic_load(&o.broken)
}

@(private = "file")
output_queue :: proc(o: ^Output, piece: Output_Piece) {
	sync.atomic_add(&o.pending, 1)
	sync.mutex_lock(&o.mutex)
	append(&o.queue, piece)
	sync.mutex_unlock(&o.mutex)
	sync.cond_signal(&o.cond)
}

// Signals, and a terminal's window resized, as POSIX numbers them: whatever caught one sets its bit and wakes the loop,
// which takes them after its turn.
Signal_Set :: distinct bit_set[0 ..< 32; u32]

SIGNAL_HANGUP :: 1
SIGNAL_INTERRUPT :: 2
SIGNAL_QUIT :: 3
SIGNAL_TERMINATE :: 15
SIGNAL_RESIZE :: 28

@(private = "file")
signals_caught: u32 // atomic

signal_caught :: proc "contextless" (signal: int) {
	sync.atomic_or(&signals_caught, u32(1) << uint(signal))
	context = runtime.default_context()
	loop_wake()
}

// The signals caught since this was last asked.
signals_take :: proc() -> Signal_Set {
	return transmute(Signal_Set)sync.atomic_exchange(&signals_caught, 0)
}

// The event loop these threads wake, while there is one: a thread that has just read, written or caught something
// may wake it as it is being let go of, and must not then.
@(private = "file")
loop_awake: ^nbio.Event_Loop
@(private = "file")
loop_guard: sync.Mutex

// Woken by an operation it is given to do, not by nbio.wake_up alone: a loop that is not yet asleep as it is woken so,
// as on Windows, sleeps on as though it had not been, while what it is given it looks for before it sleeps.
@(private = "file")
loop_waker: ^nbio.Operation // made ready on the loop's thread; whoever wakes it takes it

loop_wake :: proc() {
	sync.mutex_lock(&loop_guard)
	if loop_awake != nil && loop_waker != nil {
		op := loop_waker
		loop_waker = nil // and if there is none, one is on its way already, and wakes it
		nbio.exec(op)
	}
	sync.mutex_unlock(&loop_guard)
}

// On the loop's thread: a waker ready for the next who would wake it.
@(private = "file")
loop_waker_ready :: proc() {
	op := nbio.prep_timeout(0, proc(op: ^nbio.Operation) {
		op.detached = false // the loop takes it back after this
		sync.mutex_lock(&loop_guard)
		if loop_awake != nil {
			loop_waker_ready()
		}
		sync.mutex_unlock(&loop_guard)
	})
	nbio.detach(op)
	loop_waker = op
}

// Says which loop to wake, or with nil that there is none to. On that loop's thread.
loop_wakes :: proc(loop: ^nbio.Event_Loop) {
	sync.mutex_lock(&loop_guard)
	loop_awake = loop
	if loop != nil && loop_waker == nil {
		loop_waker_ready()
	} else if loop == nil && loop_waker != nil {
		nbio.reattach(loop_waker) // never done, nor will be
		loop_waker = nil
	}
	sync.mutex_unlock(&loop_guard)
}
