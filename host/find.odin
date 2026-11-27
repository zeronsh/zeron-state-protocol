package host

import "core:time"
import "../find"
import "../zsp"

// Answers what local clients ask. Nothing is kept for it until something is, nor for long after nothing is.

FIND_LINGER :: 10 * time.Second

@(private)
Found :: struct {
	finder: find.Finder,
	file:   Pages_File,
	more:   bool, // there is more to do
	idle:   time.Tick, // since when nobody has asked anything
	resting: bool,
}

@(private)
questions :: proc(s: ^Space) -> zsp.Questions {
	return {
		data = s,
		asked = proc(data: rawptr, session: ^zsp.Session, type: u8, payload: []byte) -> bool {
			return find.finder_asked(space_finder((^Space)(data)), session, type, payload)
		},
		shows = proc(data: rawptr, session: ^zsp.Session, row: zsp.Id) -> bool {
			s := (^Space)(data)
			return s.found != nil && find.finder_shows(&s.found.finder, session, row)
		},
		again = proc(data: rawptr, session: ^zsp.Session) {
			if s := (^Space)(data); s.found != nil {
				s.found.more = true
				find.finder_again(&s.found.finder, session)
			}
		},
		ended = proc(data: rawptr, session: ^zsp.Session) {
			if s := (^Space)(data); s.found != nil {
				find.finder_ended(&s.found.finder, session)
			}
		},
		called = proc(data: rawptr, call: u64, device: zsp.Key32, scope: zsp.Scope, body: []byte) {
			find.finder_called(space_finder((^Space)(data)), call, device, body)
		},
		flow = proc(data: rawptr, call: u64, kind: zsp.Flow, payload: []byte) {
			if s := (^Space)(data); s.found != nil {
				s.found.more = true
				find.finder_flow(&s.found.finder, call, kind, payload)
			}
		},
		wanted = proc(data: rawptr, _: ^zsp.Session) {
			if s := (^Space)(data); s.found != nil {
				s.found.more = true
			}
		},
	}
}

@(private)
space_finder :: proc(s: ^Space) -> ^find.Finder {
	if s.found == nil {
		s.found = new(Found)
		key := zsp.hkdf256(s.node.space[:], s.keys.secret[:], transmute([]byte)string("zsp-find"))
		find.finder_open(&s.found.finder, &s.node, pages_file(&s.found.file, s.dir), key)
		s.found.finder.settled = s.node.full
		s.found.finder.pace = true
	}
	s.found.more = true
	return &s.found.finder
}

// Once a tick, before anything is said.
@(private)
found_run :: proc(s: ^Space, now: time.Tick) {
	f := s.found
	if f == nil {
		return
	}
	f.more = !find.finder_run(&f.finder)
	if len(f.finder.live) > 0 || len(f.finder.calls) > 0 {
		f.resting = false
		if !f.more && f.finder.x.unsaved > 1 << 16 {
			found_save(s)
		}
	} else if !f.resting {
		f.resting, f.idle = true, now
	} else if time.tick_diff(f.idle, now) >= FIND_LINGER {
		found_close(s)
	}
}

@(private)
found_save :: proc(s: ^Space) {
	x := &s.found.finder.x
	if x.unsaved > 0 && x.tailing && zsp.store_sync(&s.node.store) && !find.index_save(x) {
		s.found.more ||= x.failed // it has to be made again
	}
}

@(private)
found_close :: proc(s: ^Space) {
	if s.found == nil {
		return
	}
	found_save(s)
	find.finder_close(&s.found.finder)
	free(s.found)
	s.found = nil
}

@(private)
found_deadline :: proc(s: ^Space, now: time.Tick) -> (due: time.Tick, ok: bool) {
	switch f := s.found; {
	case f == nil:
		return
	case f.more:
		return now, true
	case f.finder.wake != nil:
		return f.finder.wake.?, true
	case f.resting:
		return time.tick_add(f.idle, FIND_LINGER + time.Millisecond), true
	}
	return
}
