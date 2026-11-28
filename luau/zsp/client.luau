--!strict
--!native
--!optimize 2
-- A query client. It keeps what is on screen, live, and nothing else: windows over ordered lists that grow
-- in either direction, shared between whoever observes them and let go when nobody does. Writes show at
-- once and survive reconnection. It owns no thread, clock or socket; the host lends it those.

local asking = require("./ask")
local codec = require("./codec")
local sha256 = require("./sha256")
local text = require("./text")

local HELLO, ROSTER, WATCH, UNWATCH, CELLS, ACK = 1, 2, 3, 4, 7, 8
local ASK, UNASK, ANSWER, FETCH = 32, 33, 34, 35
local LIVE, SYNCED, PRESENCE, ERROR, SERVE, CALL, FLOW, AUTHOR = 9, 10, 12, 13, 14, 15, 16, 17
local GRAVE, PLACE, VALUE, PIECE, BUNDLE = 1, 2, 3, 4, 5
local W_DATA, W_LIVE, W_BACK, W_ADOPT, W_COUNTS = 1, 2, 4, 8, 32
local MESSAGE_MOST = 1048576 -- bytes sent down the pipe at a time
local MAX_FRAME = 4 * 1048576 -- the most a node reads as one frame
local F_DATA, F_END, F_FAULT, F_CANCEL, F_CREDIT = 0, 1, 2, 3, 4
local CALL_WINDOW = 262144
local WINDOW_MOST = 16 * CALL_WINDOW -- what a receiver may credit ahead
local WINDOW_QUICK = 0.25 -- seconds: a window used up within this grows
local MAX_OPEN = 1048576 - 192
local ZERO32 = string.rep("\0", 32)
local ZERO16 = string.rep("\0", 16)

local PIECE_BYTES = 4096 -- a piece is sealed at this size,
local PIECE_MOST = 65536 - 128 -- and is never more, as no live frame a node carries is;
local INSERT_MOST = 1 + 2 * (1 + 8 + 5) + 5 -- what an insertion's operation is besides its bytes, at most
local PIECE_SECONDS = 1 -- or this long after it began,
local LIVE_SECONDS = 10 -- and live text unconfirmed for this long is dropped
local LEAP_SECONDS = 15 * 60 -- a node refuses a stamp further ahead of its clock than this
local NOWHERE = "no such position"

export type Wire = { send: (data: buffer) -> (), close: () -> () }
export type Host = {
	-- Opens a pipe to the node: calls `receive` for every message and `closed` once. May yield.
	connect: (receive: (data: buffer | string) -> (), closed: () -> ()) -> Wire?,
	credential: string,
	random: (bytes: number) -> string, -- cryptographic
	now: () -> number, -- seconds since 1970, with fraction
	defer: (f: () -> ()) -> (), -- runs f soon, once the current work is done
	after: (seconds: number, f: () -> ()) -> () -> (), -- runs f later; returns a way to cancel it
	linger: number?, -- seconds a window nobody observes stays warm: 5
}

export type Column = {
	read slot: number,
	read text: boolean,
	read is: string, -- what it can be asked about as
	read encode: (any) -> string,
	read decode: (string) -> any,
	read who: ("last" | "all")?, -- not what is in the slot, but who wrote it
}
export type Table = { [string]: Column }
export type Row = { id: string, order: number, [string]: any }
export type State = {
	read rows: { Row },
	read status: "loading" | "stale" | "ready" | "denied",
	read before: number, -- rows of the list that lie before these,
	read after: number, -- and after
}
export type Answer = {
	read rows: { Row },
	read status: "loading" | "indexing" | "ready" | "stale" | "denied" | "faulty",
	read progress: number, -- of indexing, from 0 to 1
	read total: number, -- rows there are in all,
	read first: number, -- and how many come before these
	read totals: { [string]: any }, -- as named: numbers, or lists of { value, count }
}
type Asked = {
	id: number,
	question: asking.Question,
	schema: Table,
	totals_of: { asking.Told },
	observer: (Answer) -> (),
	ids: { string },
	said: Said?, -- while being sent afresh
	shown: { [string]: boolean },
	once: ((Answer) -> ())?, -- it is to be answered once, and this told
	stopped: boolean, -- though the node may not know yet, and count on its rows being held
	answer: Answer?,
	status: any,
	progress: number,
	total: number,
	first: number,
	totals: { [string]: any },
	changed: boolean,
}
export type Device = { read id: string, read subject: string }

-- A cell, as one string: its kind (1 byte), its stamp (16) and its body, the rest. One string rather than a table of
-- three, which is a fifth of the memory and one allocation, read from what came in a single read.
type Cell = string
-- What a slot holds: its one cell, which is what almost every slot holds; or, of a text's pieces, several, by stamp.
type Cells = Cell | { [string]: Cell }
-- A row as it is held: one table, its cells under their slots' numbers beside its fields. What only some rows need is
-- there only once they need it, so that a row no one edits, types in or views is three fields and its cells.
type Stored = {
	[number]: Cells, -- by slot
	id: string,
	pages: number, -- that hold it
	version: number, -- counts changes to what it holds, that whoever reads it may know whether to again
	dead: true?,
	authors: { [string]: Device }?, -- who wrote each cell, by its slot (a byte) and stamp, where that is known
	texts: { [number]: text.Text }?,
	held: { [number]: number }?, -- open editors, by slot
	asking: (() -> ())?, -- for the sake of those, while nothing else shows it: ends that
	awaited: { () -> () }?, -- by those, until it is here
	lives: { [number]: number }?, -- when live text was last heard, by slot
	views: { [any]: Row }?, -- by table, until the row changes
	dirty: { [number]: boolean }?, -- slots with live text to send
}

-- What a row is made from: room for its three fields and five cells, so that it is made once rather than grown.
local ROW = { id = false, pages = false, version = false, a = false, b = false, c = false, d = false, e = false }
for k in ROW do
	ROW[k] = nil -- the room stays
end

local function cell(kind: number, stamp: string, body: string): Cell
	return string.char(kind) .. stamp .. body
end

local function kind_of(c: Cell): number
	return (string.byte(c, 1))
end

local function stamp_of(c: Cell): string
	return string.sub(c, 2, 17)
end

local function body_of(c: Cell): string
	return string.sub(c, 18)
end

-- The latest value in a slot, if any.
local function latest(row: Stored, slot: number): Cell?
	local v = row[slot]
	if type(v) == "string" then
		return if string.byte(v, 1) == VALUE then v else nil
	end
	local best: Cell? = nil
	for _, c in v or {} :: any do
		if string.byte(c, 1) == VALUE and (not best or c > best) then -- of one kind, the stamp decides
			best = c
		end
	end
	return best
end

-- Whose what is in a slot is: whom the last to write there goes by; or, `all`, everyone who has, in order of their names.
local function whose(row: Stored, slot: number, all: boolean): any
	local v = row[slot]
	local authors = row.authors
	local last: Cell? = nil
	local names: { [string]: boolean } = {}
	local function see(c: Cell)
		if not last or stamp_of(c) > stamp_of(last) then
			last = c
		end
		local who = if authors then authors[string.char(slot) .. stamp_of(c)] else nil
		if who and who.subject ~= "" then
			names[who.subject] = true
		end
	end
	if type(v) == "string" then
		see(v)
	elseif v then
		for _, c in v do
			see(c)
		end
	end
	if all then
		local list: { string } = {}
		for name in names do
			table.insert(list, name)
		end
		table.sort(list)
		return table.freeze(list)
	end
	local who = if last and authors then authors[string.char(slot) .. stamp_of(last)] else nil
	return if who and who.subject ~= "" then who.subject else nil
end

-- Each cell of a slot, as a table: for what reads cells plainly, as tests do.
local function cells_of(row: Stored, slot: number): { { kind: number, stamp: string, body: string, author: Device? } }
	local out = {}
	local v = row[slot]
	local all: { Cell } = if type(v) == "string" then { v } else {}
	if type(v) == "table" then
		for _, c in v do
			table.insert(all, c)
		end
	end
	for _, c in all do
		local stamp = stamp_of(c)
		table.insert(out, { kind = kind_of(c), stamp = stamp, body = body_of(c), author = if row.authors then row.authors[string.char(slot) .. stamp] else nil })
	end
	return out
end

local function forget_author(row: Stored, slot: number, stamp: string)
	local authors = row.authors
	if authors then
		authors[string.char(slot) .. stamp] = nil
		if next(authors) == nil then
			row.authors = nil
		end
	end
end

-- A slot's cells as compact as they go: one held as itself, none not at all.
local function compact(row: Stored, slot: number)
	local v = row[slot]
	if type(v) == "table" then
		local k, c = next(v)
		if k == nil then
			row[slot] = nil
		elseif next(v, k) == nil then
			row[slot] = c
		end
	end
end

-- Versions of rows, of every client here: no two states of any rows have the same, so that one is known again only as
-- itself, though the row be let go of and come again.
local versions = 0
local function version(): number
	versions += 1
	return versions
end

-- That it holds something other than it did: what was read of it is to be read again.
-- (A field set to nil that is not there is made there, empty, in a table that may have to grow for it: so it is only
-- let go of where it is.)
local function unview(row: Stored)
	row.version = version()
	if row.views then
		row.views = nil
	end
end
type Said = { [string]: { [string]: boolean } }
-- What was written and not yet acknowledged; and the editors' texts sealed in it, by row and slot, told why should it never be durable.
type Pending = { seq: number, scope: number, body: string, rows: { string }, cells: number, texts: { string }, done: (() -> ())? }
-- Whoever waits for everything written up to a sequence number: told once each is acknowledged, or that one never will be.
type Barrier = { seq: number, failed: string?, notify: (boolean, string?) -> () }
type Page = {
	id: number,
	window: Window,
	lo: string,
	hi: string,
	open: boolean, -- still owed its first sync
	settled: boolean,
	before: number,
	after: number,
	limit: number, -- as first asked for, until the node says what the page spans
	back: boolean,
	stale: Said?, -- while being sent afresh: rows, and which cells of each are there still
}
export type Window = {
	key: string,
	scope: number,
	list: string,
	schema: Table,
	size: number,
	back: boolean, -- it begins at the end
	pages: { Page },
	keys: { string }, -- of the rows it holds, in order,
	held: { Stored }, -- and the rows, each where its key is
	at: { [Stored]: string }, -- where each of them is among them
	bare: boolean, -- its observers want to know when it changes, not how it is
	observers: { [(State) -> ()]: boolean },
	watching: number,
	state: State?,
	changed: boolean,
	denied: boolean,
	linger: (() -> ())?,
}
-- A call: a stream of messages each way. What comes is credited back, so that more may, once on_data is done with
-- it; on_data returning false keeps it, until `consumed` says how much of it is done with. So a slow reader holds up
-- whoever writes to it, and nothing piles up between them.
export type Call = {
	send: (data: string) -> (), -- what there is no credit for yet waits for it, here
	finish: () -> (),
	cancel: () -> (),
	consumed: (n: number) -> (), -- bytes kept from on_data are done with
	room: () -> number, -- what may be sent now without waiting
	on_data: ((data: string) -> ...boolean)?,
	on_end: (() -> ())?,
	on_fault: ((fault: string) -> ())?,
	on_room: (() -> ())?, -- credit came: room grew
	device: string,
	method: string,
	subject: string?, -- of one that is answered: whom whoever calls goes by
}
export type Call_Options = {
	-- Of the link stream the call takes, 0 most urgent to 7 least: 3 if not said. Something typed at as it is
	-- answered might say 1, a bulk copy 6.
	urgency: number?,
}
type Follower = { f: (string) -> (), on: boolean } -- on until it is stopped, even while the rest are being told

type Live_Call = {
	call: Call,
	side: number,
	finishing: boolean, -- no more will be sent,
	mine_ended: boolean, -- and the other side has been told so
	theirs_ended: boolean,
	credit: number,
	queue: { string }, -- awaiting credit
	queued: number, -- bytes of it
	window: number, -- what the other side may have outstanding
	used: number, -- of it, consumed since the window last grew
	since: number,
}

local Faults = { "denied", "unreachable", "unserved", "lost", "overrun", "busy" }

-- A scope's number, as one is: else it is refused here, rather than said, and refused for good, later.
local function whole(scope: number)
	if type(scope) ~= "number" or scope < 0 or scope > 4294967295 or scope % 1 ~= 0 then
		error("a scope is a whole number below 2^32", 3)
	end
end

-- ---------------------------------------------------------------- columns

local function column(slot: number, is: string, encode: (any) -> string, decode: (string) -> any, who: ("last" | "all")?): Column
	assert(slot >= 16 and slot <= 255 and slot % 1 == 0, "data slots are 16 to 255")
	return table.freeze({ slot = slot, text = is == "text", is = is, encode = encode, decode = decode, who = who })
end

local function same(v: any): any
	return v
end

local columns = {}

function columns.string(slot: number): Column
	return column(slot, "string", same, same)
end

local function encode_number(v: any): string
	return string.pack(">d", v)
end

local function decode_number(s: string): any
	return (string.unpack(">d", s))
end

function columns.number(slot: number): Column
	return column(slot, "number", encode_number, decode_number)
end

function columns.boolean(slot: number): Column
	return column(slot, "boolean", function(v)
		return if v then "\1" else "\0"
	end, function(s)
		return s == "\1"
	end)
end

-- Another row, by its id.
function columns.row(slot: number): Column
	return column(slot, "id", same, same)
end

-- Anything, given a way to write it down. What is written as JSON can be asked about by path.
function columns.custom(slot: number, encode: (any) -> string, decode: (string) -> any): Column
	return column(slot, "string", encode, decode)
end

-- Whose what is in a slot is: whom the last to write there goes by, where the scope says; and everyone who has
-- written there, in order of their names, for texts.
local function unwritable(): string
	error("whose a row is cannot be written")
end

function columns.author(slot: number): Column
	return column(slot, "author", unwritable, same, "last")
end

function columns.authors(slot: number): Column
	return column(slot, "author", unwritable, same, "all")
end

-- Collaborative, streamable text.
function columns.text(slot: number): Column
	return column(slot, "text", same, same)
end

table.freeze(columns)

-- ---------------------------------------------------------------- the client

local Client = {}
Client.__index = Client

