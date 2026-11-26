#+build !js
package zsp

import "core:math/rand"
import "core:slice"
import "core:testing"

// What review found, each held to a test that fails without its fix.

@(private)
review_cell :: proc(row_lo: u64, slot: Slot, t: u64, body: []byte) -> Cell {
	return Cell{row = {u64(1) << 48, row_lo}, slot = slot, kind = .Value, stamp = {t, row_lo + 1}, body = body}
}

// How many of a pack's pages the host keeps, among the tops or the rest.
@(private)
review_pack_cached :: proc(h: ^Model_Host, gen: u64) -> (n: int) {
	for kind in ([?]Cached{.Page, .Top}) {
		for k, b in h.cache[kind] {
			if k >> PACK_SHIFT == gen {
				n += len(b) / PAGE_SIZE
			}
		}
	}
	return
}

// Answers one operation under way, as it is, or as failed.
@(private)
review_answer :: proc(h: ^Model_Host, r: ^Remote, idx: int, ok: bool) {
	op := h.ops[idx]
	unordered_remove(&h.ops, idx)
	switch op.kind {
	case .Get_Pages, .Get_Log, .Get_Hints:
		o := Remote_Object{op.number, b64(op.kind != .Get_Log)}
		bytes, there := h.objects[o]
		if !ok || !there {
			remote_done(r, op.id, ok, absent = !there)
		} else {
			lo := min(int(op.off), len(bytes))
			hi := min(int(op.off + op.len), len(bytes))
			remote_done(r, op.id, true, bytes = bytes[lo:hi])
		}
	case .Put_Pack, .Put_Extent, .Delete:
		if ok {
			model_land(h, op)
		}
		remote_done(r, op.id, ok && (op.body != nil || op.kind == .Delete))
	}
	model_free(op)
}

@(private)
review_commit :: proc(s: ^Store, cells: []Cell) {
	t := store_begin(s)
	store_commit(s, cells)
	assert(!store_missed(s, &t))
	store_end(s, &t, true)
}

@(private)
review_answer_all :: proc(x: ^Remote_Store, kind: Remote_Op_Kind, ok: bool) {
	for i := len(x.host.ops) - 1; i >= 0; i -= 1 {
		if x.host.ops[i].kind == kind {
			review_answer(&x.host, &x.remote, i, ok)
		}
	}
}

// A segment is evacuated only once object storage has all of it: else its extents, still to be put, would be cut from
// the host's storage under them, and their puts would fail for ever, and nothing after them be let go of.
@(test)
review_evacuation_waits_for_object_storage :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	body := make([]byte, 4096)
	defer delete(body)
	for i in u64(0) ..< 80 {
		body[0] = byte(i)
		review_commit(&x.store, {review_cell(i + 1, 1, 100 + i, body)})
	}
	for i in u64(0) ..< 80 {
		review_commit(&x.store, {review_cell(i + 1, 1, 500 + i, {1, 2, 3, 4})})
	}
	testing.expect(t, store_sync(&x.store))
	for store_work(&x.store) {}
	testing.expect(t, !slice.contains(x.store.evacuated[:], u64(0)), "evacuated before object storage had it")
	// And with puts failing now and then, everything settles: uploaded goes past it, and it goes.
	x.host.fail = 4
	for _ in 0 ..< 20 {
		x.remote.want_checkpoint = true
		remote_store_settle(t, &x)
	}
	testing.expectf(t, x.remote.uploaded >= SEGMENT, "uploaded only to %d", x.remote.uploaded)
	testing.expectf(t, x.store.evac.seg != 0 || !x.store.evac.active, "still evacuating the first segment")
	testing.expect(t, !x.store.failed)
}

// What came to be deleted while a pack was being put is deleted, and named until it is: not dropped when it is put.
@(test)
review_redelete_kept_through_commit :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	review_commit(&x.store, {review_cell(1, 1, 10, {1})})
	x.remote.want_checkpoint = true
	for remote_store_turn(&x, 8) {}
	review_commit(&x.store, {review_cell(1, 1, 20, {2})})
	x.remote.want_checkpoint = true
	for remote_store_turn(&x, 8) {}
	testing.expect(t, len(x.remote.redelete) > 0)
	target := x.remote.redelete[0].object
	review_commit(&x.store, {review_cell(1, 1, 30, {3})})
	x.remote.want_checkpoint = true
	remote_work(&x.remote)
	remote_ops(&x.remote)
	x.host.clock += REDELETE_AFTER + 1
	remote_work(&x.remote)
	remote_ops(&x.remote)
	testing.expect(t, slice.contains(x.remote.deletes[:], target))
	review_answer_all(&x, .Put_Pack, true)
	in_redelete := false
	for d in x.remote.redelete {
		in_redelete ||= d.object == target
	}
	testing.expectf(t, slice.contains(x.remote.deletes[:], target) || in_redelete, "%v is named nowhere", target)
}

// A host that dies just after a checkpoint's manifest is written deletes again later what that checkpoint let go of.
@(test)
review_crash_after_commit_deletes_again :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	for store_work(&x.store) {}
	for i in u64(0) ..< 60 {
		review_commit(&x.store, {review_cell(i + 1, 1, 100 + i, {byte(i)})})
	}
	x.remote.want_checkpoint = true
	remote_store_settle(t, &x)
	// Every page of that pack superseded: the next checkpoint lets it go.
	for i in u64(0) ..< 60 {
		review_commit(&x.store, {review_cell(i + 1, 1, 900 + i, {byte(i + 1)})})
	}
	testing.expect(t, store_sync(&x.store))
	before := slice.clone(x.remote.deletes[:], context.temp_allocator)
	x.remote.want_checkpoint = true
	for _ in 0 ..< 10 {
		if x.remote.inflight != nil {
			break
		}
		remote_work(&x.remote)
		remote_ops(&x.remote)
		review_answer_all(&x, .Get_Pages, true)
	}
	review_answer_all(&x, .Put_Pack, true)
	victim: Remote_Object
	found := false
	for o in x.remote.deletes {
		if o.pack && !slice.contains(before, o) {
			victim, found = o, true
		}
	}
	testing.expect(t, found, "nothing was let go of")
	// Dies just after: nothing under way lands, and nothing it had in memory survives.
	remote_store_close(&x)
	for op in x.host.ops {
		model_free(op)
	}
	clear(&x.host.ops)
	remote_store_open(t, &x)
	for remote_store_turn(&x, 8) {}
	// A put of it from before lands now; an hour on, it is gone again.
	x.host.objects[victim] = slice.clone([]byte{0xde, 0xad})
	x.host.clock += 2 * REDELETE_AFTER
	for remote_store_turn(&x, 8) {}
	testing.expectf(t, victim not_in x.host.objects, "%v never deleted again", victim)
	remote_store_close(&x)
}

