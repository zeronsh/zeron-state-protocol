--!strict
-- What structured state costs on a client, without a network.
--
--   lune run luau/tests/mirror_bench.luau [rows]                    every case once, timed, with what it holds after
--   lune run luau/tests/mirror_bench.luau rows prep FILE            what a node sends, made once and written down
--   lune run luau/tests/mirror_bench.luau rows CASE FILE COUNT      one case, COUNT times (0: only what leads to it)
--
--   lune run luau/tests/mirror_bench.luau rows CASE FILE COUNT memory   and what the heap holds after, collected
--   lune run luau/tests/mirror_bench.luau rows CASE FILE COUNT alloc    and what the case made, with nothing collected
--
-- bench/mirror.py runs each case as a process of its own, with COUNT 0 and COUNT n, so that what a case alone costs in
-- instructions and in memory at its height is the difference between them. Where ZSP_PERF_CTL names perf's control fifo,
-- perf counts only the case itself; where ZSP_QUIET is a number of MB, the heap is made that much bigger first, of
-- strings the collector need not look into, so that it is not round while a few changes are made (see paused()).

local codec = require("../zsp/codec")
local zsp = require("../zsp")
local m = zsp.mirror
local fs = require("@lune/fs")
local process = require("@lune/process")
local task = require("@lune/task")

local CELLS, ACK, ROSTER, LIVE, ASK, UNASK, ANSWER = 7, 8, 2, 9, 32, 33, 34
local KEY = string.rep("k", 32)
local TIMES = 200 -- of each change
-- Of each change heard, written down: as many as bench/mirror.py has done first, not counted, and then counted, each new.
-- Fewer moves: each is sent with the whole of the list's order, which every move makes longer.
local FRAMES, MOVES = 3200, 400

-- ---------------------------------------------------------------- clients that hear only what they are given

type Peer = {
	client: any,
	receive: (any) -> (),
	deferred: { () -> () },
	out: { string },
	live: { string },
	asks: { string },
	sent: number, -- the last of what it wrote
	acked: number,
	unasks: { number }, -- questions no longer asked, to be let go of
}

local clock = 1800000000
-- The same numbers every run: a xorshift of 32 bits.
local seed = 2463534242
local rng = {}
function rng.NextInteger(_: any, lo: number, hi: number): number
	seed = bit32.bxor(seed, bit32.lshift(seed, 13))
	seed = bit32.bxor(seed, bit32.rshift(seed, 17))
	seed = bit32.bxor(seed, bit32.lshift(seed, 5))
	return lo + seed % (hi - lo + 1)
end
local function peer(): Peer
	local self: Peer = { client = nil, receive = function() end, deferred = {}, out = {}, live = {}, asks = {}, sent = 0, acked = 0, unasks = {} }
	self.client = zsp.connect({
		credential = "x",
		now = function(): number
			return clock
		end,
		random = function(n: number): string
			-- As cheap as a host's own would be, so that what is measured is the client; and the same each run.
			local b = buffer.create(n)
			for i = 0, n - 1 do
				buffer.writeu8(b, i, rng:NextInteger(0, 255))
			end
			return buffer.tostring(b)
		end,
		defer = function(f: () -> ())
			table.insert(self.deferred, f)
		end,
		after = function(_: number, _f: () -> ())
			return function() end
		end,
		connect = function(receive: any, _closed: any)
			self.receive = receive
			local rest = ""
			return {
				send = function(data: buffer)
					-- A stream of bytes, sent in pieces of at most a MiB: a frame may be cut, and is read once it is whole.
					local all = rest .. buffer.tostring(data)
					local r = codec.reader(all)
					while r.pos < r.len do
						local at = r.pos
						local ok, n = pcall(codec.varint, r)
						if not ok or r.pos + n > r.len then
							r.pos = at
							break
						end
						local body = codec.take(r, n)
						local kind = string.byte(body)
						if kind == CELLS then
							-- What it writes, as another would be sent it.
							local f = codec.reader(string.sub(body, 2))
							self.sent = codec.varint(f)
							table.insert(self.out, codec.rest(f))
						elseif kind == LIVE then
							table.insert(self.live, body)
						elseif kind == ASK then
							table.insert(self.asks, string.sub(body, 2))
						elseif kind == UNASK then
							table.insert(self.unasks, codec.varint(codec.reader(string.sub(body, 2))))
						end
					end
					rest = string.sub(all, r.pos + 1)
				end,
				close = function() end,
			}
		end,
	})
	local w = codec.writer()
	codec.put_u8(w, ROSTER)
	codec.put(w, string.rep("\0", 8) .. "\1\7" .. KEY)
	local framed = codec.writer()
	codec.put_bytes(framed, codec.string(w))
	self.receive(codec.string(framed))
	return self
