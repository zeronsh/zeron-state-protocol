#+build !js
package pipe

import "core:container/priority_queue"
import "core:math/rand"
import "core:encoding/endian"
import "core:slice"
import "core:testing"
import "../zsp"

@(private)
Flight :: struct {
	at:    Time,
	order: int,
	to:    int,
	size:  int,
	bytes: [PACKET_MAX]byte,
}

// Two links across a path that drops, reorders and duplicates, with a bottleneck and virtual time.
@(private)
Net :: struct {
	links:    [2]Link,
	flights:  priority_queue.Priority_Queue(^Flight),
	now:      Time,
	order:    int,
	loss:     f32,
	delay:    Time,
	jitter:   int,
	rate:     f64, // bytes per microsecond
	free_at:  [2]f64,
	mtu:      int,
	packets:  int,
	got:      [2][dynamic]byte,
	gotten:   [2]int, // datagrams
}

@(private)
net_init :: proc(t: ^testing.T, n: ^Net) {
	n.now = 1000
	n.mtu = 1500
	priority_queue.init(&n.flights, proc(a, b: ^Flight) -> bool {return a.at < b.at || (a.at == b.at && a.order < b.order)}, priority_queue.default_swap_proc(^Flight))
	secrets: [2]zsp.Key32
	for &s in secrets {
		for &b in s {
			b = byte(rand.uint32())
		}
	}
	space: zsp.Key32
	testing.expect(t, link_dial(&n.links[0], secrets[0], zsp.x25519_public(secrets[1]), space))
	buf: [PACKET_MAX]byte
	testing.expect(t, link_answer(&n.links[1], secrets[1], space, link_hello(&n.links[0], buf[:])))
	testing.expect(t, n.links[1].channel.peer == zsp.x25519_public(secrets[0]))
	testing.expect(t, link_input(&n.links[0], link_hello(&n.links[1], buf[:]), n.now))
	for &l, i in n.links {
		l.data = &n.got[i]
		l.on_stream = proc(l: ^Link, id: u64, bytes: []byte, event: Stream_Event) {
			if id == 0 {
				append((^[dynamic]byte)(l.data), ..bytes)
			}
		}
	}
}

@(private)
net_destroy :: proc(n: ^Net) {
	for &l in n.links {
		link_destroy(&l)
	}
	for &g in n.got {
		delete(g)
	}
	for priority_queue.len(n.flights) > 0 {
		free(priority_queue.pop(&n.flights))
	}
	priority_queue.destroy(&n.flights)
}

@(private)
net_push :: proc(n: ^Net, from: int) {
	for {
		buf: [PACKET_MAX]byte
		out := link_output(&n.links[from], buf[:], n.now)
		if out == nil {
			return
		}
		n.packets += 1
		if rand.float32() < n.loss || len(out) + 28 > n.mtu {
			continue
		}
		at := f64(n.now)
		if n.rate > 0 {
			n.free_at[from] = max(n.free_at[from], at) + f64(len(out)) / n.rate
			if n.free_at[from] - at > 100_000 {
				n.free_at[from] -= f64(len(out)) / n.rate
				continue // the bottleneck's queue is full
			}
			at = n.free_at[from]
		}
		many := (2 if rand.float32() < n.loss else 1)
		for _ in 0 ..< many {
			f := new(Flight)
			n.order += 1
			f.at, f.order, f.to, f.size = Time(at) + n.delay + Time(rand.int_max(n.jitter + 1)), n.order, 1 - from, len(out)
			copy(f.bytes[:], out)
			priority_queue.push(&n.flights, f)
		}
	}
}

// Advances to the next event; false when nothing will ever happen again.
@(private)
net_step :: proc(n: ^Net) -> bool {
	net_push(n, 0)
	net_push(n, 1)
	next: Time
	if priority_queue.len(n.flights) > 0 {
		next = priority_queue.peek(n.flights).at
	}
	for &l in n.links {
		if d := link_deadline(&l); d != 0 && (next == 0 || d < next) {
			next = d
		}
	}
	if next == 0 {
		return false
	}
	n.now = max(n.now, next)
	for priority_queue.len(n.flights) > 0 && priority_queue.peek(n.flights).at <= n.now {
		f := priority_queue.pop(&n.flights)
		link_input(&n.links[f.to], f.bytes[:f.size], n.now)
		free(f)
	}
	return true
}