// A host that dies between writing a checkpoint's manifest and letting go of what of the log object storage now has,
// lets go of it on waking.
@(test)
review_crash_after_commit_lets_log_go :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	for store_work(&x.store) {}
	body := make([]byte, 4096)
	defer delete(body)
	for i in u64(0) ..< 40 {
		review_commit(&x.store, {review_cell(i + 1, 1, 100 + i, body)})
	}
	testing.expect(t, store_sync(&x.store))
	remote_work(&x.remote)
	remote_ops(&x.remote)
	review_answer_all(&x, .Put_Extent, true)
	saved := x.remote.host.log_cut
	x.remote.host.log_cut = proc(_: rawptr, _, _: u64) {} // dies before it is done
	review_answer_all(&x, .Put_Pack, true)
	x.remote.host.log_cut = saved
	testing.expect(t, x.remote.local_from > 0)
	remote_store_close(&x)
	for op in x.host.ops {
		model_free(op)
	}
	clear(&x.host.ops)
	remote_store_open(t, &x)
	for remote_store_turn(&x, 8) {}
	probe: [16]byte
	leaked := memory_disk(&x.host.local).log_read(&x.host.local, 0, probe[:]) && probe[0] != 0xee
	testing.expect(t, !leaked, "the host still holds log before where it begins")
	remote_store_close(&x)
}

// A segment evacuated is said to be gone in the checkpoint that lets it go: a host woken after does not evacuate it
// again, finding it empty and seeking every cell out of it.
@(test)
review_evacuated_stays_gone_on_waking :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	for store_work(&x.store) {}
	body := make([]byte, 4096)
	defer delete(body)
	for i in u64(0) ..< 80 {
		review_commit(&x.store, {review_cell(i + 1, 1, 100 + i, body)})
	}
	for i in u64(0) ..< 200 {
		review_commit(&x.store, {review_cell(1000 + i, 1, 200 + i, {2})})
	}
	for i in u64(0) ..< 64 {
		review_commit(&x.store, {review_cell(i + 1, 1, 500 + i, {1})})
	}
	testing.expect(t, store_sync(&x.store))
	// Until the first segment has been evacuated, and not yet let go of.
	for round := 0; !slice.contains(x.store.evacuated[:], u64(0)); round += 1 {
		testing.expect(t, round < 10_000)
		remote_store_turn(&x, 1 << 20)
	}
	for x.remote.inflight != nil {
		remote_store_turn(&x, 1 << 20)
	}
	if slice.contains(x.store.evacuated[:], u64(0)) {
		// The checkpoint that lets it go, and then the host dies.
		x.remote.want_checkpoint = true
		for _ in 0 ..< 10 {
			if x.remote.inflight != nil {
				break
			}
			remote_work(&x.remote)
			remote_ops(&x.remote)
			review_answer_all(&x, .Get_Pages, true)
		}
		review_answer_all(&x, .Put_Pack, true)
	}
	testing.expect(t, !slice.contains(x.store.evacuated[:], u64(0)), "the segment was not let go of")
	remote_store_close(&x)
	for op in x.host.ops {
		model_free(op)
	}
	clear(&x.host.ops)
	for kind in Cached {
		for _, b in x.host.cache[kind] {
			delete(b)
		}
		clear(&x.host.cache[kind])
	}
	remote_store_open(t, &x)
	scanned, again := false, false
	for _ in 0 ..< 200 {
		store_work(&x.store)
		scanned ||= x.store.evac.active && x.store.evac.scanning
		again ||= slice.contains(x.store.evacuated[:], u64(0)) || (x.store.evac.active && x.store.evac.seg == 0)
		remote_work(&x.remote)
		remote_ops(&x.remote)
		if len(x.host.ops) == 0 && !x.store.evac.active {
			break
		}
		model_tick(&x.host, &x.remote, 8)
	}
	testing.expect(t, !scanned && !again, "evacuated again on waking, every cell sought")
	remote_store_close(&x)
}

// Replaying, with as much changed as memory should hold and a checkpoint under way, it waits to hear of that, rather
// than asking to be called again at once, for ever.
@(test)
review_replay_waits_for_the_checkpoint :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	for store_work(&x.store) {}
	for i in u64(0) ..< 10 {
		review_commit(&x.store, {review_cell(i + 1, 1, 10 + i, {1, 2, 3, 4})})
	}
	testing.expect(t, store_sync(&x.store))
	remote_store_close(&x)
	remote_store_open(t, &x)
	x.remote.inflight = Inflight {
		gen = 1,
		op  = 999,
	}
	for i in Page_No(1) ..= Page_No(CHECKPOINT_HARD + 1) {
		x.store.dirty[TEMP_PAGES + i] = new(Page)
	}
	x.store.more = false
	store_work(&x.store)
	remote_work(&x.remote)
	testing.expect(t, !x.store.more, "asked to be called again at once, with nothing to do but wait")
	x.remote.inflight = nil
	remote_store_close(&x)
}

// Where reads may answer "not yet", pages given up in a step are let go of, not kept count of for ever.
@(test)
review_no_free_list_grows :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	for i in u64(0) ..< 200 {
		review_commit(&x.store, {review_cell(1, 1, 10 + i, {byte(i)})})
	}
	x.remote.want_checkpoint = true
	for remote_store_turn(&x, 8) {}
	testing.expectf(t, len(x.store.free) == 0, "%d free page numbers kept", len(x.store.free))
}

// A run of pages fetched is kept by the host as fetched, though some of it was at hand already.
@(test)
review_fetched_run_kept_as_read :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	for i in u64(0) ..< 100 {
		review_commit(&x.store, {review_cell(i + 1, 1, 10 + i, {byte(i)})})
	}
	x.remote.want_checkpoint = true
	for remote_store_turn(&x, 8) {}
	last := Page_No(0)
	for no in x.remote.pages {
		if no >> PACK_SHIFT == 1 && no > last {
			last = no
		}
	}
	testing.expect(t, last > 1 << PACK_SHIFT)
	for kind in Cached {
		for _, b in x.host.cache[kind] {
			delete(b)
		}
		clear(&x.host.cache[kind])
	}
	x.remote.host.cache_put = proc(data: rawptr, kind: Cached, key: u64, bytes: []byte) {
		h := (^Model_Host)(data)
		if old, ok := h.cache[kind][key]; ok {
			delete(old)
		}
		h.cache[kind][key] = slice.clone(bytes)
	}
	free(x.remote.pages[last].pg)
	delete_key(&x.remote.pages, last)
	step := store_begin(&x.store)
	_ = page(&x.store, last)
	store_end(&x.store, &step, false)
	remote_ops(&x.remote)
	review_answer(&x.host, &x.remote, 0, true)
	probe: Page
	testing.expect(t, remote_cached(&x.remote, last, &probe), "the page fetched is not kept")
}

