--!strict
--!native
--!optimize 2
-- A query client. It keeps what is on screen, live, and nothing else: windows over ordered lists that grow
-- in either direction, shared between whoever observes them and let go when nobody does. Writes show at
-- once and survive reconnection. It owns no thread, clock or socket; the host lends it those.

local codec = require("./codec")
local sha256 = require("./sha256")
local text = require("./text")

local HELLO, ROSTER, WATCH, UNWATCH, CELLS, ACK = 1, 2, 3, 4, 7, 8
local LIVE, SYNCED, PRESENCE, ERROR, SERVE, CALL, FLOW = 9, 10, 12, 13, 14, 15, 16
local GRAVE, PLACE, VALUE, PIECE, BUNDLE = 1, 2, 3, 4, 5
local W_DATA, W_LIVE, W_BACK, W_ADOPT, W_COUNTS = 1, 2, 4, 8, 32
local F_DATA, F_END, F_FAULT, F_CANCEL, F_CREDIT = 0, 1, 2, 3, 4
local CALL_WINDOW = 262144
local MAX_OPEN = 1048576 - 128
local ZERO32 = string.rep("\0", 32)

local PIECE_BYTES = 4096 -- a piece is sealed at this size,
local PIECE_SECONDS = 1 -- or this long after it began,
local LIVE_SECONDS = 10 -- and live text unconfirmed for this long is dropped

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
	read encode: (any) -> string,
	read decode: (string) -> any,
}
export type Table = { [string]: Column }
export type Row = { id: string, order: number, [string]: any }
export type State = {
	read rows: { Row },
	read status: "loading" | "stale" | "ready" | "denied",
	read before: number, -- rows of the list that lie before these,
	read after: number, -- and after
}
export type Device = { read id: string, read subject: string }

type Cell = { kind: number, stamp: string, body: string }
type Stored = {
	id: string,
	slots: { [number]: { [string]: Cell } }, -- by stamp
	dead: boolean,
	pages: number, -- that hold it
	texts: { [number]: text.Text },
	held: { [number]: number }, -- open editors, by slot
	lives: { [number]: number }, -- when live text was last heard, by slot
	views: { [any]: Row }, -- by table, until the row changes
	dirty: { [number]: boolean }, -- slots with live text to send
}
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
	stale: { [string]: boolean }?, -- while being sent afresh: rows not yet mentioned
}
export type Window = {
	key: string,
	scope: number,
	list: string,
	schema: Table,
	size: number,
	pages: { Page },
	entries: { { key: string, row: Stored } }, -- in order
	observers: { [(State) -> ()]: boolean },
	watching: number,
	state: State?,
	changed: boolean,
	denied: boolean,
	linger: (() -> ())?,
}
export type Call = {
	send: (data: string) -> (),
	finish: () -> (),
	cancel: () -> (),
	on_data: ((data: string) -> ())?,
	on_end: (() -> ())?,
	on_fault: ((fault: string) -> ())?,
	device: string,
	method: string,
}
type Live_Call = {
	call: Call,
	side: number,
	finishing: boolean, -- no more will be sent,
	mine_ended: boolean, -- and the other side has been told so
	theirs_ended: boolean,
	credit: number,
	queue: { string }, -- awaiting credit
}

local Faults = { "denied", "unreachable", "unserved", "lost", "overrun", "busy" }

-- ---------------------------------------------------------------- columns

local function column(slot: number, is_text: boolean, encode: (any) -> string, decode: (string) -> any): Column
	assert(slot >= 16 and slot <= 255, "data slots are 16 to 255")
	return table.freeze({ slot = slot, text = is_text, encode = encode, decode = decode })
end

local function same(v: any): any
	return v
end

local columns = {}

function columns.string(slot: number): Column
	return column(slot, false, same, same)
end

function columns.number(slot: number): Column
	return column(slot, false, function(v)
		return string.pack(">d", v)
	end, function(s)
		return (string.unpack(">d", s))
	end)
end

function columns.boolean(slot: number): Column
	return column(slot, false, function(v)
		return if v then "\1" else "\0"
	end, function(s)
		return s == "\1"
	end)
end

-- Anything, given a way to write it down.
function columns.custom(slot: number, encode: (any) -> string, decode: (string) -> any): Column
	return column(slot, false, encode, decode)
end

-- Collaborative, streamable text.
function columns.text(slot: number): Column
	return column(slot, true, same, same)
end

table.freeze(columns)

-- ---------------------------------------------------------------- the client

local Client = {}
Client.__index = Client

