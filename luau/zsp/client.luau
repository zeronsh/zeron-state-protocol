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
local F_DATA, F_END, F_FAULT, F_CANCEL, F_CREDIT = 0, 1, 2, 3, 4
local CALL_WINDOW = 262144
local WINDOW_MOST = 16 * CALL_WINDOW -- what a receiver may credit ahead
local WINDOW_QUICK = 0.25 -- seconds: a window used up within this grows
local MAX_OPEN = 1048576 - 192
local ZERO32 = string.rep("\0", 32)

local PIECE_BYTES = 4096 -- a piece is sealed at this size,
local PIECE_SECONDS = 1 -- or this long after it began,
local LIVE_SECONDS = 10 -- and live text unconfirmed for this long is dropped
local LEAP_SECONDS = 15 * 60 -- a node refuses a stamp further ahead of its clock than this

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

type Cell = { kind: number, stamp: string, body: string, author: Device? }
type Stored = {
	id: string,
	slots: { [number]: { [string]: Cell } }, -- by stamp
	dead: boolean,
	pages: number, -- that hold it
	texts: { [number]: text.Text },
	held: { [number]: number }, -- open editors, by slot
	asking: (() -> ())?, -- for the sake of those, while nothing else shows it: ends that
	awaited: { () -> () }, -- by those, until it is here
	lives: { [number]: number }, -- when live text was last heard, by slot
	views: { [any]: Row }, -- by table, until the row changes
	dirty: { [number]: boolean }, -- slots with live text to send
}
type Said = { [string]: { [string]: boolean } }
type Pending = { seq: number, scope: number, body: string, rows: { string }, done: () -> () }
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
	entries: { { key: string, row: Stored } }, -- in order
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

-- ---------------------------------------------------------------- columns

local function column(slot: number, is: string, encode: (any) -> string, decode: (string) -> any, who: ("last" | "all")?): Column
	assert(slot >= 16 and slot <= 255, "data slots are 16 to 255")
	return table.freeze({ slot = slot, text = is == "text", is = is, encode = encode, decode = decode, who = who })
end

local function same(v: any): any
	return v
end

local columns = {}

function columns.string(slot: number): Column
	return column(slot, "string", same, same)
end

function columns.number(slot: number): Column
	return column(slot, "number", function(v)
		return string.pack(">d", v)
	end, function(s)
		return (string.unpack(">d", s))
	end)
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
		unacked = {} :: { [string]: number }, -- rows in pending, and how often
		out = codec.writer(),
		flushing = false,
		calls = {} :: { [number]: Live_Call }, -- ours
		answers = {} :: { [number]: Live_Call }, -- of others
		next_call = 0,
		handlers = {} :: { [string]: (Call, string) -> () },
		followers = {} :: { [(string) -> ()]: boolean },
		typing = {} :: { [Stored]: boolean }, -- rows with live text to send
		tags = {} :: { [string]: string }, -- of lists, by their scope, its key and their name
		bulk = nil :: { [Window]: { { key: string, row: Stored } } }?, -- rows to add to windows, all at once
	}, Client)
	self:_dial()
	return self
end

export type Client = typeof(new_client(nil :: any))

-- ---------------------------------------------------------------- the pipe

function Client._dial(self: Client)
	if self.closed or self.wire then
		return
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
	for _, set in { self.calls, self.answers } do
		for id, c in set do
			set[id] = nil
			if c.call.on_fault then
				c.call.on_fault("lost")
			end
		end
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
	self:_tell("status", false)
	if not self.closed then
		-- Soon after a pipe that was well; later and later after each that never came up, or that the node found fault
		-- with, since what this client says it would say again.
		if well then
			self.failures = 0
		end
		local wait = math.min(0.1 * 2 ^ self.failures, 10)
		self.failures += 1
		self.host.after(wait, function()
			self:_dial()
		end)
	end
end