// A live frame that comes by the lossy way is a step too: a relay that has not at hand what it reads drops it.
@(test)
review_datagram_is_a_step :: proc(t: ^testing.T) {
	d: Slow_Disk
	defer slow_disk_destroy(&d)
	n: Node
	defer node_destroy(&n)
	root, space := test_root()
	k: Keyring
	keyring_init(&k, Key32{0 = 7, 1 = 9})
	defer keyring_destroy(&k)
	none: Roster
	dr := draft_from(&none, 100)
	dr.random = sim_random
	sc := draft_scope(&dr)
	draft_grant(&dr, k.device, k.signer, sc, {.Read, .Write, .Call})
	rb, signed := roster_sign(&k, root, &dr)
	testing.expect(t, signed)
	defer delete(rb)
	testing.expect(t, node_init(&n, slow_disk(&d), space, nil, true))
	d.store = &n.store
	d.all = true
	for store_work(&n.store) {}
	testing.expect(t, node_adopt(&n, rb))
	row := Id{u64(sc) << 32, 1}
	b := make([]byte, 24, context.temp_allocator)
	put_u64(b[0:], u64(sc) << 32 | 1)
	put_u64(b[8:], 1)
	review_commit(&n.store, {Cell{row = row, slot = PLACE, kind = .Place, stamp = {10, 1}, body = b}})
	testing.expect(t, store_checkpoint(&n.store))
	s := session_open(&n, .Peer, false, k.device)
	s.greeted, s.accepted, s.ready = true, true, true
	append(&s.grants, Grant{scope = sc, rights = {.Write}})
	n.now = 1000
	d.all = false
	clear(&d.pages)
	dg: [dynamic]byte
	defer delete(dg)
	at := frame_begin(&dg, .Live)
	write_pair(&dg, row)
	write_u8(&dg, 1)
	write_u64(&dg, 7)
	write_varint(&dg, 0)
	write_stamp(&dg, Stamp{1000 << 16, 42})
	append(&dg, 1, 2, 3, 4)
	frame_end(&dg, at)
	session_datagram(s, dg[:])
	testing.expectf(t, d.unguarded == 0, "%d reads outside any step", d.unguarded)
	testing.expect(t, !n.failed)
}

// Storage that may answer "not yet" is a relay's alone: a node with keys, or a partial replica, is refused it.
@(test)
review_lazy_storage_is_a_relays :: proc(t: ^testing.T) {
	k: Keyring
	keyring_init(&k, Key32{0 = 3})
	defer keyring_destroy(&k)
	for c in ([]struct {
			keys: ^Keyring,
			full: bool,
			ok:   bool,
		}{{&k, true, false}, {nil, false, false}, {&k, false, false}, {nil, true, true}}) {
		d: Slow_Disk
		n: Node
		got := node_init(&n, slow_disk(&d), Key32{0 = 1}, c.keys, c.full)
		testing.expectf(t, got == c.ok, "keys %v full %v: %v", c.keys != nil, c.full, got)
		if got {
			node_destroy(&n)
		}
		slow_disk_destroy(&d)
	}
}

// Object storage falling behind makes writing wait, rather than fill the host's own storage: a relay holds no more of
// the log than it may, and goes on once object storage catches up.
@(test)
review_writing_waits_for_object_storage :: proc(t: ^testing.T) {
	state := seeded(21)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	s.lazy = .Remote
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	relay := s.nodes[2]
	r := &relay.remote.remote
	relay.remote.host.fail = 0
	MOST :: 300 << 10
	r.local_most = MOST
	sim_link(&s, 0, 2)
	sim_settle(&s)
	a := s.nodes[0]
	big := make([]byte, 4 << 10)
	defer delete(big)
	held := 0
	for i in 0 ..< 200 {
		s.now += 3
		a.node.now = sim_now(&s, a)
		body: [24]byte
		put_u64(body[:], 1 << 32 | 5)
		put_u64(body[8:], 5)
		put_u64(body[16:], u64(i))
		row := node_id(&a.node, 1)
		_ = node_write(&a.node, {{row, PLACE, .Place, node_stamp(&a.node), body[:]}, {row, DATA, .Value, node_stamp(&a.node), big}})
		// Bytes move and the relay works, but object storage takes no extent.
		for _ in 0 ..< 4 {
			for l in s.links {
				sim_pass(&s, l.a, l.b)
				sim_pass(&s, l.b, l.a)
			}
			node_sync(&a.node)
			node_retry(&relay.node)
			remote_work(r)
			remote_ops(r)
			for j := len(relay.remote.host.ops) - 1; j >= 0; j -= 1 {
				if relay.remote.host.ops[j].kind != .Put_Extent {
					review_answer(&relay.remote.host, r, j, true)
				}
			}
			tail := store_tail(&relay.node.store)
			held = max(held, int(tail - min(tail, r.local_from)))
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, held <= MOST + MAX_RECORD, "the host held %d of the log, where it may hold %d", held, MOST)
	testing.expect(t, !relay.node.failed)
	// Object storage catches up, and everything gets through.
	sim_settle(&s)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	sim_check(&s)
}

// A session is not saved for sleep while it holds what saving would lose: changes it has yet to be sent, a comparison
// owed, an acknowledgement owed, or a verdict awaited. It reconnects instead.
@(test)
review_session_saved_only_whole :: proc(t: ^testing.T) {
	state := seeded(31)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	s.lazy = .Remote
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	sim_link(&s, 0, 2)
	sim_settle(&s)
	at_relay := s.links[0].b
	saved := make([dynamic]byte, context.temp_allocator)
	testing.expect(t, session_save(at_relay, &saved), "a session level and quiet is saved")
	n := &s.nodes[2].node
	cases := []string{"changes unsent", "a comparison owed", "an acknowledgement owed", "a verdict awaited"}
	for c, i in cases {
		cursor, recompare, seq_in, accepted := at_relay.cursor, at_relay.recompare, at_relay.seq_in, at_relay.accepted
		switch i {
		case 0:
			at_relay.cursor = n.events.next - 1 if n.events.next > 0 else n.events.next + 1
		case 1:
			at_relay.recompare = true
		case 2:
			at_relay.seq_in = at_relay.acked_in + 1
		case 3:
			at_relay.accepted = false
		}
		clear(&saved)
		testing.expectf(t, !session_save(at_relay, &saved), "saved with %s", c)
		at_relay.cursor, at_relay.recompare, at_relay.seq_in, at_relay.accepted = cursor, recompare, seq_in, accepted
	}
}

// A segment evacuated after the next pack's books were begun is forgotten as waste by that pack all the same, as it lets
// it go: what a checkpoint lets go of is just what it says is gone.
@(test)
review_evacuated_late_still_forgotten :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	st := store_begin(&x.store)
	tree_put(&x.store, &x.store.waste, {0, 0, 0, 0, 7}, {SEGMENT, 0})
	store_end(&x.store, &st, true)
	review_commit(&x.store, {review_cell(1, 1, 10, {1})})
	testing.expect(t, store_sync(&x.store))
	// The books begun, and the pack's entry made, before the segment is done with.
	testing.expect(t, !remote_account_steps(&x.remote))
	testing.expect(t, x.remote.entry)
	append(&x.store.evacuated, 7)
	x.remote.want_checkpoint = true
	remote_store_settle(t, &x)
	testing.expect(t, !slice.contains(x.store.evacuated[:], u64(7)), "not let go of")
	gone := false
	remote_store_step(t, &x, &gone, proc(s: ^Store, data: rawptr) {
		_, there := tree_get(s, s.waste, {0, 0, 0, 0, 7})
		(^bool)(data)^ = !there
	})
	testing.expect(t, gone, "let go of, and still said to be waste")
}

