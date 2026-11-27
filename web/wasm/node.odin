/*
A device's node as a WebAssembly module, for a browser or Node: packages zsp and find behind a handful of
exports. The host gives it files, a clock, entropy and WebSockets; it gives back bytes to send, and says when it
next has something to do. Its local clients are in the same process, and speak to it over a pipe of messages.
*/
package web

import "base:runtime"
import "core:crypto"
import "core:time"
import "../../find"
import "../../zsp"

foreign import host "host"

@(default_calling_convention = "contextless")
foreign host {
	log_write :: proc(off: f64, ptr: [^]byte, len: int) -> bool ---
	log_read :: proc(off: f64, ptr: [^]byte, len: int) -> bool ---
	log_end :: proc() -> f64 ---
	log_drop :: proc(segment: f64) ---
	log_truncate :: proc(off: f64) ---
	log_sync :: proc() -> bool ---
	page_read :: proc(no: u32, ptr: rawptr) -> bool ---
	page_write :: proc(no: u32, ptr: [^]byte, len: int) -> bool ---
	page_sync :: proc() -> bool ---
	find_read :: proc(no: u32, ptr: rawptr) -> bool ---
	find_write :: proc(no: u32, ptr: [^]byte, len: int) -> bool ---
	find_sync :: proc() -> bool ---
	// What is to be given back at the next start: 0 the keys learnt, 1 the roster. Durable when it returns.
	keep :: proc(what: u32, ptr: [^]byte, len: int) -> bool ---
	now :: proc() -> f64 --- // milliseconds since 1970
	// A WebSocket to a relay, binary. `opened`, `input` and `closed` follow.
	dial :: proc(conn: u32, url: [^]byte, len: int) ---
	send :: proc(conn: u32, ptr: [^]byte, len: int) ---
	room :: proc(conn: u32) -> int --- // what may be sent now without piling up
	backlog :: proc(conn: u32) -> int --- // what was sent and is not yet on its way; the host is woken as it goes
	ping :: proc(conn: u32) --- // a text message "ping", for a browser cannot send a WebSocket's own
	hangup :: proc(conn: u32) ---
	say :: proc(level: u32, ptr: [^]byte, len: int) ---
}

// Milliseconds: a connection quiet for so long is pinged, to keep middleboxes and edges from forgetting it; and one that
// does not answer in so long is gone.
ping_idle: f64 = 45_000
pong_wait: f64 = 15_000
SYNC_MOST :: 100 * time.Millisecond // the longest a commit waits to share a sync with others
MAX_PLAIN :: 60 << 10 // per Noise message
PAGES_KEPT :: 2048 // of each kind, before the coldest are let go
FIND_LINGER :: 10 * time.Second

Conn :: struct {
	id:        u32,
	session:   ^zsp.Session,
	dialer:    ^Dialer, // if it is a relay this end dialled; else a local client
	handshake: ^zsp.Handshake,
	channel:   zsp.Channel,
	quiet_at:  f64, // last heard from
	pinged:    bool,
	gone:      bool, // the host has been told to let go of it
	admitted:  bool, // its session has been ready
}

Dialer :: struct {
	key:      zsp.Key32,
	url:      string, // owned
	conn:     ^Conn,
	failures: int,
	due:      f64, // when to try again, while there is no conn
	pinned:   bool, // named by whoever runs this rather than by the roster
	dropped:  bool, // no longer in the roster
}

// Pages read from the host, in two generations: what is touched is kept, and what is not touched for a generation goes.
Pages :: struct {
	hot, cold: map[u32]rawptr,
}

node: zsp.Node
keys: zsp.Keyring
credential: []byte
conns: map[u32]^Conn
next_conn: u32 = 1
dialers: [dynamic]^Dialer
tree_pages, find_pages: Pages
message: [dynamic]byte // handed in and out
synced_at: time.Tick // when the log was last synced
sync_took: time.Duration // and how long that took
sync_due: Maybe(time.Tick)
found: ^Found
failed: bool
started: bool
kept_roster: bool // since adopting began: what says whether a roster was taken is whether it was kept

@(private)
Found :: struct {
	finder:  find.Finder,
	more:    bool, // there is more to do
	idle:    time.Tick, // since when nobody has asked anything
	resting: bool,
}

@(private)
ctx :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.logger = {
		procedure = proc(_: rawptr, level: runtime.Logger_Level, text: string, _: runtime.Logger_Options, _ := #caller_location) {
			say(u32(level), raw_data(text), len(text))
		},
		lowest_level = .Debug,
	}
	return c
}

@(private)
report :: proc(level: runtime.Logger_Level, text: string) {
	say(u32(level), raw_data(text), len(text))
}

// ---------------------------------------------------------------- pages

