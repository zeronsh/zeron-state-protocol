--!strict
-- What structured state costs on a client, without a network: lune run luau/tests/mirror_bench.luau [rows]

local codec = require("../zsp/codec")
local zsp = require("../zsp")
local m = zsp.mirror

local CELLS, ROSTER = 7, 2
local KEY = string.rep("k", 32)

-- ---------------------------------------------------------------- clients that hear only each other

type Peer = { client: any, receive: (any) -> (), deferred: { () -> () }, out: { string } }

local clock = 1800000000
local function peer(): Peer
	local self: Peer = { client = nil, receive = function() end, deferred = {}, out = {} }
	self.client = zsp.connect({
		credential = "x",
		now = function(): number
			return clock
		end,
		random = function(n: number): string
			-- As cheap as a host's own would be, so that what is measured is the client.
			if n == 8 then
				return string.pack("<I4I4", math.random(0, 0x7FFFFFFF) * 2 + math.random(0, 1), math.random(0, 0x7FFFFFFF) * 2 + math.random(0, 1))
			end
			local b = {}
			for i = 1, n do
				b[i] = string.char(math.random(0, 255))
			end
			return table.concat(b)
		end,
		defer = function(f: () -> ())
			table.insert(self.deferred, f)
		end,
		after = function(_: number, _f: () -> ())
			return function() end
		end,
		connect = function(receive: any, _closed: any)
			self.receive = receive
			return {
				send = function(data: buffer)
					local r = codec.reader(data)
					while r.pos < r.len do
						local body = codec.bytes(r)
						if string.byte(body) == CELLS then
							-- What it writes, as another would be sent it.
							local f = codec.reader(string.sub(body, 2))
							codec.varint(f)
							table.insert(self.out, codec.rest(f))
						end
					end
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

local function run(p: Peer)
	while #p.deferred > 0 do
		(table.remove(p.deferred, 1) :: any)()
	end
end

-- As a node would send it: whole rows, of what it holds; and nothing of a row it holds deleted, but a later deletion.
local received = 0 -- of the time hearing takes, what is the client's own
type Held = { rows: { [string]: { [string]: string } }, dead: { [string]: string } }
local nodes: { [Peer]: Held } = setmetatable({}, { __mode = "k" }) :: any
local function hear(p: Peer, cells: string)
	local node = nodes[p] or { rows = {}, dead = {} }
	nodes[p] = node
	local touched: { [string]: boolean } = {}
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
		if kind == 1 then
			if not node.dead[id] or stamp > node.dead[id] then
				node.dead[id] = stamp
				node.rows[id] = { grave = codec.string(w) }
				touched[id] = true
			end
		elseif not node.dead[id] then
			node.rows[id] = node.rows[id] or {}
			node.rows[id][string.char(slot, kind) .. stamp] = codec.string(w)
			touched[id] = true
		end
	end
	-- Only what is in the list, as a watch of it is sent: a row with no place yet is nowhere until it has one.
	local out = {}
	for t in touched do
		local placed = node.rows[t].grave ~= nil
		for k in node.rows[t] do
			placed = placed or string.byte(k, 2) == 2
		end
		if placed then
			for _, c in node.rows[t] do
				table.insert(out, c)
			end
		end
	end
	cells = table.concat(out)
	local w = codec.writer()
	codec.put_u8(w, CELLS)
	codec.put_varint(w, 0)
	codec.put(w, cells)
	local framed = codec.writer()
	codec.put_bytes(framed, codec.string(w))
	local t = os.clock()
	p.receive(codec.string(framed))
	run(p)
	received += os.clock() - t
end

-- ---------------------------------------------------------------- measured

local p = peer()
local Big = m.map({ items = m.list(18, m.map({ n = zsp.number(16), label = zsp.string(17) })) })
local doc = m.open(p.client, { scope = 1, name = "big", schema = Big })
local N = tonumber(require("@lune/process").args[1] or "2000") :: number
local items = {}
for i = 1, N do
	items[i] = { n = i, label = `item {i}` }
end
local function each(what: string, times: number, f: () -> ())
	local t = os.clock()
	for _ = 1, times do
		f()
		run(p)
	end
	print(string.format("  %-58s %8.2f ms", what, (os.clock() - t) * 1000 / times))
end
print(`{N} rows, each a map in one list`)
each("made, all at once", 1, function()
	doc.set({ items = items })
end)
do
	local q = peer()
	local other = m.open(q.client, { scope = 1, name = "big", schema = Big })
	run(q)
	local sent = table.concat(p.out)
	received = 0
	hear(q, sent)
	print(string.format("  %-58s %8.2f ms", "opened by another, from what a node sends", received * 1000))
	assert(#other.state().items == N, "the other has it all")
	other.stop()
end
each("one changed, by set, sharing what did not change", 50, function()
	local now = doc.state()
	local list = table.clone(now.items)
	local i = math.random(#list)
	local item = table.clone(list[i])
	item.n += 1
	list[i] = item
	local nxt = table.clone(now)
	nxt.items = list
	doc.set(nxt)
end)
each("one changed, by update", 50, function()
	doc.update(function(d)
		d.items[math.random(#d.items)].n += 1
	end)
end)
each("one moved, by set", 50, function()
	local now = doc.state()
	local list = table.clone(now.items)
	local x = table.remove(list, math.random(#list))
	table.insert(list, math.random(#list + 1), x)
	local nxt = table.clone(now)
	nxt.items = list
	doc.set(nxt)
end)
each("one moved, by update", 50, function()
	doc.update(function(d)
		local x = table.remove(d.items, math.random(#d.items))
		table.insert(d.items, math.random(#d.items + 1), x)
	end)
end)