// However small the host's storage is said to be, writing that waits for object storage waits only until it has caught
// up: past what is kept, a whole extent is always there to put.
@(test)
review_waiting_is_never_for_ever :: proc(t: ^testing.T) {
	for c in ([][2]u64{{EXTENT / 3, EXTENT * 3 / 4}, {2 * EXTENT, EXTENT + EXTENT / 2}}) {
		state := seeded(201)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		s.lazy = .Remote
		sim_init(t, &s, 2, 0, 1, 64)
		defer sim_destroy(&s)
		relay := s.nodes[2]
		r := &relay.remote.remote
		relay.remote.host.fail = 0
		remote_limits(r, c[0], c[1])
		testing.expect(t, r.local_most >= r.local_keep + 2 * EXTENT)
		sim_link(&s, 0, 2)
		sim_settle(&s)
		a := s.nodes[0]
		big := make([]byte, 4 << 10)
		defer delete(big)
		for i in 0 ..< 120 {
			s.now += 3
			a.node.now = sim_now(&s, a)
			body: [24]byte
			put_u64(body[:], 1 << 32 | 5)
			put_u64(body[8:], 5)
			put_u64(body[16:], u64(i))
			row := node_id(&a.node, 1)
			_ = node_write(&a.node, {{row, PLACE, .Place, node_stamp(&a.node), body[:]}, {row, DATA, .Value, node_stamp(&a.node), big}})
			if i % 10 == 0 {
				sim_settle(&s)
			}
			free_all(context.temp_allocator)
		}
		sim_settle(&s)
		testing.expectf(t, !remote_full(r), "waiting for ever: tail %d, uploaded %d, from %d, most %d", store_tail(&relay.node.store), r.uploaded, r.local_from, r.local_most)
		sim_link(&s, 1, 2)
		sim_settle(&s)
		sim_check(&s)
	}
}

// A host opened with nothing at hand asks at once for the head of the latest pack, where every tree's root and upper
// branches are: one read, before anything has gone down any tree.
@(test)
remote_opening_asks_for_the_tops :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	for store_work(&x.store) {}
	for i in u64(0) ..< 200 {
		review_commit(&x.store, {review_cell(i + 1, 1, 10 + i, {byte(i)})})
	}
	x.remote.want_checkpoint = true
	remote_store_settle(t, &x)
	latest := x.remote.kept_gen
	testing.expect(t, latest > 0)
	remote_store_close(&x)
	for kind in Cached {
		for _, b in x.host.cache[kind] {
			delete(b)
		}
		clear(&x.host.cache[kind])
	}
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	remote_ops(&x.remote)
	asked := false
	for op in x.host.ops {
		asked ||= op.kind == .Get_Pages && op.number == latest && op.off == 0
	}
	testing.expect(t, asked, "the tops were not asked for")
}

// Changes flushed, then a count beyond a window that misses: the count is still owed once what it wanted has come, and
// the session does not sleep owing it.
@(test)
review_counts_owed_stay_owed :: proc(t: ^testing.T) {
	state := seeded(77)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	s.lazy = .Remote
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	relay := s.nodes[2]
	r := &relay.remote.remote
	relay.remote.host.fail = 0
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)

	a := s.nodes[0]
	place :: proc(s: ^Sim, a: ^Sim_Node, v: u64) {
		s.now += 3
		a.node.now = sim_now(s, a)
		body: [24]byte
		put_u64(body[:], 1 << 32 | 5)
		put_u64(body[8:], 5)
		put_u64(body[16:], v)
		row := node_id(&a.node, 1)
		_ = node_write(&a.node, {{row, PLACE, .Place, node_stamp(&a.node), body[:]}})
	}
	for i in u64(0) ..< 600 {
		place(&s, a, (i + 1) * 10)
		if i % 100 == 99 {
			sim_settle(&s)
		}
		free_all(context.temp_allocator)
	}
	sim_settle(&s)
	r.want_checkpoint = true
	sim_settle(&s)
	// The leftmost leaf in a later pack than the leaves about the window.
	place(&s, a, 2)
	sim_settle(&s)
	r.want_checkpoint = true
	sim_settle(&s)

	at_relay := s.links[1].b
	out := &s.links[1].a.out
	at := frame_begin(out, .Watch)
	write_varint(out, 999)
	write_u8(out, transmute(u8)Watch_Flags{data = true, counts = true})
	write_key(out, Key{1 << 32 | 5, 5, 5500, 0, 0})
	write_key(out, Key{1 << 32 | 5, 5, 5600, 0, 0})
	write_varint(out, 0)
	frame_end(out, at)
	sim_settle(&s)
	watch := -1
	for w, i in at_relay.watches {
		if w.id == 999 {
			watch = i
		}
	}
	testing.expect(t, watch >= 0)
	if watch < 0 {
		return
	}
	before := at_relay.watches[watch].before

	for _, c in r.pages {
		free(c.pg)
	}
	clear(&r.pages)
	for kind in Cached {
		for _, b in relay.remote.host.cache[kind] {
			delete(b)
		}
		clear(&relay.remote.host.cache[kind])
	}
	place(&s, a, 1)
	sim_settle(&s)
	testing.expectf(t, at_relay.watches[watch].before == before + 1, "counted %d before the window, not %d", at_relay.watches[watch].before, before + 1)
}