@(private)
pages_get :: proc(p: ^Pages, no: u32, read: proc "contextless" (no: u32, ptr: rawptr) -> bool) -> rawptr {
	if pg, ok := p.hot[no]; ok {
		return pg
	}
	if pg, ok := p.cold[no]; ok {
		delete_key(&p.cold, no)
		p.hot[no] = pg
		return pg
	}
	pg := new([zsp.PAGE_SIZE]byte)
	if !read(no, pg) {
		free(pg)
		return nil
	}
	p.hot[no] = pg
	return pg
}

@(private)
pages_forget :: proc(p: ^Pages, no: u32) {
	if pg, ok := p.hot[no]; ok {
		free(pg)
		delete_key(&p.hot, no)
	}
	if pg, ok := p.cold[no]; ok {
		free(pg)
		delete_key(&p.cold, no)
	}
}

// Between bursts, and so never while anyone holds a page.
@(private)
pages_rest :: proc(p: ^Pages) {
	if len(p.hot) + len(p.cold) <= PAGES_KEPT {
		return
	}
	for _, pg in p.cold {
		free(pg)
	}
	clear(&p.cold)
	p.hot, p.cold = p.cold, p.hot
}

@(private)
pages_destroy :: proc(p: ^Pages) {
	for _, pg in p.hot {
		free(pg)
	}
	for _, pg in p.cold {
		free(pg)
	}
	delete(p.hot)
	delete(p.cold)
	p^ = {}
}

// ---------------------------------------------------------------- starting

// What the buffer held of a secret, once it is copied where it is kept.
@(private)
wipe :: proc(size: int) {
	if n := min(size, len(message)); n > 0 {
		crypto.zero_explicit(raw_data(message), n)
	}
}

// Where the host should put bytes for the next call.
@(export)
buffer :: proc "c" (size: int) -> [^]byte {
	context = ctx()
	resize(&message, size)
	return raw_data(message)
}

// The start of the buffer, which may have moved.
@(export)
data :: proc "c" () -> [^]byte {
	return raw_data(message)
}

// What the node holds of its memory, in bytes, but for the pages it keeps read from the host, which it lets go of as it
// needs: what something taking and not giving back would add to. Counted only when asked, from the allocator's own
// books, so costing nothing meanwhile.
@(export)
held_bytes :: proc "c" () -> f64 {
	context = ctx()
	used := runtime.wasm_allocator_size() - runtime.wasm_allocator_free_space()
	pages := uint(len(tree_pages.hot) + len(tree_pages.cold) + len(find_pages.hot) + len(find_pages.cold)) * zsp.PAGE_SIZE
	return f64(used - min(used, pages))
}

// How long a segment of the log is: the host's files must agree.
@(export)
segment :: proc "c" () -> f64 {
	return f64(zsp.SEGMENT)
}

// What an admin needs to admit a device, from its secret: its key and its signer's, 64 bytes into `into`.
@(export)
identity :: proc "c" (secret: ^zsp.Key32, into: [^]byte) {
	context = ctx()
	k: zsp.Keyring
	zsp.keyring_init(&k, secret^)
	copy(into[:32], k.device[:])
	copy(into[32:64], k.signer[:])
	zsp.keyring_destroy(&k)
}