end

-- What is deferred, done; and then, as a node would, what was written acknowledged and what was no longer asked let go of.
local function run(p: Peer)
	while true do
		while #p.deferred > 0 do
			(table.remove(p.deferred, 1) :: any)()
		end
		local w = codec.writer()
		if p.acked < p.sent then
			p.acked = p.sent
			codec.put_u8(w, ACK)
			codec.put_varint(w, p.sent)
		elseif #p.unasks > 0 then
			codec.put_u8(w, ANSWER)
			codec.put_varint(w, table.remove(p.unasks, 1) :: number)
			codec.put_u8(w, 16)
		else
			return
		end
		local framed = codec.writer()
		codec.put_bytes(framed, codec.string(w))
		p.receive(codec.string(framed))
	end
end

local function frame(body: string): string
	local framed = codec.writer()
	codec.put_bytes(framed, body)
	return codec.string(framed)
end

local function cells_frame(cells: string): string
	local w = codec.writer()
	codec.put_u8(w, CELLS)
	codec.put_varint(w, 0)
	codec.put(w, cells)
	return frame(codec.string(w))
end

-- What a node holds: whole rows, and of each that is deleted, by what. It sends whole rows of what it is told, of those
-- that are in the list, as a watch of it is sent.
type Node = { rows: { [string]: { [string]: string } }, dead: { [string]: string }, order: { string } }
local function node(): Node
	return { rows = {}, dead = {}, order = {} }
end
local function store(n: Node, cells: string): { string }
	local touched, seen = {}, {}
	local r = codec.reader(cells)
	local id = ""
	while r.pos < r.len do
		local tag = codec.u8(r)
		if tag < 128 then
			id = codec.take(r, 16)
		end
		local slot = codec.u8(r)
		local stamp = codec.take(r, 16)
		local body = codec.bytes(r)
		local kind = tag % 64
		local w = codec.writer()
		codec.put_u8(w, kind)
		codec.put(w, id)
		codec.put_u8(w, slot)
		codec.put(w, stamp)
		codec.put_bytes(w, body)
		local fresh = false
		if kind == 1 then
			if not n.dead[id] or stamp > n.dead[id] then
				n.dead[id] = stamp
				n.rows[id] = { grave = codec.string(w) }
				fresh = true
			end
		elseif not n.dead[id] then
			if not n.rows[id] then
				n.rows[id] = {}
				table.insert(n.order, id)
			end
			n.rows[id][string.char(slot, kind) .. stamp] = codec.string(w)
			fresh = true
		end
		if fresh and not seen[id] then
			seen[id] = true
			table.insert(touched, id)
		end
	end
	return touched
end
local function rows_of(n: Node, ids: { string }): string
	local out = {}
	for _, t in ids do
		local row = n.rows[t]
		if row then
			local placed = row.grave ~= nil
			local keys = {}
			for k in row do
				placed = placed or string.byte(k, 2) == 2
				table.insert(keys, k)
			end
			if placed then
				table.sort(keys) -- the same bytes every run
				for _, k in keys do
					table.insert(out, row[k])
				end
			end
		end
	end
	return table.concat(out)
end
-- What a node sends of what a writer wrote since last asked.
local function sent(n: Node, p: Peer): string
	local touched = {}
	for _, cells in p.out do
		for _, id in store(n, cells) do
			table.insert(touched, id)
		end
	end
	table.clear(p.out)
	return cells_frame(rows_of(n, touched))
end

-- ---------------------------------------------------------------- what is measured

local Big = m.map({ items = m.list(18, m.map({ n = zsp.number(16), label = zsp.string(17) })) })
local Notes = m.map({ items = m.list(18, m.map({ n = zsp.number(16), body = zsp.text(17) })) })
local Plain = { n = zsp.number(16), label = zsp.string(17) }