function Client.close(self: Client)
	self.closed = true
	self:_flush()
	self.hang_up()
	for _, a in table.clone(self.asked) do
		self:_fetched(a) -- as far as it got
	end
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
		if next(row.dirty) ~= nil then
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
	for _, window in self.windows do
		if window.changed then
			self:_publish(window)
		end
	end
	for _, a in table.clone(self.asked) do
		if a.changed and not a.stopped then
			a.changed = false
			a.observer(self:_answer(a))
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
		self.closed = code == 2 or code == 3 -- refused, or speaking another language: trying again is no use
		self:_tell("error", code)
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
		for _, a in self.asked do
			if a.status == "denied" and not a.stopped then
				self:_ask(a)
			end
		end
		self:_tell("status", true)
		return
	end
	self.ready = true
	-- Say again whatever the last pipe was told: what is served, unacknowledged and watched. What this client may no
	-- longer write in is let go of, never to be durable: a node would refuse it, and this client with it, for good.
	for key in self.handlers do
		self:_serve(key, true)
	end
	for _, p in table.clone(self.pending) do
		if not self:may(p.scope, "write") then
			table.remove(self.pending, table.find(self.pending, p) :: number)
			self:_settle(p)
			continue
		end
		local w = codec.writer()
		codec.put_varint(w, p.seq)
		codec.put(w, p.body)
		self:_frame(CELLS, w)
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
	for _, a in self.asked do
		self:_ask(a)
	end
	self:_tell("status", true)
end

-- ---------------------------------------------------------------- observing things that are not windows

function Client._tell(self: Client, what: string, value: any)
	local set = self.watchers[what]
	if set then
		for f in table.clone(set) do
			f(value)
		end
	end
end