@(test)
link_delivers :: proc(t: ^testing.T) {
	for seed in 0 ..< 12 {
		state := rand.create(u64(seed))
		context.random_generator = rand.default_random_generator(&state)
		n: Net
		net_init(t, &n)
		defer net_destroy(&n)
		n.loss = f32(seed % 4) * 0.07
		n.delay = Time(1 + seed * 7) * MS
		n.jitter = seed % 3 * 10_000
		n.mtu = 1500 if seed % 2 == 0 else 1280
		sent: [2][dynamic]byte
		defer delete(sent[0])
		defer delete(sent[1])
		for i in 0 ..< 200 {
			from := rand.int_max(2)
			chunk: [3000]byte
			for &b in chunk {
				b = byte(rand.uint32())
			}
			size := min(rand.int_max(len(chunk)), max(link_room(&n.links[from]), 0))
			link_write(&n.links[from], 0, chunk[:size])
			append(&sent[from], ..chunk[:size])
			many_2 := rand.int_max(6)
			for _ in 0 ..< many_2 {
				net_step(&n)
			}
			if i % 50 == 0 {
				_ = link_datagram(&n.links[from], chunk[:100])
			}
		}
		steps := 0
		for net_step(&n) && steps < 200_000 {
			steps += 1
		}
		testing.expect(t, steps < 200_000)
		testing.expect(t, string(n.got[1][:]) == string(sent[0][:]))
		testing.expect(t, string(n.got[0][:]) == string(sent[1][:]))
		testing.expect_value(t, n.links[0].state, Link_State.Open)
		testing.expect_value(t, n.links[0].mtu, PACKET_MAX if n.mtu == 1500 else PACKET)
		// Idle means idle: no deadline, no packet, whatever time does.
		packets := n.packets
		n.now += 10_000_000 * MS
		testing.expect_value(t, link_deadline(&n.links[0]), 0)
		testing.expect(t, !net_step(&n) && n.packets == packets)
	}
}

// A long fat bottleneck is filled, and a lossy one is not abandoned.
@(test)
link_fills_the_pipe :: proc(t: ^testing.T) {
	state := rand.create(7)
	context.random_generator = rand.default_random_generator(&state)
	for loss in ([]f32{0, 0.005, 0.03}) {
		n: Net
		net_init(t, &n)
		defer net_destroy(&n)
		n.rate = 2.5 // 20 Mbit/s
		n.delay = 20 * MS
		n.loss = loss
		chunk: [16 << 10]byte
		total := 0
		start := n.now
		for n.now - start < 4000 * MS {
			for link_room(&n.links[0]) > len(chunk) {
				link_write(&n.links[0], 0, chunk[:])
				total += len(chunk)
			}
			net_step(&n)
		}
		share := f64(len(n.got[1])) / (2.5 * 4_000_000)
		testing.expectf(t, share > 0.7, "loss %v used %.2f of the bottleneck", loss, share)
	}
}

@(test)
link_notices_death :: proc(t: ^testing.T) {
	state := rand.create(8)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	n.delay = 10 * MS
	for net_step(&n) {}
	n.loss = 1
	link_write(&n.links[0], 0, {1, 2, 3})
	start := n.now
	for net_step(&n) {}
	testing.expect_value(t, n.links[0].state, Link_State.Closed)
	testing.expectf(t, n.now - start < 20_000 * MS, "took %v ms", (n.now - start) / MS)
}

// A packet counts once, from wherever and whenever it comes again.
@(test)
link_ignores_replays :: proc(t: ^testing.T) {
	state := rand.create(9)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	for net_step(&n) {}
	got := 0
	n.links[1].data = &got
	n.links[1].on_datagram = proc(l: ^Link, bytes: []byte) {(^int)(l.data)^ += 1}
	kept: [dynamic][]byte
	defer delete(kept)
	for _ in 0 ..< 200 {
		testing.expect(t, link_datagram(&n.links[0], {1, 2, 3}))
		buf: [PACKET_MAX]byte
		out := link_output(&n.links[0], buf[:], n.now)
		copied := make([]byte, len(out), context.temp_allocator)
		copy(copied, out)
		append(&kept, copied)
		n.links[0].in_flight = 0
	}
	feed :: proc(n: ^Net, p: []byte) -> bool {
		b := make([]byte, len(p), context.temp_allocator)
		copy(b, p)
		return link_input(&n.links[1], b, n.now)
	}
	// Every other one, then the gaps, so that ranges are evicted and then merge.
	for i := 0; i < 200; i += 2 {
		feed(&n, kept[i])
	}
	for i := 151; i < 200; i += 2 {
		feed(&n, kept[i])
	}
	before := got
	for p in kept[:150] {
		testing.expect(t, !feed(&n, p))
	}
	for i := 0; i < 150; i += 2 {
		testing.expect(t, !feed(&n, kept[i]))
	}
	testing.expectf(t, got - before <= 64, "%d", got - before) // the odd ones still within the window
	again := got
	for p in kept {
		testing.expect(t, !feed(&n, p))
	}
	testing.expect_value(t, got, again)
}

