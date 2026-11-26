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
	probe := make([]byte, size_of(Page))
	defer delete(probe)
	testing.expect(t, x.remote.host.cache_get(x.remote.host.data, .Page, last, probe), "the page fetched is not kept")
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