// The buffer holds: secret (32), space (32), then the credential, the keys kept, the roster and the one before it,
// each a u32 length, little-endian, and that many bytes. A partial replica keeps what it no longer watches for `age`
// milliseconds, and no more than about `bytes` of all it holds: see zsp/retain.odin; 0 for no bound.
@(export)
start :: proc "c" (full: bool, age, bytes: f64) -> bool {
	context = ctx()
	defer wipe(len(message)) // the secret and the credential, copied to where they are kept
	r := zsp.Reader{buf = message[:]}
	secret, space: zsp.Key32
	copy(secret[:], zsp.read_take(&r, 32))
	copy(space[:], zsp.read_take(&r, 32))
	part :: proc(r: ^zsp.Reader) -> []byte {
		b := zsp.read_take(r, 4)
		if r.bad {
			return nil
		}
		return zsp.read_take(r, int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16 | int(b[3]) << 24)
	}
	cred, kept, roster, before := part(&r), part(&r), part(&r), part(&r)
	if r.bad {
		return false
	}
	credential = make([]byte, len(cred))
	copy(credential, cred)
	zsp.keyring_init(&keys, secret)
	crypto.zero_explicit(&secret, size_of(secret))
	if len(kept) > 0 {
		zsp.keyring_load(&keys, kept)
	}
	node.now = u64(now())
	disk := zsp.Disk {
		log_write = proc(_: rawptr, off: u64, bytes: []byte) -> bool {
			return log_write(f64(off), raw_data(bytes), len(bytes))
		},
		log_read = proc(_: rawptr, off: u64, into: []byte) -> bool {
			return log_read(f64(off), raw_data(into), len(into))
		},
		log_end = proc(_: rawptr) -> u64 {return u64(log_end())},
		log_drop = proc(_: rawptr, segment: u64) {log_drop(f64(segment))},
		log_truncate = proc(_: rawptr, off: u64) {log_truncate(f64(off))},
		log_sync = proc(_: rawptr) -> bool {return log_sync()},
		// A store on a volume of its own uses its pages again, and so never numbers one past 2^32: 16 TiB of tree.
		page = proc(_: rawptr, no: zsp.Page_No) -> ^zsp.Page {
			assert(no <= zsp.Page_No(max(u32)))
			return (^zsp.Page)(pages_get(&tree_pages, u32(no), page_read))
		},
		page_write = proc(_: rawptr, no: zsp.Page_No, bytes: []byte) -> bool {
			assert(no <= zsp.Page_No(max(u32)))
			pages_forget(&tree_pages, u32(no))
			return page_write(u32(no), raw_data(bytes), len(bytes))
		},
		page_sync = proc(_: rawptr) -> bool {return page_sync()},
		close = proc(_: rawptr) {},
	}
	zsp.node_init(&node, disk, space, &keys, full) or_return
	if len(roster) > 0 && !zsp.node_resume(&node, before, roster) {
		report(.Warning, "the saved roster is not sound")
	}
	if node.becoming {
		report(.Info, "this store was a full replica's: it is one until it is level with another, and partial from then on")
	}
	zsp.node_keep(&node, {u64(min(age, 1e15)), u64(min(bytes, 1e18))})
	node.host = {
		keep = proc(_: rawptr, bytes: []byte) {
			// Keys learnt and not kept are lost at the next start, and with them all sealed under them: storage has failed.
			if !keep(0, raw_data(bytes), len(bytes)) {
				report(.Error, "could not keep the keys; stopping rather than going on with what may be lost")
				failed = true
			}
		},
		roster = proc(_: rawptr, bytes: []byte) {
			// Kept after the keys it needs: should they not have been, nor is it, so that a change said to have failed is not
			// found done at the next start, under a roster whose keys were never kept.
			if failed {
				return
			}
			if !keep(1, raw_data(bytes), len(bytes)) {
				report(.Error, "could not keep the roster; stopping rather than going on with what may be lost")
				failed = true
			} else {
				kept_roster = true
			}
			dialers_refresh()
		},
		authenticate = proc(_: rawptr, s: ^zsp.Session, _: []byte) {
			if s.role == .Open {
				// A client in this very process, which the host has already let in by opening it.
				zsp.session_accept(s, {{0, {.Read, .Write, .Call}, 0}})
			} else {
				zsp.session_accept(s) // what it may do is the roster's to say
			}
		},
		questions = questions(),
		reach = relayed_reach,
		link = relayed_input,
		backlog = proc(_: rawptr, s: ^zsp.Session) -> int {
			c := conn_of(s)
			return backlog(c.id) if c != nil else 0
		},
		flush = proc(_: rawptr, s: ^zsp.Session) {
			if c := conn_of(s); c != nil {
				conn_push(c)
			}
		},
	}
	synced_at = time.tick_now()
	started = true
	dialers_refresh()
	free_all(context.temp_allocator)
	return true
}

// How much the store holds, about, in bytes: of cells, and what each costs to keep.
@(export)
held :: proc "c" () -> f64 {
	context = ctx()
	return f64(zsp.store_held(&node.store)) if started else 0
}

// Whether this device belongs to the space, by the roster it holds.
@(export)
member :: proc "c" () -> bool {
	context = ctx()
	return zsp.node_member(&node)
}

// Whether the buffer holds a genuine roster, signed for the space it names; it need not be held by a node to be asked.
@(export)
genuine :: proc "c" (size: int) -> bool {
	context = ctx()
	defer free_all(context.temp_allocator)
	b := message[:size]
	if len(b) < 38 {
		return false
	}
	space: zsp.Key32
	copy(space[:], b[6:38])
	r, ok := zsp.roster_parse(b, space)
	if ok {
		zsp.roster_destroy(&r)
	}
	return ok
}

// Adopts a roster in the buffer, if it is genuine and newer: how a device joins without a relay.
@(export)
adopt :: proc "c" (size: int) -> bool {
	context = ctx()
	return !failed && adopt_kept(message[:size])
}

// Adopts a roster: taken if it is kept, whatever happens after, for at the next start it is what the device holds; and not
// taken if it is not, though held for now, for then it is not.
@(private)
adopt_kept :: proc(bytes: []byte) -> bool {
	kept_roster = false
	zsp.node_adopt(&node, bytes)
	return kept_roster
}

// Keeps a session with a relay, whether or not the roster names it: how a new device reaches the first one it was
// told of. The buffer holds its key (32) and then its URL.
@(export)
relay :: proc "c" (size: int) {
	context = ctx()
	key: zsp.Key32
	copy(key[:], message[:32])
	dial_relay(key, string(message[32:size]), true)
}

