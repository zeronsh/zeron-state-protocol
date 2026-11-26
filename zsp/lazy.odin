package zsp

import "base:runtime"
import "core:slice"

// Storage that may answer "not yet".
//
// A relay whose store lives in object storage holds only some of it at hand. A read of what is not at hand does not
// wait: it is counted (Disk.missed), returns something harmless in its place (an empty page, zeroes), and the host
// starts fetching it. Whatever was being done when it was read is a step, and a step that read something not yet
// at hand is undone, entirely, and done again once the host has fetched what it asked for. Nothing is ever blocked
// and nothing polls: the host says when what was missing has come, and the steps that wanted it run again.
//
// A step is one frame from a peer, one unit of what is sent to one (a change, a task), one record replayed on
// opening, or one piece of a larger piece of work (a job). Undoing it undoes its store transaction (the trees are
// copy-on-write: pages dirty before the step are copied, never changed, until the step is kept), the log it wrote,
// the changes it announced, and what it did to its session (Session_Mark). Steps are written so that what they do
// beyond their session and the store, they do only after every read: to another session, to interests, to the node.
//
// Storage that always answers (Disk.missed is nil) never begins a step, and none of this costs it anything.

// What a page that is not yet at hand reads as: an empty leaf. Nothing is ever written to it.
EMPTY_PAGE: Page

@(private)
Step :: struct {
	active:  bool, // this began the step; else an enclosing one decides
	missed:  int, // reads answered "not yet" before it began
	roots:   [5]Page_No,
	next:    Page_No,
	pending: int,
	clock:   u64,
	forgot:  u64,
	tail:    u64,
	base:    u64,
	used:    int, // of the log buffer
	flushed: int,
	ring:    u64,
}

// Whether reads may answer "not yet".
@(require_results)
store_lazy :: #force_inline proc(s: ^Store) -> bool {
	return s.disk.missed != nil
}

@(private)
store_misses :: #force_inline proc(s: ^Store) -> int {
	return s.disk.missed(s.disk.data) if s.disk.missed != nil else 0
}

// Begins a step, or a part of the step already begun.
@(private)
store_begin :: proc(s: ^Store) -> (t: Step) {
	if !store_lazy(s) {
		return
	}
	t.missed = store_misses(s)
	if s.pager.step {
		return
	}
	t.active = true
	s.step_missed = t.missed
	t.roots = {s.shelf.root, s.cells.root, s.waste.root, s.outbox.root, s.repair.root}
	t.next = s.next
	t.pending = len(s.pending)
	t.clock, t.forgot = s.clock, s.forgot
	t.tail, t.base, t.used, t.flushed = store_tail(s), s.buf_base, len(s.buf), s.flushed
	t.ring = s.events.next
	s.pager.step = true
	return
}

// Whether something read in the step under way was not yet at hand: then whatever else it reads may be nonsense, as it
// may have been asked for by what stood in.
@(private, require_results)
step_doubtful :: proc(s: ^Store) -> bool {
	return store_lazy(s) && s.pager.step && store_misses(s) != s.step_missed
}

// Whether something read since the step, or this part of it, began was not yet at hand.
@(private, require_results)
store_missed :: #force_inline proc(s: ^Store, t: ^Step) -> bool {
	return store_lazy(s) && store_misses(s) != t.missed
}

// Keeps the step or undoes it. A part of a step leaves that to the step.
@(private)
store_end :: proc(s: ^Store, t: ^Step, keep: bool) {
	if !t.active {
		return
	}
	p := &s.pager
	p.step = false
	if keep {
		for no in p.retired {
			if pg, ok := p.dirty[no]; ok {
				free(pg)
				delete_key(&p.dirty, no)
				append(&p.free, no)
			}
		}
		clear(&p.retired)
		clear(&p.fresh)
		return
	}
	for no in p.fresh {
		free(p.dirty[no])
		delete_key(&p.dirty, no)
	}
	clear(&p.fresh)
	clear(&p.retired)
	s.shelf.root, s.cells.root, s.waste.root, s.outbox.root, s.repair.root = t.roots[0], t.roots[1], t.roots[2], t.roots[3], t.roots[4]
	p.next = t.next
	resize(&p.pending, t.pending)
	s.clock, s.forgot = t.clock, t.forgot
	if s.buf_base == t.base && s.flushed <= t.used {
		resize(&s.buf, t.used)
	} else {
		// It went on into another segment, and wrote what it left behind: that goes too.
		s.disk.log_truncate(s.disk.data, t.tail)
		s.buf_base = t.tail
		clear(&s.buf)
		s.flushed = 0
	}
	r := &s.events
	for i in t.ring ..< r.next {
		if k, ok := r.spill[i]; ok {
			delete(k)
			delete_key(&r.spill, i)
		}
	}
	r.next = t.ring
	r.first = min(r.first, r.next)
}