local function new_client(host: Host)
	local self = setmetatable({
		host = host,
		wire = nil :: Wire?,
		hang_up = function() end,
		ready = false,
		closed = false,
		failures = 0, -- pipes in a row that never came up, or that the node found fault with
		faulted = false, -- this pipe has: the node said so, or said nonsense
		input = "",
		clock_ms = 0,
		clock_n = 0,
		heard = "", -- the latest stamp heard
		scopes = {} :: { [number]: { rights: number, key: string } },
		authors = {} :: { [number]: Device }, -- by what this pipe calls them: 0 is this client
		devices = {} :: { Device },
		watchers = {} :: { [string]: { [(any) -> ()]: boolean } },
		rows = {} :: { [string]: Stored },
		windows = {} :: { [string]: Window },
		pages = {} :: { [number]: Page },
		next_page = 0,
		asked = {} :: { [number]: Asked },
		next_ask = 0,
		loose = {} :: { [string]: boolean }, -- rows sent for an answer still to come
		shapes = (setmetatable({}, { __mode = "k" }) :: any) :: { [Table]: number },
		next_shape = 0,
		seq = 0,
		pending = {} :: { Pending },
		barriers = {} :: { Barrier }, -- by sequence number
		-- Once closed: until all it wrote is acknowledged, then whether it was, and those who wait to hear.
		closing = nil :: { result: { any }?, waiters: { (boolean, string?) -> () } }?,
		early = {} :: { [{}]: boolean }, -- editors' typing before their rows were here: until it is typed in them
		early_done = nil :: (() -> ())?, -- what a client closed does once it is
		-- Given up on, or refused for good: nothing more is delivered, nor dialled for, and why; counted, as given up on.
		abandoned = nil :: string?,
		abandon_counted = false,
		given_up = {} :: { Pending }, -- what it was given up on with, to be counted with anything sealed after
		owed = nil :: string?, -- what was never to be delivered, with nobody waiting to be told: the next to wait is told
		never_delivered = nil :: string?, -- anything it wrote that never will be delivered, as flushed() says once it is closed
		refused_texts = {} :: { [string]: string }, -- editors' texts, by row and slot, sealed where it may no longer write
		unacked = {} :: { [string]: number }, -- rows in pending, and how often
		out = codec.writer(),
		flushing = false,
		tells = {} :: { [string]: number }, -- what was told of each, so far: one told again within another is told afresh
		faults = {} :: { [Live_Call]: string }, -- calls to be told of their end, unless cancelled first
		calls = {} :: { [number]: Live_Call }, -- ours
		answers = {} :: { [number]: Live_Call }, -- of others
		next_call = 0,
		handlers = {} :: { [string]: (Call, string) -> () },
		followers = {} :: { Follower }, -- made anew as they change: what is being told stays as it was
		typing = {} :: { [Stored]: boolean }, -- rows with live text to send
		tags = {} :: { [number]: { key: string, lists: { [string]: string } } }, -- of lists, by their scope, while its key is the same
		bulk = nil :: { [Window]: { Stored } }?, -- rows to add to windows, all at once
		timers = {} :: { [() -> ()]: boolean }, -- what is to be done later, by the ways to cancel each
	}, Client)
	self:_dial()
	return self
end

export type Client = typeof(new_client(nil :: any))

-- ---------------------------------------------------------------- the pipe