// The credential to present to relays from now on, in the buffer, which is wiped: one given by the host as the old one
// expires. A relay that has not admitted this device yet, or is waiting to be tried again, is dialled again at once
// with it; a session it has admitted already goes on as it is, and presents this one when it is next dialled.
@(export)
credential_set :: proc "c" (size: int) {
	context = ctx()
	defer wipe(size)
	if !started {
		return // the host gives it at the start
	}
	given := message[:size]
	if len(credential) > 0 {
		crypto.zero_explicit(raw_data(credential), len(credential))
	}
	delete(credential)
	credential = make([]byte, size)
	copy(credential, given)
	t := now()
	for d in dialers {
		if c := d.conn; c != nil {
			if c.session != nil && c.session.ready {
				continue
			}
			conn_drop(c) // presenting the old one, or about to
		}
		d.failures = 0
		d.due = t
	}
}

// How long a connection to a relay may be quiet before it is pinged, and how long it then has to answer.
@(export)
keepalive :: proc "c" (idle, wait: f64) {
	ping_idle, pong_wait = idle, wait
}

// Lets go of everything, and makes what was written durable. The node is not to be used again.
@(export)
stop :: proc "c" () {
	context = ctx()
	if !started {
		return // of no space yet: there is nothing to stop
	}
	started = false
	relayed_close()
	links_destroy()
	found_close()
	for _, c in conns {
		if c.session != nil {
			zsp.session_close(c.session)
		}
		if c.handshake != nil {
			free(c.handshake)
		}
		free(c)
	}
	clear(&conns)
	// However little was written since: what was let go of, and when lists were last watched, are written down only so.
	if zsp.store_sync(&node.store) {
		zsp.store_checkpoint(&node.store)
	}
	zsp.node_destroy(&node)
	zsp.keyring_destroy(&keys)
	if len(credential) > 0 {
		crypto.zero_explicit(raw_data(credential), len(credential))
	}
	delete(credential)
	credential = nil
	for d in dialers {
		delete(d.url)
		free(d)
	}
	clear(&dialers)
	pages_destroy(&tree_pages)
	pages_destroy(&find_pages)
}

// ---------------------------------------------------------------- connections

// A local client, whose messages carry frames in the open. Returns its number.
@(export)
client :: proc "c" () -> u32 {
	context = ctx()
	c := conn_new()
	c.session = zsp.session_open(&node, .Open, false)
	return c.id
}

@(private)
conn_new :: proc() -> ^Conn {
	c := new(Conn)
	c.id = next_conn
	next_conn += 1
	c.quiet_at = now()
	conns[c.id] = c
	return c
}

// A message from a connection lies in the buffer.
@(export)
input :: proc "c" (id: u32, size: int) {
	context = ctx()
	c := conns[id] or_else nil
	if c == nil || c.gone {
		return
	}
	node.now = u64(now())
	c.quiet_at = now()
	c.pinged = false
	bytes := message[:size]
	ok := true
	switch {
	case c.dialer == nil:
		ok = zsp.session_input(c.session, bytes)
	case c.handshake != nil:
		channel, done := zsp.handshake_finish(c.handshake, bytes, c.dialer.key)
		free(c.handshake)
		c.handshake = nil
		if ok = done; ok {
			c.channel = channel
			c.session = zsp.session_open(&node, .Peer, true, channel.peer, credential, relay = true)
		}
	case c.session != nil:
		plain: []byte
		plain, ok = zsp.channel_open(&c.channel, bytes)
		ok = ok && zsp.session_input(c.session, plain)
	case:
		ok = false
	}
	// One that is closing has its reason said, and is let go once it has.
	if !ok && (c.session == nil || !c.session.closing) {
		conn_drop(c)
	}
	// What was committed goes to the files now, rather than at the end of the burst: the store holds no more of it in
	// memory than one input's worth, however much comes at once; and nor do its trees hold more than a checkpoint's.
	zsp.store_flush(&node.store)
	if zsp.store_wants_checkpoint(&node.store) {
		sync()
	}
}

// Anything at all was heard on a connection, such as the answer to a ping.
@(export)
heard :: proc "c" (id: u32) {
	if c := conns[id] or_else nil; c != nil {
		c.quiet_at = now()
		c.pinged = false
	}
}

// A relay's WebSocket is open: the handshake begins.
@(export)
opened :: proc "c" (id: u32) {
	context = ctx()
	c := conns[id] or_else nil
	if c == nil || c.dialer == nil || c.gone {
		return
	}
	c.quiet_at = now()
	c.handshake = new(zsp.Handshake)
	first, ok := zsp.handshake_start(c.handshake, keys.secret, c.dialer.key, node.space)
	if !ok {
		conn_drop(c)
		return
	}
	send(c.id, &first[0], len(first))
}

// The host lost a connection, or let go of it as told.
@(export)
closed :: proc "c" (id: u32) {
	context = ctx()
	c := conns[id] or_else nil
	if c == nil {
		return
	}
	c.gone = true // so that it is not told to hang up what has already gone
	conn_drop(c)
}