// What a step may change of its session, to be put back should the step be undone.
@(private)
Session_Mark :: struct {
	out, tasks, task_head, refused, unacked: int,
	head:                                     Task,
	cells:                                    Cells_Frame,
	seq_out, cursor, whole_to, seq_in, ack_at: u64,
	whole:                                    Id,
	fault:                                    Fault,
	closing, ready, settled, told:            bool,
}

@(private)
session_mark :: proc(s: ^Session) -> (m: Session_Mark) {
	m = {
		out       = len(s.out),
		tasks     = len(s.tasks),
		task_head = s.task_head,
		refused   = len(s.refused),
		unacked   = len(s.unacked),
		cells     = s.cells,
		seq_out   = s.seq_out,
		cursor    = s.cursor,
		whole_to  = s.whole_to,
		seq_in    = s.seq_in,
		ack_at    = s.ack_at,
		whole     = s.whole,
		fault     = s.fault,
		closing   = s.closing,
		ready     = s.ready,
		settled   = s.settled,
		told      = s.told,
	}
	if s.task_head < len(s.tasks) {
		m.head = s.tasks[s.task_head]
	}
	return
}

@(private)
session_restore :: proc(s: ^Session, m: ^Session_Mark) {
	resize(&s.out, m.out)
	resize(&s.tasks, m.tasks)
	s.task_head = m.task_head
	if s.task_head < len(s.tasks) {
		s.tasks[s.task_head] = m.head
	}
	resize(&s.refused, m.refused)
	resize(&s.unacked, m.unacked)
	s.cells = m.cells
	s.seq_out, s.cursor, s.whole_to, s.seq_in, s.ack_at = m.seq_out, m.cursor, m.whole_to, m.seq_in, m.ack_at
	s.whole = m.whole
	s.fault, s.closing, s.ready, s.settled, s.told = m.fault, m.closing, m.ready, m.settled, m.told
}

// Runs one frame as a step. False if it read something not yet at hand: then it is as though it had not been run,
// and it is run again when that has come.
@(private)
frame_step :: proc(s: ^Session, frame: []byte) -> bool {
	n := s.node
	if !store_lazy(&n.store) {
		if f := session_frame(s, frame); f != .None {
			session_fail(s, f)
		}
		return true
	}
	if n.store.replaying {
		return false
	}
	m := session_mark(s)
	t := store_begin(&n.store)
	outer := n.current
	n.current = &t
	f := session_frame(s, frame)
	if f != .None {
		session_fail(s, f)
	}
	n.current = outer
	if store_missed(&n.store, &t) {
		store_end(&n.store, &t, false)
		session_restore(s, &m)
		return false
	}
	store_end(&n.store, &t, true)
	return true
}

// Tells the step under way that what it read and was not yet at hand was not relied on: the step is kept. Only for
// a step that does nothing after the read that missed, as when a lossy frame is dropped rather than held up.
step_consume :: proc(n: ^Node) {
	if n.current != nil {
		n.current.missed = store_misses(&n.store)
	}
}

// Runs one unit of a session's output as a step. False if it was undone.
@(private)
unit_step :: proc(s: ^Session, unit: proc(s: ^Session, t: ^Task), t: ^Task = nil) -> bool {
	n := s.node
	if !store_lazy(&n.store) {
		unit(s, t)
		return true
	}
	if n.store.replaying {
		return false
	}
	m := session_mark(s)
	step := store_begin(&n.store)
	unit(s, t)
	if store_missed(&n.store, &step) {
		store_end(&n.store, &step, false)
		session_restore(s, &m)
		return false
	}
	store_end(&n.store, &step, true)
	return true
}