// A full datagram leaves no room, and that is fine.
@(test)
link_packs_to_the_brim :: proc(t: ^testing.T) {
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	for net_step(&n) {}
	for size in n.links[0].mtu - HEAD - zsp.TAG - 24 ..= n.links[0].mtu - HEAD - zsp.TAG - 4 {
		d := make([]byte, size, context.temp_allocator)
		link_datagram(&n.links[0], d)
		link_write(&n.links[0], 0, d)
		for net_step(&n) {}
	}
}

// Out of order, overlapping, in crumbs: all that was accepted arrives, and what is held is bounded.
@(test)
link_holds_what_it_accepts :: proc(t: ^testing.T) {
	state := rand.create(11)
	context.random_generator = rand.default_random_generator(&state)
	for _ in 0 ..< 12 {
		n: Net
		net_init(t, &n)
		defer net_destroy(&n)
		l := &n.links[1]
		want: [400]byte
		for &b in want {
			b = byte(rand.uint32())
		}
		have: [400]bool
		for _ in 0 ..< 30 {
			lo := 1 + rand.int_max(398)
			hi := lo + 1 + rand.int_max(min(80, 400 - lo))
			if link_stream(l, 0, u64(lo), want[lo:hi], false) {
				for &h in have[lo:hi] {
					h = true
				}
			}
		}
		testing.expect_value(t, len(n.got[1]), 0)
		link_stream(l, 0, 0, want[:1], false)
		for h, i in have {
			if i > 0 && !h {
				link_stream(l, 0, u64(i), want[i:][:1], false)
			}
		}
		testing.expect(t, string(n.got[1][:]) == string(want[:]))
	}
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	refused := 0
	crumb := [1]byte{7}
	for i := u64(STREAM_WINDOW) - 1; i > 1; i -= 2 {
		refused += 0 if link_stream(&n.links[1], 0, i, crumb[:], false) else 1
	}
	testing.expect(t, n.links[1].early <= MAX_EARLY && refused > 0)
}

// Nobody is there any more, and it is found out, however often there is more to say to them, and however slow the path was.
@(test)
link_to_nobody_is_closed :: proc(t: ^testing.T) {
	for every, n_th in ([]Time{50 * MS, 300 * MS, 1000 * MS, 1700 * MS, 5000 * MS, 1000 * MS}) {
		state := rand.create(u64(every))
		context.random_generator = rand.default_random_generator(&state)
		n: Net
		net_init(t, &n)
		defer net_destroy(&n)
		n.delay = 5 * MS if n_th < 5 else 150 * MS
		for i in 0 ..< 50 {
			link_write(&n.links[i % 2], 0, {1, 2, 3})
			for net_step(&n) {
			}
		}
		testing.expect(t, n.links[0].state == .Open)
		l := &n.links[0]
		start := n.now
		for n.now - start < 60_000 * MS && l.state == .Open {
			link_write(l, 0, {1, 2, 3})
			until := n.now + every
			for l.state == .Open && n.now < until {
				buf: [PACKET_MAX]byte
				for link_output(l, buf[:], n.now) != nil {
				}
				d := link_deadline(l)
				n.now = min(max(d, n.now + 1), until) if d != 0 else until
			}
		}
		testing.expectf(t, l.state == .Closed && n.now - start < 15_000 * MS + every, "after %v ms, saying something every %v", (n.now - start) / MS, every / MS)
	}
}

// ---------------------------------------------------------------- many streams

// What one end of a link was told, stream by stream.
@(private)
Heard :: struct {
	got:     map[u64][dynamic]byte,
	ends:    map[u64]Stream_Event, // Fin or Reset, the first said
	stopped: map[u64]bool,
	first:   map[u64]int, // how much of stream 0 had been delivered when a stream's first bytes were
	events:  int,
}