// A relay woken with its cache as it was asks R2 for nothing, and leaves the latest pack cached whole.
@(test)
review_warm_wake_asks_nothing :: proc(t: ^testing.T) {
	keeps :: proc(data: rawptr, kind: Cached, key: u64, bytes: []byte) {
		h := (^Model_Host)(data)
		if old, ok := h.cache[kind][key]; ok {
			delete(old)
		}
		h.cache[kind][key] = slice.clone(bytes)
	}
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	x.remote.host.cache_put = keeps
	for store_work(&x.store) {}
	for i in u64(0) ..< 3000 {
		review_commit(&x.store, {review_cell(i + 1, 1, 10 + i, {byte(i), byte(i >> 8), 1, 2})})
	}
	x.remote.want_checkpoint = true
	remote_store_settle(t, &x)
	first := x.remote.kept_gen << PACK_SHIFT
	cached := review_pack_cached(&x.host, x.remote.kept_gen)
	testing.expectf(t, cached > 2 * PAGE_RUN, "only %d pages cached", cached)
	probe_page: Page
	target := first + 2 * PAGE_RUN
	testing.expect(t, remote_cached(&x.remote, target, &probe_page))

	remote_store_close(&x)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	x.remote.host.cache_put = keeps
	remote_ops(&x.remote)
	gets := x.remote.stats.gets
	for len(x.host.ops) > 0 {
		review_answer(&x.host, &x.remote, 0, true)
	}
	testing.expectf(t, gets == 0, "%d gets on a warm wake", gets)
	testing.expect(t, remote_cached(&x.remote, target, &probe_page), "the latest pack is no longer cached whole")
}

// A relay woken with a watcher's counts to make again, and a change before they are: the watcher hears of it, rather
// than the change being counted in silently as though it had been told.
@(test)
review_counts_kept_through_sleep :: proc(t: ^testing.T) {
	state := seeded(77)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	s.lazy = .Remote
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	relay := s.nodes[2]
	r := &relay.remote.remote
	relay.remote.host.fail = 0
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)

	a := s.nodes[0]
	place :: proc(s: ^Sim, a: ^Sim_Node, row: Id, v: u64) {
		s.now += 3
		a.node.now = sim_now(s, a)
		body: [24]byte
		put_u64(body[:], 1 << 32 | 5)
		put_u64(body[8:], 5)
		put_u64(body[16:], v)
		_ = node_write(&a.node, {{row, PLACE, .Place, node_stamp(&a.node), body[:]}})
	}
	for i in u64(0) ..< 600 {
		place(&s, a, node_id(&a.node, 1), (i + 1) * 10)
		if i % 100 == 99 {
			sim_settle(&s)
		}
		free_all(context.temp_allocator)
	}
	sim_settle(&s)
	r.want_checkpoint = true
	sim_settle(&s)
	place(&s, a, node_id(&a.node, 1), 2)
	row_b := node_id(&a.node, 1)
	place(&s, a, row_b, 9999)
	sim_settle(&s)
	r.want_checkpoint = true
	sim_settle(&s)

	at_relay := s.links[1].b
	out := &s.links[1].a.out
	at := frame_begin(out, .Watch)
	write_varint(out, 999)
	write_u8(out, transmute(u8)Watch_Flags{data = true, counts = true})
	write_key(out, Key{1 << 32 | 5, 5, 5500, 0, 0})
	write_key(out, Key{1 << 32 | 5, 5, 5600, 0, 0})
	write_varint(out, 0)
	frame_end(out, at)
	sim_settle(&s)

	saved_b := make([dynamic]byte)
	defer delete(saved_b)
	testing.expect(t, session_save(at_relay, &saved_b))
	saved_a := make([dynamic]byte)
	defer delete(saved_a)
	testing.expect(t, session_save(s.links[0].b, &saved_a))
	before_sleep := 0
	for w in at_relay.watches {
		if w.id == 999 {
			before_sleep = w.before
		}
	}
	testing.expect(t, before_sleep > 0)
	{
		// As saved by a relay that kept no counts, after a watch with an interest upstream: it reconnects instead, and
		// leaves nothing of itself behind.
		rd := Reader{buf = saved_b[:]}
		_, _, _ = read_varint(&rd), read_u8(&rd), read_key32(&rd)
		for _ in 0 ..< 4 {
			_ = read_varint(&rd)
		}
		old := make([dynamic]byte, context.temp_allocator)
		append(&old, ..saved_b[:rd.pos])
		write_varint(&old, 5)
		write_u8(&old, 8)
		write_key(&old, KEY_MIN)
		write_key(&old, KEY_MAX)
		write_varint(&old, 77)
		for rd.pos < len(rd.buf) {
			id, f := read_varint(&rd), read_u8(&rd)
			lo, hi := read_key(&rd), read_key(&rd)
			write_varint(&old, id)
			write_u8(&old, f & ~u8(64))
			write_key(&old, lo)
			write_key(&old, hi)
			if f & 8 != 0 {
				write_varint(&old, read_varint(&rd))
			}
			if f & 64 != 0 {
				_, _ = read_varint(&rd), read_varint(&rd)
			}
		}
		interests := len(relay.node.interests)
		_, ok := session_load(&relay.node, old[:])
		testing.expect(t, !ok, "revived without counts it may not read")
		testing.expect_value(t, len(relay.node.interests), interests)
	}

	// Asleep, and woken with the latest pack at hand and the older cold.
	session_close(s.links[0].b)
	session_close(s.links[1].b)
	latest := r.kept_gen
	for no, c in r.pages {
		if no >> PACK_SHIFT != latest {
			free(c.pg)
			delete_key(&r.pages, no)
		}
	}
	for kind in Cached {
		for k, b in relay.remote.host.cache[kind] {
			if kind == .Log || k >> PACK_SHIFT != latest {
				delete(b)
				delete_key(&relay.remote.host.cache[kind], k)
			}
		}
	}
	reloaded_a, ok_a := session_load(&relay.node, saved_a[:])
	reloaded_b, ok_b := session_load(&relay.node, saved_b[:])
	testing.expect(t, ok_a && ok_b)
	if !ok_a || !ok_b {
		return
	}
	s.links[0].b, s.links[1].b = reloaded_a, reloaded_b
	_ = session_output(reloaded_b)
	remote_ops(r)

	// The row after the window moves before it.
	place(&s, a, row_b, 1)
	pass :: proc(from, to: ^Session) {
		if b := session_output(from); len(b) > 0 {
			chunk := slice.clone(b, context.temp_allocator)
			session_sent(from, len(chunk))
			_ = session_input(to, chunk)
		}
	}
	pass(s.links[0].a, s.links[0].b)
	told := before_sleep
	heard := false
	for _ in 0 ..< 100 {
		if !relay.node.store.replaying {
			_ = store_sync(&relay.node.store)
		}
		_ = node_retry(&relay.node)
		remote_work(r)
		remote_ops(r)
		pass(s.links[0].b, s.links[0].a)
		if b := session_output(s.links[1].b); len(b) > 0 {
			chunk := slice.clone(b, context.temp_allocator)
			session_sent(s.links[1].b, len(chunk))
			rd := Reader{buf = chunk}
			for rd.pos < len(rd.buf) {
				frame := read_take(&rd, int(read_varint(&rd)))
				if len(frame) > 0 && Message(frame[0]) == .Synced {
					fr := Reader{buf = frame[1:]}
					wid := read_varint(&fr)
					_ = read_u8(&fr)
					_, _ = read_key(&fr), read_key(&fr)
					bef := int(read_varint(&fr))
					_ = read_varint(&fr)
					if wid == 999 {
						heard = true
						told = bef
					}
				}
			}
			_ = session_input(s.links[1].a, chunk)
		}
		remote_ops(r)
		model_tick(&relay.remote.host, r, 1)
		pass(s.links[0].a, s.links[0].b)
		free_all(context.temp_allocator)
	}
	testing.expectf(t, heard && told == before_sleep + 1, "the watcher was told %d before the window (heard %v), not %d", told, heard, before_sleep + 1)
}