// After the host has brought what was missing: everything that waited for it goes on. Returns whether anything is
// still waiting.
node_retry :: proc(n: ^Node) -> (waiting: bool) {
	if !store_lazy(&n.store) {
		return false
	}
	if store_work(&n.store) || sweep_work(n) {
		return true
	}
	for i := 0; i < len(n.sessions); i += 1 {
		s := n.sessions[i]
		if s.stalled && !s.busy {
			session_input(s, nil)
			waiting ||= s.stalled
		}
	}
	return
}

// Work that is done a step at a time where storage may answer "not yet". Returns whether some of it waits.
@(private)
store_work :: proc(s: ^Store) -> (waiting: bool) {
	if s.replaying {
		return replay_steps(s)
	}
	if len(s.dropped) > 0 {
		// What is said of segments a checkpoint dropped goes in a step of its own, as it reads the tree it is in.
		t := store_begin(s)
		for seg in s.dropped {
			tree_delete(s, &s.waste, {0, 0, 0, 0, seg})
		}
		if store_missed(s, &t) {
			store_end(s, &t, false)
			return true
		}
		store_end(s, &t, true)
		clear(&s.dropped)
	}
	if s.repair.root != 0 && repair_steps(s) {
		return true
	}
	return evac_steps(s)
}

SWEEP_STEP :: 2048 // cells gone over in a step

// Goes over what a roster has made unlawful, a step at a time. Once all of it has been, the store says it is held
// against that roster, and sessions compare again whatever may have changed.
@(private)
sweep_work :: proc(n: ^Node) -> (waiting: bool) {
	w := &n.sweep
	for len(w.plans) > 0 {
		at, cursor, started, swept := w.at, w.cursor, w.started, w.swept
		t := store_begin(&n.store)
		done := sweep_step(n, nil, SWEEP_STEP)
		if store_missed(&n.store, &t) {
			store_end(&n.store, &t, false)
			w.at, w.cursor, w.started, w.swept = at, cursor, started, swept
			return true
		}
		store_end(&n.store, &t, true)
		if done {
			n.serial = w.serial
			if w.swept {
				for s in n.sessions {
					s.recompare ||= s.ready
				}
			}
			sweep_reset(w)
		}
	}
	return false
}

EVAC_STEP :: 64 << 10 // bytes of a segment's records moved in a step

// Where storage may answer "not yet", a segment is evacuated a step at a time rather than within a checkpoint:
// what lives in it is copied to the tail, a few records a step, and the checkpoint after the last step drops it.
@(private)
Evacuation :: struct {
	seg:      u64,
	active:   bool,
	pos:      int, // how far through it
	damaged:  bool, // something in it could not be read
	scanning: bool, // and the cells that lay there are being sought
	cursor:   Key,
}

@(private)
evac_steps :: proc(s: ^Store) -> (waiting: bool) {
	for {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		e := &s.evac
		if !e.active {
			if len(s.evacuated) > 0 {
				return false // one at a time: the next checkpoint drops it first
			}
			t := store_begin(s)
			seg, found := evac_victim(s)
			if store_missed(s, &t) {
				store_end(s, &t, false)
				return true
			}
			store_end(s, &t, true)
			if !found {
				return false
			}
			e^ = {seg = seg, active = true}
		}
		saved := e^
		t := store_begin(s)
		finished := evac_scan_step(s) if e.scanning else evac_step(s)
		if store_missed(s, &t) {
			store_end(s, &t, false)
			s.evac = saved
			return true
		}
		store_end(s, &t, true)
		if finished {
			append(&s.evacuated, e.seg)
			e^ = {}
		}
		if s.failed {
			return false
		}
	}
}

// The segment worst wasted, if any is at least half dead.
@(private)
evac_victim :: proc(s: ^Store) -> (seg: u64, ok: bool) {
	scan := tree_scan(s, s.waste, KEY_MIN, KEY_MAX)
	worst: u64
	for leaf in tree_next(&scan) {
		if slice.contains(s.dropped[:], leaf.key[4]) {
			continue
		}
		if leaf.val[0] >= SEGMENT / 2 && leaf.key[4] != store_tail(s) / SEGMENT && leaf.val[0] > worst {
			worst, seg, ok = leaf.val[0], leaf.key[4], true
		}
	}
	return
}