@(private)
heard_wire :: proc(l: ^Link, h: ^Heard) {
	l.data = h
	l.on_stream = proc(l: ^Link, id: u64, bytes: []byte, event: Stream_Event) {
		h := (^Heard)(l.data)
		h.events += 1
		switch event {
		case .Data:
			if id not_in h.got {
				h.got[id] = {}
				h.first[id] = len(h.got[0]) if 0 in h.got else 0
			}
			append(&h.got[id], ..bytes)
		case .Fin, .Reset:
			if id not_in h.ends {
				h.ends[id] = event
			}
		case .Stopped:
			h.stopped[id] = true
		}
	}
}

@(private)
heard_destroy :: proc(h: ^Heard) {
	for _, g in h.got {
		delete(g)
	}
	delete(h.got)
	delete(h.ends)
	delete(h.stopped)
	delete(h.first)
}

// Streams opened, written, finished, reset and stopped at random from both ends, over a path that loses, reorders,
// duplicates and delays: each stream arrives whole and in order, apart from the rest, and no earlier than what
// was written to stream 0 before it; each end is told; and once all are over, nothing is held.
@(test)
streams_arrive_apart :: proc(t: ^testing.T) {
	Mine :: struct {
		from:    int,
		id:      u64,
		sent:    [dynamic]byte, // by its opener
		back:    [dynamic]byte, // by the other end
		after:   int, // stream 0 written by its opener when it began
		back_after: int,
		ended, back_ended: bool, // finished, or given up
		reset, back_reset, stopped, back_stopped: bool,
	}
	for seed in 0 ..< 24 {
		state := rand.create(u64(1000 + seed))
		context.random_generator = rand.default_random_generator(&state)
		n: Net
		net_init(t, &n)
		defer net_destroy(&n)
		heard: [2]Heard
		defer heard_destroy(&heard[0])
		defer heard_destroy(&heard[1])
		heard_wire(&n.links[0], &heard[0])
		heard_wire(&n.links[1], &heard[1])
		n.loss = f32(seed % 4) * 0.06
		n.delay = Time(1 + seed % 5 * 9) * MS
		n.jitter = seed % 3 * 15_000
		n.rate = 0 if seed % 2 == 0 else 1.0
		zero: [2][dynamic]byte
		defer delete(zero[0])
		defer delete(zero[1])
		streams: [dynamic]^Mine
		defer {
			for m in streams {
				delete(m.sent)
				delete(m.back)
				free(m)
			}
			delete(streams)
		}
		chunk: [4000]byte
		for step in 0 ..< 600 {
			for &b in chunk[:64] {
				b = byte(rand.uint32())
			}
			for i in 64 ..< len(chunk) {
				chunk[i] = chunk[i % 64] ~ byte(i)
			}
			from := rand.int_max(2)
			l := &n.links[from]
			switch rand.int_max(10) {
			case 0, 1:
				size := min(rand.int_max(300), link_room(l, 0))
				if link_write(l, 0, chunk[:size]) {
					append(&zero[from], ..chunk[:size])
				}
			case 2:
				if id, ok := link_open(l, u8(rand.int_max(8))); ok {
					m := new(Mine)
					m.from, m.id, m.after = from, id, len(zero[from])
					append(&streams, m)
				}
			case 3, 4, 5, 6:
				if len(streams) == 0 {
					break
				}
				m := rand.choice(streams[:])
				// Either end of it speaks.
				opener := rand.int_max(2) == 0
				end := m.from if opener else 1 - m.from
				if opener ? m.ended : m.back_ended {
					break
				}
				if !opener && !(m.id in heard[1 - m.from].got) {
					break // the other end does not know of it yet
				}
				room := link_room(&n.links[end], m.id)
				size := min(rand.int_max(len(chunk)), room)
				if !opener && len(m.back) == 0 && size > 0 {
					m.back_after = len(zero[end])
				}
				if link_write(&n.links[end], m.id, chunk[:size]) {
					append(&m.sent if opener else &m.back, ..chunk[:size])
				}
			case 7:
				if len(streams) == 0 {
					break
				}
				m := rand.choice(streams[:])
				opener := rand.int_max(2) == 0
				end := m.from if opener else 1 - m.from
				if !opener && !(m.id in heard[end].got) && !(m.id in heard[end].ends) {
					break
				}
				done := &m.ended if opener else &m.back_ended
				if done^ {
					break
				}
				done^ = true
				switch rand.int_max(6) {
				case 0:
					link_reset(&n.links[end], m.id)
					(&m.reset if opener else &m.back_reset)^ = true
				case 1:
					// Wants no more of the other side's, and is finished with its own.
					link_stop(&n.links[end], m.id)
					(&m.back_stopped if opener else &m.stopped)^ = true
					link_finish(&n.links[end], m.id)
				case:
					link_finish(&n.links[end], m.id)
				}
			case:
			}
			for _ in 0 ..< rand.int_max(4) {
				net_step(&n)
			}
			_ = step
		}
		// Whatever is left, each end finishes.
		for m in streams {
			if !m.ended {
				link_finish(&n.links[m.from], m.id)
				m.ended = true
			}
		}
		steps := 0
		for steps < 400_000 {
			for m in streams {
				if !m.back_ended && (m.id in heard[1 - m.from].got || m.id in heard[1 - m.from].ends) {
					link_finish(&n.links[1 - m.from], m.id)
					m.back_ended = true
				}
			}
			if !net_step(&n) {
				break
			}
			steps += 1
		}
		testing.expectf(t, steps < 400_000, "seed %d did not settle", seed)
		testing.expectf(t, string(heard[1].got[0][:]) == string(zero[0][:]), "seed %d: stream 0", seed)
		testing.expectf(t, string(heard[0].got[0][:]) == string(zero[1][:]), "seed %d: stream 0 back", seed)
		for m in streams {
			there, here := &heard[1 - m.from], &heard[m.from]
			// What the opener said, as the other end heard it.
			got := there.got[m.id][:] if m.id in there.got else nil
			if m.stopped || m.reset {
				testing.expectf(t, len(got) <= len(m.sent) && string(got) == string(m.sent[:len(got)]), "seed %d stream %d: a prefix", seed, m.id)
			} else {
				testing.expectf(t, string(got) == string(m.sent[:]), "seed %d stream %d: %d of %d", seed, m.id, len(got), len(m.sent))
				if m.id in there.first {
					testing.expectf(t, there.first[m.id] >= m.after, "seed %d stream %d came before stream 0 had", seed, m.id)
				}
			}
			back := here.got[m.id][:] if m.id in here.got else nil
			if m.back_stopped || m.back_reset {
				testing.expectf(t, len(back) <= len(m.back) && string(back) == string(m.back[:len(back)]), "seed %d stream %d: a prefix back", seed, m.id)
			} else {
				testing.expectf(t, string(back) == string(m.back[:]), "seed %d stream %d back: %d of %d", seed, m.id, len(back), len(m.back))
				if len(m.back) > 0 {
					testing.expectf(t, here.first[m.id] >= m.back_after, "seed %d stream %d back came before stream 0 had", seed, m.id)
				}
			}
			// Each end heard how the other's side ended, unless it had stopped it.
			if !m.stopped {
				testing.expectf(t, there.ends[m.id] == (.Reset if m.reset else .Fin), "seed %d stream %d: %v", seed, m.id, there.ends[m.id])
			}
			if !m.back_stopped {
				testing.expectf(t, here.ends[m.id] == (.Reset if m.back_reset else .Fin), "seed %d stream %d back: %v", seed, m.id, here.ends[m.id])
			}
		}
		for &l, i in n.links {
			testing.expectf(t, len(l.streams) == 1, "seed %d: %d streams left at %d", seed, len(l.streams), i)
			testing.expectf(t, l.early == 0 && l.held == 0, "seed %d: %d pieces, %d held", seed, l.early, l.held)
			testing.expect_value(t, l.state, Link_State.Open)
		}
	}
}