-- "status" (connected or not), "devices" (those reachable, this one first), "self" (this device, and whom this client
-- goes by) or "error". Returns a way to stop.
function Client.on(self: Client, what: "status" | "devices" | "self" | "error", f: (any) -> ()): () -> ()
	local set = self.watchers[what] or {}
	self.watchers[what] = set
	set[f] = true
	if what == "status" then
		f(self.ready)
	elseif what == "devices" then
		f(self.devices)
	elseif what == "self" and self.authors[0] then
		f(self.authors[0])
	end
	return function()
		set[f] = nil
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
	local k = string.pack(">I4", scope) .. s.key .. list
	local tag = self.tags[k]
	if not tag then
		tag = string.sub(k, 1, 4) .. string.sub(sha256(s.key .. list), 1, 12)
		self.tags[k] = tag
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
	local key = `{query.scope}/{from}/{query.size or 50}/{shape}/{query.list}/{query.bare == true}`
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
			entries = {},
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
	window.observers[observer] = true
	window.watching += 1
	observer(if window.bare then nil :: any else self:_state(window))
	local stopped = false

	return table.freeze({
		-- The rows now on screen, by position. Loads what is near, lets go of what is far.
		visible = function(first: number, last: number)
			self:_visible(window, first, last)
		end,
		load_before = function()
			self:_load_before(window)
		end,
		load_after = function()
			self:_load_after(window)
		end,
		-- The rows as they are held, in order: for what is built on the client, such as a mirror.
		entries = function(): { { key: string, row: Stored } }
			return window.entries
		end,
		stop = function()
			if stopped then
				return
			end
			stopped = true
			window.observers[observer] = nil
			window.watching -= 1
			if window.watching == 0 then
				-- Whoever comes back soon finds it still warm.
				window.linger = self.host.after(self.host.linger or 5, function()
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
	for _, e in page.window.entries do
		if e.key >= page.lo and e.key < page.hi then
			stale[e.row.id] = {}
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
		for _, e in window.entries do
			if e.key >= lo and e.key < hi then
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

-- What was read of a row is read again when next it is wanted. Nothing keeps the table of views but the row, so one
-- that is empty already need not be made again: a cell comes for each column of each row, and this is all of them.
local function unview(row: Stored)
	if next(row.views) ~= nil then
		row.views = {}
	end
end

-- A range was said over again and this row was not in it: it was moved away, or deleted, while this client
-- was not listening. Only its place there is known to be wrong. Where else it is, and what is being typed in
-- it, stand.
function Client._unplace(self: Client, row: Stored, lo: string, hi: string)
	for slot = 1, 15 do
		local cells = row.slots[slot]
		if cells then
			for stamp, c in cells do
				local key = string.sub(c.body, 1, 24) .. row.id
				if key >= lo and key < hi then
					cells[stamp] = nil
				end
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
	local some = false
	for slot, cells in row.slots do
		local gone = false
		for stamp in cells do
			if not said[stamp] then
				cells[stamp] = nil
				gone = true
			end
		end
		if gone then
			some = true
			self:_rebuild(row, slot)
		end
	end
	if some then
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
	if last > #window.entries - near then
		self:_load_after(window)
	end
	-- A page that has grown far past its size is two pages.
	for i, page in window.pages do
		local lo, hi = self:_span(window, page)
		if not page.open and hi - lo > window.size * 2 then
			local middle = window.entries[(lo + hi) // 2].key
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
		local count = #window.entries - lo + 1
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
	local entries = window.entries
	local lo, hi = 1, #entries + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if entries[mid].key < key then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

function Client._trim(self: Client, window: Window)
	local lo, hi = window.pages[1].lo, window.pages[#window.pages].hi
	local kept = {}
	table.clear(window.at)
	for _, e in window.entries do
		if e.key >= lo and e.key < hi then
			table.insert(kept, e)
			window.at[e.row] = e.key
		else
			self:_release(e.row)
		end
	end
	window.entries = kept
	self:_touch(window)
end

function Client._forget(self: Client, window: Window)
	self.windows[window.key] = nil
	for _, page in window.pages do
		self:_drop_page(page)
	end
	for _, e in window.entries do
		self:_release(e.row)
	end
end

function Client._release(self: Client, row: Stored)
	row.pages -= 1
	if row.pages == 0 and not row.asking and not row.dead then
		self:_keep(row)
	end
	if row.pages == 0 and next(row.held) == nil and not self:_pending(row.id) then
		self.rows[row.id] = nil
	end
end

-- Has a row that is being edited shown, if nothing else shows it, so that what others write in it is heard of too.
-- Calls back once it is here, or known not to be anywhere.
function Client._keep(self: Client, row: Stored, here: (() -> ())?)
	if row.pages > 0 or next(row.held) == nil then
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
		row.awaited = {}
		for _, f in awaited do
			f()
		end
	end
	if here then
		table.insert(row.awaited, here)
		-- Once, too: answered by one who holds everything if one can be reached, and otherwise with what is held, as a
		-- partial replica with nobody to ask that can read answers it, never "ready". What waits for the row goes on then.
		if #row.awaited == 1 then
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
	if next(row.held) then
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
	local rows: { Row } = table.create(#window.entries) :: any
	for i, e in window.entries do
		rows[i] = self:_view(e.row, window.schema, e.key)
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
	for f in table.clone(window.observers) do
		f(state)
	end
end

-- A row as the application sees it: one frozen table, the same one until something in it changes.
function Client._view(self: Client, row: Stored, schema: Table, key: string): Row
	local view = row.views[schema]
	local order = codec.from_u64(string.sub(key, 17, 24))
	if view and view.order == order then
		return view
	end
	local made: { [string]: any } = { id = row.id, order = order }
	for name, c in schema do
		if c.who then
			local latest: Cell? = nil
			local names: { [string]: boolean } = {}
			for _, cell in row.slots[c.slot] or {} :: any do
				if not latest or cell.stamp > latest.stamp then
					latest = cell
				end
				if cell.author and cell.author.subject ~= "" then
					names[cell.author.subject] = true
				end
			end
			local list: { string } = {}
			for name in names do
				table.insert(list, name)
			end
			table.sort(list)
			if c.who == "all" then
				made[name] = table.freeze(list)
			elseif latest and latest.author and latest.author.subject ~= "" then
				made[name] = latest.author.subject
			end
		elseif c.text then
			local t = self:_text(row, c.slot)
			made[name] = text.read(t)
		else
			local slot = row.slots[c.slot]
			if slot then
				for _, cell in slot do
					if cell.kind == VALUE then
						-- What cannot be read as the column's kind is no value, rather than the end of everything shown.
						local fine, v = pcall(c.decode, cell.body)
						made[name] = if fine then v else nil
					end
				end
			end
		end
	end
	table.freeze(made)
	row.views[schema] = made :: any
	return made :: any
end

-- ---------------------------------------------------------------- rows

function Client._row(self: Client, id: string): Stored
	local row = self.rows[id]
	if not row then
		local made: Stored = { id = id, slots = {}, dead = false, pages = 0, texts = {}, held = {}, lives = {}, views = {}, dirty = {}, asking = nil, awaited = {} }
		row = made
		self.rows[id] = made
	end
	return row
end

local function bundle_has(body: string, stamp: string): boolean
	local n: number = string.unpack(">I4", body) :: any
	local lo, hi = 0, n
	while lo < hi do
		local mid = (lo + hi) // 2
		local s = string.sub(body, 5 + mid * 16, 20 + mid * 16)
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

-- Whether a cell is one a node could have sent: what the merge rule and placing read of it is there. One that is not, as
-- a bundle that says it holds more stamps than it does, is nonsense, and not to be looked through.
local function sound(kind: number, slot: number, body: string): boolean
	if kind == GRAVE then
		return slot == 0
	elseif kind == PLACE then
		return slot >= 1 and slot <= 15 and #body >= 24
	elseif kind == VALUE or kind == PIECE then
		return slot >= 16
	elseif kind == BUNDLE then
		return slot >= 16 and #body >= 4 and 4 + (string.unpack(">I4", body) :: any) * 16 <= #body
	end
	return false
end

-- The merge rule. Returns whether the cell was news.
local function merge(row: Stored, slot: number, kind: number, stamp: string, body: string, author: Device?): boolean
	if row.dead then
		return false
	end
	if kind == GRAVE then
		row.dead = true
		row.slots = {}
		return true
	end
	local cells = row.slots[slot]
	if not cells then
		cells = {}
		row.slots[slot] = cells
	end
	if cells[stamp] then
		return false
	end
	for s, c in cells do
		if (c.kind == PLACE or c.kind == VALUE) and stamp <= s then
			return false
		elseif c.kind == BUNDLE and (kind == PIECE or kind == BUNDLE) and bundle_has(c.body, stamp) then
			return false
		end
	end
	if kind == PLACE or kind == VALUE then
		for s in cells do
			if s < stamp then
				cells[s] = nil
			end
		end
	elseif kind == BUNDLE then
		for s, c in cells do
			if (c.kind == PIECE or c.kind == BUNDLE) and bundle_has(body, s) then
				cells[s] = nil
			end
		end
	end
	cells[stamp] = { kind = kind, stamp = stamp, body = body, author = author }
	return true
end

local function cells_of(self: Client, r: codec.Reader, touched: { [Stored]: boolean })
	codec.varint(r)
	local id = ""
	while r.pos < r.len do
		local tag = codec.u8(r)
		if tag < 128 then
			id = codec.take(r, 16)
		end
		if id == "" then
			error(codec.Malformed, 0)
		end
		local slot = codec.u8(r)
		local stamp = codec.take(r, 16)
		local body = codec.bytes(r)
		local author: Device? = nil
		if bit32.btest(tag, 64) then
			author = self.authors[codec.varint(r)]
		end
		if not sound(tag % 64, slot, body) then
			error(codec.Malformed, 0)
		end
		self:_heard(stamp)
		local row = self:_row(id)
		touched[row] = true
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
		self:_accept(row, slot, tag % 64, stamp, body, author)
	end
end

function Client._on_cells(self: Client, r: codec.Reader)
	local touched: { [Stored]: boolean } = {}
	local fine, why = pcall(cells_of, self, r, touched)
	self:_place_all(touched) -- what came before any nonsense is shown, as it is held
	if not fine then
		error(why, 0)
	end
end

function Client._accept(self: Client, row: Stored, slot: number, kind: number, stamp: string, body: string, author: Device?): boolean
	if not merge(row, slot, kind, stamp, body, author) then
		-- Known already; but perhaps not whose it is, or by what name they go now.
		local cell = row.slots[slot] and row.slots[slot][stamp]
		if cell and author then
			if not cell.author or cell.author.subject ~= author.subject then
				unview(row)
			end
			cell.author = author
		end
		if cell and cell.body ~= body then
			cell.body = body -- less of it, since its author may no longer have written the rest
			self:_rebuild(row, slot)
		end
		return false
	end
	local t = row.texts[slot]
	if t and kind >= VALUE then
		if text.apply(t, kind, stamp, body) == "rebuild" then
			self:_rebuild(row, slot)
		end
	end
	unview(row)
	return true
end

-- The text in a slot, made from its cells when first wanted.
function Client._text(self: Client, row: Stored, slot: number): text.Text
	local t = row.texts[slot]
	if not t then
		t = text.new()
		row.texts[slot] = t
		local cells = row.slots[slot]
		if cells then
			local sorted: { Cell } = {}
			for _, c in cells do
				table.insert(sorted, c)
			end
			table.sort(sorted, function(a: Cell, b: Cell)
				return a.stamp < b.stamp
			end)
			for _, c in sorted do
				text.apply(t, c.kind, c.stamp, c.body)
			end
		end
	end
	return t
end

function Client._rebuild(self: Client, row: Stored, slot: number)
	local old = row.texts[slot]
	if old and old.open ~= "" then
		self:_seal(row, slot) -- nothing typed here may be lost with it
	end
	row.texts[slot] = nil
	row.lives[slot] = nil
	unview(row)
end

-- Puts a row where its placements say, in every window, and takes it from where they do not. Followers hear of it
-- first, unless they have been told already.
function Client._place(self: Client, row: Stored, told: boolean?)
	if not told then
		for f in self.followers do
			f(row.id)
		end
	end
	local keys = {}
	if not row.dead then
		for slot = 1, 15 do
			local cells = row.slots[slot]
			if cells then
				for _, c in cells do
					keys[string.sub(c.body, 1, 24) .. row.id] = true
				end
			end
		end
	end
	for _, window in self.windows do
		if #window.pages > 0 then
			local lo, hi = window.pages[1].lo, window.pages[#window.pages].hi
			local want: string? = nil
			for key in keys do
				if key >= lo and key < hi and (not want or key < want) then
					want = key
				end
			end
			local entries = window.entries
			-- Where it is now, found by where it was: keys are in order, and each is a row's own.
			local was = window.at[row]
			local have: number? = if was then self:_find(window, was) else nil
			if have and (not want or entries[have].key ~= want) then
				table.remove(entries, have)
				window.at[row] = nil
				row.pages -= 1
				if row.pages == 0 and not row.asking and not row.dead then
					self:_keep(row)
				end
				self:_touch(window)
				have = nil
			end
			if want and not have then
				local e = { key = want, row = row }
				local bulk = self.bulk
				if bulk then
					bulk[window] = bulk[window] or {}
					table.insert(bulk[window], e)
				else
					table.insert(entries, self:_find(window, want), e)
				end
				window.at[row] = want
				row.pages += 1
				self:_touch(window)
			elseif want then
				self:_touch(window)
			end
		end
	end
	self:_touch_asked(row)
	if row.pages <= 0 and next(row.held) == nil and (row.dead or not self:_pending(row.id)) then
		if next(self.asked) ~= nil and not row.dead then
			self.loose[row.id] = true
		else
			self.rows[row.id] = nil
		end
	end
end

-- Places rows, each once. Many at once go into windows at once: sorted together, rather than each moving all after it.
-- Followers hear of them all first, so that whatever they do of it is done before any row is half put, as one held
-- where it goes and not yet among the rows there.
function Client._place_all(self: Client, rows: { [Stored]: boolean })
	local many = 0
	for _ in rows do
		many += 1
		if many > 64 then
			break
		end
	end
	if many <= 64 then
		for row in rows do
			self:_place(row)
		end
		return
	end
	for row in rows do
		for f in self.followers do
			f(row.id)
		end
	end
	local bulk: { [Window]: { { key: string, row: Stored } } } = {}
	self.bulk = bulk
	for row in rows do
		self:_place(row, true)
	end
	self.bulk = nil
	for window, add in bulk do
		for _, e in add do
			table.insert(window.entries, e)
		end
		table.sort(window.entries, function(x: { key: string, row: Stored }, y: { key: string, row: Stored }): boolean
			return x.key < y.key
		end)
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
	observer(self:_answer(a))
	return table.freeze({
		move = function(offset: number, limit: number?)
			local q: any = table.clone(a.question)
			q.offset, q.limit = offset, limit or q.limit
			a.question = q
			if self.ready and not a.stopped then
				self:_ask(a)
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
				coroutine.resume(thread)
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

function Client._ask(self: Client, a: Asked)
	local may = self.scopes[a.question.scope] ~= nil
	local body, totals = asking.write(a.question, function(scope, name)
		if self.scopes[scope] then
			return self:_tag(scope, name)
		end
		may = false
		return string.rep("\0", 16)
	end)
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
		if row and row.pages <= 0 and next(row.held) == nil and not self:_pending(id) then
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
				local cells = row.slots[slot]
				local _, c = next(cells or {} :: { [string]: Cell })
				if c then
					key = string.sub(c.body, 1, 24) .. id
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
		if not row.lives[slot] then
			self:_expire(row, slot)
		end
		row.lives[slot] = self.host.now()
	end
end

-- Live text whose writer vanished before sealing it is not text.
function Client._expire(self: Client, row: Stored, slot: number)
	self.host.after(LIVE_SECONDS, function()
		local last = row.lives[slot]
		local t = row.texts[slot]
		if not last or not t then
			return
		end
		if not text.provisional(t) then
			row.lives[slot] = nil
		elseif self.host.now() - last >= LIVE_SECONDS then
			self:_rebuild(row, slot)
			self:_place(row)
		else
			self:_expire(row, slot)
		end
	end)
end

function Client._send_live(self: Client, row: Stored)
	for slot in row.dirty do
		row.dirty[slot] = nil
		local t = row.texts[slot]
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
				self:_seal(row, slot)
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

function Client._seal(self: Client, row: Stored, slot: number)
	local t = row.texts[slot]
	if not t or t.open == "" then
		return
	end
	local stamp = self:_stamp(row.id)
	local body = text.close(t, stamp)
	if body then
		merge(row, slot, PIECE, stamp, body, self:_mine(string.unpack(">I4", row.id) :: any))
		unview(row)
		self:_send_cells({ { row = row.id, slot = slot, kind = PIECE, stamp = stamp, body = body } })
	end
end

-- An editor for a text column. Edits show here at once, reach everyone watching as they are made, and
-- become durable a piece at a time.
function Client.text(self: Client, id: string, col: Column)
	assert(col.text, "not a text column")
	assert(type(id) == "string" and #id == 16, "a row's id is 16 bytes")
	local slot = col.slot
	local scope: number = string.unpack(">I4", id) :: any
	local early: { () -> () }? = if self.rows[id] then nil else {} -- what is done before there is a row to do it to
	local row = self:_row(id)
	row.held[slot] = (row.held[slot] or 0) + 1
	local closed, ended = false, false
	local function fresh(): string
		return self.host.random(8)
	end
	local function edited()
		row.dirty[slot] = true
		self.typing[row] = true
		unview(row)
		self:_place(row)
		self:_later()
	end
	local timer: (() -> ())? = nil
	local function schedule()
		if not timer then
			timer = self.host.after(PIECE_SECONDS, function()
				timer = nil
				self:_seal(row, slot)
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
		row.held[slot] -= 1
		if row.held[slot] == 0 then
			row.held[slot] = nil
		end
		local asking = row.asking
		if asking and next(row.held) == nil then
			row.asking = nil
			asking()
		end
		self:_place(row)
	end
	self:_keep(row, function()
		local todo = early
		early = nil
		if todo and #todo > 0 and not row.dead then
			for _, f in todo do
				f()
			end
			edited()
			schedule()
		end
		if closed then
			finish()
		end
	end)
	return table.freeze({
		read = function(): string
			return text.read(self:_text(row, slot))
		end,
		-- Positions count bytes.
		insert = function(pos: number, s: string)
			edit(function(t)
				text.insert(t, pos, s, fresh)
			end)
		end,
		append = function(s: string)
			edit(function(t)
				text.insert(t, text.len(t), s, fresh)
			end)
		end,
		delete = function(pos: number, count: number)
			edit(function(t)
				text.delete(t, pos, count, fresh)
			end)
		end,
		-- Makes what has been written durable now rather than shortly.
		commit = function()
			self:_seal(row, slot)
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
	self.followers[f] = true
	return function()
		self.followers[f] = nil
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
	local ms, n = codec.clock(stamp)
	if ms > self.clock_ms or (ms == self.clock_ms and n > self.clock_n) then
		self.clock_ms, self.clock_n = ms, n
	end
end

-- A stamp for a cell of a row: no earlier than the row was made, for no cell is older than its row.
function Client._stamp(self: Client, row: string): string
	local born = (string.unpack(">I4", row, 5) :: any) * 1000
	if born > self.clock_ms then
		self.clock_ms, self.clock_n = born, 0
	end
	local ms = math.floor(self.host.now() * 1000)
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
-- this client with it. One made later than a stamp of this client's may be ahead of the clock is never written.
function Client._may_write(self: Client, id: string, scope: number)
	if type(id) ~= "string" or #id ~= 16 then
		error("a row's id is 16 bytes", 3)
	elseif string.unpack(">I4", id) ~= scope then
		error("that row is of another scope", 3)
	elseif self.ready and not self:may(scope, "write") then
		error("this client may not write there", 3)
	elseif (string.unpack(">I4", id, 5) :: any) > self.host.now() + LEAP_SECONDS then
		error("that row was made later than any clock may yet say", 3)
	end
end

function Client._send_cells(self: Client, cells: { Written }, done: (() -> ())?)
	local scope: number = string.unpack(">I4", cells[1].row) :: any
	-- What this client may no longer write in, since it began, is never said: a node refuses it, and this client with it.
	if self.ready and not self:may(scope, "write") then
		return
	end
	local w = codec.writer()
	local last = ""
	local rows: { string } = {}
	for _, c in cells do
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
	table.insert(self.pending, { seq = self.seq, scope = scope, body = body, rows = rows, done = done or function() end })
	if self.ready then
		local framed = codec.writer()
		codec.put_varint(framed, self.seq)
		codec.put(framed, body)
		self:_frame(CELLS, framed)
	end
end

function Client._on_ack(self: Client, seq: number)
	while #self.pending > 0 and self.pending[1].seq <= seq do
		local p = table.remove(self.pending, 1) :: Pending
		self:_settle(p)
		p.done()
	end
end

-- What was written is pending no more: its rows are let go of, unless something else holds them.
function Client._settle(self: Client, p: Pending)
	for _, id in p.rows do
		local n = self.unacked[id] - 1
		self.unacked[id] = if n > 0 then n else nil
		local row = self.rows[id]
		if n == 0 and row and row.pages == 0 and next(row.held) == nil then
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
	-- one this change made.
	local saved: { [string]: any } = {}
	local function keep(id: string, slot: number)
		local was = saved[id]
		if was == nil then
			local row = self.rows[id]
			if row then
				-- What editors have open in the row is their own writing, sent whatever becomes of this change: first, then,
				-- so that undoing the change cannot take it back.
				for k, t in row.texts do
					if t.open ~= "" then
						self:_seal(row, k)
					end
				end
				local slots = {}
				for k, cs in row.slots do
					slots[k] = table.clone(cs)
				end
				was = { dead = row.dead, slots = slots, touched = {} }
			else
				was = false
			end
			saved[id] = was
		end
		if was then
			was.touched[slot] = true
		end
	end
	local function put(row: string, slot: number, kind: number, body: string)
		assert(#body <= MAX_OPEN, "a value may be 1 MiB at most, less 192 bytes")
		if not sound(kind, slot, body) then
			error(`no cell of kind {kind} goes in slot {slot}`, 0) -- as a column made by hand may say
		end
		local stamp = self:_stamp(row)
		keep(row, slot)
		rows[row] = true
		table.insert(cells, { row = row, slot = slot, kind = kind, stamp = stamp, body = body })
		self:_accept(self:_row(row), slot, kind, stamp, body, self:_mine(scope))
	end
	local function set(id: string, schema: Table, values: { [string]: any })
		for name, value in values do
			local c = schema[name]
			assert(c and not c.who, `no column {name} to write`)
			-- Empty text is what a text is before anything is written: it need only be said to clear one.
			local row = self.rows[id]
			if value ~= "" or not c.text or (row and row.slots[c.slot]) or not fresh[id] then
				put(id, c.slot, VALUE, c.encode(value))
			end
		end
	end
	local function place(id: string, list: string, order: number, slot: number?)
		if type(order) ~= "number" or order < 0 or order > 9007199254740991 or order ~= math.floor(order) then
			error("an order is a whole number from 0 to 2^53", 0)
		elseif slot ~= nil and (type(slot) ~= "number" or slot < 1 or slot > 15 or slot ~= math.floor(slot)) then
			error("a row is placed in slots 1 to 15", 0)
		end
		put(id, slot or 1, PLACE, self:_tag(scope, list) .. codec.u64(order))
	end
	-- A row of this scope: what a change does to a row of another is refused, and the whole change with it, by any node.
	local function writable(id: string): string
		self:_may_write(id, scope)
		return id
	end
	local change: Change = {
		insert = function(schema, list, order, values)
			-- As late as anything heard of: later, then, than any right that is known to have ended.
			local ms = math.floor(self.host.now() * 1000)
			if ms > self.clock_ms then
				self.clock_ms, self.clock_n = ms, 0
			end
			local id = string.pack(">I4I4", scope, self.clock_ms // 1000) .. self.host.random(8)
			fresh[id] = true
			place(id, list, order)
			set(id, schema, values)
			return id
		end,
		set = function(id, schema, values)
			set(writable(id), schema, values)
		end,
		place = function(id, list, order, slot)
			place(writable(id), list, order, slot)
		end,
		delete = function(id)
			put(writable(id), 0, GRAVE, "")
		end,
		edit = function(id, slot, f)
			assert(slot >= 16 and slot <= 255, "data slots are 16 to 255")
			writable(id)
			local row = self:_row(id)
			if row.texts[slot] and row.texts[slot].open ~= "" then
				self:_seal(row, slot) -- what an editor has open goes first
			end
			keep(id, slot)
			local t = self:_text(row, slot)
			f(t, function(): string
				return self.host.random(8)
			end)
			local stamp = self:_stamp(id)
			local body = text.close(t, stamp)
			if body then
				assert(#body <= MAX_OPEN, "an edit may be 1 MiB at most, less 192 bytes")
				rows[id] = true
				table.insert(cells, { row = id, slot = slot, kind = PIECE, stamp = stamp, body = body })
				merge(row, slot, PIECE, stamp, body, self:_mine(scope))
				unview(row)
			end
		end,
	}
	local ok, why = pcall(f, change)
	if not ok then
		-- All or nothing: whatever was done here is undone, and nothing is said.
		for id, was in saved do
			local row = self.rows[id]
			if not was then
				self.rows[id] = nil
			elseif row then
				row.dead = was.dead
				row.slots = was.slots
				for slot in was.touched do
					row.texts[slot] = nil -- read again from its cells when next wanted
					row.lives[slot] = nil
				end
				unview(row)
			end
		end
		error(why, 0)
	end
	if #cells > 0 then
		self:_send_cells(cells, done)
	elseif done then
		self.host.defer(done)
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
	self.next_call += 1
	local id = self.next_call
	local live = self:_call(id, 0, device, method)
	if not self.ready or #data > CALL_WINDOW then
		self.calls[id] = nil
		self.host.defer(function()
			if live.call.on_fault then
				live.call.on_fault(if self.ready then "overrun" else "unreachable")
			end
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
				coroutine.resume(thread)
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
	handler(live.call, data)
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
		local done = true
		if call.on_data then
			done = call.on_data(data) ~= false
		end
		if done and set[id] == live then
			self:_consume(id, live, #data)
		end
	elseif kind == F_CREDIT then
		live.credit += codec.varint(r)
		self:_drain(id, live)
		if call.on_room and set[id] == live then
			call.on_room()
		end
	elseif kind == F_END then
		live.theirs_ended = true
		if live.mine_ended then
			set[id] = nil
		end
		if call.on_end then
			call.on_end()
		end
	else
		set[id] = nil
		if call.on_fault then
			local code = if kind == F_FAULT and r.pos < r.len then codec.u8(r) else 0
			call.on_fault(Faults[code] or "cancelled")
		end
	end
end

return table.freeze({ connect = new_client, columns = columns })