@(private)
conn_drop :: proc(c: ^Conn) {
	delete_key(&conns, c.id)
	if !c.gone {
		hangup(c.id)
	}
	// A session the relay was ready for and that ended of nothing but the connection going is no failure: dialled again
	// soon. One that ended for a reason, the relay's or this end's, as a device the relay turns away has, is.
	clean := false
	if c.session != nil {
		clean = (c.admitted || c.session.ready) && c.session.fault == .None
		zsp.session_close(c.session)
	}
	if c.handshake != nil {
		free(c.handshake)
	}
	if d := c.dialer; d != nil {
		d.conn = nil
		if clean {
			d.failures = 0
		}
		dialer_failed(d)
	}
	free(c)
}

@(private)
conn_of :: proc(s: ^zsp.Session) -> ^Conn {
	for _, c in conns {
		if c.session == s {
			return c
		}
	}
	return nil
}

// What a session has queued already, to the host now, as far as it has room: in the midst of the session's own work or
// another's, so nothing more is made and nothing is let go (see zsp.Host.flush).
@(private)
conn_push :: proc(c: ^Conn) {
	for {
		out := zsp.session_queued(c.session)
		space := room(c.id)
		if len(out) == 0 || space <= 0 {
			return
		}
		n := min(len(out), MAX_PLAIN, space)
		conn_send(c, out[:n])
		zsp.session_sent(c.session, n)
	}
}

@(private)
conn_send :: proc(c: ^Conn, out: []byte) {
	if c.dialer == nil {
		send(c.id, raw_data(out), len(out))
	} else {
		sealed := make([dynamic]byte, 0, len(out) + zsp.TAG, context.temp_allocator)
		zsp.channel_seal(&c.channel, &sealed, out)
		send(c.id, raw_data(sealed), len(sealed))
	}
}

// Draws what a connection's session has to say, for as long as the host has room.
@(private)
conn_flush :: proc(c: ^Conn) {
	s := c.session
	if s == nil {
		return
	}
	for {
		out := zsp.session_output(s)
		space := room(c.id)
		if len(out) == 0 || space <= 0 {
			break
		}
		n := min(len(out), MAX_PLAIN, space)
		conn_send(c, out[:n])
		zsp.session_sent(s, n)
	}
	if s.closing && len(zsp.session_output(s)) == 0 {
		conn_drop(c) // all has been said, the reason last
	}
}

// ---------------------------------------------------------------- relays

@(private)
dialers_refresh :: proc() {
	for r in node.roster.relays {
		dial_relay(r.key, r.url, false)
	}
	for d in dialers {
		d.dropped = !d.pinned
		for r in node.roster.relays {
			if d.key == r.key && d.url == r.url {
				d.dropped = false
			}
		}
	}
}

@(private)
dial_relay :: proc(key: zsp.Key32, url: string, pinned: bool) {
	for d in dialers {
		if d.key == key && d.url == url {
			d.pinned ||= pinned
			return
		}
	}
	d := new(Dialer)
	d.key, d.pinned, d.due = key, pinned, now()
	d.url = string(make([]byte, len(url)))
	copy(transmute([]byte)d.url, url)
	append(&dialers, d)
}

// Tries again, soon at first and then ever less often.
@(private)
dialer_failed :: proc(d: ^Dialer) {
	wait := 200 * f64(u64(1) << uint(min(d.failures, 8)))
	d.failures += 1
	jitter: [1]byte
	crypto.rand_bytes(jitter[:])
	d.due = now() + wait + wait * f64(jitter[0] % 64) / 128
}

@(private)
dialers_run :: proc(t: f64) {
	for d in dialers {
		c := d.conn
		switch {
		case c == nil:
			if !d.dropped && t >= d.due {
				c = conn_new()
				c.dialer = d
				d.conn = c
				dial(c.id, raw_data(d.url), len(d.url))
			}
		case d.dropped:
			conn_drop(c)
		case:
			if c.session != nil && c.session.ready {
				c.admitted = true // not merely answered: whether that was a failure is known when it ends
			}
			quiet := t - c.quiet_at
			if c.pinged && quiet >= pong_wait {
				conn_drop(c)
			} else if !c.pinged && quiet >= ping_idle {
				c.pinged = true
				c.quiet_at = t
				ping(c.id)
			}
		}
	}
}

// ---------------------------------------------------------------- questions

@(private)
questions :: proc() -> zsp.Questions {
	return {
		asked = proc(_: rawptr, session: ^zsp.Session, type: u8, payload: []byte) -> bool {
			return find.finder_asked(finder(), session, type, payload)
		},
		shows = proc(_: rawptr, session: ^zsp.Session, row: zsp.Id) -> bool {
			return found != nil && find.finder_shows(&found.finder, session, row)
		},
		again = proc(_: rawptr, session: ^zsp.Session) {
			if found != nil {
				found.more = true
				find.finder_again(&found.finder, session)
			}
		},
		ended = proc(_: rawptr, session: ^zsp.Session) {
			if found != nil {
				find.finder_ended(&found.finder, session)
			}
		},
		called = proc(_: rawptr, call: u64, device: zsp.Key32, scope: zsp.Scope, body: []byte) {
			find.finder_called(finder(), call, device, body)
		},
		flow = proc(_: rawptr, call: u64, kind: zsp.Flow, payload: []byte) {
			if found != nil {
				found.more = true
				find.finder_flow(&found.finder, call, kind, payload)
			}
		},
		wanted = proc(_: rawptr, _: ^zsp.Session) {
			if found != nil {
				found.more = true
			}
		},
	}
}