local function new_client(host: Host)
	local self = setmetatable({
		host = host,
		wire = nil :: Wire?,
		ready = false,
		closed = false,
		failures = 0,
		input = "",
		clock_ms = 0,
		clock_n = 0,
		scopes = {} :: { [number]: { rights: number, key: string } },
		devices = {} :: { Device },
		watchers = {} :: { [string]: { [(any) -> ()]: boolean } },
		rows = {} :: { [string]: Stored },
		windows = {} :: { [string]: Window },
		pages = {} :: { [number]: Page },
		next_page = 0,
		shapes = (setmetatable({}, { __mode = "k" }) :: any) :: { [Table]: number },
		next_shape = 0,
		seq = 0,
		pending = {} :: { { seq: number, body: string, rows: { string }, done: () -> () } },
		unacked = {} :: { [string]: number }, -- rows in pending, and how often
		out = codec.writer(),
		flushing = false,
		calls = {} :: { [number]: Live_Call }, -- ours
		answers = {} :: { [number]: Live_Call }, -- of others
		next_call = 0,
		handlers = {} :: { [string]: (Call, string) -> () },
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
	local w = codec.writer()
	codec.put(w, "\1\0")
	codec.put(w, ZERO32)
	codec.put_varint(w, 0)
	codec.put_bytes(w, self.host.credential)
	self:_frame(HELLO, w)
end

function Client._lost(self: Client)
	self.wire = nil
	self.ready = false
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
	self:_tell("status", false)
	if not self.closed then
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
	if self.wire then
		self.wire.close()
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
	for _, row in self.rows do
		if next(row.dirty) ~= nil then
			self:_send_live(row)
		end
	end
	local out = self.out
	if out.pos > 0 and self.wire then
		local sized = buffer.create(out.pos)
		buffer.copy(sized, 0, out.buf, 0, out.pos)
		out.pos = 0
		self.wire.send(sized)
	end
	for _, window in self.windows do
		if window.changed then
			self:_publish(window)
		end
	end
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
				if self.wire then
					self.wire.close()
				end
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
		self:_handle(codec.u8(r), r)
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
	elseif kind == ACK then
		self:_on_ack(codec.varint(r))
	elseif kind == FLOW then
		self:_on_flow(r)
	elseif kind == CALL then
		self:_on_call(r)
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
		self.closed = code == 2 or code == 3 -- refused, or speaking another language: trying again is no use
		self:_tell("error", code)
	end
end

function Client._on_scopes(self: Client, r: codec.Reader)
	self:_heard(codec.take(r, 8))
	table.clear(self.scopes)
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
		self:_tell("status", true)
		return
	end
	self.ready = true
	self.failures = 0
	-- Say again whatever the last pipe was told: what is served, unacknowledged and watched.
	for key in self.handlers do
		self:_serve(key, true)
	end
	for _, p in self.pending do
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

-- "status" (connected or not), "devices" (those reachable, this one first) or "error". Returns a way to stop.
function Client.on(self: Client, what: "status" | "devices" | "error", f: (any) -> ()): () -> ()
	local set = self.watchers[what] or {}
	self.watchers[what] = set
	set[f] = true
	if what == "status" then
		f(self.ready)
	elseif what == "devices" then
		f(self.devices)
	end
	return function()
		set[f] = nil
	end
end

-- ---------------------------------------------------------------- windows

function Client._tag(self: Client, scope: number, list: string): string
	local s = self.scopes[scope]
	assert(s, "no such scope")
	return string.pack(">I4", scope) .. string.sub(sha256(s.key .. list), 1, 12)
end

export type Query = {
	scope: number,
	list: string,
	table: Table,
	size: number?, -- rows to a page: 50
	from: ("start" | "end")?, -- where to begin: the end
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
	local key = `{query.scope}/{from}/{query.size or 50}/{shape}/{query.list}`
	local window = self.windows[key]
	if not window then
		local made: Window = {
			key = key,
			scope = query.scope,
			list = query.list,
			schema = query.table,
			size = query.size or 50,
			pages = {},
			entries = {},
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
	observer(self:_state(window))
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
	self:_watch(page, window.size, not string.find(window.key, "/start/", 1, true))
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
	local stale = {}
	for _, e in page.window.entries do
		if e.key >= page.lo and e.key < page.hi then
			stale[e.row.id] = true
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
	page.lo, page.hi = codec.key(r), codec.key(r)
	page.limit = 0 -- from here on it is a range, however many are in it
	page.before, page.after = codec.varint(r), codec.varint(r)
	page.settled = bit32.btest(flags, 1)
	page.open = false
	local stale = page.stale
	page.stale = nil
	if stale then
		for id in stale do
			local row = self.rows[id]
			if row and not self:_pending(id) then
				self:_unplace(row, page.lo, page.hi)
			end
		end
	end
	-- Where a full replica says the page ends, what lay past it was never known to be whole.
	self:_trim(window)
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
	if #window.pages == 0 or not self.ready then
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
	for _, e in window.entries do
		if e.key >= lo and e.key < hi then
			table.insert(kept, e)
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
	if row.pages == 0 and next(row.held) == nil and not self:_pending(row.id) then
		self.rows[row.id] = nil
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
	local state = self:_state(window)
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
		if c.text then
			local t = self:_text(row, c.slot)
			made[name] = text.read(t)
		else
			local slot = row.slots[c.slot]
			if slot then
				for _, cell in slot do
					if cell.kind == VALUE then
						made[name] = c.decode(cell.body)
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
		row = { id = id, slots = {}, dead = false, pages = 0, texts = {}, held = {}, lives = {}, views = {}, dirty = {} }
		self.rows[id] = row
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

-- The merge rule. Returns whether the cell was news.
local function merge(row: Stored, slot: number, kind: number, stamp: string, body: string): boolean
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
	cells[stamp] = { kind = kind, stamp = stamp, body = body }
	return true
end

function Client._on_cells(self: Client, r: codec.Reader)
	codec.varint(r)
	local id = ""
	local touched: { [Stored]: boolean } = {}
	while r.pos < r.len do
		local tag = codec.u8(r)
		if tag < 128 then
			id = codec.take(r, 16)
		end
		local slot = codec.u8(r)
		local stamp = codec.take(r, 16)
		local body = codec.bytes(r)
		self:_heard(stamp)
		local row = self:_row(id)
		touched[row] = true
		for _, page in self.pages do
			if page.stale then
				page.stale[id] = nil
			end
		end
		self:_accept(row, slot, tag % 128, stamp, body)
	end
	for row in touched do
		self:_place(row)
	end
end

function Client._accept(self: Client, row: Stored, slot: number, kind: number, stamp: string, body: string): boolean
	if not merge(row, slot, kind, stamp, body) then
		return false
	end
	local t = row.texts[slot]
	if t and kind >= VALUE then
		if text.apply(t, kind, stamp, body) == "rebuild" then
			self:_rebuild(row, slot)
		end
	end
	row.views = {}
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
	row.views = {}
end

-- Puts a row where its placements say, in every window, and takes it from where they do not.
function Client._place(self: Client, row: Stored)
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
			local have: number? = nil
			for i, e in entries do
				if e.row == row then
					have = i
					break
				end
			end
			if have and (not want or entries[have].key ~= want) then
				table.remove(entries, have)
				row.pages -= 1
				self:_touch(window)
				have = nil
			end
			if want and not have then
				table.insert(entries, self:_find(window, want), { key = want, row = row })
				row.pages += 1
				self:_touch(window)
			elseif want then
				self:_touch(window)
			end
		end
	end
	if row.pages <= 0 and next(row.held) == nil and (row.dead or not self:_pending(row.id)) then
		self.rows[row.id] = nil
	end
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
		row.views = {}
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

function Client._seal(self: Client, row: Stored, slot: number)
	local t = row.texts[slot]
	if not t or t.open == "" then
		return
	end
	local stamp = self:_stamp()
	local body = text.close(t, stamp)
	if body then
		merge(row, slot, PIECE, stamp, body)
		self:_send_cells({ { row = row.id, slot = slot, kind = PIECE, stamp = stamp, body = body } })
	end
end

-- An editor for a text column. Edits show here at once, reach everyone watching as they are made, and
-- become durable a piece at a time.
function Client.text(self: Client, id: string, col: Column)
	assert(col.text, "not a text column")
	local slot = col.slot
	local row = self:_row(id)
	row.held[slot] = (row.held[slot] or 0) + 1
	local closed = false
	local function fresh(): string
		return self.host.random(8)
	end
	local function edited()
		row.dirty[slot] = true
		row.views = {}
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
		f(self:_text(row, slot))
		edited()
		schedule()
	end
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
			if timer then
				timer()
			end
			self:_seal(row, slot)
			row.held[slot] -= 1
			if row.held[slot] == 0 then
				row.held[slot] = nil
			end
			self:_place(row)
		end,
	})
end

-- ---------------------------------------------------------------- writing

function Client._heard(self: Client, stamp: string)
	local ms, n = codec.clock(stamp)
	if ms > self.clock_ms or (ms == self.clock_ms and n > self.clock_n) then
		self.clock_ms, self.clock_n = ms, n
	end
end

function Client._stamp(self: Client): string
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

function Client._send_cells(self: Client, cells: { Written }, done: (() -> ())?)
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
	table.insert(self.pending, { seq = self.seq, body = body, rows = rows, done = done or function() end })
	if self.ready then
		local framed = codec.writer()
		codec.put_varint(framed, self.seq)
		codec.put(framed, body)
		self:_frame(CELLS, framed)
	end
end

function Client._on_ack(self: Client, seq: number)
	while #self.pending > 0 and self.pending[1].seq <= seq do
		local p = table.remove(self.pending, 1) :: any
		for _, id in p.rows do
			local n = self.unacked[id] - 1
			self.unacked[id] = if n > 0 then n else nil
			local row = self.rows[id]
			if n == 0 and row and row.pages == 0 and next(row.held) == nil then
				self.rows[id] = nil
			end
		end
		p.done()
	end
end

export type Change = {
	insert: (schema: Table, list: string, order: number, values: { [string]: any }) -> string,
	set: (id: string, schema: Table, values: { [string]: any }) -> (),
	place: (id: string, list: string, order: number, slot: number?) -> (),
	delete: (id: string) -> (),
}

-- Applies several changes as one: all visible in the same turn, all durable together or not at all.
-- `done` is called when they are durable on this device.
function Client.write(self: Client, scope: number, f: (Change) -> (), done: (() -> ())?)
	local s = self.scopes[scope]
	assert(s and bit32.btest(s.rights, 2), "this client may not write there")
	local cells: { Written } = {}
	local fresh: { [string]: boolean } = {} -- rows made here
	local rows: { [string]: boolean } = {}
	local function put(row: string, slot: number, kind: number, body: string)
		assert(#body <= MAX_OPEN, "a value may be 1 MiB at most, less 128 bytes")
		local stamp = self:_stamp()
		rows[row] = true
		table.insert(cells, { row = row, slot = slot, kind = kind, stamp = stamp, body = body })
		self:_accept(self:_row(row), slot, kind, stamp, body)
	end
	local function set(id: string, schema: Table, values: { [string]: any })
		for name, value in values do
			local c = schema[name]
			assert(c, `no column {name}`)
			-- Empty text is what a text is before anything is written: it need only be said to clear one.
			local row = self.rows[id]
			if value ~= "" or not c.text or (row and row.slots[c.slot]) or not fresh[id] then
				put(id, c.slot, VALUE, c.encode(value))
			end
		end
	end
	local function place(id: string, list: string, order: number, slot: number?)
		put(id, slot or 1, PLACE, self:_tag(scope, list) .. codec.u64(order))
	end
	f({
		insert = function(schema, list, order, values)
			local id = string.pack(">I4I4", scope, math.floor(self.host.now())) .. self.host.random(8)
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
	})
	if #cells > 0 then
		self:_send_cells(cells, done)
	elseif done then
		self.host.defer(done)
	end
	for id in rows do
		local row = self.rows[id]
		if row then
			self:_place(row)
		end
	end
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
		on_data = nil,
		on_end = nil,
		on_fault = nil,
		send = function(data: string)
			assert(#data <= CALL_WINDOW, "a message may be 256 KiB at most")
			if not over() and not live.finishing then
				table.insert(live.queue, data)
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
	}
	live = {
		call = call,
		side = side,
		finishing = false,
		mine_ended = false,
		theirs_ended = false,
		credit = CALL_WINDOW,
		queue = {},
	}
	set[id] = live
	return live
end

-- Sends what the other side has room for, and then, if there is no more, says so.
function Client._drain(self: Client, id: number, live: Live_Call)
	while #live.queue > 0 and live.credit >= #live.queue[1] do
		local data = table.remove(live.queue, 1) :: string
		live.credit -= #data
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

-- Calls a method on a device. Set on_data, on_end and on_fault on the result before yielding.
function Client.call(self: Client, device: string, scope: number, method: string, data: string): Call
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
	codec.put(w, data)
	self:_frame(CALL, w)
	return live.call
end

-- One question, one answer; yields the coroutine it is called from. Returns the answer, or nil and why not.
function Client.request(self: Client, device: string, scope: number, method: string, data: string): (string?, string?)
	local thread = coroutine.running()
	local answer: string? = nil
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
	local call = self:call(device, scope, method, data)
	call.on_data = function(d: string)
		answer = (answer or "") .. (d :: string)
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
	return answer or "", nil
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
	local handler = self.handlers[`{scope}/{method}`]
	if not handler then
		self:_flow(id, 1, F_FAULT, "\3")
		return
	end
	local data = codec.rest(r)
	local live = self:_call(id, 1, device, method)
	local w = codec.writer()
	codec.put_varint(w, #data)
	self:_flow(id, 1, F_CREDIT, codec.string(w))
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
		local w = codec.writer()
		codec.put_varint(w, #data)
		self:_flow(id, live.side, F_CREDIT, codec.string(w))
		if call.on_data then
			call.on_data(data)
		end
	elseif kind == F_CREDIT then
		live.credit += codec.varint(r)
		self:_drain(id, live)
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