// Nor for a latest pack smaller than one run: nothing is asked for past its end.
@(test)
review_warm_wake_of_a_small_pack_asks_nothing :: proc(t: ^testing.T) {
	keeps :: proc(data: rawptr, kind: Cached, key: u64, bytes: []byte) {
		h := (^Model_Host)(data)
		if old, ok := h.cache[kind][key]; ok {
			delete(old)
		}
		h.cache[kind][key] = slice.clone(bytes)
	}
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	x.remote.host.cache_put = keeps
	for store_work(&x.store) {}
	for i in u64(0) ..< 10 {
		review_commit(&x.store, {review_cell(i + 1, 1, 10 + i, {byte(i), 1, 2, 3})})
	}
	x.remote.want_checkpoint = true
	remote_store_settle(t, &x)
	cached := review_pack_cached(&x.host, x.remote.kept_gen)
	testing.expectf(t, cached > 0 && cached <= PAGE_RUN, "a pack of %d pages", cached)
	testing.expect_value(t, x.remote.kept_pages, u64(cached))

	remote_store_close(&x)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	x.remote.host.cache_put = keeps
	remote_ops(&x.remote)
	gets := x.remote.stats.gets
	for len(x.host.ops) > 0 {
		review_answer(&x.host, &x.remote, 0, true)
	}
	testing.expectf(t, gets == 0, "%d gets on a warm wake of a pack of %d pages", gets, cached)
}

// A log of rows, put in object storage and let go of here, for reading back.
@(private)
review_log_store :: proc(t: ^testing.T, x: ^Remote_Store, blocks: int) -> (bytes: int) {
	remote_store_open(t, x, 2048, blocks)
	ROWS :: 300
	big := make([]byte, 6 << 10)
	defer delete(big)
	for i in 0 ..< ROWS {
		body: [24]byte
		put_u64(body[:], 1 << 32 | 1)
		put_u64(body[16:], u64(i))
		row := Id{1 << 32 | u64(i), 7}
		cells := [2]Cell{{row, PLACE, .Place, {u64(i) * 2 + 1, 1}, body[:]}, {row, DATA, .Value, {u64(i) * 2 + 2, 1}, big}}
		remote_store_step(t, x, &cells, proc(s: ^Store, data: rawptr) {store_commit(s, (^[2]Cell)(data)[:])})
		testing.expect(t, store_sync(&x.store))
		remote_store_turn(x, 1 << 20)
		free_all(context.temp_allocator)
	}
	for _ in 0 ..< 5 {
		x.remote.want_checkpoint = true
		remote_store_settle(t, x)
	}
	for _, c in x.remote.blocks {
		delete(c.bytes)
	}
	clear(&x.remote.blocks)
	return ROWS * (len(big) + 100)
}

// A reader of rows in order, from a row on: a step reads the next few.
@(private)
Review_Reader :: struct {
	from: Key,
	to:   Key,
	done: bool,
}

@(private)
review_read_on :: proc(t: ^testing.T, x: ^Remote_Store, f: ^Review_Reader) {
	remote_store_step(t, x, f, proc(s: ^Store, data: rawptr) {
		f := (^Review_Reader)(data)
		scan := tree_scan(s, s.shelf, f.from, f.to)
		rows := 0
		for leaf in tree_next(&scan) {
			cs := row_scan(s, key_row(leaf.key))
			for _ in row_next(s, &cs) {}
			if rows += 1; rows == 4 {
				f.from = key_next(leaf.key)
				return
			}
		}
		f.done = true
	})
}

// A reader slower than what it reads ahead, on a host with room for little: what was read ahead and not yet read is
// kept until it is, rather than let go of and read again.
@(test)
review_slow_reader_keeps_what_it_has_not_read :: proc(t: ^testing.T) {
	state := seeded(5)
	context.random_generator = rand.default_random_generator(&state)
	x: Remote_Store
	defer model_host_destroy(&x.host)
	bytes := review_log_store(t, &x, 1)
	defer remote_store_close(&x)
	before := x.remote.stats.log_gets
	f := Review_Reader{KEY_MIN, KEY_MAX, false}
	for !f.done {
		review_read_on(t, &x, &f)
		remote_ops(&x.remote)
		model_tick(&x.host, &x.remote, 1 << 20)
		remote_rest(&x.remote)
	}
	gets := x.remote.stats.log_gets - before
	testing.expectf(t, gets <= bytes / EXTENT + 6, "%d reads of the log for %d extents of it", gets, bytes / EXTENT + 1)
}