-- A change may be 4 MiB at most (SPEC.md 8): a document of many items is made in changes of so many, each the items there
-- are and so many more.
local PART = 10000
local function set_in_parts(doc: any, field: string, items: { any }, after: () -> ())
	local at = 0
	repeat
		local list = table.clone(doc.state()[field])
		local upto = math.min(at + PART, #items)
		table.move(items, at + 1, upto, #list + 1, list)
		at = upto
		doc.set({ [field] = list })
		after()
	until at >= #items
end

local function items_of(n: number): { any }
	local items = table.create(n)
	for i = 1, n do
		items[i] = { n = i, label = `item {i}` }
	end
	return items
end

-- Everything a node would send for each case, made by writers: a document, its changes and moves, a plain list, a
-- document with a text in each item and what is typed in one, and the rows a question finds.
local function prepare(N: number): { [string]: { string } }
	local out: { [string]: { string } } = {}
	local p = peer()
	local n = node()
	local doc = m.open(p.client, { scope = 1, name = "big", schema = Big })
	run(p)
	set_in_parts(doc, "items", items_of(N), function()
		run(p)
	end)
	out.open = { sent(n, p) }
	local root: string? = nil
	for _, rid in n.order do
		if string.sub(rid, 5, 8) == "\0\0\0\0" then
			root = rid -- made from the scope's key, as only a map's id is: the document's own
		end
	end
	out.change, out.move = {}, {}
	for _ = 1, FRAMES do
		local now = doc.state()
		local list = table.clone(now.items)
		local i = rng:NextInteger(1, #list)
		local item = table.clone(list[i])
		item.n += 1
		list[i] = item
		doc.set({ items = list })
		run(p)
		table.insert(out.change, sent(n, p))
	end
	for _ = 1, MOVES do
		local list = table.clone(doc.state().items)
		local x = table.remove(list, rng:NextInteger(1, #list))
		table.insert(list, rng:NextInteger(1, #list + 1), x)
		doc.set({ items = list })
		run(p)
		table.insert(out.move, sent(n, p))
	end
	-- Rows that are not a document, in one list, so many to a change.
	for from = 1, N, PART do
		p.client:write(1, function(change)
			for i = from, math.min(from + PART - 1, N) do
				change.insert(Plain, "plain", i, { n = i, label = `row {i}` })
			end
		end)
		run(p)
	end
	out.window = { sent(n, p) }
	-- A text in every item, and someone typing in one.
	local notes = m.open(p.client, { scope = 1, name = "notes", schema = Notes })
	run(p)
	local items = table.create(N)
	for i = 1, N do
		items[i] = { n = i, body = `note {i}` }
	end
	set_in_parts(notes, "items", items, function()
		run(p)
	end)
	out.notes = { sent(n, p) }
	local id = notes.state().items[(N + 1) // 2].id
	local editor = p.client:text(id, zsp.text(17))
	out.live = {}
	for k = 1, FRAMES do
		editor.append(string.char(96 + k % 26))
		run(p)
		for _, body in p.live do
			table.insert(out.live, frame(body))
		end
		table.clear(p.live)
	end
	editor.close()
	run(p)
	table.insert(out.live, sent(n, p))
	out.typing = { id }
	-- A question of the first document: its items whose n is at most 50, the first 50 of them.
	local found = {}
	for _, item in doc.state().items do
		if item.n <= 50 then
			table.insert(found, item.id)
		end
	end
	table.sort(found)
	out.found = { rows_of(n, found), table.concat(found) }
	out.root = { rows_of(n, { root :: string }), root :: string }
	return out
end

local function write_file(path: string, data: { [string]: { string } })
	local w = codec.writer()
	local names = {}
	for name in data do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		codec.put_bytes(w, name)
		codec.put_varint(w, #data[name])
		for _, f in data[name] do
			codec.put_bytes(w, f)
		end
	end
	fs.writeFile(path, codec.string(w))
end

local function read_file(path: string): { [string]: { string } }
	local r = codec.reader(fs.readFile(path))
	local out = {}
	while r.pos < r.len do
		local name = codec.bytes(r)
		local list = {}
		for i = 1, codec.varint(r) do
			list[i] = codec.bytes(r)
		end
		out[name] = list
	end
	return out
end

-- What the heap holds once the collector has been round more than once: what is live, give or take what it is about.
local function settled(): number
	local least, last, falls = gcinfo(), gcinfo(), 0
	local junk = nil
	for i = 1, 50000000 do
		junk = { i, junk ~= nil }
		if i % 512 == 0 then
			local g = gcinfo()
			if g < last then
				falls += 1
			end
			least = math.min(least, g)
			last = g
			if falls >= 40 and i > 2000000 then
				break
			end
		end
	end
	return least
end

-- What leads to a case collected, and the collector between its rounds: churned until it has been round more than once
-- and then until the heap has only grown for a while, as it does only once a round is done and before the next. Luau has
-- no collecting at once; this is the nearest. The next round is when the heap is twice what it was after this one, so a
-- case that makes less than that (ZSP_QUIET makes it more) is not collected while it is done.
-- (The churning is of tables of 16 KiB arrays, which the system gives and takes back: churned as many small tables, the
-- heap would be left with as many small holes, which what is measured then would be slower to allocate in.)
-- What each table churned in waiting for the collector holds, in KB: 1024 values of 16 bytes, and what a table is (16.05).
local EACH_KB = 16

local function paused()
	-- A round gone through: a key held by nothing else is gone from a weak table only then.
	local probe = setmetatable({}, { __mode = "k" }) :: any
	probe[{}] = true
	local junk = nil
	local made, peak = 0, gcinfo()
	while next(probe) ~= nil do
		peak = gcinfo() -- before the table whose making may end the round and begin its sweep at once
		junk = table.create(1024, true)
		made += 1
		assert(made < 10000000, "the collector never went round")
	end
	-- And swept, all of it. What was made to wait for the round is all but all of what the round found was garbage, as this
	-- is done twice (see below), and it is most of the heap: it is gone once the sweep is done, or nearly. (Waiting only
	-- for the heap to grow is not enough: a sweep may go over pages of what is held, freeing nothing, for a while.)
	-- Where little was made, the heap may never come so low: so this ends, too, as the next round does, which a key made
	-- now goes from only then.
	local due = peak - made * EACH_KB * 0.85
	local next_round = setmetatable({}, { __mode = "k" }) :: any
	next_round[{}] = true
	local swept = 0
	while gcinfo() > due and next(next_round) ~= nil do
		junk = table.create(1024, true)
		swept += 1
		assert(swept < 10000000, "what was made was never swept")
	end
	-- Then the heap only grows, for as long as it takes to be twice what it was. A quarter of what it is, at most 32 MB,
	-- rising and never falling, is taken for that: where the heap is small, a round can come sooner than 32 MB. (A quarter
	-- of what it is as it falls, too.)
	local last, rising, steps = gcinfo(), 0, 0
	local enough = math.clamp(last // 1024, 4, 128) -- in steps of 256 KB
	while rising < enough do
		steps += 1
		assert(steps < 10000000, "the heap never only grew")
		for _ = 1, 16 do
			junk = table.create(1024, true)
		end
		local g = gcinfo()
		if g < last then
			rising = 0
			enough = math.clamp(g // 1024, 4, 128)
		else
			rising += 1
		end
		last = g
	end
	local _ = junk
end

-- Counting by perf, when bench/mirror.py runs it so (perf stat -D -1 --control): only what is between counting(true)
-- and counting(false). Lune cannot wait for perf's answer, so it sleeps a little after asking, which costs the same
-- with or without the case, and is taken away with what leads to it.
local function counting(on: boolean)
	local ctl = process.env.ZSP_PERF_CTL
	if not ctl then
		return
	end
	fs.writeFile(ctl, if on then "enable\n" else "disable\n")
	task.wait(0.02)
end

-- Answers a question as a node would, with the rows it was given: by ids, those; anything else, what the document's
-- question finds.
local function answer(q: Peer, data: { [string]: { string } })
	while #q.asks > 0 do
		local body = table.remove(q.asks, 1) :: string
		local r = codec.reader(body)
		local id = codec.varint(r)
		codec.varint(r) -- scope
		-- By ids, or all of: the list (16 bytes) and ids.
		local op = codec.u8(r)
		local by_ids = op == 11
		if op == 1 then
			for _ = 1, codec.varint(r) do
				local inner = codec.u8(r)
				if inner == 11 then
					by_ids = true
					break
				elseif inner ~= 9 then
					break
				end
				codec.take(r, 16)
			end
		end
		local rows, ids = data.found[1], data.found[2]
		if by_ids then
			rows, ids = data.root[1], data.root[2]
		end
		q.receive(cells_frame(rows))
		local a = codec.writer()
		codec.put_u8(a, ANSWER)
		codec.put_varint(a, id)
		codec.put_u8(a, 1)
		codec.put_varint(a, #ids // 16)
		codec.put_varint(a, 0)
		codec.put_varint(a, #ids // 16)
		codec.put(a, ids)
		codec.put_varint(a, 0)
		q.receive(frame(codec.string(a)))
		run(q)
	end
end

-- Each case: what leads to it, and the thing itself, done `count` times.
type Case = { setup: (data: { [string]: { string } }) -> any, step: (s: any, data: { [string]: { string } }, k: number) -> () }

local function opened(data: { [string]: { string } }, name: string, schema: any, frames: string): (Peer, any)
	local q = peer()
	local doc = m.open(q.client, { scope = 1, name = name, schema = schema })
	run(q)
	for _, f in data[frames] do
		q.receive(f)
	end
	run(q)
	return q, doc
end

local cases: { [string]: Case } = {
	make = {
		setup = function(data)
			local p = peer()
			local doc = m.open(p.client, { scope = 1, name = "big", schema = Big })
			run(p)
			return { p = p, doc = doc, items = items_of(tonumber(data.rows[1]) :: number) }
		end,
		step = function(s)
			set_in_parts(s.doc, "items", s.items, function()
				run(s.p)
			end)
			table.clear(s.p.out)
		end,
	},
	open = {
		setup = function(data)
			local q = peer()
			local doc = m.open(q.client, { scope = 1, name = "big", schema = Big })
			run(q)
			return { q = q, doc = doc }
		end,
		step = function(s, data)
			s.q.receive(data.open[1])
			run(s.q)
			assert(#s.doc.state().items == tonumber(data.rows[1]), "all of it is there")
		end,
	},
	set_change = {
		setup = function(data)
			local q, doc = opened(data, "big", Big, "open")
			return { q = q, doc = doc }
		end,
		step = function(s)
			local now = s.doc.state()
			local list = table.clone(now.items)
			local i = rng:NextInteger(1, #list)
			local item = table.clone(list[i])
			item.n += 1
			list[i] = item
			s.doc.set({ items = list })
			run(s.q)
			table.clear(s.q.out)
		end,
	},
	update_change = {
		setup = function(data)
			local q, doc = opened(data, "big", Big, "open")
			return { q = q, doc = doc }
		end,
		step = function(s)
			s.doc.update(function(d)
				d.items[rng:NextInteger(1, #d.items)].n += 1
			end)
			run(s.q)
			table.clear(s.q.out)
		end,
	},
	set_move = {
		setup = function(data)
			local q, doc = opened(data, "big", Big, "open")
			return { q = q, doc = doc }
		end,
		step = function(s)
			local list = table.clone(s.doc.state().items)
			local x = table.remove(list, rng:NextInteger(1, #list))
			table.insert(list, rng:NextInteger(1, #list + 1), x)
			s.doc.set({ items = list })
			run(s.q)
			table.clear(s.q.out)
		end,
	},
	update_move = {
		setup = function(data)
			local q, doc = opened(data, "big", Big, "open")
			return { q = q, doc = doc }
		end,
		step = function(s)
			s.doc.update(function(d)
				local x = table.remove(d.items, rng:NextInteger(1, #d.items))
				table.insert(d.items, rng:NextInteger(1, #d.items + 1), x)
			end)
			run(s.q)
			table.clear(s.q.out)
		end,
	},
	heard_change = {
		setup = function(data)
			local q, doc = opened(data, "big", Big, "open")
			return { q = q, doc = doc }
		end,
		step = function(s, data, k)
			s.q.receive(data.change[(k - 1) % #data.change + 1])
			run(s.q)
		end,
	},
	heard_move = {
		setup = function(data)
			local q, doc = opened(data, "big", Big, "open")
			return { q = q, doc = doc }
		end,
		step = function(s, data, k)
			s.q.receive(data.move[(k - 1) % #data.move + 1])
			run(s.q)
		end,
	},
	window = {
		setup = function()
			local q = peer()
			local states = 0
			local w = q.client:window({ scope = 1, list = "plain", table = Plain, size = 0, from = "start" }, function()
				states += 1
			end)
			run(q)
			return { q = q, w = w }
		end,
		step = function(s, data)
			s.q.receive(data.window[1])
			run(s.q)
			assert(#s.w.entries() == tonumber(data.rows[1]), "all of it is there")
		end,
	},
	-- Every row a window holds, read: what a list on screen shows.
	window_rows = {
		setup = function()
			local q = peer()
			local last: any = nil
			q.client:window({ scope = 1, list = "plain", table = Plain, size = 0, from = "start" }, function(state)
				last = state
			end)
			run(q)
			return { q = q, last = function()
				return last
			end }
		end,
		step = function(s, data)
			s.q.receive(data.window[1])
			run(s.q)
			assert(#s.last().rows == tonumber(data.rows[1]), "all of it is there")
		end,
	},
	notes_open = {
		setup = function()
			local q = peer()
			local doc = m.open(q.client, { scope = 1, name = "notes", schema = Notes })
			run(q)
			return { q = q, doc = doc }
		end,
		step = function(s, data)
			s.q.receive(data.notes[1])
			run(s.q)
			assert(#s.doc.state().items == tonumber(data.rows[1]), "all of it is there")
		end,
	},
	typing = {
		setup = function(data)
			local q, doc = opened(data, "notes", Notes, "notes")
			local editor = q.client:text(data.typing[1], zsp.text(17))
			run(q)
			return { q = q, doc = doc, editor = editor }
		end,
		step = function(s, _, k)
			s.editor.insert(0, string.char(96 + k % 26))
			run(s.q)
			table.clear(s.q.out)
		end,
	},
	live_heard = {
		setup = function(data)
			local q, doc = opened(data, "notes", Notes, "notes")
			return { q = q, doc = doc }
		end,
		step = function(s, data, k)
			s.q.receive(data.live[(k - 1) % #data.live + 1])
			run(s.q)
		end,
	},
	ask = {
		setup = function()
			return { q = peer() }
		end,
		step = function(s, data)
			local got: any = nil
			local asked = m.ask(s.q.client, { scope = 1, name = "big", schema = Big }, { "items" }, {
				where = zsp.where.under("n", 51),
				limit = 50,
			}, function(a)
				got = a
			end)
			run(s.q)
			answer(s.q, data)
			assert(got and #got.rows == #data.found[2] // 16, "the question is answered, with what the node found")
			asked.stop()
			run(s.q)
		end,
	},
}
local ORDER = { "make", "open", "set_change", "update_change", "set_move", "update_move", "heard_change", "heard_move", "window", "window_rows", "notes_open", "typing", "live_heard", "ask" }
local ONCE = { make = true, open = true, window = true, window_rows = true, notes_open = true }

local args = process.args
local N = tonumber(args[1] or "2000") :: number
if args[2] == "prep" then
	local data = prepare(N)
	data.rows = { tostring(N) }
	write_file(args[3], data)
	return
elseif args[2] then
	local data = read_file(args[3])
	local case = cases[args[2]]
	assert(case, "no such case")
	local count = tonumber(args[4] or "1") :: number
	local quiet = {}
	for _ = 1, math.ceil((tonumber(process.env.ZSP_QUIET) or 0) / 256) do
		table.insert(quiet, string.rep(string.char(#quiet % 256), 256 * 1048576))
	end
	local s = case.setup(data)
	-- Done some times first, not counted (ZSP_WARM), so that what is counted is a change as it is once the client has been
	-- going a while, and not what is let go of only once, after what led to it.
	local warm = tonumber(process.env.ZSP_WARM) or 0
	for k = 1, warm do
		case.step(s, data, k)
	end
	-- Only before changes: an opening is led to by almost nothing, and the churning would set the most the process has
	-- held, which is what opening is measured by too.
	if warm > 0 then
		-- Twice: the first round may have begun with much else to collect, made before; the second only with what was
		-- churned to wait for it, which tells when it has been swept.
		paused()
		paused()
	end
	local before = if args[5] == "memory" then settled() else 0
	-- Whether the collector finished a round while the case was done: a key held by nothing else is gone then.
	local probe = setmetatable({}, { __mode = "k" }) :: { [any]: boolean }
	probe[{}] = true
	counting(true)
	local made = collectgarbage("count")
	local t = os.clock()
	for k = 1, count do
		case.step(s, data, warm + k)
	end
	local took = os.clock() - t
	made = collectgarbage("count") - made
	counting(false)
	local after = if args[5] == "memory" then settled() else 0
	print(string.format("seconds %.6f heap_kb %d", took, after - before))
	if args[5] == "alloc" then
		print(string.format("alloc_kb %.1f collected %d", made, if next(probe) == nil then 1 else 0))
	end
	local _ = { s, quiet }
	return
end

-- Every case once, in one process: a quick look.
local data = prepare(N)
data.rows = { tostring(N) }
print(`{N} rows, each a map in one list; {TIMES} of each change`)
for _, name in ORDER do
	local case = cases[name]
	local count = if ONCE[name] then 1 else TIMES
	local s = case.setup(data)
	local before = settled()
	local t = os.clock()
	for k = 1, count do
		case.step(s, data, k)
	end
	local ms = (os.clock() - t) * 1000 / count
	local held = settled() - before
	print(string.format("  %-16s %10.2f ms %10d KB held after", name, ms, held))
	local _ = s
end