// Moves the next few records. True when the whole segment has been gone over.
@(private)
evac_step :: proc(s: ^Store) -> bool {
	e := &s.evac
	base := e.seg * SEGMENT
	size := int(log_size(s.disk, base, SEGMENT))
	if e.pos >= size {
		return evac_end(s, size)
	}
	window := min(size - e.pos, EVAC_STEP)
	head: [RECORD_HEAD]byte
	if size - e.pos >= RECORD_HEAD && s.disk.log_read(s.disk.data, base + u64(e.pos), head[:]) {
		if want := int(get_u32(head[:])); want > 0 && want <= MAX_RECORD && RECORD_HEAD + want <= size - e.pos {
			window = max(window, RECORD_HEAD + want)
		}
	}
	part := make([]byte, window, context.temp_allocator)
	if !s.disk.log_read(s.disk.data, base + u64(e.pos), part) {
		if !step_doubtful(s) {
			s.failed = true // not "not yet", but never
		}
		return false
	}
	pos := 0
	for pos < len(part) {
		n := record_at(part[pos:])
		if n == 0 {
			if !e.damaged && len(part) - pos == RECORD_HEAD && e.pos + pos + RECORD_HEAD == size && get_u64(part[pos:]) == ROLLED {
				e.pos = size // the mark it ends with
				return evac_end(s, size)
			}
			if len(part) < size - e.pos {
				// Perhaps a record that runs past the window: the next window begins with it.
				if pos + RECORD_HEAD > len(part) {
					break
				}
				if want := int(get_u32(part[pos:])); want > 0 && want <= MAX_RECORD && pos + RECORD_HEAD + want > len(part) && e.pos + pos + RECORD_HEAD + want <= size {
					break
				}
			}
			e.damaged = true
			pos += 1
			continue
		}
		if !relocate(s, base + u64(e.pos + pos + RECORD_HEAD), part[pos + RECORD_HEAD:][:n]) {
			return false
		}
		pos += RECORD_HEAD + n
	}
	e.pos += pos
	return e.pos >= size && evac_end(s, size)
}

// The end of a segment's records: whole, or cut short, or with damage in it, and then what lay there is sought.
@(private)
evac_end :: proc(s: ^Store, size: int) -> bool {
	e := &s.evac
	if !e.damaged && size >= SEGMENT - RECORD_HEAD {
		return true // full to the brim, with no room for the mark
	}
	if !e.damaged && size >= RECORD_HEAD {
		// Whole only if it ends with the mark; a segment cut short lost what followed.
		mark: [RECORD_HEAD]byte
		if e.pos == size && s.disk.log_read(s.disk.data, e.seg * SEGMENT + u64(size - RECORD_HEAD), mark[:]) && get_u64(mark[:]) == ROLLED {
			return true
		}
	}
	e.scanning, e.cursor = true, KEY_MIN
	return false
}

// Seeks the cells that lay where nothing was found, and forgets them, a step at a time.
@(private)
evac_scan_step :: proc(s: ^Store) -> bool {
	e := &s.evac
	lost := make([dynamic]Leaf, context.temp_allocator)
	scan := tree_scan(s, s.cells, e.cursor, KEY_MAX)
	seen := 0
	for leaf in tree_next(&scan) {
		if seen == SWEEP_STEP {
			e.cursor = leaf.key
			forget(s, lost[:])
			return false
		}
		seen += 1
		if place_unpack(leaf.val).off / SEGMENT == e.seg {
			append(&lost, leaf)
		}
	}
	forget(s, lost[:])
	return true
}

REPAIR_STEP :: 4096 // shelf entries looked over in a step