// Two readers at once, each on through its own part of the log: each is read ahead of, as one alone would be.
@(test)
review_readers_read_ahead_each :: proc(t: ^testing.T) {
	state := seeded(5)
	context.random_generator = rand.default_random_generator(&state)
	x: Remote_Store
	defer model_host_destroy(&x.host)
	bytes := review_log_store(t, &x, 256)
	defer remote_store_close(&x)
	before := x.remote.stats.log_gets
	middle: Key
	{
		// The row half way along the shelf.
		i := 0
		scan := tree_scan(&x.store, x.store.shelf, KEY_MIN, KEY_MAX)
		for leaf in tree_next(&scan) {
			if i += 1; i == 150 {
				middle = leaf.key
				break
			}
		}
	}
	readers := [2]Review_Reader{{KEY_MIN, middle, false}, {middle, KEY_MAX, false}}
	for !readers[0].done || !readers[1].done {
		for &f in readers {
			if !f.done {
				review_read_on(t, &x, &f)
			}
		}
		remote_ops(&x.remote)
		model_tick(&x.host, &x.remote, 1 << 20)
		remote_rest(&x.remote)
	}
	gets := x.remote.stats.log_gets - before
	testing.expectf(t, gets <= bytes / EXTENT + 8, "%d reads of the log for %d extents of it", gets, bytes / EXTENT + 1)
}

// A host whose cache has turned over still has every tree's tops: a row is read in one round of fetching, its leaf,
// rather than a round a level down the tree.
@(test)
review_cold_lookup_is_one_round :: proc(t: ^testing.T) {
	state := seeded(COLD_SEED)
	context.random_generator = rand.default_random_generator(&state)
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	keeps :: proc(data: rawptr, kind: Cached, key: u64, bytes: []byte) {
		h := (^Model_Host)(data)
		if old, ok := h.cache[kind][key]; ok {
			delete(old)
		}
		h.cache[kind][key] = slice.clone(bytes)
	}
	x.remote.host.cache_put = keeps
	for store_work(&x.store) {}
	ROWS :: 30000
	for i := u64(0); i < ROWS; i += 100 {
		cells: [100]Cell
		for j in u64(0) ..< 100 {
			cells[j] = review_cell(i + j + 1, DATA, 10 + i + j, {byte(j)})
		}
		review_commit(&x.store, cells[:])
		free_all(context.temp_allocator)
	}
	x.remote.want_checkpoint = true
	remote_store_settle(t, &x)
	testing.expectf(t, page(&x.store, x.store.cells.root).level >= 2, "a tree of %d levels", page(&x.store, x.store.cells.root).level + 1)

	// Woken, with only the tops kept.
	remote_store_close(&x)
	for kind in ([?]Cached{.Page, .Log}) {
		for _, b in x.host.cache[kind] {
			delete(b)
		}
		clear(&x.host.cache[kind])
	}
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	x.remote.host.cache_put = keeps
	// Whatever there is to replay is, first: what is counted is a read of a woken store, not its waking.
	for x.store.replaying {
		store_work(&x.store)
		remote_ops(&x.remote)
		for len(x.host.ops) > 0 {
			review_answer(&x.host, &x.remote, 0, true)
		}
	}
	remote_rest(&x.remote)
	rounds, wanted := 0, 0
	for tries := 0; tries < 10; tries += 1 {
		step := store_begin(&x.store)
		cs := row_scan(&x.store, review_cell(12345, DATA, 0, nil).row)
		for _ in row_next(&x.store, &cs) {}
		missed := store_missed(&x.store, &step)
		store_end(&x.store, &step, false)
		if !missed {
			break
		}
		// Rounds of fetching pages: the log, where the value is in R2, is a round of its own.
		if len(x.remote.want_pages) > 0 {
			rounds += 1
			wanted += len(x.remote.want_pages)
		}
		remote_ops(&x.remote)
		for len(x.host.ops) > 0 {
			review_answer(&x.host, &x.remote, 0, true)
		}
		remote_rest(&x.remote)
	}
	testing.expectf(t, rounds <= 1, "%d rounds of fetching pages for one row", rounds)
	testing.expectf(t, wanted <= 1, "%d pages wanted for one row", wanted)
}

// While writing goes on, no checkpoint until the log waking would replay is CHECKPOINT_TAIL long; once it stops, one if
// there is more than QUIET_TAIL to replay, and none for less.
@(test)
review_checkpoints_wait_for_quiet :: proc(t: ^testing.T) {
	state := seeded(3)
	context.random_generator = rand.default_random_generator(&state)
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	body := make([]byte, 1000)
	defer delete(body)
	write :: proc(t: ^testing.T, x: ^Remote_Store, from, n: u64, body: []byte) {
		for i in from ..< from + n {
			review_commit(&x.store, {review_cell(i + 1, DATA, 10 + i, body)})
			testing.expect(t, store_sync(&x.store))
			remote_store_turn(x, 1 << 20)
			free_all(context.temp_allocator)
		}
	}
	before := x.remote.stats.checkpoints
	n := u64(CHECKPOINT_TAIL / 2 / 1000)
	write(t, &x, 0, n, body)
	testing.expectf(t, x.remote.stats.checkpoints == before, "%d checkpoints while writing went on", x.remote.stats.checkpoints - before)
	testing.expect(t, remote_quiet_due(&x.remote))
	remote_quiet(&x.remote)
	remote_store_settle(t, &x)
	testing.expect_value(t, x.remote.stats.checkpoints, before + 1)
	testing.expect(t, store_tail(&x.store) - x.store.checkpoint <= QUIET_TAIL)
	testing.expect(t, !remote_quiet_due(&x.remote))
	// A little, and quiet: not worth one.
	write(t, &x, n, 2, body)
	testing.expect(t, !remote_quiet_due(&x.remote))
	// On and on: one at CHECKPOINT_TAIL, quiet or not.
	write(t, &x, n + 2, u64(CHECKPOINT_TAIL / 1000) + 2, body)
	testing.expect(t, x.remote.stats.checkpoints >= before + 2)
}

COLD_SEED :: #config(COLD_SEED, 11)

// Where the host has little room, writing that goes on is checkpointed so that it need not wait, whatever QUIET_TAIL is.
@(test)
review_little_room_whatever_quiet :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	remote_limits(&x.remote, 750_000, 1_500_000)
	x.remote.quiet_tail = 64 << 20
	body := make([]byte, 8192)
	defer delete(body)
	stalled := false
	for i in u64(0) ..< 500 {
		body[0] = byte(i)
		review_commit(&x.store, {review_cell(i + 1, DATA, 10 + i, body)})
		testing.expect(t, store_sync(&x.store))
		if remote_full(&x.remote) {
			stalled = true
			break
		}
		remote_work(&x.remote)
		remote_ops(&x.remote)
		for len(x.host.ops) > 0 {
			review_answer(&x.host, &x.remote, 0, true)
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, !stalled, "writing waited, with R2 answering at once: tail %d, local_from %d, checkpoint %d, most %d", store_tail(&x.store), x.remote.local_from, x.store.checkpoint, x.remote.local_most)
}