// Nothing is kept for questions until something is asked, nor for long after nothing is.
@(private)
finder :: proc() -> ^find.Finder {
	if found == nil {
		found = new(Found)
		disk := find.Disk {
			view = proc(_: rawptr, no: u32) -> []byte {
				pg := pages_get(&find_pages, no, find_read)
				return ([^]byte)(pg)[:find.PAGE_SIZE] if pg != nil else nil
			},
			write = proc(_: rawptr, no: u32, bytes: []byte) -> bool {
				pages_forget(&find_pages, no)
				return find_write(no, raw_data(bytes), len(bytes))
			},
			sync = proc(_: rawptr) -> bool {return find_sync()},
			close = proc(_: rawptr) {pages_destroy(&find_pages)},
		}
		key := zsp.hkdf256(node.space[:], keys.secret[:], transmute([]byte)string("zsp-find"))
		find.finder_open(&found.finder, &node, disk, key)
		found.finder.settled = node.full
		found.finder.pace = true
	}
	found.more = true
	return &found.finder
}

@(private)
found_run :: proc(t: time.Tick) {
	f := found
	if f == nil {
		return
	}
	f.more = !find.finder_run(&f.finder)
	if len(f.finder.live) > 0 || len(f.finder.calls) > 0 {
		f.resting = false
		if !f.more && f.finder.x.unsaved > 1 << 16 {
			found_save()
		}
	} else if !f.resting {
		f.resting, f.idle = true, t
	} else if time.tick_diff(f.idle, t) >= FIND_LINGER {
		found_close()
	}
}

@(private)
found_save :: proc() {
	x := &found.finder.x
	// By a whole sync, which checkpoints and lets go of what is held beyond its bound when it is time to, and stops the node
	// should it fail: not by the store's alone, after which the next tick would think there was nothing to sync.
	if x.unsaved > 0 && x.tailing && sync() && !find.index_save(x) {
		found.more ||= x.failed // it has to be made again
	}
}

@(private)
found_close :: proc() {
	if found == nil {
		return
	}
	found_save()
	find.finder_close(&found.finder)
	free(found)
	found = nil
}

// How long until questions have something to do: zero for at once.
@(private)
found_deadline :: proc(t: time.Tick) -> (wait: time.Duration, ok: bool) {
	switch f := found; {
	case f == nil:
		return
	case f.more:
		return 0, true
	case f.finder.wake != nil:
		return max(time.tick_diff(t, f.finder.wake.?), 0), true
	case f.resting:
		return max(time.tick_diff(t, time.tick_add(f.idle, FIND_LINGER + time.Millisecond)), 0), true
	}
	return
}

// ---------------------------------------------------------------- running

// Makes what was committed durable, and checkpoints if it is time to.
@(private)
sync :: proc() -> bool {
	sync_due = nil
	began := time.tick_now()
	synced := zsp.node_sync(&node)
	synced_at = time.tick_now()
	sync_took = time.tick_diff(began, synced_at)
	if !synced {
		report(.Error, "storage failed; stopping rather than acknowledging what may be lost")
		failed = true
	}
	return synced
}

// What links have to say, over UDP and through relays; and then what every connection has to say, that included.
@(private)
flush_links :: proc(ids: []u32) {
	links_flush()
	#reverse for r, i in relayed {
		relayed_flush(r)
		if r.link.state == .Closed {
			ordered_remove(&relayed, i) // given up, or closed, as it sent: let go now, not when next looked at
			relayed_drop(r)
		}
	}
	for id in ids {
		if c := conns[id] or_else nil; c != nil {
			conn_flush(c)
		}
	}
}

