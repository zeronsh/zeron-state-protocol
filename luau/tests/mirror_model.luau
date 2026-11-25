--!strict
-- Structured state, held to what it should be: clients that hear each other's writing in any order and any number of
-- times, each of whose documents is at every step what a reading of its rows from nothing says it is; that come to the
-- same; and in which each change reads back as what was set. lune run luau/tests/mirror_model.luau

local codec = require("../zsp/codec")
local sha256 = require("../zsp/sha256")
local text = require("../zsp/text")
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

-- ---------------------------------------------------------------- what a document should be, from nothing

local ZERO = string.rep("\0", 16)

local document = "board"
local function derive(...: string): string
	return string.pack(">I4I4", 1, 0) .. string.sub(sha256(KEY .. "zsp-mirror\0" .. document .. "\0" .. table.concat({ ... }, "\0")), 1, 8)
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

-- Every row's word on what it is in, read plainly.
local function wheres(client: any): { [string]: any }
	local out = {}
	for id, row in client.rows do
		if not row.dead then
			local c = latest(row, 255)
			if c then
				local ok, w = pcall(function()
					local r = codec.reader(c.body)
					local w: any = { owner = codec.take(r, 16), field = codec.bytes(r), kind = codec.u8(r), stamp = c.stamp }
					local rest = codec.rest(r)
					if w.kind == 1 then
						w.marker = rest
					elseif w.kind == 2 then
						w.present, w.key = string.byte(rest) ~= 0, string.sub(rest, 2)
					elseif w.kind == 3 then
						w.parent, w.marker, w.from, w.back = string.sub(rest, 1, 16), string.sub(rest, 17, 28), string.sub(rest, 29, 44), string.sub(rest, 45, 56)
					end
					return w
				end)
				if ok then
					out[id] = w
				end
			end
		end
	end
	return out
end

local function model(client: any, schema: any): any
	local ws = wheres(client)
	local function row(id: string): any
		local r = client.rows[id]
		return if r and not r.dead then r else nil
	end
	local function value(c: any, r: any): any
		if c.text then
			local t = r.texts[c.slot]
			if not t then
				t = text.new()
				local cells = {}
				for _, cell in r.slots[c.slot] or {} do
					table.insert(cells, cell)
				end
				table.sort(cells, function(a, b)
					return a.stamp < b.stamp
				end)
				for _, cell in cells do
					text.apply(t, cell.kind, cell.stamp, cell.body)
				end
			end
			return text.read(t)
		end
		local cell = latest(r, c.slot)
		if not cell or cell.body == "" then
			return nil
		end
		local ok, v = pcall(c.decode, cell.body) -- what does not read as one of its kind is nothing
		return if ok then v else nil
	end
	local function seq(id: string, slot: number): text.Text?
		local r = row(id)
		return if r then client:held_text(id, slot) else nil
	end
	local map: (s: any, id: string) -> any
	local standing = { [derive("")] = true } -- there for everyone, come or not
	local function box(b: any, owner: string, field: string): any
		if b.kind == "map" then
			standing[derive(owner, field)] = true
			return map(b, derive(owner, field))
		end
		if not row(owner) and not standing[owner] then
			return if b.kind == "record" then {} else {}
		end
		if b.kind == "list" and not b.of.kind then
			local t = seq(owner, b.slot)
			local out = {}
			if t then
				local bytes = text.read(t)
				local at = 1
				while at <= #bytes do
					local r = codec.reader(string.sub(bytes, at))
					local ok, n = pcall(codec.varint, r)
					if not ok or at + r.pos + n - 1 > #bytes then
						break
					end
					local fine, v = pcall(b.of.decode, string.sub(bytes, at + r.pos, at + r.pos + n - 1))
					if fine and v ~= nil then
						table.insert(out, v)
					end
					at += r.pos + n
				end
			end
			return out
		elseif b.kind == "list" then
			local t = seq(owner, b.slot)
			local order = if t then text.order(t) else {}
			local items = {}
			for id, w in ws do
				if w.owner == owner and w.field == field and w.kind == 1 and order[w.marker] then
					table.insert(items, { id = id, at = order[w.marker] })
				end
			end
			table.sort(items, function(x, y)
				return x.at < y.at or (x.at == y.at and x.id < y.id)
			end)
			local out = {}
			for i, it in items do
				out[i] = map(b.of, it.id)
			end
			return out
		elseif b.kind == "record" then
			local out = {}
			for id, w in ws do
				if w.owner == owner and w.field == field and w.kind == 2 and w.present and id == derive(owner, field, w.key) then
					if b.of.kind then
						out[w.key] = map(b.of, id)
					else
						local v = value(b.of, row(id))
						if v ~= nil then
							out[w.key] = v
						end
					end
				end
			end
			return out
		else
			-- Undo, one at a time, the latest move of each loop, until there is none.
			local nodes, parent, marker = {}, {}, {}
			for id, w in ws do
				if w.owner == owner and w.field == field and w.kind == 3 and #w.back == 12 then
					nodes[id] = w
					parent[id] = w.parent
					marker[id] = w.marker
				end
			end
			local undone = {}
			local function loop(): { string }?
				local ids = {}
				for id in nodes do
					table.insert(ids, id)
				end
				table.sort(ids)
				for _, start in ids do
					local seen, path = {}, {}
					local at = start
					while at ~= ZERO and nodes[at] and not seen[at] do
						seen[at] = #path + 1
						table.insert(path, at)
						at = parent[at]
					end
					if at ~= ZERO and nodes[at] and seen[at] then
						return { table.unpack(path, seen[at]) }
					end
				end
				return nil
			end
			while true do
				local l = loop()
				if not l then
					break
				end
				local last = l[1]
				for _, id in l do
					if nodes[id].stamp > nodes[last].stamp then
						last = id
					end
				end
				parent[last] = if undone[last] then ZERO else nodes[last].from
				marker[last] = if undone[last] then "" else nodes[last].back
				undone[last] = true
			end
			local function reaches(id: string): boolean
				local n = 0
				while id ~= ZERO do
					if not nodes[id] or n > 10000 then
						return false
					end
					id = parent[id]
					n += 1
				end
				return true
			end
			local function level(under: string): any
				local t = seq(if under == ZERO then owner else under, b.slot)
				local order = if t then text.order(t) else {}
				local items = {}
				for id in nodes do
					local at = order[marker[id]] or (if marker[id] == "" then math.huge else nil)
					if parent[id] == under and reaches(id) and at then
						table.insert(items, { id = id, at = at })
					end
				end
				table.sort(items, function(x, y)
					return x.at < y.at or (x.at == y.at and x.id < y.id)
				end)
				local out = {}
				for i, it in items do
					local node = table.clone(map(b.of, it.id))
					node.children = level(it.id)
					out[i] = node
				end
				return out
			end
			return level(ZERO)
		end
	end
	map = function(s: any, id: string): any
		local r = row(id)
		local out: any = { id = id }
		for name, c in s.columns do
			if r then
				out[name] = value(c, r)
			end
		end
		for name, b in s.boxes do
			out[name] = box(b, id, name)
		end
		return out
	end
	return map(schema, derive(""))
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
		return a == b
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

