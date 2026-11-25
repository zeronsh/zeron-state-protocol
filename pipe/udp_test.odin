package pipe

import "core:container/priority_queue"
import "core:math/rand"
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
		l.on_stream = proc(l: ^Link, bytes: []byte) {
			append((^[dynamic]byte)(l.data), ..bytes)
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
		for _ in 0 ..< (2 if rand.float32() < n.loss else 1) {
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
			link_write(&n.links[from], chunk[:size])
			append(&sent[from], ..chunk[:size])
			for _ in 0 ..< rand.int_max(6) {
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
				link_write(&n.links[0], chunk[:])
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
	link_write(&n.links[0], {1, 2, 3})
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
		link_write(&n.links[0], d)
		for net_step(&n) {}
	}
}
