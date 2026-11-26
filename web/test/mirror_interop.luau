--!strict
-- The Luau side of web/test/mirror_interop.ts: a client of its own, through a node made of nothing, with a document that
-- web/test/mirror_interop.ts writes into too. Told what to do a line at a time, it says what came of it a line at a time:
--   seed <n> | clock <seconds> | write | hear <hex> | state | quit
-- lune run web/test/mirror_interop.luau <path of luau/zsp from here>

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local base: string = process.args[1]
local codec = (require :: any)(base .. "/codec")
local sha256 = (require :: any)(base .. "/sha256")
local zsp = (require :: any)(base)
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
	p.receive(codec.string(framed))
	run(p)
end

-- ---------------------------------------------------------------- changes of every kind

-- Numbers as eight bytes and nothing else, as the TypeScript side reads them too: so that what is read of a value is
-- the same to both, and what is held to the same is the mirror.
local function number(slot: number): any
	return zsp.custom(slot, function(v: number): string
		return string.pack(">d", v)
	end, function(s: string): number
		assert(#s == 8, "a number is eight bytes")
		return (string.unpack(">d", s))
	end)
end

local Task = m.map({ title = zsp.string(16), done = zsp.boolean(17), notes = zsp.text(18), tags = m.list(19, zsp.string(16)) })
local Person = m.map({ role = zsp.string(16), bio = zsp.text(17), pets = m.list(18, m.map({ name = zsp.string(16) })) })
local Board = m.map({
	title = zsp.string(16),
	count = number(17),
	meta = m.map({ owner = zsp.string(16), size = number(17), more = m.map({ deep = zsp.boolean(16) }) }),
	tasks = m.list(18, Task),
	scores = m.record(number(16)),
	people = m.record(Person),
	outline = m.tree(19, m.map({ name = zsp.string(16), body = zsp.text(17), marks = m.list(18, number(16)) })),
	numbers = m.list(20, number(16)),
})

local words = { "alpha", "beta", "gamma", "delta", "eps", "zeta" }
local function word(): string
	return words[math.random(#words)]
end

local function mutate(d: any)
	for _ = 1, math.random(1, 5) do
		local r = math.random(16)
		if r == 1 then
			table.insert(d.tasks, math.random(1, #d.tasks + 1), { title = word(), done = math.random(2) == 1, tags = { word() } })
		elseif r == 2 and #d.tasks > 0 then
			table.remove(d.tasks, math.random(#d.tasks))
		elseif r == 3 and #d.tasks > 1 then
			local t = table.remove(d.tasks, math.random(#d.tasks))
			table.insert(d.tasks, math.random(1, #d.tasks + 1), t)
		elseif r == 4 and #d.tasks > 0 then
			local t = d.tasks[math.random(#d.tasks)]
			t.title = word()
			local n = t.notes or ""
			local at = math.random(0, #n)
			t.notes = string.sub(n, 1, at) .. word() .. string.sub(n, at + 1 + math.random(0, 2))
			table.insert(t.tags, math.random(1, #t.tags + 1), word())
			if #t.tags > 2 and math.random(2) == 1 then
				table.remove(t.tags, 1)
			end
		elseif r == 5 then
			d.scores[word()] = if math.random(3) == 1 then nil else math.random(100)
		elseif r == 6 then
			local k = word()
			if math.random(3) == 1 then
				d.people[k] = nil
			elseif d.people[k] then
				d.people[k].role = word()
				table.insert(d.people[k].pets, { name = word() })
				d.people[k].bio = (d.people[k].bio or "") .. word()
			else
				d.people[k] = { role = word(), bio = word(), pets = { { name = word() } } }
			end
		elseif r <= 9 then
			-- A node, new or moved, anywhere; or deleted, with all beneath it.
			local all = {}
			local function collect(level: any)
				for _, n in level do
					table.insert(all, n)
					collect(n.children or {})
				end
			end
			collect(d.outline)
			local function take(level: any, target: any): any
				for i, n in level do
					if n == target then
						return table.remove(level, i)
					end
					local found = take(n.children or {}, target)
					if found then
						return found
					end
				end
				return nil
			end
			if #all > 0 and r == 7 then
				local node = take(d.outline, all[math.random(#all)])
				local rest = {}
				collect = function(level: any)
					for _, n in level do
						table.insert(rest, n)
						collect(n.children or {})
					end
				end
				collect(d.outline)
				if #rest > 0 and math.random(3) > 1 then
					local into = rest[math.random(#rest)]
					into.children = into.children or {}
					table.insert(into.children, math.random(1, #into.children + 1), node)
				else
					table.insert(d.outline, math.random(1, #d.outline + 1), node)
				end
			elseif #all > 0 and r == 8 then
				take(d.outline, all[math.random(#all)])
			elseif #all > 0 and math.random(2) == 1 then
				local n = all[math.random(#all)]
				n.name = word()
				n.body = (n.body or "") .. word()
				table.insert(n.marks, math.random(100))
			else
				local into = if #all > 0 and math.random(2) == 1 then all[math.random(#all)].children else d.outline
				table.insert(into, math.random(1, #into + 1), { name = word(), children = {}, marks = { 1, 2 } })
			end
		elseif r == 10 then
			d.count = if math.random(4) == 1 then nil else math.random(1000)
			d.title = word()
		elseif r == 11 then
			d.meta.owner = word()
			d.meta.more.deep = math.random(2) == 1
		elseif r == 12 then
			table.insert(d.numbers, math.random(1, #d.numbers + 1), math.random(50))
		elseif r == 13 and #d.numbers > 0 then
			table.remove(d.numbers, math.random(#d.numbers))
		elseif r == 14 and #d.numbers > 1 then
			d.numbers[math.random(#d.numbers)] = math.random(50)
		elseif r == 15 and #d.tasks > 0 then
			d.tasks[math.random(#d.tasks)].tags = {}
		elseif r == 16 then
			-- A whole new list, some of it the old.
			local keep = {}
			for _, t in d.tasks do
				if math.random(2) == 1 then
					table.insert(keep, t)
				end
			end
			table.insert(keep, { title = word(), tags = {} })
			d.tasks = keep
		end
	end
end


-- ---------------------------------------------------------------- what is read, written down the same in either language

local HEX: { [string]: string } = {}
for b = 0, 255 do
	HEX[string.char(b)] = string.format("%02x", b)
end
local function hex(s: string): string
	return (string.gsub(s, ".", HEX))
end
local function unhex(h: string): string
	return (string.gsub(h, "..", function(two: string): string
		return string.char(tonumber(two, 16) :: number)
	end))
end

-- Strings and numbers as their bytes, maps by their keys' bytes, in order, and ids as hex. An empty string in a map is no
-- value, as it is to a mirror; and an empty list is "{}", as is an empty map.
local function canon(v: any): string
	local t = type(v)
	if t == "string" then
		return "s" .. hex(v)
	elseif t == "number" then
		return if v ~= v then "nnan" else "n" .. hex(string.pack(">d", v))
	elseif t == "boolean" then
		return if v then "t" else "f"
	elseif t ~= "table" then
		return "?" .. tostring(v)
	end
	if #v > 0 then
		local parts = {}
		for i, x in v do
			parts[i] = canon(x)
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local parts = {}
	for k, x in v do
		if x ~= "" then
			table.insert(parts, if k == "id" then "id=" .. hex(x) else hex(k) .. "=" .. canon(x))
		end
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

-- ---------------------------------------------------------------- held to it

local ZERO = string.rep("\0", 16)
local NOWHERE = string.rep("\0", 12)
local function derive(...: string): string
	return string.pack(">I4I4", 1, 0) .. string.sub(sha256(KEY .. "zsp-mirror\0board\0" .. table.concat({ ... }, "\0")), 1, 8)
end

local function latest(row: any, slot: number): any
	local best = nil
	for _, c in row.slots[slot] or {} do
		if c.kind == 3 and (not best or c.stamp > best.stamp) then
			best = c
		end
	end
	return best
end

-- An empty string is no value, and no text is an empty one.
local function equal(a: any, b: any, ids: boolean?): boolean
	if a == "" then
		a = nil
	end
	if b == "" then
		b = nil
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b or (a ~= a and b ~= b)
	end
	for k, v in a do
		if (ids ~= false or k ~= "id") and not equal(v, b[k], ids) then
			return false
		end
	end
	for k, v in b do
		if (ids ~= false or k ~= "id") and not equal(a[k], v, ids) then
			return false
		end
	end
	return true
end

-- A copy as plain tables, as a draft is once it is done with.
local function plain(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = plain(x)
	end
	return out
end

-- Every row's word on where it is, as docs/mirror.md lays it out, from whichever writer: what is wrong, or nil.
local function misplaced(client: any): string?
	local function id(s: string): boolean
		return s == ZERO or string.sub(s, 1, 4) == "\0\0\0\1"
	end
	local function marker(s: string): boolean
		return #s == 12 and (string.unpack(">I4", s, 9) :: number) < 2 ^ 20
	end
	for row, stored in client.rows do
		local c = if stored.dead then nil else latest(stored, 255)
		if c then
			local r = codec.reader(c.body)
			local owner, field, kind = codec.take(r, 16), codec.bytes(r), codec.u8(r)
			local rest = codec.rest(r)
			local fine
			if kind == 0 then
				fine = rest == "" and (if owner == ZERO then field == "" and row == derive("") else row == derive(owner, field))
			elseif kind == 1 then
				fine = marker(rest)
			elseif kind == 2 then
				fine = #rest >= 1 and string.byte(rest) <= 1 and row == derive(owner, field, string.sub(rest, 2))
			elseif kind == 3 then
				local parent, at, from, back = string.sub(rest, 1, 16), string.sub(rest, 17, 28), string.sub(rest, 29, 44), string.sub(rest, 45, 56)
				fine = #rest == 56 and id(parent) and marker(at) and id(from) and (back == NOWHERE or marker(back))
			end
			if not fine or not id(owner) then
				return `row {hex(row)}: kind {kind}, {hex(c.body)}`
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------- told what to do

local p: Peer = peer()
local doc: any = nil
local function say(line: string)
	stdio.write(line .. "\n")
end
while true do
	local line = stdio.readLine()
	if line == nil then
		break
	end
	local op, arg = string.match((string.gsub(line, "%s+$", "")), "^(%S+)%s*(.*)$")
	if op == "seed" then
		math.randomseed(tonumber(arg) :: number)
		p = peer()
		doc = m.open(p.client, { scope = 1, name = "board", schema = Board })
		run(p)
		say("ok")
	elseif op == "clock" then
		clock = tonumber(arg) :: number
		say("ok")
	elseif op == "write" then
		local before = #p.out
		local draft: any = nil
		doc.update(function(d)
			mutate(d)
			draft = plain(d)
		end)
		run(p)
		local out = {}
		for k = before + 1, #p.out do
			table.insert(out, hex(p.out[k]))
		end
		-- What was set is what is read.
		say(if equal(doc.state(), draft, false) then "cells " .. table.concat(out, " ") else "unlike " .. canon(draft))
	elseif op == "hear" then
		hear(p, unhex(arg))
		say("ok")
	elseif op == "state" then
		say(canon(doc.state()))
	elseif op == "check" then
		say(misplaced(p.client) or "ok")
	else
		break
	end
end
process.exit(0)