// Rows lost where they lay could not be read may be shelved where nothing now says: the shelf is gone over, a
// step at a time, for entries of theirs that are no longer where they are.
@(private)
repair_steps :: proc(s: ^Store) -> (waiting: bool) {
	for s.repair.root != 0 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		t := store_begin(s)
		cursor := s.repair_at
		if cursor == {} {
			clear(&s.repair_added) // a pass begins: whatever is waiting now waits for all of it
		}
		stale := make([dynamic]Key, context.temp_allocator)
		scan := tree_scan(s, s.shelf, cursor, KEY_MAX)
		done := true
		seen := 0
		for leaf in tree_next(&scan) {
			if seen == REPAIR_STEP {
				cursor, done = leaf.key, false
				break
			}
			seen += 1
			row := key_row(leaf.key)
			if _, ok := tree_get(s, s.repair, {row[0], row[1], 0, 0, 0}); ok {
				places := row_places(s, row)
				if !slice.contains(places.keys[:places.count], leaf.key) {
					append(&stale, leaf.key)
				}
			}
		}
		for k in stale {
			tree_delete(s, &s.shelf, k)
		}
		if done {
			// Each row that was waiting the whole way over is done with; one that came along meanwhile goes again.
			rows := make([dynamic]Key, context.temp_allocator)
			all := tree_scan(s, s.repair, KEY_MIN, KEY_MAX)
			for leaf in tree_next(&all) {
				if !slice.contains(s.repair_added[:], key_row(leaf.key)) {
					append(&rows, leaf.key)
				}
			}
			for k in rows {
				tree_delete(s, &s.repair, k)
			}
		}
		if store_missed(s, &t) {
			store_end(s, &t, false)
			return true
		}
		store_end(s, &t, true)
		s.repair_at = cursor if !done else {}
		if done {
			clear(&s.repair_added)
		}
	}
	return false
}

// Replays the log past the checkpoint, a record at a time, each record a step, as replay does all at once. The log
// there is always at hand: the host keeps what lies past the checkpoint in its own storage. Returns whether a record
// waits for something that is not.
@(private)
replay_steps :: proc(s: ^Store) -> (waiting: bool) {
	WINDOW :: 1 << 20
	end := s.disk.log_end(s.disk.data)
	for s.replay_at < end {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		next_seg := (s.replay_at / SEGMENT + 1) * SEGMENT
		limit := int(log_size(s.disk, s.replay_at, min(end, next_seg) - s.replay_at)) // only the last segment reaches the end
		if limit == 0 {
			s.replay_at = next_seg
			continue
		}
		// A window, grown to hold whole the record that seems to begin it.
		size := min(limit, WINDOW)
		head: [RECORD_HEAD]byte
		if limit >= RECORD_HEAD && s.disk.log_read(s.disk.data, s.replay_at, head[:]) {
			if want := int(get_u32(head[:])); want > 0 && want <= MAX_RECORD && RECORD_HEAD + want <= limit {
				size = max(size, RECORD_HEAD + want)
			}
		}
		part := make([]byte, size, context.temp_allocator)
		if !s.disk.log_read(s.disk.data, s.replay_at, part) {
			s.failed = true
			return false
		}
		pos := 0
		scan: for pos < size {
			n := record_at(part[pos:])
			if n == 0 {
				if size < limit {
					// Perhaps a record that runs past the window: the next window begins with it.
					if pos + RECORD_HEAD > size {
						break scan
					}
					if want := int(get_u32(part[pos:])); want > 0 && want <= MAX_RECORD && pos + RECORD_HEAD + want > size && pos + RECORD_HEAD + want <= limit {
						break scan
					}
				}
				pos += 1 // damaged, whatever was damaged in it: stepped over
				continue
			}
			at := s.replay_at + u64(pos)
			t := store_begin(s)
			replay_record(s, at, part[pos + RECORD_HEAD:][:n])
			if store_missed(s, &t) {
				store_end(s, &t, false)
				s.replay_at = at
				return true
			}
			store_end(s, &t, true)
			pos += RECORD_HEAD + n
			s.replay_tail = at + u64(RECORD_HEAD + n)
		}
		s.replay_at += u64(pos)
		if pos == limit {
			s.replay_at = next_seg if s.replay_at < end else s.replay_at
		}
	}
	// Only what follows the last good record, and so is torn or nothing, is cut off.
	if s.replay_tail < end {
		s.disk.log_truncate(s.disk.data, s.replay_tail)
	}
	ring_clear(&s.events)
	s.buf_base = s.replay_tail
	s.synced = s.checkpoint
	s.replaying = false
	return false
}

