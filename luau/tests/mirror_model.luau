--!strict
-- Structured state, held to what it should be: clients that hear each other's writing in any order and any number of
-- times, each of whose documents is at every step what a reading of its rows from nothing says it is; that come to the
-- same; and in which each change reads back as what was set. lune run luau/tests/mirror_model.luau

local codec = require("../zsp/codec")
local sha256 = require("../zsp/sha256")
local text = require("../zsp/text")
local zsp = require("../zsp")
local m = zsp.mirror

local CELLS, ROSTER, ASK, UNASK, ANSWER, FETCH = 7, 2, 32, 33, 34, 35
local KEY = string.rep("k", 32)

-- ---------------------------------------------------------------- clients that hear only each other

type Peer = {
	client: any,
	receive: (any) -> (),
	deferred: { () -> () },
	out: { string },
	asked: { [number]: any },
	said: { [number]: string },
	entered: { [string]: boolean }, -- rows its own writing put in the list, which the node then sends whole
}
local store: (Peer, string) -> { [string]: boolean }
local parse_question: (string) -> any

local clock = 1800000000
local function peer(): Peer
	local self: Peer = { client = nil, receive = function() end, deferred = {}, out = {}, asked = {}, said = {}, entered = {} }
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
						local kind = string.byte(body)
						if kind == CELLS then
							-- What it writes, as another would be sent it; and its own node has it.
							local f = codec.reader(string.sub(body, 2))
							codec.varint(f)
							local cells = codec.rest(f)
							table.insert(self.out, cells)
							for id in store(self, cells) do
								self.entered[id] = true
							end
						elseif kind == ASK or kind == FETCH then
							local f = codec.reader(string.sub(body, 2))
							local id = codec.varint(f)
							self.asked[id] = parse_question(codec.rest(f))
							self.said[id] = nil
						elseif kind == UNASK then
							local f = codec.reader(string.sub(body, 2))
							local id = codec.varint(f)
							self.asked[id] = nil
							self.said[id] = nil
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

local answer: (Peer) -> boolean
local enter: (Peer) -> boolean
-- What the client itself defers, and nothing a node sends back.
local function drain(p: Peer)
	while #p.deferred > 0 do
		(table.remove(p.deferred, 1) :: any)()
	end
end
local function run(p: Peer)
	repeat
		while #p.deferred > 0 do
			(table.remove(p.deferred, 1) :: any)()
		end
	until not enter(p) and not answer(p)
end

-- As a node would send it: whole rows, of what it holds; and nothing of a row it holds deleted, but a later deletion.
type Held = { rows: { [string]: { [string]: string } }, dead: { [string]: string } }
local nodes: { [Peer]: Held } = setmetatable({}, { __mode = "k" }) :: any
store = function(p: Peer, cells: string): { [string]: boolean }
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
	return touched
end

-- Whole rows, as a node sends them, of those it holds that have a place.
local function rows_of(node: Held, ids: { [string]: boolean }): string
	local out = {}
	for t in ids do
		local row = node.rows[t]
		if row then
			local placed = row.grave ~= nil
			for k in row do
				placed = placed or string.byte(k, 2) == 2
			end
			if placed then
				for _, c in row do
					table.insert(out, c)
				end
			end
		end
	end
	return table.concat(out)
end

local function send_cells(p: Peer, cells: string)
	local w = codec.writer()
	codec.put_u8(w, CELLS)
	codec.put_varint(w, 0)
	codec.put(w, cells)
	local framed = codec.writer()
	codec.put_bytes(framed, codec.string(w))
	p.receive(codec.string(framed))
end

-- A row the client's own writing gives a place, or keeps in one, is sent whole, as a node sends what comes into what is
-- watched: with what others wrote in it that was nowhere until then.
enter = function(p: Peer): boolean
	if next(p.entered) == nil then
		return false
	end
	local ids = p.entered
	p.entered = {}
	send_cells(p, rows_of(nodes[p], ids))
	return true
end

local function hear(p: Peer, cells: string)
	local touched = store(p, cells)
	local node = nodes[p]
	-- Only what is in the list, as a watch of it is sent: a row with no place yet is nowhere until it has one.
	send_cells(p, rows_of(node, touched))
	run(p)