-- Where two differ first.
local function where_differ(a: any, b: any, path: string): string?
	if equal(a, b) then
		return nil
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return `{path}: {tostring(a)} / {tostring(b)}`
	end
	for k, v in a do
		local d = where_differ(v, b[k], `{path}.{tostring(k)}`)
		if d then
			return d
		end
	end
	for k, v in b do
		local d = where_differ(a[k], v, `{path}.{tostring(k)}`)
		if d then
			return d
		end
	end
	return path
end

local function show(v: any): string
	if type(v) ~= "table" then
		return tostring(v)
	end
	local parts = {}
	for k, x in v do
		if k ~= "id" then
			table.insert(parts, `{tostring(k)}={show(x)}`)
		end
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ", ") .. "}"
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

-- ---------------------------------------------------------------- changes of every kind

local Task = m.map({ title = zsp.string(16), done = zsp.boolean(17), notes = zsp.text(18), tags = m.list(19, zsp.string(16)) })
local Person = m.map({ role = zsp.string(16), bio = zsp.text(17), pets = m.list(18, m.map({ name = zsp.string(16) })) })
local Board = m.map({
	title = zsp.string(16),
	count = zsp.number(17),
	meta = m.map({ owner = zsp.string(16), size = zsp.number(17), more = m.map({ deep = zsp.boolean(16) }) }),
	tasks = m.list(18, Task),
	scores = m.record(zsp.number(16)),
	people = m.record(Person),
	outline = m.tree(19, m.map({ name = zsp.string(16), body = zsp.text(17), marks = m.list(18, zsp.number(16)) })),
	numbers = m.list(20, zsp.number(16)),
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

-- ---------------------------------------------------------------- someone who minds nothing

-- Cells as a writer who may write there could send them, saying anything at all: rows that claim to be in any part of the
-- document, records with keys that are not theirs, values of any length in any slot, markers that are no one's, and
-- pieces of order that refer to what they like.
local hostile_clock = 0
local function hostile(client: any): string
	local fields = { "tasks", "scores", "people", "outline", "numbers", "meta", "pets", "marks", "tags", "x" }
	local ids, markers = {}, {}
	for id, row in client.rows do
		if not row.dead then
			table.insert(ids, id)
			local c = latest(row, 255)
			if c and #c.body >= 28 then
				table.insert(markers, string.sub(c.body, -12))
			end
		end
	end
	local function any_id(): string
		if math.random(3) == 1 then
			return derive("") -- most of what there is hangs from the top
		end
		if #ids > 0 and math.random(4) > 1 then
			return ids[math.random(#ids)]
		end
		return string.pack(">I4I4", 1, math.random(0, 3)) .. string.rep(string.char(math.random(0, 255)), 8)
	end
	local function any_marker(): string
		if #markers > 0 and math.random(3) > 1 then
			return markers[math.random(#markers)]
		end
		return string.rep(string.char(math.random(0, 255)), 12)
	end
	hostile_clock += 1
	local w = codec.writer()
	for _ = 1, math.random(1, 4) do
		local stamp = string.pack(">I4I2I2", math.floor(clock * 1000) // 65536, math.floor(clock * 1000) % 65536, hostile_clock % 65536) .. string.rep(string.char(math.random(0, 255)), 8)
		local r = math.random(5)
		local row, slot, kind, body
		if r <= 2 then
			-- A row anywhere, saying it is in anything.
			row = string.pack(">I4I4", 1, math.floor(clock)) .. string.rep(string.char(math.random(0, 255)), 8)
			codec.put_u8(w, 2)
			codec.put(w, row)
			codec.put_u8(w, 1)
			codec.put(w, stamp)
			codec.put_bytes(w, client:_tag(1, "mirror/" .. document) .. string.rep("\0", 8))
			slot, kind = 255, 3
			local where = codec.writer()
			codec.put(where, any_id())
			codec.put_bytes(where, if math.random(2) == 1 then ({ "scores", "people", "tasks", "outline" })[math.random(4)] else fields[math.random(#fields)])
			local k = math.random(0, 4)
			codec.put_u8(where, k)
			if k == 1 then
				codec.put(where, any_marker())
			elseif k == 2 then
				codec.put(where, string.char(math.random(0, 1)) .. words[math.random(#words)])
			elseif k == 3 then
				codec.put(where, any_id() .. any_marker() .. any_id() .. any_marker())
			else
				codec.put(where, string.rep("?", math.random(0, 3)))
			end
			body = codec.string(where)
		elseif r == 3 then
			-- A value of any length in any slot of what there is.
			row, slot, kind = any_id(), if math.random(3) > 1 then math.random(16, 20) else math.random(16, 255), 3
			body = string.rep(string.char(math.random(0, 255)), math.random(0, 9))
		else
			-- A piece of order, of any order.
			row, slot, kind = any_id(), ({ 18, 19, 20 })[math.random(3)], 4
			local p = codec.writer()
			codec.put(p, string.rep(string.char(math.random(1, 255)), 8))
			codec.put_u8(p, 1)
			for _ = 1, 2 do
				if math.random(3) == 1 then
					codec.put_u8(p, 0)
				else
					codec.put_u8(p, 2)
					local m = any_marker()
					codec.put(p, string.sub(m, 1, 8))
					codec.put_varint(p, (string.unpack(">I4", m, 9) :: any) % 4)
				end
			end
			codec.put_bytes(p, string.rep("\0", math.random(1, 3)))
			body = codec.string(p)
		end
		codec.put_u8(w, kind)
		codec.put(w, row)
		codec.put_u8(w, slot)
		codec.put(w, stamp)
		codec.put_bytes(w, body)
	end
	return codec.string(w)
end

-- ---------------------------------------------------------------- held to it

local failures = 0
local SEEDS = tonumber(require("@lune/process").args[1] or "") or 60
-- And with every shortcut off, held to the same.
if require("@lune/process").args[2] == "plain" then
	m._plain(true)
end
for seed = 1, SEEDS do
	math.randomseed(seed)
	local n = 2 + seed % 2
	local peers, docs, others = {}, {}, {}
	for i = 1, n do
		peers[i] = peer()
		docs[i] = m.open(peers[i].client, { scope = 1, name = "board", schema = Board })
		others[i] = m.open(peers[i].client, { scope = 1, name = "another", schema = Board })
	end
	local log: { string } = {} -- every write, in the order written
	local heard: { [number]: { [number]: boolean } } = {}
	for i = 1, n do
		heard[i] = {}
	end
	local function check(i: number, what: string)
		local want = model(peers[i].client, Board)
		if not equal(docs[i].state(), want) then
			failures += 1
			local function ids(list: any): string
				local out = {}
				for _, t in list do
					table.insert(out, string.format("%02x%02x:", string.byte(t.id, 15, 16)) .. tostring(t.title))
				end
				return table.concat(out, " ")
			end
			error(`seed {seed}, client {i}, {what}: {where_differ(docs[i].state(), want, "")}\n  mirror {ids(docs[i].state().tasks)}\n  model  {ids(want.tasks)}`)
		end
	end
	for step = 1, 30 do
		clock += math.random() * 3
		-- Some write; each change reads back as what was set.
		for i = 1, n do
			if math.random(3) > 1 then
				local before = #peers[i].out
				if math.random(3) == 1 then
					-- Another document, of the same shape, in the same scope: nothing of it is in this one.
					others[i].update(mutate)
					run(peers[i])
				end
				local draft: any = nil
				docs[i].update(function(d)
					mutate(d)
					draft = plain(d)
				end)
				run(peers[i])
				if not equal(docs[i].state(), draft, false) then
					failures += 1
					local function strip(v: any): any
						if type(v) ~= "table" then
							return v
						end
						local out = {}
						for k, x in v do
							if k ~= "id" then
								out[k] = strip(x)
							end
						end
						return out
					end
					print("differ", where_differ(strip(draft), strip(docs[i].state()), ""))
										error(`seed {seed} step {step}, client {i}: what was set is not what is read\n  set  {show(draft)}\n  read {show(docs[i].state())}`)
				end
				check(i, `step {step}, after writing`)
				for k = before + 1, #peers[i].out do
					table.insert(log, peers[i].out[k])
				end
			end
		end
		if seed % 3 == 0 and math.random(3) == 1 then
			table.insert(log, hostile(peers[1].client))
		end
		-- Some of what was written reaches some, in any order, some of it twice.
		for i = 1, n do
			for _ = 1, math.random(0, 4) do
				if #log > 0 then
					local k = math.random(#log)
					hear(peers[i], log[k])
					heard[i][k] = true
					check(i, `step {step}, after hearing`)
				end
			end
		end
	end
	-- Then all of it, everywhere: one document.
	for i = 1, n do
		local order = {}
		for k = 1, #log do
			table.insert(order, k)
		end
		for j = #order, 2, -1 do
			local k = math.random(j)
			order[j], order[k] = order[k], order[j]
		end
		for _, k in order do
			hear(peers[i], log[k])
		end
		check(i, "at the end")
	end
	-- Each writes once more, which lets go of what nothing shows; and once that is everywhere, nothing is kept that is not
	-- shown, but keys that were let go of, which hold nothing.
	if seed % 3 ~= 0 then
		local before = {}
		for i = 1, n do
			before[i] = #peers[i].out
			docs[i].update(function() end)
			run(peers[i])
		end
		for i = 1, n do
			for k = before[i] + 1, #peers[i].out do
				for j = 1, n do
					hear(peers[j], peers[i].out[k])
				end
			end
		end
		for i = 1, n do
			check(i, "after letting go")
			local shown = {}
			local function walk(v: any)
				if type(v) == "table" then
					if type(v.id) == "string" then
						shown[v.id] = v
					end
					for _, x in v do
						walk(x)
					end
				end
			end
			walk(docs[i].state())
			local tag = peers[i].client:_tag(1, "mirror/" .. document)
			for id, w in wheres(peers[i].client) do
				local row = peers[i].client.rows[id]
				local here = false
				for _, c in row.slots[1] or {} do
					here = here or string.sub(c.body, 1, 16) == tag
				end
				local empty = true -- a key that holds nothing, however it came to: as a deleted one is
				for slot, cells in row.slots do
					if slot >= 16 and slot < 255 then
						local c = latest(row, slot)
						empty = empty and (c == nil or c.body == "")
					end
				end
				local held = w.kind == 2 and shown[w.owner] and type(shown[w.owner][w.field]) == "table" and shown[w.owner][w.field][w.key] ~= nil
				local fine = not here or shown[id] or held or (w.kind == 2 and (not w.present or empty)) or w.kind == 0
				if not fine then
					failures += 1
																				error(`seed {seed}, client {i}: a row is kept that nothing shows (kind {w.kind})`)
				end
			end
		end
	end
	for i = 2, n do
		if not equal(docs[i].state(), docs[1].state()) then
			failures += 1
			error(`seed {seed}: clients 1 and {i} differ: {where_differ(docs[1].state(), docs[i].state(), "")}`)
		end
	end
	-- No loops, no node twice.
	local seen = {}
	local function walk(level: any)
		for _, node in level do
			assert(not seen[node.id], "a node twice")
			seen[node.id] = true
			walk(node.children)
		end
	end
	walk(docs[1].state().outline)
end
print(if failures == 0 then "ok" else `{failures} failed`)