// Keystrokes on one stream while another carries all a lossy bottleneck will take: they arrive about as soon as the
// path allows, for nothing lost from the bulk holds them, and they go ahead of it.
@(test)
interactive_is_not_held_by_bulk :: proc(t: ^testing.T) {
	for seed in 0 ..< 4 {
		state := rand.create(u64(77 + seed))
		context.random_generator = rand.default_random_generator(&state)
		n: Net
		net_init(t, &n)
		defer net_destroy(&n)
		heard: [2]Heard
		defer heard_destroy(&heard[0])
		defer heard_destroy(&heard[1])
		heard_wire(&n.links[0], &heard[0])
		heard_wire(&n.links[1], &heard[1])
		n.rate = 2.5 // 20 Mbit/s
		n.delay = 20 * MS
		n.loss = 0.02 * f32(seed % 2 + 1)
		for net_step(&n) && n.now < 100 * MS {}
		bulk, ok := link_open(&n.links[0], 6)
		testing.expect(t, ok)
		keys: u64
		keys, ok = link_open(&n.links[0], 1)
		testing.expect(t, ok)
		chunk: [16 << 10]byte
		latencies: [dynamic]Time
		defer delete(latencies)
		sent_at: [dynamic]Time
		defer delete(sent_at)
		start := n.now
		next_key := start + 500 * MS // once the bulk has filled the pipe
		for n.now - start < 6000 * MS {
			for link_room(&n.links[0], bulk) >= len(chunk) {
				link_write(&n.links[0], bulk, chunk[:])
			}
			if n.now >= next_key {
				// Each keystroke is its number, so its arrival can be timed.
				k: [8]byte
				endian.unchecked_put_u64le(k[:], u64(len(sent_at)))
				testing.expect(t, link_write(&n.links[0], keys, k[:]))
				append(&sent_at, n.now)
				next_key += 50 * MS
			}
			net_step(&n)
			if keys in heard[1].got {
				for got := heard[1].got[keys][:]; (len(latencies) + 1) * 8 <= len(got); {
					i := endian.unchecked_get_u64le(got[len(latencies) * 8:])
					append(&latencies, n.now - sent_at[i])
				}
			}
		}
		slice.sort(latencies[:])
		testing.expectf(t, len(latencies) > len(sent_at) - 10, "%d of %d keystrokes arrived", len(latencies), len(sent_at))
		median := latencies[len(latencies) / 2]
		p95 := latencies[len(latencies) * 95 / 100]
		share := f64(len(heard[1].got[bulk])) / (2.5 * 6_000_000)
		testing.expectf(t, median < 45 * MS && p95 < 110 * MS, "seed %d: keystrokes took %v ms at the median, %v at the 95th centile", seed, median / MS, p95 / MS)
		testing.expectf(t, share > 0.6, "seed %d: the bulk had %.2f of the bottleneck", seed, share)
	}
}