end

-- ---------------------------------------------------------------- a node that answers questions (SPEC 15), of what it holds

parse_question = function(body: string): any
	local r = codec.reader(body)
	local function column(): any
		local kind = codec.u8(r)
		if kind == 7 or kind == 8 then
			return { kind = kind }
		elseif kind == 9 then
			return { kind = kind, list = codec.take(r, 16) }
		elseif kind == 10 then
			return { kind = kind, slot = codec.u8(r) }
		end
		return { kind = kind, slot = codec.u8(r), path = codec.bytes(r) }
	end
	local function condition(): any
		local op = codec.u8(r)
		if op == 0 then
			return { op = 0 }
		elseif op == 1 or op == 2 then
			local of = {}
			for i = 1, codec.varint(r) do
				of[i] = condition()
			end
			return { op = op, of = of }
		elseif op == 3 then
			return { op = 3, of = condition() }
		elseif op == 4 then
			local c = column()
			local flags = codec.u8(r)
			local lo = if bit32.btest(flags, 1) then codec.bytes(r) else nil
			local hi = if bit32.btest(flags, 2) then codec.bytes(r) else nil
			return { op = 4, column = c, flags = flags, lo = lo, hi = hi }
		elseif op == 5 then
			local c = column()
			local set = {}
			for i = 1, codec.varint(r) do
				set[i] = codec.bytes(r)
			end
			return { op = 5, column = c, set = set }
		elseif op == 6 or op == 7 then
			return { op = op, column = column(), bytes = codec.bytes(r) }
		elseif op == 8 then
			return { op = 8, column = column() }
		elseif op == 9 then
			return { op = 9, list = codec.take(r, 16) }
		elseif op == 11 then
			local ids = {}
			for _ = 1, codec.varint(r) do
				ids[codec.take(r, 16)] = true
			end
			return { op = 11, ids = ids }
		end
		error(`the harness's node does not know condition {op}`)
	end
	local q: any = { scope = codec.varint(r) }
	q.where = condition()
	q.order = {}
	for i = 1, codec.varint(r) do
		local how = codec.u8(r)
		local desc = codec.u8(r) == 1
		q.order[i] = { how = how, desc = desc, column = if how == 0 then column() else nil }
	end
	q.from_end = codec.u8(r) == 1
	q.offset = codec.varint(r)
	q.limit = math.min(codec.varint(r), 1000)
	assert(codec.varint(r) == 0, "the harness's node gives no totals")
	return q
end

-- A row's cells, read from how the node keeps them.
local function cells_of(row: { [string]: string }): { { kind: number, slot: number, stamp: string, body: string } }
	local out = {}
	for _, c in row do
		local r = codec.reader(c)
		local kind = codec.u8(r)
		codec.take(r, 16)
		local slot = codec.u8(r)
		local stamp = codec.take(r, 16)
		table.insert(out, { kind = kind, slot = slot, stamp = stamp, body = codec.bytes(r) })
	end
	return out
end

local function fold(s: string): string
	return string.lower(s)
end

-- A column's value in a row, as the kind says it is compared; nil if it has none.
local function value_of(cells: any, id: string, c: any): any
	if c.kind == 7 or c.kind == 8 then
		return nil -- not asked here
	end
	local best = nil
	for _, cell in cells do
		if cell.kind == 3 and cell.slot == c.slot and (not best or cell.stamp > best.stamp) then
			best = cell
		end
	end
	if not best or best.body == "" then
		return nil
	end
	local body = best.body
	if c.kind == 1 then
		return body
	elseif c.kind == 2 then
		return fold(body)
	elseif c.kind == 3 then
		return if #body == 8 then string.unpack(">d", body) else nil
	elseif c.kind == 4 then
		return if #body == 1 then string.byte(body) else nil
	elseif c.kind == 5 then
		return if #body >= 16 then string.sub(body, 1, 16) else nil
	end
	return nil
end