// A checkpoint that lands before the extent it was to let go of is followed, once the extent lands, by one that does.
@(test)
review_little_room_pack_before_extent :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	remote_limits(&x.remote, 0, 2 * EXTENT)
	body := make([]byte, 8192)
	defer delete(body)
	n := u64(0)
	for store_tail(&x.store) <= EXTENT {
		n += 1
		body[0] = byte(n)
		review_commit(&x.store, {review_cell(n, DATA, 10 + n, body)})
		testing.expect(t, store_sync(&x.store))
		remote_work(&x.remote)
		remote_ops(&x.remote)
		free_all(context.temp_allocator)
	}
	review_answer_all(&x, .Put_Pack, true)
	review_answer_all(&x, .Put_Extent, true)
	stalled := false
	for store_tail(&x.store) <= 2 * EXTENT + 16384 {
		n += 1
		body[0] = byte(n)
		review_commit(&x.store, {review_cell(n, DATA, 10 + n, body)})
		testing.expect(t, store_sync(&x.store))
		if remote_full(&x.remote) {
			stalled = true
			break
		}
		remote_work(&x.remote)
		remote_ops(&x.remote)
		for len(x.host.ops) > 0 {
			review_answer(&x.host, &x.remote, 0, true)
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, !stalled, "writing waited: tail %d, local_from %d, uploaded %d, checkpoint %d, most %d", store_tail(&x.store), x.remote.local_from, x.remote.uploaded, x.store.checkpoint, x.remote.local_most)
}

// A host whose cache has turned over but kept the trees' tops asks R2 for nothing as it wakes: the head of the latest
// pack it asks for is its branches, and it has them.
@(test)
review_cold_wake_asks_nothing :: proc(t: ^testing.T) {
	keeps :: proc(data: rawptr, kind: Cached, key: u64, bytes: []byte) {
		h := (^Model_Host)(data)
		if old, ok := h.cache[kind][key]; ok {
			delete(old)
		}
		h.cache[kind][key] = slice.clone(bytes)
	}
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	x.remote.host.cache_put = keeps
	for store_work(&x.store) {}
	for i in u64(0) ..< 1500 {
		review_commit(&x.store, {review_cell(i + 1, DATA, 100 + i, {byte(i)})})
	}
	x.remote.want_checkpoint = true
	remote_store_settle(t, &x)
	testing.expectf(t, x.remote.kept_pages > PAGE_RUN, "a pack of %d pages", x.remote.kept_pages)
	remote_store_close(&x)
	for kind in ([?]Cached{.Page, .Log}) {
		for _, b in x.host.cache[kind] {
			delete(b)
		}
		clear(&x.host.cache[kind])
	}
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	remote_ops(&x.remote)
	testing.expectf(t, x.remote.stats.gets == 0, "%d gets as it woke, its tops at hand", x.remote.stats.gets)
}

// What the host kept of a pack, or an extent, being deleted when it died is let go of when it wakes, as at the commit
// that would have: dead tops do not stay among the tops for ever.
@(test)
review_dead_tops_go_on_waking :: proc(t: ^testing.T) {
	keeps :: proc(data: rawptr, kind: Cached, key: u64, bytes: []byte) {
		h := (^Model_Host)(data)
		if old, ok := h.cache[kind][key]; ok {
			delete(old)
		}
		h.cache[kind][key] = slice.clone(bytes)
	}
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	x.remote.host.cache_put = keeps
	for store_work(&x.store) {}
	for i in u64(0) ..< 200 {
		review_commit(&x.store, {review_cell(i + 1, DATA, 100 + i, {byte(i)})})
	}
	x.remote.want_checkpoint = true
	remote_store_settle(t, &x)
	pack1 := x.remote.kept_gen
	for i in u64(0) ..< 200 {
		review_commit(&x.store, {review_cell(i + 1, DATA, 900 + i, {byte(i + 1)})})
	}
	x.remote.want_checkpoint = true
	for _ in 0 ..< 10 {
		if x.remote.inflight != nil {
			break
		}
		remote_work(&x.remote)
		remote_ops(&x.remote)
		review_answer_all(&x, .Get_Pages, true)
	}
	// It dies after the manifest is written, before what it superseded is let go of here.
	drop := x.remote.host.cache_drop
	x.remote.host.cache_drop = proc(_: rawptr, _: Cached, _, _: u64) {}
	review_answer_all(&x, .Put_Pack, true)
	x.remote.host.cache_drop = drop
	remote_store_close(&x)
	for op in x.host.ops {
		model_free(op)
	}
	clear(&x.host.ops)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	remote_store_settle(t, &x)
	left := 0
	for kind in ([?]Cached{.Page, .Top}) {
		for k, b in x.host.cache[kind] {
			if k >> PACK_SHIFT == pack1 {
				left += len(b) / PAGE_SIZE
			}
		}
	}
	testing.expectf(t, left == 0, "%d pages of dead pack %d still kept", left, pack1)
}

// Where the host has some room, a small write once object storage has caught up is no reason for a checkpoint: what
// it keeps is not counted as what it must let go of.
@(test)
review_little_room_small_writes_no_checkpoint :: proc(t: ^testing.T) {
	x: Remote_Store
	defer model_host_destroy(&x.host)
	remote_store_open(t, &x)
	defer remote_store_close(&x)
	for store_work(&x.store) {}
	remote_limits(&x.remote, 2 << 20, 4 << 20) // as a relay sets them for a STORAGE_LIMIT of 8 MiB
	big := make([]byte, 8192)
	defer delete(big)
	turn :: proc(t: ^testing.T, x: ^Remote_Store) {
		testing.expect(t, store_sync(&x.store))
		remote_work(&x.remote)
		remote_ops(&x.remote)
		for len(x.host.ops) > 0 {
			review_answer(&x.host, &x.remote, 0, true)
		}
		free_all(context.temp_allocator)
	}
	n := u64(0)
	for store_tail(&x.store) <= (3 << 20) + 65536 {
		n += 1
		big[0] = byte(n)
		review_commit(&x.store, {review_cell(n, DATA, 10 + n, big)})
		turn(t, &x)
	}
	before := x.remote.stats.checkpoints
	small: [100]byte
	for i in u64(0) ..< 20 {
		n += 1
		small[0] = byte(i)
		review_commit(&x.store, {review_cell(n, DATA, 10 + n, small[:])})
		turn(t, &x)
	}
	testing.expectf(t, x.remote.stats.checkpoints == before, "%d checkpoints for 20 small writes: tail %d, local_from %d, uploaded %d", x.remote.stats.checkpoints - before, store_tail(&x.store), x.remote.local_from, x.remote.uploaded)
}