// One stream alone fills a long fat pipe: its window, and the link's, grow until they are not what limits it; and
// what the sender holds, and the receiver, stays bounded all the while.
@(test)
stream_fills_the_pipe :: proc(t: ^testing.T) {
	state := rand.create(17)
	context.random_generator = rand.default_random_generator(&state)
	for loss in ([]f32{0, 0.01}) {
		n: Net
		net_init(t, &n)
		defer net_destroy(&n)
		heard: [2]Heard
		defer heard_destroy(&heard[0])
		defer heard_destroy(&heard[1])
		heard_wire(&n.links[0], &heard[0])
		heard_wire(&n.links[1], &heard[1])
		n.rate = 12.5 // 100 Mbit/s
		n.delay = 40 * MS // a bandwidth-delay product of 1 MB
		n.loss = loss
		id, ok := link_open(&n.links[0], 6)
		testing.expect(t, ok)
		chunk: [16 << 10]byte
		start := n.now
		most_held, most_early := 0, 0
		for n.now - start < 6000 * MS {
			for link_room(&n.links[0], id) >= len(chunk) {
				link_write(&n.links[0], id, chunk[:])
			}
			net_step(&n)
			most_held = max(most_held, n.links[0].held)
			most_early = max(most_early, n.links[1].early)
		}
		share := f64(len(heard[1].got[id])) / (12.5 * 6_000_000)
		testing.expectf(t, share > 0.6, "loss %v: used %.2f of the bottleneck", loss, share)
		testing.expectf(t, most_held <= SEND_BUFFER + 16 << 10, "held %d", most_held)
		testing.expect(t, most_early <= MAX_EARLY)
	}
}