// Everything that follows from what has happened since the last call, once. Returns how many milliseconds until
// there is something to do even if nothing happens; -1 for never, -2 if storage has failed and the node must stop.
@(export)
tick :: proc "c" () -> f64 {
	context = ctx()
	defer free_all(context.temp_allocator)
	if failed {
		return -2
	}
	t := now()
	node.now = u64(t)
	if node.failed {
		report(.Error, "storage failed; stopping rather than going on with what may be lost")
		failed = true
		return -2
	}
	dialers_run(t)
	links_run()
	relayed_run(time.tick_now())
	retain_more := false
	if due := zsp.node_retain_due(&node); due != 0 && f64(due) <= t {
		retain_more = zsp.node_retain(&node) // a step at a time, others' turns between
	}
	found_run(time.tick_now())
	ids := make([dynamic]u32, 0, len(conns), context.temp_allocator)
	for id in conns {
		append(&ids, id)
	}
	for id in ids {
		if c := conns[id] or_else nil; c != nil {
			conn_flush(c) // which may let go of it
		}
	}
	flush_links(ids[:])
	zsp.store_flush(&node.store)
	if zsp.store_unsynced(&node.store) && sync_due == nil {
		// At once, unless syncing would then be busy more than half the time: so one writer waits for one sync, and many
		// writing at once share them, however fast or slow the disk.
		sync_due = time.tick_add(synced_at, min(sync_took, SYNC_MOST))
	}
	if due, ok := sync_due.?; ok && time.tick_diff(due, time.tick_now()) >= 0 {
		if !sync() {
			return -2
		}
		// What was waiting for it may now be said: to clients and relays, and over links, direct or through relays, whose
		// acknowledgments wait for what they acknowledge to be durable as any do.
		flush_links(ids[:])
	}
	pages_rest(&tree_pages)
	pages_rest(&find_pages)
	if cap(message) > 64 << 10 {
		delete(message)
		message = {}
	}

	wait := -1.0
	sooner :: proc(wait: ^f64, ms: f64) {
		if wait^ < 0 || ms < wait^ {
			wait^ = max(ms, 0)
		}
	}
	if due, ok := sync_due.?; ok {
		sooner(&wait, f64(time.tick_diff(time.tick_now(), due)) / f64(time.Millisecond))
	}
	for d in dialers {
		if d.conn == nil && !d.dropped {
			sooner(&wait, d.due - t)
		} else if d.conn != nil {
			sooner(&wait, d.conn.quiet_at + (pong_wait if d.conn.pinged else ping_idle) - t)
		}
	}
	if w, ok := found_deadline(time.tick_now()); ok {
		sooner(&wait, f64(w) / f64(time.Millisecond))
	}
	if retain_more {
		sooner(&wait, 0)
	} else if due := zsp.node_retain_due(&node); due != 0 {
		sooner(&wait, f64(due) - t)
	}
	if w, ok := links_deadline(); ok {
		sooner(&wait, f64(w) / f64(time.Millisecond))
	}
	if due := relayed_deadline(); due != 0 {
		sooner(&wait, f64(i64(due) - i64(now_us())) / 1000)
	}
	return wait
}

// ---------------------------------------------------------------- governing the space

// Makes a space this device owns, as `zspd create` does: the buffer holds the device's secret, and is given back
// holding the space's name (32) and its first roster. Returns that length.
@(export)
create :: proc "c" () -> int {
	context = ctx()
	defer free_all(context.temp_allocator)
	secret: zsp.Key32
	copy(secret[:], message[:32])
	root: zsp.Key32
	crypto.rand_bytes(root[:])
	space := zsp.ed25519_public(root)
	k: zsp.Keyring
	zsp.keyring_init(&k, secret)
	defer zsp.keyring_destroy(&k)
	none: zsp.Roster
	d := zsp.draft_from(&none, u64(now()) << 16)
	home := zsp.draft_scope(&d)
	zsp.draft_grant(&d, k.device, k.signer, home, {.Read, .Write, .Call}).owner = true
	bytes, ok := zsp.roster_sign(&k, root, &d, context.temp_allocator)
	crypto.zero_explicit(&root, size_of(root))
	crypto.zero_explicit(&secret, size_of(secret))
	if !ok {
		return 0
	}
	clear(&message)
	append(&message, ..space[:])
	append(&message, ..bytes)
	return len(message)
}

Govern :: enum u32 {
	Scope = 1, // signed (1): a new scope, whose number is given back
	Admit, // device (32), signer (32), scope (u32), rights (1: 1 read, 2 write, 4 call, 8 vouch)
	Revoke, // device (32), scope (u32, 0 for every one)
	Subject, // device (32), and the rest: whose it is
	Admin, // device (32), signer (32), on (1)
	Owner, // device (32), signer (32)
	Relay, // key (32), and the rest: its URL, the space's place there included
}

// Whether the space a roster is being drawn up for has a scope by this number.
@(private)
draft_has :: proc(d: ^zsp.Draft, scope: zsp.Scope) -> bool {
	for s in d.scopes {
		if s.id == scope {
			return true
		}
	}
	return false
}

// Why governing failed.
NOT_STARTED :: -1
NO_SUCH :: -2 // nonsense, or no such member
NOT_ADMIN :: -3 // this device may not sign rosters
NOT_OWNER :: -4 // only an owner may do that, or an admin who may read every scope
UNSOUND :: -5 // the roster would not be sound: as readers who do not write, where a scope is not signed
NOT_TAKEN :: -6
STORAGE :: -7 // storage has failed, and the node has stopped