function Client._dial(self: Client)
	if self.wire or self.abandoned or (self.closed and #self.pending == 0) then
		return -- a client closed dials only to deliver what it wrote
	end
	local wire: Wire? = nil
	local over = false
	local function closed()
		if over then
			return
		end
		over = true
		self:_lost()
	end
	self.input = ""
	self.out = codec.writer()
	self.faulted = false
	wire = self.host.connect(function(data)
		if not over then
			self:_receive(data)
		end
	end, closed)
	if not wire then
		-- No node to hand it to: what a client closed wrote can never be delivered, and it is told so, not dropped unsaid.
		if self.closed then
			self:_give_up("the client was closed with no node to deliver what it wrote to")
		end
		closed()
		return
	end
	self.wire = wire
	-- A pipe let go of from this end is as lost as one that broke: nothing says so but this.
	local let_go: Wire = wire
	self.hang_up = function()
		let_go.close()
		closed()
	end
	local w = codec.writer()
	codec.put(w, "\1\4") -- telling who wrote what
	codec.put(w, ZERO32)
	codec.put_varint(w, 0)
	codec.put_bytes(w, self.host.credential)
	self:_frame(HELLO, w)
end

function Client._lost(self: Client)
	local well = self.ready and not self.faulted
	self.wire = nil
	self.ready = false
	table.clear(self.authors)
	-- All of this client's own first, the next pipe asked for too: then those told of it, whatever they do.
	for _, set in { self.calls, self.answers } do
		for _, live in set do
			self.faults[live] = "lost"
		end
		table.clear(set)
	end
	for _, window in self.windows do
		for _, page in window.pages do
			page.settled = false
		end
		self:_touch(window)
	end
	for _, a in table.clone(self.asked) do
		if a.stopped then
			self:_unasked(a)
		elseif a.status == "ready" then
			a.status = "stale"
			self:_touch_answer(a)
		end
	end
	self:_sweep()
	if not self.closed or #self.pending > 0 then
		-- Soon after a pipe that was well; later and later after each that never came up, or that the node found fault
		-- with, since what this client says it would say again.
		if well then
			self.failures = 0
		end
		local wait = math.min(0.1 * 2 ^ self.failures, 10)
		self.failures += 1
		self:_after(wait, function()
			self:_dial()
		end)
	end
	for live in table.clone(self.faults) do
		self:_fault(live)
	end
	self:_tell("status", false)
end

-- Ends the client, saying first whatever is still to be said: what editors have typed is sealed, pipe or none, and
-- nothing it wrote is dropped. The pipe is let go of once all of that is acknowledged, durable on the node this client
-- speaks to, at once when nothing waits; until then the client dials again should the pipe be lost, as an open one does,
-- and does nothing else. It never yields: flushed() waits for that, and says whether it never will be, as with no node to
-- dial, one that refuses this client for good, or a scope it may no longer write in. Questions asked once are answered as
-- far as they got.
function Client.close(self: Client)
	if self.closed then
		return
	end
	self.closed = true
	local closing: { result: { any }?, waiters: { (boolean, string?) -> () } } = { result = nil, waiters = {} }
	self.closing = closing
	-- However it ends, whoever waits for it is told.
	local function settle(ok: boolean, why: string?)
		closing.result = { ok, why }
		for _, notify in closing.waiters do
			notify(ok, why)
		end
		closing.waiters = {}
	end
	local function after()
		-- Nothing else is left to be done later: a closed client keeps nothing awake but the delivery of what it wrote.
		for cancel in table.clone(self.timers) do
			cancel()
		end
		for _, a in table.clone(self.asked) do
			self:_fetched(a) -- as far as it got
		end
		for live in table.clone(self.faults) do
			self:_fault(live) -- calls never made end here, as those made do
		end
	end
	local function finished(ok: boolean, why: string?)
		for cancel in table.clone(self.timers) do
			cancel()
		end
		if self.wire then
			self.hang_up()
		end
		settle(ok, why)
	end
	local function deliver()
		self:_seal_all()
		if self.abandoned then
			-- Given up on, or refused, before it got here: what was sealed since is given up too, and said to be, with the
			-- rest, never sent, though it was framed.
			self.out = codec.writer()
			local why = self:_abandon(self.abandoned, self.abandon_counted)
			self.hang_up()
			after()
			settle(false, why)
			return
		end
		self:_flush()
		if #self.pending == 0 then
			self.hang_up()
			after()
			-- At once: nothing to deliver; unless something it wrote never will be.
			self.owed = nil
			local lost = self.never_delivered
			if lost then
				settle(false, lost)
			else
				settle(true)
			end
			return
		end
		after()
		self:_barrier(function(ok, why)
			self.host.defer(function()
				local lost = self.never_delivered -- the rest delivered, but not all
				if ok and lost then
					finished(false, lost)
				else
					finished(ok, why)
				end
			end)
		end)
		if not self.wire then
			self:_dial() -- now, rather than as an open client would have later
		end
	end
	if next(self.early) then
		-- Questions are answered as far as they got: so are those for rows editors typed in before they were here, and
		-- what they typed is typed in them, to be sealed with the rest.
		self.early_done = deliver
		after()
	else
		deliver()
	end
end

-- Yields until all this client has written is acknowledged, durable on the node it speaks to, and, once it is closed,
-- until all close delivers is. Returns true; or false and why, should any of it never be, or should `timeout` seconds
-- pass first, when it says how much is not yet delivered; and a client closed then gives up on it, dialling no more. Not
-- returning yet is the client still trying: nothing is ever dropped unsaid. Called from a coroutine.
function Client.flushed(self: Client, timeout: number?): (boolean, string?)
	local closing = self.closing
	local up_to = self.seq
	return self:_wait(function(notify)
		if closing then
			if closing.result then
				notify(closing.result[1], closing.result[2])
			else
				table.insert(closing.waiters, notify)
			end
		else
			self:_barrier(notify)
		end
	end, timeout, function(): string
		if self.closed then
			return self:_abandon(nil, true) -- given up on: it dials no more
		end
		return self:_undelivered(false, up_to)
	end)
end

-- Gives up on all it holds, and anything sealed after: why it never will be delivered, counted, as given up on, or as said.
function Client._abandon(self: Client, why: string?, counted: boolean): string
	self.abandoned = why or "given up on"
	self.abandon_counted = counted
	local told = if counted then self:_undelivered(true, math.huge) else why :: string
	self:_give_up(told)
	return told
end

-- How much is written and not yet acknowledged, as what is said of giving up on it: and, closed, what was given up already.
function Client._undelivered(self: Client, closed: boolean, up_to: number): string
	local rows: { [string]: boolean } = {}
	local nrows, cells, bytes = 0, 0, 0
	local all = if closed then table.move(self.pending, 1, #self.pending, #self.given_up + 1, table.clone(self.given_up)) else self.pending
	for _, p in all do
		if p.seq > up_to then
			break
		end
		for _, id in p.rows do
			if not rows[id] then
				rows[id] = true
				nrows += 1
			end
		end
		cells += p.cells
		bytes += #p.body
	end
	return `{if closed then "the client was closed and gave up on" else "gave up waiting for"} {cells} cells of {nrows} rows, {bytes} bytes, not yet acknowledged`
end

-- Yields the coroutine it is called from until `start` is told how it went, unless it is told at once; or until `timeout`
-- seconds pass, when it returns false and what `late` says.
function Client._wait(self: Client, start: ((boolean, string?) -> ()) -> (), timeout: number?, late: (() -> string)?): (boolean, string?)
	local thread = coroutine.running()
	local result: { any }? = nil
	local waiting = false
	local cancel: (() -> ())? = nil
	local function told(ok: boolean, why: string?)
		if result then
			return
		end
		result = { ok, why }
		if cancel then
			cancel()
		end
		if waiting then
			self:_resume(thread)
		end
	end
	if timeout then
		cancel = self.host.after(timeout, function()
			cancel = nil
			if not result then
				told(false, (late :: () -> string)())
			end
		end)
	end
	start(told)
	if not result then
		waiting = true
		coroutine.yield()
	end
	local r = result :: { any }
	return r[1], r[2]
end

-- What editors have typed and not yet sealed, sealed, as the client ends.
function Client._seal_all(self: Client)
	for _, row in self.rows do
		for slot, t in row.texts or {} do
			if t.open ~= "" then
				self:_seal(row, slot)
			end
		end
	end
end

-- Tells `notify` once everything written so far is acknowledged, or that some of it never will be, once the rest is: what
-- was refused never cuts short the delivery of anything else. At once, if nothing is pending.
function Client._barrier(self: Client, notify: (boolean, string?) -> ())
	local owed = self.owed -- something written before it never will be
	self.owed = nil
	local last = self.pending[#self.pending]
	if not last then
		if owed then
			notify(false, owed)
		else
			notify(true)
		end
		return
	end
	table.insert(self.barriers, { seq = last.seq, failed = owed, notify = notify })
end

-- Those waiting for what is no longer pending are told: all written before them is acknowledged, or some never will be.
function Client._unbar(self: Client)
	local lowest = if #self.pending > 0 then self.pending[1].seq else math.huge
	while #self.barriers > 0 and self.barriers[1].seq < lowest do
		local b = table.remove(self.barriers, 1) :: Barrier
		b.notify(b.failed == nil, b.failed)
	end
end

-- What was written that can never be durable is pending no more, and whoever waits for it is told so.
function Client._fail(self: Client, p: Pending, why: string)
	table.remove(self.pending, table.find(self.pending, p) :: number)
	self:_settle(p)
	local told = false
	for _, b in self.barriers do
		if b.seq >= p.seq then
			told = true
			if not b.failed then
				b.failed = why
			end
		end
	end
	if not told and not self.owed then
		self.owed = why -- nobody waits for it yet: whoever next does is told
	end
	self.never_delivered = self.never_delivered or why
	for _, t in p.texts do
		self.refused_texts[t] = why -- and the editor of each text in it, whoever else is told
	end
	self:_unbar()
end

function Client._give_up(self: Client, why: string)
	for _, p in table.clone(self.pending) do
		table.insert(self.given_up, p)
		self:_fail(p, why)
	end
end

-- Runs f later, unless the client is closed first; returns a way to cancel it.
function Client._after(self: Client, seconds: number, f: () -> ()): () -> ()
	if self.closed and #self.pending == 0 then
		return function() end
	end
	local stop: () -> () = function() end
	local function cancel()
		if self.timers[cancel] then
			self.timers[cancel] = nil
			stop()
		end
	end
	self.timers[cancel] = true
	stop = self.host.after(seconds, function()
		self.timers[cancel] = nil
		f()
	end)
	return cancel
end

function Client._frame(self: Client, kind: number, w: codec.Writer?)
	local out = self.out
	codec.put_varint(out, 1 + if w then w.pos else 0)
	codec.put_u8(out, kind)
	if w then
		codec.put(out, codec.string(w))
	end
	self:_later()
end

-- Everything said and shown in one turn goes out, and is told to observers, together.
function Client._later(self: Client)
	if not self.flushing then
		self.flushing = true
		self.host.defer(function()
			self:_flush()
		end)
	end
end

function Client._flush(self: Client)
	self.flushing = false
	-- Rows with live text to send: only those, however many rows are held.
	local typing = self.typing
	self.typing = {}
	for row in typing do
		if row.dirty and next(row.dirty) ~= nil then
			self:_send_live(row)
		end
	end
	local out = self.out
	if out.pos > 0 and self.wire then
		-- A piece at a time, for a pipe is a stream of bytes, and its messages may be no bigger than zspd's WebSockets take,
		-- 8 MiB: a burst of writes bigger than that, said again every time the pipe is dialled, would break it every time.
		-- Emptied first, for sending may break the pipe, or say more, there and then: what is left is for the pipe it was for.
		local size = out.pos
		local written = buffer.create(size)
		buffer.copy(written, 0, out.buf, 0, size)
		out.pos = 0
		local wire = self.wire
		for at = 0, size - 1, MESSAGE_MOST do
			if self.wire ~= wire then
				break
			end
			local n = math.min(MESSAGE_MOST, size - at)
			local piece = buffer.create(n)
			buffer.copy(piece, 0, written, at, n)
			wire.send(piece)
		end
	end
	for _, window in table.clone(self.windows) do
		if window.changed then
			self:_publish(window)
		end
	end
	for _, a in table.clone(self.asked) do
		if a.changed and not a.stopped then
			a.changed = false
			self:_hand(a.observer, self:_answer(a))
		end
	end
end

local function handle(self: Client, r: codec.Reader)
	self:_handle(codec.u8(r), r)
end

function Client._receive(self: Client, data: buffer | string)
	local s = if type(data) == "string" then data else buffer.tostring(data)
	if self.input ~= "" then
		s = self.input .. s
	end
	local at = 1
	while at <= #s do
		-- A frame's length, if it is all there.
		local n, scale, p = 0, 1, at
		while true do
			local b = string.byte(s, p)
			if not b then
				self.input = string.sub(s, at)
				return
			end
			p += 1
			if p - at > 5 then -- no frame is so long
				self.input = ""
				self.faulted = true
				self.hang_up()
				return
			end
			n += b % 128 * scale
			if b < 128 then
				break
			end
			scale *= 128
		end
		if p + n - 1 > #s then
			self.input = string.sub(s, at)
			return
		end
		local r = codec.reader(string.sub(s, p, p + n - 1))
		at = p + n
		local wire = self.wire
		local fine, why = pcall(handle, self, r)
		if not fine then
			if why ~= codec.Malformed then
				-- What is thrown while a frame is read, as by a host, which no code of an application can be: the pipe is
				-- read on from the frame after, on a turn of its own, rather than losing the rest and reading on from inside a
				-- frame.
				if self.wire == wire then
					self.input = string.sub(s, at)
					self.host.defer(function()
						if self.wire == wire then
							self:_receive("")
						end
					end)
				end
				error(why, 0)
			end
			-- Nonsense from the pipe ends the pipe and nothing else.
			self.input = ""
			self.faulted = true
			self.hang_up()
			return
		end
		if self.wire ~= wire then
			return -- let go of, by what it said or by whoever was told of it: nothing more is read from it
		end
	end
	self.input = ""
	self:_later()
end

function Client._handle(self: Client, kind: number, r: codec.Reader)
	if self.closed and kind ~= ACK and kind ~= ROSTER and kind ~= ERROR then
		return -- closed, it only delivers what it wrote
	end
	if kind == CELLS then
		self:_on_cells(r)
	elseif kind == LIVE then
		self:_on_live(r)
	elseif kind == SYNCED then
		self:_on_synced(r)
	elseif kind == ANSWER then
		self:_on_answer(r)
	elseif kind == ACK then
		self:_on_ack(codec.varint(r))
	elseif kind == FLOW then
		self:_on_flow(r)
	elseif kind == CALL then
		self:_on_call(r)
	elseif kind == AUTHOR then
		local number = codec.varint(r)
		local id = codec.take(r, 32)
		local who = table.freeze({ id = id, subject = codec.bytes(r) })
		local was = self.authors[number]
		self.authors[number] = who
		if number == 0 and not (was and was.id == id and was.subject == who.subject) then
			self:_tell("self", who)
		end
	elseif kind == ROSTER then
		self:_on_scopes(r)
	elseif kind == PRESENCE then
		local devices: { Device } = {}
		while r.pos < r.len do
			local id = codec.take(r, 32)
			table.insert(devices, table.freeze({ id = id, subject = codec.bytes(r) }))
		end
		self.devices = table.freeze(devices)
		self:_tell("devices", self.devices)
	elseif kind == ERROR then
		local code = codec.u8(r)
		self.faulted = true
		self:_tell("error", code)
		if code == 2 or code == 3 then
			-- Refused, or speaking another language: trying again is no use, and what is pending never will be durable, nor
			-- anything it seals as it closes: it dials no more.
			self:_abandon(if code == 2 then "the node refused this client" else "the node speaks another version", false)
			self:close()
		end
	end
end

function Client._on_scopes(self: Client, r: codec.Reader)
	self:_heard(codec.take(r, 8))
	table.clear(self.scopes)
	for _, a in self.asked do
		local said: Said = {}
		for _, id in a.ids do
			said[id] = {}
		end
		a.said = said
	end
	while r.pos < r.len do
		local scope = codec.varint(r)
		local rights = codec.u8(r)
		self.scopes[scope] = { rights = rights, key = codec.take(r, 32) }
	end
	if self.ready then
		if self.closed then
			return
		end
		-- Rights have changed: windows waiting for this one open.
		for _, window in self.windows do
			if window.denied and self.scopes[window.scope] then
				for _, page in window.pages do
					self:_watch(page)
				end
				if #window.pages == 0 then
					self:_open(window)
				end
				window.denied = false
				self:_touch(window)
			end
		end
		for _, a in table.clone(self.asked) do
			if a.status == "denied" and not a.stopped then
				self:_ask(a, nil, true)
			end
		end
		self:_tell("status", true)
		return
	end
	self.ready = true
	-- Say again whatever the last pipe was told: what is served, unacknowledged and watched. What this client may no
	-- longer write in is let go of, never to be durable: a node would refuse it, and this client with it, for good.
	if not self.closed then
		for key in self.handlers do
			self:_serve(key, true)
		end
	end
	for _, p in table.clone(self.pending) do
		if not self:may(p.scope, "write") then
			self:_fail(p, "this client may no longer write there")
			continue
		end
		local w = codec.writer()
		codec.put_varint(w, p.seq)
		codec.put(w, p.body)
		self:_frame(CELLS, w)
	end
	if self.closed then
		return -- and nothing more
	end
	for _, window in self.windows do
		if #window.pages == 0 then
			self:_open(window)
		else
			for _, page in window.pages do
				self:_watch(page)
			end
		end
	end
	for _, a in table.clone(self.asked) do -- and none asked meanwhile, twice
		self:_ask(a, nil, true)
	end
	self:_tell("status", true)
end

-- ---------------------------------------------------------------- observing things that are not windows

-- Calls code that is not this client's own, once all that this client does of its own is done: what it throws is its
-- own, thrown on a turn of its own, so that whoever else was to hear does, and nothing of this client is left half done.
function Client._hand(self: Client, f: (any) -> ...any, a: any): any
	local fine, out = pcall(f, a)
	if fine then
		return out
	end
	self.host.defer(function()
		error(out, 0)
	end)
	return nil
end

-- Resumes a thread that waits for this client, on a turn of its own, as a promise would be kept: what it does then is
-- never done in the middle of what this client does, and what it throws is thrown there.
function Client._resume(self: Client, thread: thread)
	self.host.defer(function()
		-- Only one that waits still: one closed or cancelled meanwhile by whoever ran it is let be. What is thrown is the
		-- thread's own.
		if coroutine.status(thread) == "suspended" then
			local fine, why = coroutine.resume(thread)
			if not fine then
				error(why, 0)
			end
		end
	end)
end

-- Each hears, whatever another does, if it is hearing still; and once something else is told of the same, as "status" is
-- by close(), the rest hear that, rather than what is no longer so.
function Client._tell(self: Client, what: string, value: any)
	local set = self.watchers[what]
	if not set then
		return
	end
	local told = (self.tells[what] or 0) + 1
	self.tells[what] = told
	for f in table.clone(set) do
		if self.tells[what] ~= told then
			return
		end
		if set[f] then
			self:_hand(f, value)
		end
	end
end

-- "status" (connected or not), "devices" (those reachable, this one first), "self" (this device, and whom this client
-- goes by) or "error". Returns a way to stop.
function Client.on(self: Client, what: "status" | "devices" | "self" | "error", f: (any) -> ()): () -> ()
	local set = self.watchers[what] or {}
	self.watchers[what] = set
	-- Each is its own, though the same function hear twice: stopping one stops no other.
	local function own(value: any)
		f(value)
	end
	set[own] = true
	-- What is known is told at once, and what that throws is thrown later: the caller has the way to stop it first.
	if what == "status" then
		self:_hand(f, self.ready)
	elseif what == "devices" then
		self:_hand(f, self.devices)
	elseif what == "self" and self.authors[0] then
		self:_hand(f, self.authors[0])
	end
	return function()
		set[own] = nil
	end
end

-- ---------------------------------------------------------------- windows

-- Whether what is written in a scope may be read here, or written, or its methods called. "status" is told when it changes.
function Client.may(self: Client, scope: number, what: "read" | "write" | "call"): boolean
	local s = self.scopes[scope]
	return s ~= nil and bit32.btest(s.rights, if what == "read" then 1 elseif what == "write" then 2 else 4)
end

function Client._tag(self: Client, scope: number, list: string): string
	local s = self.scopes[scope]
	assert(s, "no such scope")
	local of = self.tags[scope]
	if not of or of.key ~= s.key then
		of = { key = s.key, lists = {} }
		self.tags[scope] = of
	end
	local tag = of.lists[list]
	if not tag then
		tag = string.pack(">I4", scope) .. string.sub(sha256(s.key .. list), 1, 12)
		of.lists[list] = tag
	end
	return tag
end

export type Query = {
	scope: number,
	list: string,
	table: Table,
	size: number?, -- rows to a page: 50; 0 for all of them
	from: ("start" | "end")?, -- where to begin: the end
	bare: boolean?, -- observers are only told that it changed, as what is built on the client wants
}

-- Observes a list. The observer hears the current state at once, and every change after, at most once a
-- turn. Returns the window's controls.
function Client.window(self: Client, query: Query, observer: (State) -> ())
	local from = query.from or "end"
	local shape = self.shapes[query.table]
	if not shape then
		self.next_shape += 1
		shape = self.next_shape
		self.shapes[query.table] = shape
	end
	local size = query.size or 50
	if type(size) ~= "number" or size < 0 or size % 1 ~= 0 or size > 9007199254740991 then
		error("a page's size is a whole number", 2)
	end
	whole(query.scope)
	-- A list is named by a string, as its tag is made of one: else it is refused here, not once it is opened, maybe on a
	-- pipe come up, where it would stop all that comes after it.
	if type(query.list) ~= "string" then
		error("a list's name is a string", 2)
	end
	local key = `{query.scope}/{from}/{size}/{shape}/{query.list}/{query.bare == true}`
	local window = self.windows[key]
	if not window then
		local made: Window = {
			key = key,
			scope = query.scope,
			list = query.list,
			schema = query.table,
			size = query.size or 50,
			back = from ~= "start",
			pages = {},
			keys = {},
			held = {},
			at = {},
			bare = query.bare == true,
			observers = {},
			watching = 0,
			state = nil,
			changed = false,
			denied = false,
			linger = nil,
		}
		window = made
		self.windows[key] = made
		if self.ready then
			self:_open(window)
		end
	end
	local linger = window.linger
	if linger then
		linger()
		window.linger = nil
	end
	-- Each observer is its own, though the same function observe twice.
	local function own(state: State)
		observer(state)
	end
	window.observers[own] = true
	window.watching += 1
	self:_hand(own, if window.bare then nil :: any else self:_state(window))
	local stopped = false

	return table.freeze({
		-- The rows now on screen, by position. Loads what is near, lets go of what is far.
		-- A window stopped is looked at no more by whoever stopped it: what they ask of it then asks for nothing, as it may
		-- be let go of already, and a page asked for of it would be watched for good.
		visible = function(first: number, last: number)
			if not stopped then
				self:_visible(window, first, last)
			end
		end,
		load_before = function()
			if not stopped then
				self:_load_before(window)
			end
		end,
		load_after = function()
			if not stopped then
				self:_load_after(window)
			end
		end,
		-- The rows as they are held, in order: for what is built on the client, such as a mirror.
		entries = function(): { { key: string, row: Stored } }
			local out: { { key: string, row: Stored } } = table.create(#window.keys) :: any
			for i, key in window.keys do
				out[i] = { key = key, row = window.held[i] }
			end
			return out
		end,
		stop = function()
			if stopped then
				return
			end
			stopped = true
			window.observers[own] = nil
			window.watching -= 1
			if window.watching == 0 then
				-- Whoever comes back soon finds it still warm.
				window.linger = self:_after(self.host.linger or 5, function()
					self:_forget(window)
				end)
			end
		end,
	})
end

function Client._open(self: Client, window: Window)
	if not self.scopes[window.scope] then
		window.denied = true
		self:_touch(window)
		return
	end
	window.denied = false
	local tag = self:_tag(window.scope, window.list)
	local page = self:_page(window, tag .. string.rep("\0", 24), codec.after(tag))
	table.insert(window.pages, page)
	self:_watch(page, window.size, window.back)
end

function Client._page(self: Client, window: Window, lo: string, hi: string): Page
	self.next_page += 1
	local page: Page = {
		id = self.next_page,
		window = window,
		lo = lo,
		hi = hi,
		open = true,
		settled = false,
		before = 0,
		after = 0,
		limit = 0,
		back = false,
		stale = nil,
	}
	self.pages[page.id] = page
	return page
end

function Client._watch(self: Client, page: Page, limit: number?, back: boolean?, adopt: boolean?)
	if limit then
		page.limit, page.back = limit, back == true
	end
	local w = codec.writer()
	codec.put_varint(w, page.id)
	codec.put_u8(w, W_DATA + W_LIVE + W_COUNTS + (if page.back then W_BACK else 0) + (if adopt then W_ADOPT else 0))
	codec.put_key(w, page.lo)
	codec.put_key(w, page.hi)
	codec.put_varint(w, page.limit)
	if not adopt then
		self:_mark(page)
	end
	self:_frame(WATCH, w)
end

-- What is not mentioned before the next sync is gone.
function Client._mark(self: Client, page: Page)
	local stale: Said = {}
	local held = page.window.held
	for i, key in page.window.keys do
		if key >= page.lo and key < page.hi then
			stale[held[i].id] = {}
		end
	end
	page.stale = stale
end

function Client._drop_page(self: Client, page: Page)
	self.pages[page.id] = nil
	local w = codec.writer()
	codec.put_varint(w, page.id)
	self:_frame(UNWATCH, w)
end

function Client._on_synced(self: Client, r: codec.Reader)
	local page = self.pages[codec.varint(r)]
	if not page then
		return
	end
	local window = page.window
	local flags = codec.u8(r)
	if bit32.btest(flags, 4) then
		window.denied = true
		self:_touch(window)
		return
	end
	if bit32.btest(flags, 2) then
		self:_mark(page)
		return
	end
	local was_lo, was_hi = page.lo, page.hi
	page.lo, page.hi = codec.key(r), codec.key(r)
	page.limit = 0 -- from here on it is a range, however many are in it
	page.before, page.after = codec.varint(r), codec.varint(r)
	page.settled = bit32.btest(flags, 1)
	page.open = false
	local stale = page.stale
	page.stale = nil
	if stale then
		for id, said in stale do
			local row = self.rows[id]
			if row and next(said) ~= nil then
				self:_prune(row, said)
			elseif row and not self:_pending(id) then
				self:_unplace(row, page.lo, page.hi)
			end
		end
	end
	-- A page at an end of the window may come to end short of where it was first said to, as one a partial replica
	-- answered at once from what it held ends where a full one says: what the window showed beyond it is had again by
	-- the page that follows, rather than let go of unseen.
	local function cut(lo: string, hi: string): boolean
		if lo >= hi then
			return false
		end
		for _, key in window.keys do
			if key >= lo and key < hi then
				return true
			end
		end
		return false
	end
	local after = page == window.pages[#window.pages] and cut(page.hi, was_hi)
	local before = page == window.pages[1] and cut(was_lo, page.lo)
	-- Where a full replica says the page ends, what lay past it was never known to be whole.
	self:_trim(window)
	if after then
		self:_load_after(window)
	end
	if before then
		self:_load_before(window)
	end
end

-- A range was said over again and this row was not in it: it was moved away, or deleted, while this client
-- was not listening. Only its place there is known to be wrong. Where else it is, and what is being typed in
-- it, stand.
function Client._unplace(self: Client, row: Stored, lo: string, hi: string)
	for slot, v in row do
		if type(slot) == "number" and slot >= 1 and slot <= 15 then
			if type(v) == "string" then
				local key = string.sub(v, 18, 41) .. row.id
				if key >= lo and key < hi then
					row[slot] = nil
					forget_author(row, slot, stamp_of(v))
				end
			else
				for stamp, c in v do
					local key = string.sub(c, 18, 41) .. row.id
					if key >= lo and key < hi then
						v[stamp] = nil
						forget_author(row, slot, stamp)
					end
				end
				compact(row, slot)
			end
		end
	end
	self:_place(row)
end

-- A row was said over again, whole: what was not said is there no longer, and nothing has said that it went. What is yet
-- to be acknowledged may not have been there to say.
function Client._prune(self: Client, row: Stored, said: { [string]: boolean })
	if self:_pending(row.id) then
		return
	end
	-- Which slots lost something, first: what is done for each may write in the row, which is not to be changed while it is
	-- gone through.
	local gone: { number } = {}
	for slot, v in row do
		if type(slot) ~= "number" then
			continue
		elseif type(v) == "string" then
			if not said[stamp_of(v)] then
				table.insert(gone, slot)
			end
		else
			for stamp in v do
				if not said[stamp] then
					table.insert(gone, slot)
					break
				end
			end
		end
	end
	for _, slot in gone do
		local v = row[slot]
		if type(v) == "string" then
			forget_author(row, slot, stamp_of(v))
			row[slot] = nil
		elseif v then
			for stamp in v do
				if not said[stamp] then
					v[stamp] = nil
					forget_author(row, slot, stamp)
				end
			end
			compact(row, slot)
		end
		self:_rebuild(row, slot)
	end
	if #gone > 0 then
		unview(row)
		self:_place(row)
	end
end

function Client._pending(self: Client, id: string): boolean
	return self.unacked[id] ~= nil
end

function Client._load_before(self: Client, window: Window)
	local first = window.pages[1]
	if not first or first.open or not first.settled or first.before == 0 or not self.ready then
		return
	end
	local tag = string.sub(first.lo, 1, 16)
	local page = self:_page(window, tag .. string.rep("\0", 24), first.lo)
	table.insert(window.pages, 1, page)
	self:_watch(page, window.size, true)
	self:_touch(window)
end

function Client._load_after(self: Client, window: Window)
	local last = window.pages[#window.pages]
	if not last or last.open or not last.settled or last.after == 0 or not self.ready then
		return
	end
	local page = self:_page(window, last.hi, codec.after(string.sub(last.lo, 1, 16)))
	table.insert(window.pages, page)
	self:_watch(page, window.size, false)
	self:_touch(window)
end

function Client._visible(self: Client, window: Window, first: number, last: number)
	-- A window of all of a list is one page, however long it grows, and has nothing beyond it to load.
	if #window.pages == 0 or not self.ready or window.size == 0 then
		return
	end
	local near = window.size // 2
	if first <= near then
		self:_load_before(window)
	end
	if last > #window.keys - near then
		self:_load_after(window)
	end
	-- A page that has grown far past its size is two pages.
	for i, page in window.pages do
		local lo, hi = self:_span(window, page)
		if not page.open and hi - lo > window.size * 2 then
			local middle = window.keys[(lo + hi) // 2]
			local upper = self:_page(window, middle, page.hi)
			upper.open, upper.settled, upper.after = false, page.settled, page.after
			page.hi = middle
			table.insert(window.pages, i + 1, upper)
			self:_watch(upper, 0, false, true)
			self:_watch(page, 0, false, true)
			break
		end
	end
	-- And pages far from anything visible are let go, outermost first.
	while #window.pages > 1 do
		local _, hi = self:_span(window, window.pages[1])
		if window.pages[1].open or hi + window.size * 2 >= first then
			break
		end
		local gone = table.remove(window.pages, 1) :: Page
		window.pages[1].before = math.max(window.pages[1].before, gone.before + hi - 1)
		self:_drop_page(gone)
		self:_trim(window)
		first -= hi - 1
		last -= hi - 1
	end
	while #window.pages > 1 do
		local page = window.pages[#window.pages]
		local lo = self:_span(window, page)
		if page.open or lo - window.size * 2 <= last then
			break
		end
		local count = #window.keys - lo + 1
		table.remove(window.pages)
		local edge = window.pages[#window.pages]
		edge.after = math.max(edge.after, page.after + count)
		self:_drop_page(page)
		self:_trim(window)
	end
end

-- Positions [lo, hi) of a page's entries.
function Client._span(self: Client, window: Window, page: Page): (number, number)
	return self:_find(window, page.lo), self:_find(window, page.hi)
end

-- Position of the first entry at or past a key.
function Client._find(self: Client, window: Window, key: string): number
	local keys = window.keys
	local lo, hi = 1, #keys + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if keys[mid] < key then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

function Client._trim(self: Client, window: Window)
	local lo, hi = window.pages[1].lo, window.pages[#window.pages].hi
	local keys, held = window.keys, window.held
	-- What lies outside is let go of; what is kept stays where it is, and is known where it was.
	local n = 0
	for i, key in keys do
		local row = held[i]
		if key >= lo and key < hi then
			n += 1
			keys[n], held[n] = key, row
		else
			window.at[row] = nil
			self:_release(row)
		end
	end
	for i = #keys, n + 1, -1 do
		keys[i], held[i] = nil, nil
	end
	self:_touch(window)
end

function Client._forget(self: Client, window: Window)
	self.windows[window.key] = nil
	for _, page in window.pages do
		self:_drop_page(page)
	end
	for _, row in window.held do
		self:_release(row)
	end
end

function Client._release(self: Client, row: Stored)
	row.pages -= 1
	if row.pages == 0 and not row.asking and not row.dead then
		self:_keep(row)
	end
	if row.pages == 0 and not row.held and not self:_pending(row.id) then
		self.rows[row.id] = nil
	end
end

-- Has a row that is being edited shown, if nothing else shows it, so that what others write in it is heard of too.
-- Calls back once it is here, or known not to be anywhere.
function Client._keep(self: Client, row: Stored, here: (() -> ())?)
	if row.pages > 0 or not row.held then
		if here then
			here()
		end
		return
	end
	local function question(): asking.Question
		return { scope = string.unpack(">I4", row.id) :: any, table = {}, where = asking.where.ids({ row.id }), limit = 1 }
	end
	local function release()
		local awaited = row.awaited
		if awaited then
			row.awaited = nil
		end
		for _, f in awaited or {} do
			f()
		end
	end
	if here then
		local awaited = row.awaited or {}
		row.awaited = awaited
		table.insert(awaited, here)
		-- Once, too: answered by one who holds everything if one can be reached, and otherwise with what is held, as a
		-- partial replica with nobody to ask that can read answers it, never "ready". What waits for the row goes on then.
		if #awaited == 1 then
			coroutine.wrap(function()
				pcall(self.fetch, self, question())
				release()
			end)()
		end
	end
	if row.asking then
		return
	end
	local function hear(answer: Answer)
		if #answer.rows > 0 or answer.status == "ready" or answer.status == "denied" or answer.status == "faulty" then
			release()
		end
	end
	local asked = self:ask(question(), hear)
	if row.held then
		row.asking = asked.stop
	else
		asked.stop()
	end
end

function Client._touch(self: Client, window: Window)
	window.changed = true
	window.state = nil
	self:_later()
end

function Client._state(self: Client, window: Window): State
	local state = window.state
	if state then
		return state
	end
	local rows: { Row } = table.create(#window.keys) :: any
	local held = window.held
	for i, key in window.keys do
		rows[i] = self:_view(held[i], window.schema, key)
	end
	local status: "loading" | "stale" | "ready" | "denied" = "ready"
	for _, page in window.pages do
		if page.open then
			status = "loading"
			break
		elseif not page.settled then
			status = "stale"
		end
	end
	if #window.pages == 0 then
		status = "loading"
	end
	if window.denied then
		status = "denied"
	end
	local first, last = window.pages[1], window.pages[#window.pages]
	local made: State = table.freeze({
		rows = table.freeze(rows :: any),
		status = status,
		before = if first then first.before else 0,
		after = if last then last.after else 0,
	})
	window.state = made
	return made
end

function Client._publish(self: Client, window: Window)
	window.changed = false
	local state = if window.bare then nil :: any else self:_state(window)
	-- Only to those observing still, and only while it is so: once it changes, the rest are told of it as it is then.
	for f in table.clone(window.observers) do
		if window.changed then
			return
		end
		if window.observers[f] then
			self:_hand(f, state)
		end
	end
end

-- A row as the application sees it: one frozen table, the same one until something in it changes.
function Client._view(self: Client, row: Stored, schema: Table, key: string): Row
	local views = row.views
	local view = if views then views[schema] else nil
	local order = codec.from_u64(string.sub(key, 17, 24))
	if view and view.order == order then
		return view
	end
	local made: { [string]: any } = { id = row.id, order = order }
	for name, c in schema do
		if c.who then
			made[name] = whose(row, c.slot, c.who == "all")
		elseif c.text then
			made[name] = self:_read_text(row, c.slot)
		else
			local v = latest(row, c.slot)
			if v then
				-- What cannot be read as the column's kind is no value, rather than the end of everything shown.
				local fine, x = pcall(c.decode, body_of(v))
				made[name] = if fine then x else nil
			end
		end
	end
	table.freeze(made)
	if not views then
		views = {}
		row.views = views
	end
	(views :: any)[schema] = made
	return made :: any
end

-- What a text column reads as. One that nothing has been typed in, only set, is what was set: there is no text to make of
-- it until someone types, or reads it as a text.
function Client._read_text(self: Client, row: Stored, slot: number): string
	local t = if row.texts then row.texts[slot] else nil
	if not t then
		local v = row[slot]
		if v == nil then
			return ""
		elseif type(v) == "string" and string.byte(v, 1) == VALUE then
			return body_of(v)
		end
		return text.read(self:_text(row, slot))
	end
	return text.read(t)
end

-- ---------------------------------------------------------------- rows

function Client._row(self: Client, id: string): Stored
	local row = self.rows[id]
	if not row then
		local made: Stored = table.clone(ROW) :: any
		made.id, made.pages, made.version = id, 0, version()
		row = made
		self.rows[id] = made
	end
	return row
end

local MAX_CELL = 1048576

-- Whether a cell has the shape a node keeps (SPEC.md 1, as zsp/types.odin's cell_valid has it): a kind there is, in a slot
-- for it, with all of its clear prefix, and a bundle whose stamps are in order and before its own. What has not is passed
-- over, as a node would pass it over; whether whoever wrote it might is for the node to say.
local function shaped(id: string, slot: number, c: Cell): boolean
	local n = #c - 17
	if n > MAX_CELL or string.byte(c, 2) >= 128 then -- a body too long, or a time of 2^63 or more
		return false
	end
	local kind = string.byte(c, 1)
	if kind == GRAVE then
		return slot == 0
	elseif kind == PLACE then
		if slot < 1 or slot > 15 or n < 24 or string.unpack(">I4", c, 18) ~= string.unpack(">I4", id) then
			return false
		end
		local a, b, d = string.unpack(">I4I4I4", c, 22)
		return a ~= 0 or b ~= 0 or d ~= 0 -- not the scope's graveyard
	elseif kind == VALUE or kind == PIECE then
		return slot >= 16
	elseif kind == BUNDLE then
		if slot < 16 or n < 4 then
			return false
		end
		local count: number = string.unpack(">I4", c, 18) :: any
		if count == 0 or count > MAX_CELL // 16 or n < 4 + count * 16 then
			return false
		end
		local prev = string.sub(c, 22, 37)
		for i = 1, count - 1 do
			local s = string.sub(c, 22 + i * 16, 37 + i * 16)
			if s <= prev then
				return false
			end
			prev = s
		end
		return prev < string.sub(c, 2, 17)
	end
	return false
end

-- Whether a bundle (a cell, its body from byte 18) holds a piece of this stamp. One too short to say holds none.
local function bundle_has(c: Cell, stamp: string): boolean
	if #c < 21 then
		return false
	end
	local n: number = string.unpack(">I4", c, 18) :: any
	local lo, hi = 0, n
	while lo < hi do
		local mid = (lo + hi) // 2
		local s = string.sub(c, 22 + mid * 16, 37 + mid * 16)
		if s == stamp then
			return true
		elseif s < stamp then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return false
end

-- The merge rule, for a cell. Returns whether it was news.
local function merge(row: Stored, slot: number, c: Cell, author: Device?): boolean
	if row.dead then
		return false
	end
	local kind = string.byte(c, 1)
	if kind == GRAVE then
		row.dead = true
		for k in row do
			if type(k) == "number" then
				row[k] = nil
			end
		end
		if row.authors then
			row.authors = nil
		end
		return true
	end
	local slots = row
	local v = slots[slot]
	local stamp = if v == nil and not author then "" else string.sub(c, 2, 17)
	if v == nil then
		slots[slot] = c
	elseif type(v) == "string" then
		local s = string.sub(v, 2, 17)
		if s == stamp then
			return false
		end
		local k = string.byte(v, 1)
		if (k == PLACE or k == VALUE) and stamp <= s then
			return false
		elseif k == BUNDLE and (kind == PIECE or kind == BUNDLE) and bundle_has(v, stamp) then
			return false
		end
		local drop = false
		if kind == PLACE or kind == VALUE then
			drop = s < stamp
		elseif kind == BUNDLE then
			drop = (k == PIECE or k == BUNDLE) and bundle_has(c, s)
		end
		if drop then
			forget_author(row, slot, s)
			slots[slot] = c
		else
			slots[slot] = { [s] = v, [stamp] = c }
		end
	else
		if v[stamp] then
			return false
		end
		for s, x in v do
			local k = string.byte(x, 1)
			if (k == PLACE or k == VALUE) and stamp <= s then
				return false
			elseif k == BUNDLE and (kind == PIECE or kind == BUNDLE) and bundle_has(x, stamp) then
				return false
			end
		end
		if kind == PLACE or kind == VALUE then
			for s in v do
				if s < stamp then
					v[s] = nil
					forget_author(row, slot, s)
				end
			end
		elseif kind == BUNDLE then
			for s, x in v do
				local k = string.byte(x, 1)
				if (k == PIECE or k == BUNDLE) and bundle_has(c, s) then
					v[s] = nil
					forget_author(row, slot, s)
				end
			end
		end
		v[stamp] = c
		compact(row, slot)
	end
	if author then
		local authors = row.authors or {}
		row.authors = authors
		authors[string.char(slot) .. stamp] = author
	end
	return true
end

-- Whether anything listens for what is said again, as a page or a question being sent afresh does.
function Client._saying(self: Client): boolean
	for _, page in self.pages do
		if page.stale then
			return true
		end
	end
	for _, a in self.asked do
		if a.said then
			return true
		end
	end
	return false
end

function Client._on_cells(self: Client, r: codec.Reader)
	-- What came before any nonsense in a message is placed, as it is held; and so is let go of what has nothing in it.
	local touched: { [Stored]: boolean } = {}
	local ok, why = pcall(self._read_cells, self, r, touched)
	self:_place_all(touched)
	if not ok then
		error(why, 0)
	end
end

function Client._read_cells(self: Client, r: codec.Reader, touched: { [Stored]: boolean })
	codec.varint(r)
	-- Read straight from the message, which is this client's own copy: each cell is made one string in place, its kind
	-- written just before its stamp, which is moved to just before its body, over what has been read already.
	local buf, pos, len = r.buf, r.pos, r.len
	local malformed = codec.Malformed
	local rows = self.rows
	local saying = self:_saying()
	local id = ""
	local scope = 0 -- of the row, as four bytes are read from a buffer
	-- The row, once held: one is made, and is touched, only for a cell that is kept, so that nothing is made or told of for
	-- what is nonsense or passed over.
	local row: Stored? = nil
	local last: Stored? = nil -- touched last
	while pos < len do
		local tag = buffer.readu8(buf, pos)
		pos += 1
		if tag < 128 then
			if pos + 16 > len then
				error(malformed, 0)
			end
			id = buffer.readstring(buf, pos, 16)
			scope = buffer.readu32(buf, pos)
			pos += 16
			row = rows[id]
		elseif id == "" then
			error(malformed, 0) -- the same row as no row before it
		end
		if pos + 18 > len then -- slot, stamp, and a length
			error(malformed, 0)
		end
		local slot = buffer.readu8(buf, pos)
		local at = pos + 1
		pos = at + 16
		local size, scale = 0, 1
		for k = 1, 11 do
			if k == 11 or pos >= len then
				error(malformed, 0) -- a length of more than ten bytes, or none
			end
			local b = buffer.readu8(buf, pos)
			pos += 1
			size += bit32.band(b, 127) * scale
			if b < 128 then
				break
			end
			scale *= 128
		end
		if size > len - pos then
			error(malformed, 0)
		end
		-- What no node could have sent is nonsense, and ends the pipe: a kind there is not, in a slot not its kind's, a place
		-- too short to say where, a bundle too short to hold what it says it does. What a node could have sent but would not
		-- keep, as a place of another scope, is passed over, as it would be (see shaped).
		local kind = tag % 64
		local fine: boolean?
		if kind == VALUE or kind == PIECE then
			if slot < 16 then
				error(malformed, 0)
			end
			fine = true
		elseif kind == PLACE then
			if slot < 1 or slot > 15 or size < 24 then
				error(malformed, 0)
			end
			fine = buffer.readu32(buf, pos) == scope
				and (buffer.readu32(buf, pos + 4) ~= 0 or buffer.readu32(buf, pos + 8) ~= 0 or buffer.readu32(buf, pos + 12) ~= 0)
		elseif kind == GRAVE then
			if slot ~= 0 then
				error(malformed, 0)
			end
			fine = true
		elseif kind == BUNDLE then
			if slot < 16 or size < 4 or 4 + bit32.byteswap(buffer.readu32(buf, pos)) * 16 > size then
				error(malformed, 0)
			end
			fine = nil -- looked at whole
		else
			error(malformed, 0)
		end
		if size > MAX_CELL or buffer.readu8(buf, at) >= 128 then
			fine = false
		end
		-- What it says of the time, read before it is moved.
		local ms = bit32.byteswap(buffer.readu32(buf, at)) * 65536 + bit32.rshift(bit32.byteswap(buffer.readu16(buf, at + 4)), 16)
		local n = bit32.rshift(bit32.byteswap(buffer.readu16(buf, at + 6)), 16)
		buffer.copy(buf, pos - 16, buf, at, 16)
		buffer.writeu8(buf, pos - 17, tag % 64)
		local c = buffer.readstring(buf, pos - 17, 17 + size)
		pos += size
		local author: Device? = nil
		if bit32.btest(tag, 64) then
			r.pos = pos
			author = self.authors[codec.varint(r)]
			pos = r.pos
		end
		if fine == false or (fine == nil and not shaped(id, slot, c)) then
			continue -- what a node would not keep is passed over, as it would be
		end
		if not row then
			row = self:_row(id)
		end
		if row ~= last then
			last = row
			touched[row :: Stored] = true
		end
		-- As late as anything heard of.
		local known = self.clock_ms
		if ms > known or (ms == known and n > self.clock_n) then
			self.clock_ms, self.clock_n = ms, n
		end
		if saying then
			local stamp = string.sub(c, 2, 17)
			for _, page in self.pages do
				local said = page.stale and page.stale[id]
				if said then
					said[stamp] = true
				end
			end
			for _, a in self.asked do
				local said = a.said and a.said[id]
				if said then
					said[stamp] = true
				end
			end
		end
		local into = row :: Stored
		local slots = into
		if slots[slot] == nil and not author and not into.dead and not into.texts and tag % 64 ~= GRAVE then
			-- What almost every cell of a row heard for the first time is: one where there was none.
			slots[slot] = c
			versions += 1
			into.version = versions
			if into.views then
				into.views = nil
			end
		else
			self:_accept(into, slot, c, author)
		end
	end
	r.pos = pos
end

function Client._accept(self: Client, row: Stored, slot: number, c: Cell, author: Device?): boolean
	if not merge(row, slot, c, author) then
		-- Known already; but perhaps not whose it is, or by what name they go now.
		local stamp = string.sub(c, 2, 17)
		local v = row[slot]
		local held: Cell? = if type(v) == "string" then (if string.sub(v, 2, 17) == stamp then v else nil) elseif v then v[stamp] else nil
		if held and author then
			local authors = row.authors or {}
			row.authors = authors
			local was = authors[string.char(slot) .. stamp]
			if not was or was.subject ~= author.subject then
				unview(row)
			end
			authors[string.char(slot) .. stamp] = author
		end
		if held and string.byte(held, 1) == BUNDLE and string.byte(c, 1) == BUNDLE and held ~= c and string.sub(held, 18) ~= string.sub(c, 18) then
			-- A bundle with less of it, since its author may no longer have written the rest (SPEC.md 4): another body for what
			-- is held is otherwise no news.
			local less = string.sub(held, 1, 17) .. string.sub(c, 18)
			if type(v) == "string" then
				row[slot] = less
			else
				(v :: any)[stamp] = less
			end
			self:_rebuild(row, slot)
		end
		return false
	end
	local kind = string.byte(c, 1)
	local t = if row.texts then row.texts[slot] else nil
	if t and kind >= VALUE then
		if text.apply(t, kind, string.sub(c, 2, 17), string.sub(c, 18)) == "rebuild" then
			self:_rebuild(row, slot)
		end
	end
	unview(row)
	return true
end

-- The text in a slot, made from its cells when first wanted.
function Client._text(self: Client, row: Stored, slot: number): text.Text
	local texts = row.texts
	local t = if texts then texts[slot] else nil
	if not t then
		t = text.new()
		if not texts then
			texts = {}
			row.texts = texts
		end
		(texts :: any)[slot] = t
		local v = row[slot]
		if type(v) == "string" then
			text.apply(t, string.byte(v, 1), stamp_of(v), body_of(v))
		elseif v then
			-- In the order of their stamps, which the set is keyed by: sorted as strings are, with nothing cut to compare.
			local stamps: { string } = {}
			for stamp in v do
				table.insert(stamps, stamp)
			end
			table.sort(stamps)
			for _, stamp in stamps do
				local c = v[stamp]
				text.apply(t, string.byte(c, 1), stamp, body_of(c))
			end
		end
	end
	return t :: text.Text
end

function Client._rebuild(self: Client, row: Stored, slot: number)
	local texts = row.texts
	local old = if texts then texts[slot] else nil
	if old and old.open ~= "" then
		self:_seal(row, slot) -- nothing typed here may be lost with it
	end
	texts = row.texts
	if texts then
		texts[slot] = nil
		if next(texts) == nil then
			row.texts = nil
		end
	end
	local lives = row.lives
	if lives then
		lives[slot] = nil
		if next(lives) == nil then
			row.lives = nil
		end
	end
	unview(row)
end

-- A place's key: the first 24 bytes of its body, and the row's id. Put together where it is to be read from, which is one
-- string made rather than two, for a place as anyone writes it.
local scratch = buffer.create(64)
local function key_of(c: Cell, id: string): string
	if #c == 41 then
		buffer.writestring(scratch, 0, c)
		buffer.writestring(scratch, 41, id)
		return buffer.readstring(scratch, 17, 24 + #id)
	end
	return string.sub(c, 18, 41) .. id
end

-- Where a row is to be in a window: the least of its places in what the window spans.
local function wanted(row: Stored, lo: string, hi: string): string?
	if row.dead then
		return nil
	end
	local want: string? = nil
	for slot, v in row do
		if type(slot) == "number" and slot >= 1 and slot <= 15 then
			if type(v) == "string" then
				local key = key_of(v, row.id)
				if key >= lo and key < hi and (not want or key < want) then
					want = key
				end
			else
				for _, c in v do
					local key = key_of(c, row.id)
					if key >= lo and key < hi and (not want or key < want) then
						want = key
					end
				end
			end
		end
	end
	return want
end

-- Puts a row where its placements say, in every window, and takes it from where they do not. Followers hear of it
-- first, unless they have been told already.
function Client._place(self: Client, row: Stored, told: boolean?)
	if not told then
		self:_follow(row)
	end
	local left = false -- some window it was in, which is let go of only once where it now is is known
	for _, window in self.windows do
		if #window.pages > 0 then
			local want = wanted(row, window.pages[1].lo, window.pages[#window.pages].hi)
			local keys = window.keys
			-- Where it is now, found by where it was: keys are in order, and each is a row's own.
			local was = window.at[row]
			local have: number? = if was then self:_find(window, was) else nil
			local queued = if self.bulk then self.bulk[window] else nil
			if have and keys[have] ~= was and queued then
				-- Not among them yet, but among those to be put in all at once: there it stays, or is taken out.
				if want then
					window.at[row] = want
					continue
				end
				table.remove(queued, table.find(queued, row) :: number)
				window.at[row] = nil
				row.pages -= 1
				left = true
				continue
			end
			if have and (not want or keys[have] ~= want) then
				table.remove(keys, have)
				table.remove(window.held, have)
				window.at[row] = nil
				row.pages -= 1
				left = true
				self:_touch(window)
				have = nil
			end
			if want and not have then
				local bulk = self.bulk
				if bulk then
					local add = bulk[window]
					if not add then
						add = {}
						bulk[window] = add
					end
					table.insert(add, row)
				else
					local at = self:_find(window, want)
					table.insert(keys, at, want)
					table.insert(window.held, at, row)
				end
				window.at[row] = want
				row.pages += 1
				if window.state or not window.changed then
					self:_touch(window)
				end
			elseif want and (window.state or not window.changed) then
				self:_touch(window)
			end
		end
	end
	-- A row moved within a window, or from one to another, never left what shows it: an editor of it needs no question.
	if left and row.pages == 0 and not row.asking and not row.dead then
		self:_keep(row)
	end
	self:_touch_asked(row)
	if row.pages <= 0 and not row.held and (row.dead or not self:_pending(row.id)) then
		if next(self.asked) ~= nil and not row.dead then
			self.loose[row.id] = true
		else
			self.rows[row.id] = nil
		end
	end
end

-- Places rows, each once. Many at once go into windows at once: sorted among themselves, by their keys as strings,
-- which needs no call for each comparison, and then merged with what was there. Followers hear of them all first, so
-- that whatever they do of it is done before any row is half put, as one held where it goes and not yet among the rows
-- there.
function Client._place_all(self: Client, rows: { [Stored]: boolean })
	local many = 0
	for _ in rows do
		many += 1
		if many > 64 then
			break
		end
	end
	if many <= 64 or self.bulk then
		for row in rows do
			self:_place(row)
		end
		return
	end
	for row in rows do
		self:_follow(row)
	end
	self.bulk = {}
	for row in rows do
		self:_place(row, true)
	end
	self:_merge_bulk()
end


function Client._merge_bulk(self: Client)
	local bulk = self.bulk
	self.bulk = nil
	for window, add in bulk or {} :: any do
		local at = window.at
		local m = #add
		local keys: { string } = table.create(m) :: any
		local sorted = true
		for i, row in add do
			local key = at[row]
			keys[i] = key
			sorted = sorted and (i == 1 or keys[i - 1] < key)
		end
		local placed: { Stored } = add
		if not sorted then
			-- Sorted as strings, which needs no call for each comparison; and each found again by its key.
			local by: { [string]: Stored } = {}
			for i, row in add do
				by[keys[i]] = row
			end
			table.sort(keys)
			placed = table.create(m) :: any
			for i, key in keys do
				placed[i] = by[key]
			end
		end
		local old_keys, old_held = window.keys, window.held
		local n = #old_keys
		if n == 0 or (m > 0 and old_keys[n] < keys[1]) then
			table.move(keys, 1, m, n + 1, old_keys)
			table.move(placed, 1, m, n + 1, old_held)
		else
			local out_keys: { string } = table.create(n + m) :: any
			local out_held: { Stored } = table.create(n + m) :: any
			local i, j, k = 1, 1, 0
			while i <= n or j <= m do
				k += 1
				if i <= n and (j > m or old_keys[i] < keys[j]) then
					out_keys[k], out_held[k] = old_keys[i], old_held[i]
					i += 1
				else
					out_keys[k], out_held[k] = keys[j], placed[j]
					j += 1
				end
			end
			window.keys, window.held = out_keys, out_held
		end
	end
end

-- ---------------------------------------------------------------- questions

-- Asks a question, which stays asked: the observer hears the answer, and again whenever it changes, at most once
-- a turn. Returns ways to look at another stretch of it, and to stop.
function Client.ask(self: Client, question: asking.Question, observer: (Answer) -> ())
	asking.write(question, function()
		return string.rep("\0", 16)
	end) -- or an error, here rather than later
	self.next_ask += 1
	local a: Asked = {
		id = self.next_ask,
		question = question,
		schema = question.table :: any,
		totals_of = {},
		observer = observer,
		ids = {},
		said = nil,
		shown = {},
		stopped = false,
		once = nil,
		answer = nil,
		status = "loading",
		progress = 0,
		total = 0,
		first = 0,
		totals = {},
		changed = false,
	}
	self.asked[a.id] = a
	if self.ready then
		self:_ask(a)
	end
	self:_hand(observer, self:_answer(a))
	return table.freeze({
		-- A stretch that cannot be asked for is refused at once, and what was asked stands: else it is said again on every
		-- pipe, and refused there.
		move = function(offset: number, limit: number?)
			local q: any = table.clone(a.question)
			q.offset, q.limit = offset, limit or q.limit
			if self.ready and not a.stopped then
				self:_ask(a, q)
			else
				asking.write(q, function()
					return ZERO16
				end)
				a.question = q
			end
		end,
		stop = function()
			if a.stopped then
				return
			end
			a.stopped = true
			if not self.ready then
				self:_unasked(a)
			else
				local w = codec.writer()
				codec.put_varint(w, a.id)
				self:_frame(UNASK, w)
			end
		end,
	})
end

-- Asks a question once, and waits for the answer: for a connection, should there be none, and for the index to be made.
-- Called from a coroutine. Nothing is kept up afterwards, and the rows are as they were.
function Client.fetch(self: Client, question: asking.Question): Answer
	asking.write(question, function()
		return string.rep("\0", 16)
	end)
	local thread = coroutine.running()
	local answer: Answer? = nil
	local waiting = false
	self.next_ask += 1
	local a: Asked = {
		id = self.next_ask,
		question = question,
		schema = question.table :: any,
		totals_of = {},
		observer = function() end,
		ids = {},
		said = nil,
		shown = {},
		once = function(made)
			answer = made
			if waiting then
				self:_resume(thread)
			end
		end,
		stopped = false,
		answer = nil,
		status = "loading",
		progress = 0,
		total = 0,
		first = 0,
		totals = {},
		changed = false,
	}
	self.asked[a.id] = a
	if self.closed then
		self:_fetched(a)
	elseif self.ready then
		self:_ask(a)
	end
	if not answer then
		waiting = true
		coroutine.yield()
	end
	return answer :: any
end

-- Asks a question, or asks it now as it is to be, which it is only once it can be said. One asked again, for a pipe come
-- up or rights that came, that cannot be said, as one whose asker changed it since, is faulty: it alone, and at once.
function Client._ask(self: Client, a: Asked, question: asking.Question?, again: boolean?)
	local q = question or a.question
	local may = self.scopes[q.scope] ~= nil
	local function tag(scope: number, name: string): string
		if self.scopes[scope] then
			return self:_tag(scope, name)
		end
		may = false
		return ZERO16
	end
	local body, totals
	if again then
		local fine, said, told = pcall(asking.write, q, tag)
		if not fine then
			a.status = "faulty"
			self:_show(a, {})
			self:_touch_answer(a)
			self:_fetched(a)
			return
		end
		body, totals = said, told
	else
		body, totals = asking.write(q, tag)
	end
	a.question = q
	if not may then
		a.status = "denied"
		self:_show(a, {})
		self:_touch_answer(a)
		self:_fetched(a)
		return
	end
	a.totals_of = totals
	local w = codec.writer()
	codec.put_varint(w, a.id)
	codec.put(w, body)
	self:_frame(if a.once then FETCH else ASK, w)
end

function Client._on_answer(self: Client, r: codec.Reader)
	local a = self.asked[codec.varint(r)]
	if not a then
		return
	end
	local flags = codec.u8(r)
	if bit32.btest(flags, 16) then
		self:_unasked(a)
		return
	elseif bit32.btest(flags, 14) then
		if bit32.btest(flags, 8) then
			a.status, a.progress = "indexing", codec.u8(r) / 100
		else
			a.status = if bit32.btest(flags, 2) then "denied" else "faulty"
			self:_show(a, {})
		end
		self:_touch_answer(a)
		if a.status ~= "indexing" then
			self:_fetched(a)
		end
		return
	end
	a.status, a.progress = if bit32.btest(flags, 1) then "ready" else "stale", 1
	a.total, a.first = codec.varint(r), codec.varint(r)
	local ids = {}
	for _ = 1, codec.varint(r) do
		table.insert(ids, codec.take(r, 16))
	end
	local again = a.said
	a.said = nil
	self:_show(a, ids)
	for _, id in ids do
		local row = self.rows[id]
		if again and again[id] and next(again[id]) ~= nil and row then
			self:_prune(row, again[id])
		end
	end
	self:_sweep()
	local totals: { [string]: any } = {}
	for i = 1, codec.varint(r) do
		local some = codec.u8(r) ~= 0
		local number = string.unpack(">d", codec.take(r, 8))
		local of = a.totals_of[i]
		local facets: { { read value: any, read count: number } } = {}
		for _ = 1, codec.varint(r) do
			local count = codec.varint(r)
			local value: any = codec.bytes(r)
			if of then
				value = of.read(value)
			end
			table.insert(facets, table.freeze({ value = value, count = count }))
		end
		local out: any = if some then number else nil
		if of and of.facet then
			out = table.freeze(facets)
		elseif #facets > 0 then
			out = facets[1].value -- the least or the most, as it is
		end
		if of then
			totals[of.name] = out
		end
	end
	a.totals = table.freeze(totals)
	self:_touch_answer(a)
	self:_fetched(a)
end

-- What was asked once has been answered, and is of no more concern.
function Client._fetched(self: Client, a: Asked)
	local once = a.once
	if once then
		a.once = nil
		a.stopped = true
		local answer = self:_answer(a)
		self:_unasked(a)
		once(answer)
	end
end

-- Holds the rows of an answer, and lets go of those of the last.
function Client._show(self: Client, a: Asked, ids: { string })
	local old = a.ids
	a.ids = ids
	a.shown = {}
	for _, id in ids do
		a.shown[id] = true
		self:_row(id).pages += 1
	end
	for _, id in old do
		local row = self.rows[id]
		if row then
			self:_release(row)
		end
	end
end

-- A question is no more, here or at the node.
function Client._unasked(self: Client, a: Asked)
	self.asked[a.id] = nil
	self:_show(a, {})
	self:_sweep()
end

-- Lets go of what was sent for an answer and is not in it.
function Client._sweep(self: Client)
	for id in self.loose do
		local row = self.rows[id]
		if row and row.pages <= 0 and not row.held and not self:_pending(id) then
			self.rows[id] = nil
		end
	end
	table.clear(self.loose)
end

function Client._touch_answer(self: Client, a: Asked)
	a.changed, a.answer = true, nil
	self:_later()
end

function Client._touch_asked(self: Client, row: Stored)
	for _, a in self.asked do
		if not a.changed and a.shown[row.id] then
			self:_touch_answer(a)
		end
	end
end

function Client._answer(self: Client, a: Asked): Answer
	local answer = a.answer
	if answer then
		return answer
	end
	local rows: { Row } = table.create(#a.ids) :: any
	for _, id in a.ids do
		local row = self.rows[id]
		if row and not row.dead then
			-- A row's order is that of its first place.
			local key = string.rep("\0", 40)
			for slot = 1, 15 do
				local v = row[slot]
				local c: Cell? = if type(v) == "string" then v elseif v then select(2, next(v)) else nil
				if c then
					key = string.sub(c, 18, 41) .. id
					break
				end
			end
			table.insert(rows, self:_view(row, a.schema, key))
		end
	end
	local made: Answer = table.freeze({
		rows = table.freeze(rows :: any),
		status = a.status,
		progress = a.progress,
		total = a.total,
		first = a.first,
		totals = a.totals,
	})
	a.answer = made
	return made
end

-- ---------------------------------------------------------------- live text

function Client._on_live(self: Client, r: codec.Reader)
	local id = codec.take(r, 16)
	local slot = codec.u8(r)
	local piece = codec.take(r, 8)
	local offset = codec.varint(r)
	codec.take(r, 16)
	local row = self.rows[id]
	if not row or row.dead then
		return
	end
	local t = self:_text(row, slot)
	if text.live(t, piece, offset, codec.rest(r)) == "changed" then
		unview(row)
		self:_place(row)
		local lives = row.lives or {}
		row.lives = lives
		if not lives[slot] then
			self:_expire(row, slot)
		end
		lives[slot] = self.host.now()
	end
end

-- Live text whose writer vanished before sealing it is not text.
function Client._expire(self: Client, row: Stored, slot: number)
	self:_after(LIVE_SECONDS, function()
		local lives = row.lives
		local last = if lives then lives[slot] else nil
		local t = if row.texts then row.texts[slot] else nil
		if not last or not t then
			return
		end
		if not text.provisional(t) then
			(lives :: any)[slot] = nil
			if next(lives :: any) == nil then
				row.lives = nil
			end
		elseif self.host.now() - last >= LIVE_SECONDS then
			self:_rebuild(row, slot)
			self:_place(row)
		else
			self:_expire(row, slot)
		end
	end)
end

function Client._send_live(self: Client, row: Stored)
	local dirty = row.dirty
	row.dirty = nil
	for slot in dirty or {} do
		local t = if row.texts then row.texts[slot] else nil
		if t and t.open ~= "" then
			local piece, offset, bytes = text.flush(t)
			if bytes ~= "" and self.ready then
				local w = codec.writer()
				codec.put(w, row.id)
				codec.put_u8(w, slot)
				codec.put(w, piece)
				codec.put_varint(w, offset)
				codec.put(w, string.rep("\0", 16))
				codec.put(w, bytes)
				self:_frame(LIVE, w)
			end
			if t.size >= PIECE_BYTES then
				self:_seal_shown(row, slot)
			end
		end
	end
end

-- This device, and whom this client goes by, once that is known: "self" is told when it changes.
function Client.me(self: Client): Device?
	return self.authors[0]
end

-- Whose what is written here is, in a scope that says.
function Client._mine(self: Client, scope: number): Device?
	local s = self.scopes[scope]
	return if s and bit32.btest(s.rights, 128) then self.authors[0] else nil
end

-- Seals what is typed, and has it shown: the text is as it was, but whose it is may not be.
function Client._seal_shown(self: Client, row: Stored, slot: number)
	if self:_seal(row, slot) then
		self:_place(row)
	end
end

function Client._seal(self: Client, row: Stored, slot: number): boolean
	local t = if row.texts then row.texts[slot] else nil
	if not t or t.open == "" then
		return false
	end
	local stamp = self:_stamp()
	local body = text.close(t, stamp)
	if body then
		merge(row, slot, cell(PIECE, stamp, body), self:_mine(string.unpack(">I4", row.id) :: any))
		unview(row)
		self:_send_cells({ { row = row.id, slot = slot, kind = PIECE, stamp = stamp, body = body } })
		return true
	end
	return false
end

-- An editor for a text column. Edits show here at once, reach everyone watching as they are made, and
-- become durable a piece at a time.
function Client.text(self: Client, id: string, col: Column)
	assert(col.text, "not a text column")
	assert(type(id) == "string" and #id == 16, "a row's id is 16 bytes")
	local slot = col.slot
	assert(slot >= 16 and slot <= 255 and slot % 1 == 0, "data slots are 16 to 255") -- as a column made by hand may say
	local scope: number = string.unpack(">I4", id) :: any
	-- What is done before there is a row to do it to: none is held, or another editor of it waits for it still.
	local was = self.rows[id]
	local early: { () -> () }? = if was == nil or was.pages == 0 or (was.awaited ~= nil and #was.awaited > 0) then {} else nil
	local row = self:_row(id)
	local holding = row.held or {}
	row.held = holding
	holding[slot] = (holding[slot] or 0) + 1
	local closed, ended = false, false
	-- What is typed before the row is here is typed in it once it is: until then, what is to be done then waits for it.
	local applied: { () -> () }? = if early then {} else nil
	local token = {}
	if early then
		self.early[token] = true
	end
	local function fresh(): string
		return self.host.random(8)
	end
	local function edited()
		local dirty = row.dirty or {}
		row.dirty = dirty
		dirty[slot] = true
		self.typing[row] = true
		unview(row)
		self:_place(row)
		self:_later()
	end
	local timer: (() -> ())? = nil
	local function schedule()
		if not timer then
			timer = self:_after(PIECE_SECONDS, function()
				timer = nil
				self:_seal_shown(row, slot)
			end)
		end
	end
	local function edit(f: (text.Text) -> ())
		assert(not closed and not row.dead, "the text is closed")
		self:_may_write(id, scope)
		if early then
			table.insert(early, function()
				f(self:_text(row, slot))
			end)
			return
		end
		f(self:_text(row, slot))
		edited()
		schedule()
	end
	local function finish()
		if ended or early then
			return
		end
		ended = true
		if timer then
			timer()
		end
		self:_seal(row, slot)
		local holding = row.held :: { [number]: number }
		holding[slot] -= 1
		if holding[slot] == 0 then
			holding[slot] = nil
			if next(holding) == nil then
				row.held = nil
			end
		end
		local asking = row.asking
		if asking and not row.held then
			row.asking = nil
			asking()
		end
		self:_place(row)
	end
	self:_keep(row, function()
		local todo = early
		early = nil
		local fine, why = true, nil
		if todo and #todo > 0 and not row.dead then
			local made = false
			for _, f in todo do
				-- An edit at a place the text did not have once it came was asked of a text not yet here: it is not made,
				-- and those after it are made as if it had not been asked for.
				fine, why = pcall(f)
				if not fine and why ~= NOWHERE then
					break
				end
				made = made or fine
				fine = true
			end
			if made then
				edited()
				schedule()
			end
		end
		if closed then
			finish()
		end
		local waiting = applied
		if waiting then
			applied = nil
			self.early[token] = nil
			for _, f in waiting do
				f()
			end
			local deliver = self.early_done
			if deliver and next(self.early) == nil then
				self.early_done = nil
				deliver()
			end
		end
		if not fine then
			error(why, 0)
		end
	end)
	-- What is no place in any text is refused at once, whether or not the text is here yet; what is no place in this
	-- one, once it is here.
	local function place(n: number)
		if type(n) ~= "number" or n < 0 or n ~= math.floor(n) or n > 9007199254740991 then
			error(NOWHERE, 3)
		end
	end
	-- Types bytes in as many pieces as they need, each sealed once full: a live frame says the whole of what an open piece
	-- says, and a node passes over one longer than it carries. A piece ends where a character does, and one that has no
	-- room for the next is sealed without it: else whoever saw the piece alone would read half a character, and what they
	-- typed after it would go between its halves, for good.
	local function type_in(t: text.Text, from: number, s: string)
		local k = 0
		while k < #s do
			local n = #s - k
			local room = PIECE_MOST - INSERT_MOST - t.size
			if n > room then
				n = if room > 0 then room else 0
				local back = 0
				while back < 3 and n > 0 and bit32.band(string.byte(s, k + n + 1), 0xC0) == 0x80 do -- to where it begins
					n -= 1
					back += 1
				end
				if n == 0 then
					self:_seal(row, slot)
					continue
				end
			end
			text.insert(t, from + k, if k == 0 and n == #s then s else string.sub(s, k + 1, k + n), fresh)
			k += n
		end
	end
	local function within(t: text.Text, n: number)
		if n > text.len(t) then
			error(NOWHERE, 0)
		end
	end
	return table.freeze({
		read = function(): string
			return text.read(self:_text(row, slot))
		end,
		-- Positions count bytes.
		insert = function(pos: number, s: string)
			place(pos)
			assert(type(s) == "string", "what is typed is a string")
			edit(function(t)
				within(t, pos)
				type_in(t, pos, s)
			end)
		end,
		append = function(s: string)
			assert(type(s) == "string", "what is typed is a string")
			edit(function(t)
				type_in(t, text.len(t), s)
			end)
		end,
		delete = function(pos: number, count: number)
			place(pos)
			place(count)
			edit(function(t)
				within(t, pos + count)
				local left = count
				while true do
					left = text.delete(t, pos, left, fresh, PIECE_MOST)
					if left == 0 then
						break
					end
					self:_seal(row, slot)
				end
			end)
		end,
		-- Makes what has been written durable now rather than shortly: never yielding, and never dropping it, for what
		-- was typed before the row was here is sealed once the row is. sealed() waits for it.
		commit = function()
			local waiting = applied
			if waiting then
				table.insert(waiting, function()
					self:_seal_shown(row, slot)
				end)
				return
			end
			self:_seal_shown(row, slot)
		end,
		-- Seals what has been written, and yields until it is acknowledged, durable on the node the client speaks to, and
		-- all the client wrote before it. Returns true; or false and why, should it never be (Client.flushed).
		-- Should `timeout` seconds pass first, it returns false, and how much is not yet acknowledged.
		sealed = function(timeout: number?): (boolean, string?)
			local up_to = math.huge
			return self:_wait(function(notify)
				local function now()
					self:_seal_shown(row, slot)
					up_to = self.seq
					local refused = self.refused_texts[row.id .. string.char(slot)]
					if refused then
						notify(false, refused) -- sealed where the client may no longer write
					else
						self:_barrier(notify)
					end
				end
				local waiting = applied
				if waiting then
					table.insert(waiting, now)
				else
					now()
				end
			end, timeout, function(): string
				return self:_undelivered(false, up_to)
			end)
		end,
		close = function()
			if closed then
				return
			end
			closed = true
			finish()
		end,
	})
end

-- ---------------------------------------------------------------- for what is built on the client

-- Hears of every row that changes, here or anywhere, by its id. Returns a way to stop.
function Client.follow(self: Client, f: (string) -> ()): () -> ()
	local own: Follower = { f = f, on = true } -- its own, though the same function follow twice
	local list = table.clone(self.followers)
	table.insert(list, own)
	self.followers = list
	return function()
		own.on = false
		local i = table.find(self.followers, own)
		if i then
			local rest = table.clone(self.followers)
			table.remove(rest, i)
			self.followers = rest
		end
	end
end

-- Followers hear of a row, those following still, while the client is open: one closed within it tells no more.
function Client._follow(self: Client, row: Stored)
	for _, x in self.followers do
		if x.on and not self.closed then
			self:_hand(x.f, row.id)
		end
	end
end

-- A row as it is held: its cells by slot and stamp, or nil. Not to be changed.
function Client.held(self: Client, id: string): Stored?
	return self.rows[id]
end

-- A text column of a held row, as it is; nil if the row is not held.
function Client.held_text(self: Client, id: string, slot: number): text.Text?
	local row = self.rows[id]
	return if row then self:_text(row, slot) else nil
end

-- ---------------------------------------------------------------- writing

function Client._heard(self: Client, stamp: string)
	if stamp <= self.heard then
		return -- no later than one heard already, which the clock is as late as
	end
	self.heard = stamp
	local ms, n = codec.clock(stamp)
	if ms > self.clock_ms or (ms == self.clock_ms and n > self.clock_n) then
		self.clock_ms, self.clock_n = ms, n
	end
end

-- A stamp, as of now, or of a time read once for many, as a change's are.
function Client._stamp(self: Client, now: number?): string
	local ms = now or math.floor(self.host.now() * 1000)
	if ms > self.clock_ms then
		self.clock_ms, self.clock_n = ms, 0
	elseif self.clock_n < 65535 then
		self.clock_n += 1
	else
		self.clock_ms += 1
		self.clock_n = 0
	end
	return string.pack(">I4I2I2", self.clock_ms // 65536, self.clock_ms % 65536, self.clock_n) .. self.host.random(8)
end

type Written = { row: string, slot: number, kind: number, stamp: string, body: string }

-- A row this client may write in now, as far as it knows: what a node refuses, it refuses for good, ending the pipe and
-- this client with it. One made later than a stamp of this client's may be ahead of the clock is never written; one made
-- a little ahead of this client's clock sets it on, as no cell is older than its row.
function Client._may_write(self: Client, id: string, scope: number, may: boolean?)
	if type(id) ~= "string" or #id ~= 16 then
		error("a row's id is 16 bytes", 3)
	end
	local of, born = string.unpack(">I4I4", id)
	if of ~= scope then
		error("that row is of another scope", 3)
	elseif not may and self.ready and not self:may(scope, "write") then
		error("this client may not write there", 3)
	elseif (born :: number) * 1000 > self.clock_ms then
		if (born :: number) > self.host.now() + LEAP_SECONDS then
			error("that row was made later than any clock may yet say", 3)
		end
		self.clock_ms, self.clock_n = (born :: number) * 1000, 0
	end
end

function Client._send_cells(self: Client, cells: { Written }, done: (() -> ())?)
	local scope: number = string.unpack(">I4", cells[1].row) :: any
	-- What this client may no longer write in, since it began, is never said: a node refuses it, and this client with it. It
	-- is not delivered, and whoever next waits for what was written is told so.
	if self.ready and not self:may(scope, "write") then
		local why = "this client may no longer write there: what it wrote there is not delivered"
		self.owed = self.owed or why
		self.never_delivered = self.never_delivered or why
		for _, c in cells do
			if c.kind == PIECE then
				self.refused_texts[c.row .. string.char(c.slot)] = why
			end
		end
		return
	end
	local w = codec.writer()
	local last = ""
	local rows: { string } = {}
	local texts: { string } = {}
	for _, c in cells do
		if c.kind == PIECE then
			table.insert(texts, c.row .. string.char(c.slot))
		end
		local again = c.row == last
		if not again then
			table.insert(rows, c.row)
			self.unacked[c.row] = (self.unacked[c.row] or 0) + 1
		end
		codec.put_u8(w, c.kind + if again then 128 else 0)
		if not again then
			codec.put(w, c.row)
		end
		codec.put_u8(w, c.slot)
		codec.put(w, c.stamp)
		codec.put_bytes(w, c.body)
		last = c.row
	end
	self.seq += 1
	local body = codec.string(w)
	table.insert(self.pending, { seq = self.seq, scope = scope, body = body, rows = rows, cells = #cells, texts = texts, done = done })
	if self.ready then
		local framed = codec.writer()
		codec.put_varint(framed, self.seq)
		codec.put(framed, body)
		self:_frame(CELLS, framed)
	end
end

-- Each write acknowledged is let go of, and whoever waits for it is told on a turn of its own, as a promise is kept.
function Client._on_ack(self: Client, seq: number)
	while #self.pending > 0 and self.pending[1].seq <= seq do
		local p = table.remove(self.pending, 1) :: Pending
		self:_settle(p)
		if p.done then
			self.host.defer(p.done)
		end
	end
	if #self.barriers > 0 then
		self:_unbar()
	end
end

-- What was written is pending no more: its rows are let go of, unless something else holds them.
function Client._settle(self: Client, p: Pending)
	for _, id in p.rows do
		local n = self.unacked[id] - 1
		self.unacked[id] = if n > 0 then n else nil
		local row = self.rows[id]
		if n == 0 and row and row.pages == 0 and not row.held then
			self.rows[id] = nil
		end
	end
end

export type Change = {
	insert: (schema: Table, list: string, order: number, values: { [string]: any }) -> string,
	set: (id: string, schema: Table, values: { [string]: any }) -> (),
	place: (id: string, list: string, order: number, slot: number?) -> (),
	delete: (id: string) -> (),
	-- Edits a text column as one piece of this change: f is given the text, and a way to name pieces.
	edit: (id: string, slot: number, f: (t: text.Text, fresh: () -> string) -> ()) -> (),
}

-- Applies several changes as one: all visible in the same turn, all durable together or not at all.
-- `done` is called when they are durable on this device.
function Client.write(self: Client, scope: number, f: (Change) -> (), done: (() -> ())?)
	local s = self.scopes[scope]
	assert(s and bit32.btest(s.rights, 2), "this client may not write there")
	local cells: { Written } = {}
	local fresh: { [string]: boolean } = {} -- rows made here
	local rows: { [string]: boolean } = {}
	-- Each row as it was before this change touched it, to be put back if the change is not made after all: false for
	-- one that was not held, which is put back as empty.
	local saved: { [string]: any } = {}
	local mine = self:_mine(scope) -- whose what this change writes is, the same throughout,
	local now = math.floor(self.host.now() * 1000) -- and when
	local function keep(id: string, slot: number): Stored
		local was = saved[id]
		local row = self.rows[id]
		if was == nil then
			-- First touched: what is done to a row of another scope is refused, and the whole change with it, by any node.
			if not fresh[id] then
				self:_may_write(id, scope, true) -- as was asked of the scope, above
			end
			if row then
				-- What editors have open in the row is their own writing, sent whatever becomes of this change: first, then,
				-- so that undoing the change cannot take it back, and what the change writes over it is later.
				local sealed = false
				for k, t in row.texts or {} do
					if t.open ~= "" and self:_seal(row, k) then
						sealed = true
					end
				end
				local slots = {}
				for k, v in row do
					if type(k) == "number" then
						slots[k] = if type(v) == "table" then table.clone(v) else v
					end
				end
				local authors = row.authors
				was = { dead = row.dead, slots = slots, authors = if authors then table.clone(authors) else nil, touched = {}, sealed = sealed }
			else
				was = false
			end
			saved[id] = was
		end
		if was then
			was.touched[slot] = true
		end
		return row or self:_row(id)
	end
	local function put(row: string, slot: number, kind: number, body: string)
		assert(#body <= MAX_OPEN, "a value may be 1 MiB at most, less 192 bytes")
		local stored = keep(row, slot)
		local stamp = self:_stamp(now)
		rows[row] = true
		table.insert(cells, { row = row, slot = slot, kind = kind, stamp = stamp, body = body })
		self:_accept(stored, slot, cell(kind, stamp, body), mine)
	end
	local function set(id: string, schema: Table, values: { [string]: any })
		for name, value in values do
			local c = schema[name]
			assert(c and not c.who, `no column {name} to write`)
			if not (c.slot >= 16 and c.slot <= 255 and c.slot % 1 == 0) then
				error(`no value goes in slot {c.slot}`, 0) -- as a column made by hand may say
			end
			-- Empty text is what a text is before anything is written: it need only be said to clear one.
			local row = self.rows[id]
			if value ~= "" or not c.text or (row and row[c.slot]) or not fresh[id] then
				put(id, c.slot, VALUE, c.encode(value))
			end
		end
	end
	local function place(id: string, list: string, order: number, slot: number?)
		if not (type(order) == "number" and order >= 0 and order <= 9007199254740991 and order % 1 == 0) then
			error("an order is a whole number from 0 to 2^53", 0)
		elseif slot ~= nil and not (type(slot) == "number" and slot >= 1 and slot <= 15 and slot % 1 == 0) then
			error("a row is placed in slots 1 to 15", 0)
		end
		put(id, slot or 1, PLACE, self:_tag(scope, list) .. codec.u64(order))
	end
	local change: Change = {
		insert = function(schema, list, order, values)
			-- As late as anything heard of: later, then, than any right that is known to have ended.
			if now > self.clock_ms then
				self.clock_ms, self.clock_n = now, 0
			end
			local id = string.pack(">I4I4", scope, self.clock_ms // 1000) .. self.host.random(8)
			fresh[id] = true
			place(id, list, order)
			set(id, schema, values)
			return id
		end,
		set = set,
		place = place,
		delete = function(id)
			put(id, 0, GRAVE, "")
		end,
		edit = function(id, slot, f)
			assert(slot >= 16 and slot <= 255 and slot % 1 == 0, "data slots are 16 to 255")
			local row = keep(id, slot) -- what an editor has open goes first, and stands; and the row is known as it was, or as not there
			rows[id] = true -- and is shown as it is, though nothing be edited, or let go of if there is nothing
			local t = self:_text(row, slot)
			f(t, function(): string
				return self.host.random(8)
			end)
			local stamp = self:_stamp(now)
			local body = text.close(t, stamp)
			if body then
				assert(#body <= MAX_OPEN, "an edit may be 1 MiB at most, less 192 bytes")
				rows[id] = true
				table.insert(cells, { row = id, slot = slot, kind = PIECE, stamp = stamp, body = body })
				merge(row, slot, cell(PIECE, stamp, body), mine)
				unview(row)
			end
		end,
	}
	local ok, why = pcall(function()
		f(change)
		-- A change is said in one frame, which a node applies whole or not at all: one bigger than a node reads is refused
		-- here.
		local size = 1 + 10
		for _, c in cells do
			size += 1 + 16 + 1 + 16 + 5 + #c.body
		end
		if size > MAX_FRAME then
			error("a change may be 4 MiB at most, as it is said", 0)
		end
	end)
	if not ok then
		-- All or nothing: whatever was done here is undone, and nothing is said. What editors had open in the rows it
		-- touched was sealed, and stands: those rows are shown as they now are. The rest are as they were, and were shown
		-- so: nothing is told of them.
		local back: { [Stored]: boolean } = {}
		for id, was in saved do
			local row = self.rows[id]
			if row and was then
				row.dead = was.dead
				for k in row do
					if type(k) == "number" then
						row[k] = nil
					end
				end
				for k, v in was.slots do
					row[k] = v
				end
				row.authors = was.authors
				for slot in was.touched do
					-- Read again from its cells when next wanted.
					if row.texts then
						row.texts[slot] = nil
						if next(row.texts) == nil then
							row.texts = nil
						end
					end
					if row.lives then
						row.lives[slot] = nil
						if next(row.lives) == nil then
							row.lives = nil
						end
					end
				end
				unview(row)
				if was.sealed then
					back[row] = true
				end
			elseif row then
				-- Nothing of it was held before, and nothing of this change is.
				if row.dead then
					row.dead = nil
				end
				for k in row do
					if type(k) == "number" then
						row[k] = nil
					end
				end
				if row.authors then
					row.authors = nil
				end
				if row.texts then
					row.texts = nil
				end
				if row.lives then
					row.lives = nil
				end
				unview(row)
				if row.pages == 0 and not row.held and not self:_pending(id) then
					self.rows[id] = nil
				end
			end
		end
		self:_place_all(back)
		error(why, 0)
	end
	if #cells > 0 then
		self:_send_cells(cells, done)
	elseif done then
		-- A change of nothing is a barrier: it is done once all written before it is durable.
		local after: () -> () = done
		self:_barrier(function(ok)
			if ok then
				self.host.defer(after)
			end
		end)
	end
	local placing: { [Stored]: boolean } = {}
	for id in rows do
		local row = self.rows[id]
		if row then
			placing[row] = true
		end
	end
	self:_place_all(placing)
end

-- ---------------------------------------------------------------- calls

function Client._flow(self: Client, id: number, side: number, kind: number, payload: string?)
	local w = codec.writer()
	codec.put_varint(w, id * 2 + side)
	codec.put_u8(w, kind)
	if payload then
		codec.put(w, payload)
	end
	self:_frame(FLOW, w)
end

function Client._call(self: Client, id: number, side: number, device: string, method: string): Live_Call
	local live: Live_Call
	local set = if side == 0 then self.calls else self.answers
	local function over(): boolean
		return set[id] ~= live
	end
	local call: Call = {
		device = device,
		method = method,
		subject = nil,
		on_data = nil,
		on_end = nil,
		on_fault = nil,
		on_room = nil,
		send = function(data: string)
			assert(#data <= CALL_WINDOW, "a message may be 256 KiB at most")
			if not over() and not live.finishing then
				table.insert(live.queue, data)
				live.queued += #data
				self:_drain(id, live)
			end
		end,
		finish = function()
			if not over() and not live.finishing then
				live.finishing = true
				self:_drain(id, live)
			end
		end,
		cancel = function()
			if self.faults[live] then
				self.faults[live] = nil -- ended already, and not yet told: it is not told now
				return
			end
			if not over() then
				set[id] = nil
				self:_flow(id, side, F_CANCEL)
			end
		end,
		consumed = function(n: number)
			if not over() then
				self:_consume(id, live, n)
			end
		end,
		room = function(): number
			if over() or live.finishing then
				return 0
			end
			return math.max(live.credit - live.queued, 0)
		end,
	}
	live = {
		call = call,
		side = side,
		finishing = false,
		mine_ended = false,
		theirs_ended = false,
		credit = CALL_WINDOW,
		queue = {},
		queued = 0,
		window = CALL_WINDOW,
		used = 0,
		since = self.host.now(),
	}
	set[id] = live
	return live
end

-- Sends what the other side has room for, and then, if there is no more, says so.
function Client._drain(self: Client, id: number, live: Live_Call)
	while #live.queue > 0 and live.credit >= #live.queue[1] do
		local data = table.remove(live.queue, 1) :: string
		live.credit -= #data
		live.queued -= #data
		self:_flow(id, live.side, F_DATA, data)
	end
	if live.finishing and #live.queue == 0 and not live.mine_ended then
		live.mine_ended = true
		self:_flow(id, live.side, F_END)
		if live.theirs_ended then
			(if live.side == 0 then self.calls else self.answers)[id] = nil
		end
	end
end

-- Tells a call of its end, if it is to be told still.
function Client._fault(self: Client, live: Live_Call)
	local fault = self.faults[live]
	if fault == nil then
		return
	end
	self.faults[live] = nil
	if live.call.on_fault then
		self:_hand(live.call.on_fault, fault)
	end
end

-- Credits what is done with. A window used up quickly grows, to 4 MiB, so that a long path is kept full by a reader that
-- keeps up; one that does not never gets more than it has room for.
function Client._consume(self: Client, id: number, live: Live_Call, n: number)
	if n <= 0 then
		return
	end
	local credit = n
	live.used += n
	if live.used >= live.window then
		local now = self.host.now()
		if now - live.since < WINDOW_QUICK and live.window < WINDOW_MOST then
			credit += live.window
			live.window *= 2
		end
		live.used = 0
		live.since = now
	end
	local w = codec.writer()
	codec.put_varint(w, credit)
	self:_flow(id, live.side, F_CREDIT, codec.string(w))
end

local function urgency_of(options: Call_Options?): number
	local u = if options then options.urgency else nil
	if u == nil then
		return 3
	end
	if type(u) ~= "number" or u ~= math.floor(u) or u < 0 or u > 7 then
		error("an urgency is a whole number from 0 to 7", 3)
	end
	return u
end

-- Calls a method on a device. Set on_data, on_end and on_fault on the result before yielding.
function Client.call(self: Client, device: string, scope: number, method: string, data: string, options: Call_Options?): Call
	local urgency = urgency_of(options)
	if type(device) ~= "string" or #device ~= 32 then
		error("a device's id is 32 bytes", 2)
	end
	whole(scope)
	self.next_call += 1
	local id = self.next_call
	local live = self:_call(id, 0, device, method)
	if not self.ready or #data > CALL_WINDOW then
		self.calls[id] = nil
		-- Told on a turn of its own, once it can have been given its callbacks: unless it is cancelled first, or the client
		-- is closed, which tells it at once. As things are now, not when it is told.
		self.faults[live] = if self.ready then "overrun" else "unreachable"
		self.host.defer(function()
			self:_fault(live)
		end)
		return live.call
	end
	live.credit -= #data
	local w = codec.writer()
	codec.put_varint(w, id)
	codec.put(w, device)
	codec.put_varint(w, scope)
	codec.put_bytes(w, method)
	codec.put_bytes(w, "") -- for whom is for the node to say
	codec.put_u8(w, urgency)
	codec.put(w, data)
	self:_frame(CALL, w)
	return live.call
end

-- One question, one answer; yields the coroutine it is called from. Returns the answer, every message that came put
-- together, or nil and why not.
function Client.request(self: Client, device: string, scope: number, method: string, data: string, options: Call_Options?): (string?, string?)
	urgency_of(options) -- one out of range is the fault of whoever asked
	local thread = coroutine.running()
	local messages: { string } = {}
	local fault: string? = nil
	local waiting, settled = false, false
	local function settle()
		if not settled then
			settled = true
			if waiting then
				self:_resume(thread)
			end
		end
	end
	local call = self:call(device, scope, method, data, options)
	call.on_data = function(d: string)
		table.insert(messages, d)
	end
	call.on_end = settle
	call.on_fault = function(f)
		fault = f
		settle()
	end
	call.finish()
	if not settled then
		waiting = true
		coroutine.yield()
	end
	if fault then
		return nil, fault
	end
	return table.concat(messages), nil
end

-- Answers a method within a scope. The handler gets the call and its first message. Returns a way to stop.
function Client.serve(self: Client, scope: number, method: string, handler: (Call, string) -> ()): () -> ()
	whole(scope)
	-- A node refuses a method of no name, or of a longer one, for good: so here, at once.
	if type(method) ~= "string" or #method == 0 or #method > 255 then
		error("a method's name is 1 to 255 bytes", 2)
	end
	local key = `{scope}/{method}`
	self.handlers[key] = handler
	if self.ready then
		self:_serve(key, true)
	end
	return function()
		if self.handlers[key] == handler then
			self.handlers[key] = nil
			if self.ready then
				self:_serve(key, false)
			end
		end
	end
end

function Client._serve(self: Client, key: string, on: boolean)
	local slash = string.find(key, "/", 1, true) :: number
	local w = codec.writer()
	codec.put_varint(w, tonumber(string.sub(key, 1, slash - 1)) :: number)
	codec.put_u8(w, if on then 1 else 0)
	codec.put_bytes(w, string.sub(key, slash + 1))
	self:_frame(SERVE, w)
end

function Client._on_call(self: Client, r: codec.Reader)
	local id = codec.varint(r)
	local device = codec.take(r, 32)
	local scope = codec.varint(r)
	local method = codec.bytes(r)
	local subject = codec.bytes(r)
	local handler = self.handlers[`{scope}/{method}`]
	if not handler then
		self:_flow(id, 1, F_FAULT, "\3")
		return
	end
	local data = codec.rest(r)
	local live = self:_call(id, 1, device, method)
	live.call.subject = subject
	self:_consume(id, live, #data) -- the first message is always taken
	self:_hand(function(d: string)
		handler(live.call, d)
	end, data)
end

function Client._on_flow(self: Client, r: codec.Reader)
	local tag = codec.varint(r)
	local kind = codec.u8(r)
	local id = tag // 2
	local speaker = tag % 2
	local set = if speaker == 1 then self.calls else self.answers
	local live = set[id]
	if not live then
		return
	end
	local call = live.call
	if kind == F_DATA then
		local data = codec.rest(r)
		-- Kept only if the reader says so, and one that threw kept nothing: else what it was sent would never be credited
		-- back, and the call would wait for good.
		local done = true
		if call.on_data then
			done = self:_hand(call.on_data, data) ~= false
		end
		if done and set[id] == live then
			self:_consume(id, live, #data)
		end
	elseif kind == F_CREDIT then
		live.credit += codec.varint(r)
		self:_drain(id, live)
		if call.on_room and set[id] == live then
			self:_hand(call.on_room, nil)
		end
	elseif kind == F_END then
		live.theirs_ended = true
		if live.mine_ended then
			set[id] = nil
		end
		if call.on_end then
			self:_hand(call.on_end, nil)
		end
	else
		set[id] = nil
		if call.on_fault then
			local code = if kind == F_FAULT and r.pos < r.len then codec.u8(r) else 0
			self:_hand(call.on_fault, Faults[code] or "cancelled")
		end
	end
end

return table.freeze({
	connect = new_client,
	columns = columns,
	-- For what is built on the client: a row's cells, read plainly; the latest value in a slot; who wrote in one; and how
	-- the columns that are not made up read, to read them straight from a cell.
	cells = cells_of,
	latest = latest,
	whose = whose,
	same = same,
	decode_number = decode_number,
})