local function bound(c: any, b: string): any
	if c.kind == 2 then
		return fold(b)
	elseif c.kind == 3 then
		return (string.unpack(">d", b))
	elseif c.kind == 4 then
		return string.byte(b)
	end
	return b
end

local function holds(q: any, cond: any, id: string, cells: any): boolean
	local op = cond.op
	if op == 0 then
		return true
	elseif op == 1 then
		for _, x in cond.of do
			if not holds(q, x, id, cells) then
				return false
			end
		end
		return true
	elseif op == 2 then
		for _, x in cond.of do
			if holds(q, x, id, cells) then
				return true
			end
		end
		return false
	elseif op == 3 then
		return not holds(q, cond.of, id, cells)
	elseif op == 4 then
		local v = value_of(cells, id, cond.column)
		if v == nil then
			return false
		end
		if cond.lo then
			local lo = bound(cond.column, cond.lo)
			if v < lo or (v == lo and not bit32.btest(cond.flags, 4)) then
				return false
			end
		end
		if cond.hi then
			local hi = bound(cond.column, cond.hi)
			if v > hi or (v == hi and not bit32.btest(cond.flags, 8)) then
				return false
			end
		end
		return true
	elseif op == 5 then
		local v = value_of(cells, id, cond.column)
		for _, b in cond.set do
			if v ~= nil and v == bound(cond.column, b) then
				return true
			end
		end
		return false
	elseif op == 6 or op == 7 then
		local v = value_of(cells, id, cond.column)
		local b = if cond.column.kind == 2 then fold(cond.bytes) else cond.bytes
		if type(v) ~= "string" then
			return false
		end
		return if op == 6 then string.sub(v, 1, #b) == b else string.find(v, b, 1, true) ~= nil
	elseif op == 8 then
		return value_of(cells, id, cond.column) ~= nil
	elseif op == 9 then
		for _, cell in cells do
			if cell.kind == 2 and string.sub(cell.body, 1, 16) == cond.list then
				return true
			end
		end
		return false
	elseif op == 11 then
		return cond.ids[id] == true
	end
	return false
end

-- What answers a question, in its order, of the rows a node holds: the stretch asked for, and how many in all.
local function evaluate(node: Held, q: any): ({ string }, number)
	local found: { { id: string, cells: any } } = {}
	for rid, row in node.rows do
		if not row.grave then
			local cells = cells_of(row)
			local placed = false
			for _, c in cells do
				placed = placed or c.kind == 2
			end
			if placed and holds(q, q.where, rid, cells) then
				table.insert(found, { id = rid, cells = cells })
			end
		end
	end
	table.sort(found, function(x: any, y: any): boolean
		for _, o in q.order do
			local a, b
			if o.how == 0 then
				a, b = value_of(x.cells, x.id, o.column), value_of(y.cells, y.id, o.column)
			elseif o.how == 2 then
				a, b = x.id, y.id -- when made, and then by the rest of the id
			else
				a, b = nil, nil
			end
			if a ~= b then
				if a == nil then
					return false
				elseif b == nil then
					return true
				end
				if o.desc then
					return a > b
				end
				return a < b
			end
		end
		return x.id < y.id
	end)
	local ids = {}
	for k = q.offset + 1, math.min(#found, q.offset + q.limit) do
		local at = if q.from_end then #found - k + 1 else k
		table.insert(ids, found[at].id)
	end
	return ids, #found
end

-- Answers anything asked whose answer is not what was last said: rows first, then which. Whether anything was said.
answer = function(p: Peer): boolean
	local node = nodes[p] or { rows = {}, dead = {} }
	nodes[p] = node
	local said = false
	for id, q in p.asked do
		local ids, total = evaluate(node, q)
		local first = q.offset
		-- What would be said, and the rows themselves as they are now.
		local set = {}
		for _, rid in ids do
			set[rid] = true
		end
		local rows = rows_of(node, set)
		local w = codec.writer()
		codec.put_varint(w, total)
		codec.put_varint(w, first)
		codec.put_varint(w, #ids)
		for _, rid in ids do
			codec.put(w, rid)
		end
		codec.put_varint(w, 0)
		local said_now = codec.string(w) .. rows
		if p.said[id] ~= said_now then
			p.said[id] = said_now
			said = true
			send_cells(p, rows)
			local a = codec.writer()
			codec.put_u8(a, ANSWER)
			codec.put_varint(a, id)
			codec.put_u8(a, 1)
			codec.put(a, string.sub(said_now, 1, #said_now - #rows))
			local framed = codec.writer()
			codec.put_bytes(framed, codec.string(a))
			p.receive(codec.string(framed))
		end
	end
	return said
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

local Step = m.map({ name = zsp.string(16) })
local Task = m.map({ title = zsp.string(16), done = zsp.boolean(17), notes = zsp.text(18), tags = m.list(19, zsp.string(16)), steps = m.list(20, Step), plan = m.map({ due = zsp.number(16) }) })
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
			table.insert(d.tasks, math.random(1, #d.tasks + 1), { title = word(), done = math.random(2) == 1, tags = { word() }, steps = { { name = word() } }, plan = { due = math.random(9) } })
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
			t.plan.due = if math.random(4) == 1 then nil else math.random(9)
			if math.random(2) == 1 then
				table.insert(t.steps, math.random(1, #t.steps + 1), { name = word() })
			elseif #t.steps > 0 then
				local x = table.remove(t.steps, math.random(#t.steps))
				if math.random(2) == 1 then
					x.name = word()
					table.insert(t.steps, math.random(1, #t.steps + 1), x)
				end
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
			table.insert(keep, { title = word(), tags = {}, steps = {}, plan = {} })
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
local FIRST = tonumber(require("@lune/process").args[3] or "") or 1 -- to go back to one seed
local now = 0 -- the seed being gone over, to say if anything fails in it
local ok, why = xpcall(function()
	for seed = FIRST, FIRST + SEEDS - 1 do
		now = seed
		math.randomseed(seed)
		-- Each seed from the same start, so that any one of them can be gone back to alone.
		clock, hostile_clock = 1800000000, 0
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
		-- What is asked about is what the document shows there that answers, as a node orders it; given without its own
		-- lists, records and trees of rows.
		local function check_ask(i: number, what: string, asker: Peer?)
			local want = model(peers[i].client, Board)
			local by = asker or peers[i]
			local q = zsp.where
			local root = derive("")
			local path: { string }, cond: any, pred: (any) -> boolean, kind: string = { "tasks" }, nil, function(_: any)
				return true
			end, "list"
			local by_title = math.random(2) == 1
			local function some(t: any): string?
				local ks = {}
				for k in t or {} do
					table.insert(ks, k)
				end
				return if #ks > 0 then ks[math.random(#ks)] else nil
			end
			local r = math.random(6)
			if r == 1 then
				local c = math.random(3)
				if c == 1 then
					local v = math.random(2) == 1
					cond, pred = q.is("done", v), function(x: any)
						return x.done == v
					end
				elseif c == 2 then
					local w = word()
					cond, pred = q.is("title", w), function(x: any)
						return x.title == w
					end
				end
			elseif r == 2 then
				local lo, hi = math.random(0, 60), math.random(40, 100)
				path, kind, by_title = { "scores" }, "record", false
				cond, pred = q.between("value", lo, hi), function(x: any)
					return x >= lo and x <= hi
				end
			elseif r == 3 then
				local w = word()
				path, kind = { "people" }, "record"
				cond, pred = q.is("role", w), function(x: any)
					return x.role == w
				end
			elseif r == 4 then
				local w = word()
				path, kind = { "outline" }, "tree"
				if math.random(2) == 1 then
					cond, pred = q.is("name", w), function(x: any)
						return x.name == w
					end
				end
			elseif r == 5 then
				path = { "people", some(want.people) or word(), "pets" }
			else
				local t = want.tasks[math.random(math.max(1, #want.tasks))]
				path = { "tasks", if t then t.id else string.rep("\1", 16), "steps" }
				if math.random(2) == 1 then
					local w = word()
					cond, pred = q.is("name", w), function(x: any)
						return x.name == w
					end
				end
			end
			if kind ~= "list" and kind ~= "tree" and kind ~= "record" then
				error("no kind")
			end
			-- What the model says.
			local box: any = want
			local s: any = Board
			local k = 1
			while box ~= nil and k <= #path do
				local b = s.boxes[path[k]]
				box = box[path[k]]
				if k == #path then
					break
				end
				local key = path[k + 1]
				if b.kind == "record" then
					box = if box then box[key] else nil
				else
					local found = nil
					for _, x in box or {} do
						if x.id == key then
							found = x
						end
					end
					box = found
				end
				s = b.of
				k += 2
			end
			local function strip(v: any): any
				if type(v) ~= "table" then
					return v
				end
				local out = {}
				for f, x in v do
					if f == "children" then
						local kids = {}
						for j, n in x do
							kids[j] = strip(n)
						end
						out.children = kids
					elseif f ~= "steps" and f ~= "pets" then
						out[f] = x
					end
				end
				return out
			end
			local members = {}
			if kind == "record" then
				for key, v in box or {} do
					table.insert(members, { id = derive(root, path[#path], key), key = key, v = v })
				end
			else
				local function walk(level: any)
					for _, n in level or {} do
						table.insert(members, { id = n.id, v = n })
						walk(n.children)
					end
				end
				walk(box)
			end
			local order_by = if path[#path] == "tasks" then "title" elseif path[#path] == "people" then "role" else "name"
			local got: any = nil
			local asked = m.ask(by.client, { scope = 1, name = document, schema = Board }, path, { where = cond, order = if by_title then { order_by } else nil, limit = 1000 }, function(a)
				got = a
			end)
			run(by)
			-- Which rows answer is the node's to say, by the bytes in them, as it orders them; that they are what the
			-- document shows, and are given as it shows them, the mirror's.
			local first_asked = math.huge
			for qid in by.asked do
				first_asked = math.min(first_asked, qid)
			end
			local by_id = {}
			for _, x in members do
				by_id[x.id] = x
			end
			local expected = {}
			for _, rid in (evaluate(nodes[by], by.asked[first_asked])) do
				if by_id[rid] then
					table.insert(expected, by_id[rid])
				end
			end
			local _ = pred
			local function fail(why: string)
				failures += 1
				local shown = {}
				for _, x in expected do
					table.insert(shown, show(strip(x.v)))
				end
				local given = {}
				for _, x in got.rows do
					table.insert(given, show(x))
				end
				error(`seed {seed}, client {i}, {what}, asking about {table.concat(path, "/")} ({if by_title then order_by else "newest"}): {why}\n  want {table.concat(shown, " ")}\n  got  {table.concat(given, " ")}`)
			end
			if got.status ~= "ready" then
				fail(`it is {got.status}`)
			end
			if #got.rows ~= #expected then
				fail(`{#got.rows} rows, not {#expected}`)
			end
			for j, x in expected do
				if not equal(got.rows[j], strip(x.v)) then
					fail(`row {j} differs: {where_differ(got.rows[j], strip(x.v), "") or "?"}`)
				end
				if kind == "record" and got.keys[j] ~= x.key then
					fail(`key {j} is {tostring(got.keys[j])}, not {x.key}`)
				end
			end
			asked.stop()
			run(by)
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
					-- As written, before the node sends anything back: what comes back with it (others' writing, in rows
					-- this one put in the list) is news, and is held to the model below.
					drain(peers[i])
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
					run(peers[i])
					check(i, `step {step}, after writing`)
				if math.random(3) == 1 then
					check_ask(i, `step {step}, after writing`)
				end
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
			check_ask(i, "at the end")
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
		-- One that has heard it all and opened nothing: it holds only what it asks about, and finds the same.
		do
			local reader = peer()
			for k = 1, #log do
				hear(reader, log[k])
			end
			for _, p2 in peers do
				for _, c in p2.out do
					hear(reader, c)
				end
			end
			for _ = 1, 6 do
				check_ask(1, "by one that opened nothing", reader)
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
end, function(e: any): string
	return `seed {now}: {e}\n{debug.traceback()}`
end)
if not ok then
	error(why, 0)
end
print(if failures == 0 then "ok" else `{failures} failed`)