// Amends the roster, as zspd's commands do, and adopts it, which says it to everyone. The buffer holds what the change
// needs. Returns a scope's number for Scope, else zero; or why not, below zero.
@(export)
govern :: proc "c" (op: Govern, size: int) -> int {
	context = ctx()
	defer free_all(context.temp_allocator)
	if !started {
		return NOT_STARTED
	}
	if failed {
		return STORAGE
	}
	// Now, and no earlier: a node told nothing for a while has an old idea of the time, and a grant ended at that time
	// would undo what was rightly written since.
	node.now = u64(now())
	if !zsp.keyring_rules(&keys, &node.roster) {
		return NOT_ADMIN
	}
	b := message[:size]
	key :: proc(b: []byte, at: int) -> (k: zsp.Key32) {
		copy(k[:], b[at:at + 32])
		return
	}
	u32le :: proc(b: []byte, at: int) -> u32 {
		return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
	}
	need := [Govern]int{.Scope = 1, .Admit = 69, .Revoke = 36, .Subject = 32, .Admin = 65, .Owner = 64, .Relay = 32}
	if op < .Scope || op > .Relay || size < need[op] {
		return NO_SUCH
	}
	// No earlier than anything this device has seen: what others wrote before then stands.
	d := zsp.draft_from(&node.roster, max(node.now << 16, node.clock))
	result := 0
	switch op {
	case .Scope:
		id := zsp.draft_scope(&d, {.Signed} if b[0] != 0 else {})
		for m in d.members {
			if m.owner || m.admin {
				zsp.draft_grant(&d, m.device, m.signer, id, {.Read, .Write, .Call})
			}
		}
		result = int(id)
	case .Admit:
		if b[68] & ~transmute(u8)zsp.RIGHTS_ALL != 0 {
			return NO_SUCH // a right nobody knows: the roster would be none
		}
		rights := transmute(zsp.Rights)b[68] + {.Read}
		scope := zsp.Scope(u32le(b, 64))
		if !draft_has(&d, scope) {
			return NO_SUCH // a scope the space has not: never one a number may be taken for
		}
		zsp.draft_grant(&d, key(b, 0), key(b, 32), scope, rights)
	case .Revoke:
		device := key(b, 0)
		if m := zsp.roster_member(&node.roster, device); m == nil || m.owner {
			return NO_SUCH // an owner holds the key that is the space, and nothing can take that back
		}
		scope := zsp.Scope(u32le(b, 32))
		if scope != 0 && !draft_has(&d, scope) {
			return NO_SUCH // 0 is every scope; any other must be one the space has
		}
		zsp.draft_revoke(&d, device, scope)
	case .Subject:
		device := key(b, 0)
		found_it := false
		for &m in d.members {
			if m.device == device {
				m.subject = b[32:]
				found_it = true
			}
		}
		if !found_it {
			return NO_SUCH
		}
	case .Admin, .Owner:
		device, signer := key(b, 0), key(b, 32)
		owner := op == .Owner
		yes := owner || b[64] != 0
		if yes {
			// An admin or owner draws up rosters, and so must hold every scope's keys.
			for s in d.scopes {
				zsp.draft_grant(&d, device, signer, s.id, {.Read, .Write, .Call})
			}
		}
		found_it := false
		for &m in d.members {
			if m.device == device {
				m.owner ||= owner
				m.admin = yes if !owner else m.admin
				found_it = true
			}
		}
		if !found_it {
			return NO_SUCH
		}
	case .Relay:
		append(&d.relays, zsp.Relay{key(b, 0), string(b[32:])})
	}
	bytes, signed := zsp.roster_sign(&keys, keys.root, &d, context.temp_allocator)
	if !signed {
		return NOT_OWNER
	}
	parsed, sound := zsp.roster_parse(bytes, node.space)
	if !sound {
		return UNSOUND
	}
	zsp.roster_destroy(&parsed)
	if !adopt_kept(bytes) {
		return STORAGE if failed else NOT_TAKEN
	}
	return result // done, though storage failed after: the node stops, and the next start finds it done
}

// Who is in the space, into the buffer: for each member, device (32), signer (32), flags (1: 1 owner, 2 admin, 4 active),
// subject (u32 length and bytes), then its grants in force (u32 count, and each scope (u32) and rights (1)). Returns the length.
@(export)
members :: proc "c" () -> int {
	context = ctx()
	clear(&message)
	if !started {
		return 0
	}
	put32 :: proc(w: ^[dynamic]byte, v: u32) {
		append(w, byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24))
	}
	for &m in node.roster.members {
		append(&message, ..m.device[:])
		append(&message, ..m.signer[:])
		append(&message, (1 if m.owner else 0) | (2 if m.admin else 0) | (4 if zsp.member_active(&m) else 0))
		put32(&message, u32(len(m.subject)))
		append(&message, ..m.subject)
		n := 0
		for g in m.grants {
			n += 1 if g.until == 0 else 0
		}
		put32(&message, u32(n))
		for g in m.grants {
			if g.until == 0 {
				put32(&message, u32(g.scope))
				append(&message, transmute(u8)g.rights)
			}
		}
	}
	return len(message)
}