// The peer lets so many streams be open, and lets more be opened as they are done with.
@(test)
streams_are_limited :: proc(t: ^testing.T) {
	state := rand.create(18)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	heard: [2]Heard
	defer heard_destroy(&heard[0])
	defer heard_destroy(&heard[1])
	heard_wire(&n.links[0], &heard[0])
	heard_wire(&n.links[1], &heard[1])
	ids: [dynamic]u64
	defer delete(ids)
	for {
		id, ok := link_open(&n.links[0], 3)
		if !ok {
			break
		}
		append(&ids, id)
		link_write(&n.links[0], id, {1})
	}
	testing.expect_value(t, len(ids), STREAMS)
	for net_step(&n) {}
	testing.expect_value(t, len(heard[1].got), STREAMS)
	// Done with, both ways.
	for id in ids {
		link_finish(&n.links[0], id)
		link_finish(&n.links[1], id)
	}
	for net_step(&n) {}
	testing.expect_value(t, len(n.links[0].streams), 1)
	testing.expect_value(t, len(n.links[1].streams), 1)
	_, ok := link_open(&n.links[0], 3)
	testing.expect(t, ok)
	// A stream beyond what was let open is not taken, and what is done with does not come back.
	testing.expect(t, !link_stream(&n.links[1], u64(4 * STREAMS + 8), 0, {3, 0, 1}, false))
	testing.expect(t, link_stream(&n.links[1], ids[0], 0, {3, 0, 1}, false))
	testing.expect_value(t, len(n.links[1].streams), 1)
}

// A stream begun after stream 0 was written to is delivered after it, though stream 0 is what is lost.
@(test)
stream_waits_for_stream_0 :: proc(t: ^testing.T) {
	state := rand.create(19)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	heard: [2]Heard
	defer heard_destroy(&heard[0])
	defer heard_destroy(&heard[1])
	heard_wire(&n.links[0], &heard[0])
	heard_wire(&n.links[1], &heard[1])
	for net_step(&n) {}
	l := &n.links[0]
	link_write(l, 0, {1, 2, 3, 4, 5})
	buf: [PACKET_MAX]byte
	_ = link_output(l, buf[:], n.now) // lost
	id, _ := link_open(l, 1)
	link_write(l, id, {9})
	out := link_output(l, buf[:], n.now)
	testing.expect(t, out != nil)
	link_input(&n.links[1], out, n.now)
	testing.expect(t, id not_in heard[1].got)
	for net_step(&n) {}
	testing.expect(t, string(heard[1].got[id][:]) == "\x09")
	testing.expect_value(t, heard[1].first[id], 5)
}

// Both ends pour bytes into one stream at once, as an echo does, as fast as the link lets them: every byte arrives,
// in order, both ways.
@(test)
stream_carries_both_ways :: proc(t: ^testing.T) {
	for seed in 0 ..< 6 {
		state := rand.create(u64(31 + seed))
		context.random_generator = rand.default_random_generator(&state)
		n: Net
		net_init(t, &n)
		defer net_destroy(&n)
		heard: [2]Heard
		defer heard_destroy(&heard[0])
		defer heard_destroy(&heard[1])
		heard_wire(&n.links[0], &heard[0])
		heard_wire(&n.links[1], &heard[1])
		n.rate = 0 if seed % 2 == 0 else 50
		n.delay = Time(seed % 3) * MS
		n.loss = 0.01 if seed >= 4 else 0
		for net_step(&n) && n.now < 50 * MS {}
		id, _ := link_open(&n.links[0], 2)
		sent: [2][dynamic]byte
		defer delete(sent[0])
		defer delete(sent[1])
		chunk: [16 << 10]byte
		for &b, i in chunk {
			b = byte(i * 7 + i / 251)
		}
		total := 0
		for steps := 0; steps < 200_000 && total < 6 << 20; steps += 1 {
			for side in 0 ..< 2 {
				if side == 1 && id not_in heard[1].got {
					continue
				}
				room := link_room(&n.links[side], id)
				if room > 0 {
					k := min(room, len(chunk) - rand.int_max(100))
					at := len(sent[side]) % len(chunk)
					piece := make([]byte, k, context.temp_allocator)
					for &b, i in piece {
						b = chunk[(at + i) % len(chunk)]
					}
					link_write(&n.links[side], id, piece)
					append(&sent[side], ..piece)
					total += k
				}
			}
			net_step(&n)
		}
		for net_step(&n) {}
		got0 := heard[1].got[id][:]
		got1 := heard[0].got[id][:]
		testing.expectf(t, string(got0) == string(sent[0][:]), "seed %d: %d of %d one way", seed, len(got0), len(sent[0]))
		testing.expectf(t, string(got1) == string(sent[1][:]), "seed %d: %d of %d the other", seed, len(got1), len(sent[1]))
	}
}
