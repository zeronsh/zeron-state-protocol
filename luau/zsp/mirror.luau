--!strict
-- Structured state as plain tables: maps, lists, records and trees, nested as deep as wanted, and texts in them. What
-- an application sets is compared with what there was, and only what differs is written; what others write comes back
-- as new tables where something changed and the very same ones where nothing did. See docs/mirror.md.
--
-- Nothing here is new to the protocol. A document is the rows of one list: each row a map, and in a column of its own
-- where in the document it is, so that moving it anywhere is one write and the whole document one window.

local codec = require("./codec")
local sha256 = require("./sha256")
local text = require("./text")

export type Column = { read slot: number, read text: boolean, read is: string, read encode: (any) -> string, read decode: (string) -> any, read who: ("last" | "all")? }

export type Schema = {
	read kind: "map" | "list" | "record" | "tree",
	read fields: { [string]: any }?, -- of a map: columns, and schemas of what is in it
	read of: any?, -- of a list or record: a map schema or a column; of a tree, the map schema of a node
}

local POS = 255 -- the slot that says where a row is
local POS_NAME = "\0where"
local ZERO = string.rep("\0", 16)
local SPACING = 1024
local NIL = table.freeze({}) -- in place of nothing, where something must be

local function same(v: any): any
	return v
end

local POS_COLUMN: Column = table.freeze({ slot = POS, text = false, is = "string", encode = same, decode = same, who = nil })

local mirror = {}

local function check(fields: { [string]: any })
	for name, f in fields do
		assert(type(name) == "string" and name ~= "id" and name ~= "children", `{name} is not a name for a field`)
		if f.slot then
			assert(f.slot >= 16 and f.slot < POS, "a mirror's columns are slots 16 to 254")
		else
			assert(f.kind, `{name} is neither a column nor a schema`)
		end
	end
end

-- A row of named columns, and of whatever is nested in it under other names.
function mirror.map(fields: { [string]: any }): Schema
	check(fields)
	return table.freeze({ kind = "map" :: "map", fields = table.freeze(table.clone(fields)) })
end

-- Values in an order, which may be moved about. Maps in it have their ids, by which they are known when it is set again.
function mirror.list(of: any): Schema
	assert(of.slot or (of.kind == "map"), "a list is of maps or of values")
	return table.freeze({ kind = "list" :: "list", of = of }) :: any
end

-- Values by keys that are not known beforehand.
function mirror.record(of: any): Schema
	assert(of.slot or (of.kind == "map"), "a record is of maps or of values")
	return table.freeze({ kind = "record" :: "record", of = of }) :: any
end

-- Maps, each with its children, in order; any of them may be moved under any other.
function mirror.tree(node: Schema): Schema
	assert(node.kind == "map", "a tree is of maps")
	return table.freeze({ kind = "tree" :: "tree", of = node }) :: any
end

-- ---------------------------------------------------------------- where a row is

type Pos = { owner: string, field: string, order: number, key: string, parent: string, from: string, stamp: string }

local function pos_encode(owner: string, field: string, order: number, extra: string?): string
	local w = codec.writer()
	codec.put(w, owner)
	codec.put_bytes(w, field)
	codec.put(w, string.pack(">d", order))
	if extra then
		codec.put(w, extra)
	end
	return codec.string(w)
end

local function pos_decode(body: string, stamp: string): Pos?
	local ok, p = pcall(function()
		local r = codec.reader(body)
		local owner = codec.take(r, 16)
		local field = codec.bytes(r)
		local order = string.unpack(">d", codec.take(r, 8))
		local rest = codec.rest(r)
		return {
			owner = owner,
			field = field,
			order = order,
			key = rest,
			parent = if #rest == 32 then string.sub(rest, 1, 16) else ZERO,
			from = if #rest == 32 then string.sub(rest, 17, 32) else ZERO,
			stamp = stamp,
		}
	end)
	return if ok then p :: any else nil
end

-- ---------------------------------------------------------------- the document

export type Doc = {
	read state: () -> any,
	read status: () -> string,
	read set: (state: any) -> (),
	read update: (f: (draft: any) -> ()) -> (),
	read stop: () -> (),
}

type Index = {
	ids: { string }?, -- of a list, in order
	keys: { [string]: string }?, -- of a record: the row each key is
	losers: { string }?, -- rows of a record that lost their key to another
	nodes: { [string]: { parent: string, ids: { string } } }?, -- of a tree, by parent ("" for the top): children in order
}

function mirror.open(client: any, options: { scope: number, name: string, schema: Schema }, observer: ((any) -> ())?): Doc
	local scope, schema = options.scope, options.schema
	assert(schema.kind == "map", "a document is a map")
	local list = "mirror/" .. options.name

	-- Ids that are the same for everyone: of the document, and of a map within a map.
	local function derive(...: string): string
		local s = client.scopes[scope]
		if not s then
			return ZERO -- not yet known, or not to be read here: there is nothing, until there is
		end
		return string.pack(">I4I4", scope, 0) .. string.sub(sha256(s.key .. "zsp-mirror\0" .. table.concat({ ... }, "\0")), 1, 8)
	end

	-- Columns of each map, for reading and for writing.
	local columns: { [Schema]: { [string]: Column } } = {}
	local writing: { [Schema]: { [string]: Column } } = {}
	local function columns_of(s: Schema): { [string]: Column }
		local c = columns[s]
		if not c then
			c = {}
			local w = { [POS_NAME] = POS_COLUMN }
			for name, f in s.fields :: any do
				if f.slot then
					c[name] = f
					if not f.who then
						w[name] = f
					end
				end
			end
			columns[s] = c
			writing[s] = w
		end
		return c :: any
	end

	local named: { [Schema]: { string } } = {}
	local function names_of(s: Schema): { string }
		local n = named[s]
		if not n then
			n = {}
			for name in s.fields :: any do
				table.insert(n, name)
			end
			table.sort(n)
			named[s] = n
		end
		return n :: any
	end

	local flats: { [Schema]: boolean } = {}
	local function flat_of(s: Schema): boolean
		local f = flats[s]
		if f == nil then
			f = true
			for _, x in s.fields :: any do
				f = f and x.slot ~= nil
			end
			flats[s] = f
		end
		return f :: boolean
	end

	local placed: { [any]: Pos } = setmetatable({}, { __mode = "k" }) :: any

	local window: any = nil
	local entries: () -> { { key: string, row: any } } = function()
		return {}
	end
	local current: any = nil
	local index: { [string]: Index } = {} -- by owner and field
	local memo: { [any]: any } = {}
	local schemas: { [string]: Schema } = {} -- of each map row, as last read
	local stopped = false

	-- A value as a column holds it. An empty body is nothing, but in a column of text.
	local function decode(c: Column, row: any): any
		if c.text then
			return text.read(client:_text(row, c.slot))
		end
		local cells = row.slots[c.slot]
		local latest: any = nil
		if cells then
			for _, cell in cells do
				if cell.kind == 3 and (not latest or cell.stamp > latest.stamp) then
					latest = cell
				end
			end
		end
		if not latest then
			return nil
		elseif latest.body == "" and c.is ~= "string" then
			return nil
		end
		local ok, v = pcall(c.decode, latest.body)
		return if ok then v else nil
	end

	-- What is read of a row is kept with it, until it changes: the client forgets a row's views when it does.
	local ME = {}
	local function cache(row: any): any
		local c = row.views[ME]
		if not c then
			c = { fresh = true }
			row.views[ME] = c
		end
		return c
	end

	local function pos_read(row: any): Pos?
		local cells = row.slots[POS]
		local latest: any = nil
		if cells then
			for _, cell in cells do
				if cell.kind == 3 and (not latest or cell.stamp > latest.stamp) then
					latest = cell
				end
			end
		end
		return if latest then pos_decode(latest.body, latest.stamp) else nil
	end

	local function pos_of(row: any): Pos?
		local c = cache(row)
		if c.pos == nil then
			c.pos = pos_read(row) or false
		end
		return c.pos or nil
	end

	-- A map's columns as a row has them, in the order of their names.
	local function values_of(s: Schema, row: any, names: { string }): { any }
		local c = cache(row)
		c.values = c.values or {}
		local v = c.values[s]
		if not v then
			v = {}
			for i, name in names do
				local f = (s.fields :: any)[name]
				if f.slot then
					local x = decode(f, row)
					v[i] = if x == nil then NIL else x
				end
			end
			c.values[s] = v
		end
		return v
	end

	-- ------------------------------------------------ reading

	local function read(): any
		local groups: { [string]: { { row: any, pos: Pos } } } = {}
		local byid: { [string]: any } = {}
		local changed: { [string]: boolean } = {} -- groups where something was placed otherwise
		local dirty: { [string]: { any } } = {} -- and the rows of each that changed at all
		for _, e in entries() do
			local row = e.row
			if not row.dead then
				byid[row.id] = row
				local fresh = row.views[ME] == nil -- it has changed since it was last read, or was never read
				local p = pos_of(row)
				if p then
					local g = `{p.owner}\0{p.field}`
					local into = groups[g]
					if not into then
						into = {}
						groups[g] = into
					end
					table.insert(into, { row = row, pos = p :: Pos })
					if fresh then
						local d = dirty[g]
						if not d then
							d = {}
							dirty[g] = d
						end
						table.insert(d, row)
					end
					-- Where it is, as against where it was: only that may change an order.
					local prev = placed[row]
					if not prev or prev.owner ~= p.owner or prev.field ~= p.field or prev.order ~= p.order then
						changed[g] = true
						if prev then
							changed[`{prev.owner}\0{prev.field}`] = true
						end
						placed[row] = p
					end
				end
			end
		end
		local seen: { [any]: any } = {}
		index = {}
		schemas = {}

		local read_map: any
		local function read_value(of: any, row: any, id: string): any
			if of.slot then
				return decode(of, row)
			end
			return read_map(of, row, id)
		end

		-- In order; as it was, if none of it has changed and none come or gone.
		local function sorted(g: { { row: any, pos: Pos } }?, key: string, under: string?): { { row: any, pos: Pos } }
			local k = `{key}\0sorted\0{under or ""}`
			local was = memo[k]
			if was and not changed[key] and was.n == (if g then #g else 0) and not under then
				seen[k] = was
				return was.out
			end
			local out: { { row: any, pos: Pos } } = if g then table.clone(g) else {}
			table.sort(out, function(a: { row: any, pos: Pos }, b: { row: any, pos: Pos }): boolean
				if a.pos.order ~= b.pos.order then
					return a.pos.order < b.pos.order
				end
				return a.row.id < b.row.id
			end)
			seen[k] = { n = out and #out, out = out }
			return out
		end

		-- The same table as before if all of it is the same.
		local function share(key: any, parts: { any }, make: () -> any): any
			local was = memo[key]
			if was and #was.parts == #parts then
				local all = true
				for i, p in parts do
					if not rawequal(was.parts[i], p) then
						all = false
						break
					end
				end
				if all then
					seen[key] = was
					return was.out
				end
			end
			local out = make()
			seen[key] = { parts = parts, out = out }
			return out
		end

		local read_container: any

		read_map = function(s: Schema, row: any?, id: string): any
			schemas[id] = s
			local names = names_of(s)
			-- A map with nothing in it but columns is as its row is, and kept with it.
			local flat = flat_of(s)
			if flat and row then
				local c = cache(row)
				c.outs = c.outs or {}
				local out = c.outs[s]
				if not out then
					local values = values_of(s, row, names)
					local made: { [string]: any } = { id = id }
					for i, name in names do
						if values[i] ~= NIL then
							made[name] = values[i]
						end
					end
					out = table.freeze(made)
					c.outs[s] = out
				end
				return out
			end
			local parts: { any } = { id }
			local values = if row then values_of(s, row, names) else nil
			for i, name in names do
				local f = (s.fields :: any)[name]
				local v
				if f.slot then
					v = if values then values[i] else NIL
				else
					v = read_container(f, id, name)
				end
				table.insert(parts, if v == nil then NIL else v)
			end
			return share(id, parts, function()
				local out: { [string]: any } = { id = id }
				for i, name in names do
					local v = parts[i + 1]
					if v ~= NIL then
						out[name] = v
					end
				end
				return table.freeze(out)
			end)
		end

		read_container = function(s: Schema, owner: string, field: string): any
			local g = groups[`{owner}\0{field}`]
			local key = `{owner}\0{field}`
			if s.kind == "map" then
				local id = derive(owner, field)
				return read_map(s, byid[id], id)
			elseif s.kind == "list" then
				-- Values, or maps of nothing but columns: as they were, if none of them changed and none moved.
				local was = memo[`{key}\0whole`]
				local flat = (s.of :: any).slot ~= nil or flat_of(s.of)
				if flat and was and not changed[key] and was.n == (if g then #g else 0) then
					if not dirty[key] then
						seen[`{key}\0whole`] = was
						index[key] = { ids = was.ids } :: any
						return was.out
					end
					-- In the same order: only what changed is read again.
					local parts = table.clone(was.parts)
					local whole = true
					for _, row in dirty[key] do
						local at = was.at[row.id]
						local v = if at then read_value(s.of, row, row.id) else nil
						if v == nil then
							whole = false
							break
						end
						parts[at] = v
					end
					if whole then
						local out = table.freeze(table.clone(parts))
						seen[`{key}\0whole`] = { n = was.n, ids = was.ids, at = was.at, parts = parts, out = out }
						index[key] = { ids = was.ids } :: any
						return out
					end
				end
				local items = sorted(g, key)
				local ids, parts = {}, {}
				for _, it in items do
					local v = read_value(s.of, it.row, it.row.id)
					if v ~= nil then -- a value that is nothing is not one of them
						table.insert(ids, it.row.id)
						table.insert(parts, v)
					end
				end
				index[key] = { ids = ids }
				local out = share(key, parts, function()
					return table.freeze(table.clone(parts))
				end)
				if flat and #ids == (if g then #g else 0) then
					local at = {}
					for i, id in ids do
						at[id] = i
					end
					seen[`{key}\0whole`] = { n = #ids, ids = ids, at = at, parts = parts, out = out }
				end
				return out
			elseif s.kind == "record" then
				-- Of rows that claim one key, the last made has it.
				local best: { [string]: { row: any, pos: Pos } } = {}
				local losers = {}
				for _, it in g or {} do
					local b = best[it.pos.key]
					if not b or it.pos.order > b.pos.order or (it.pos.order == b.pos.order and it.row.id > b.row.id) then
						if b then
							table.insert(losers, b.row.id)
						end
						best[it.pos.key] = it
					else
						table.insert(losers, it.row.id)
					end
				end
				local keys: { string } = {}
				local rows: { [string]: string } = {}
				for k, it in best do
					table.insert(keys, k)
					rows[k] = it.row.id
				end
				table.sort(keys)
				local parts = {}
				for i, k in keys do
					parts[2 * i - 1] = k
					parts[2 * i] = read_value(s.of, best[k].row, best[k].row.id)
				end
				index[key] = { keys = rows, losers = losers }
				return share(key, parts, function()
					local out = {}
					for i = 1, #parts, 2 do
						out[parts[i]] = parts[i + 1]
					end
					return table.freeze(out)
				end)
			else
				-- A tree. Each node says what it is under; where that makes a loop, the node of the loop that moved last
				-- goes back to where it came from, and failing that to the top. What is under nothing there is, is not.
				local nodes: { [string]: { row: any, pos: Pos } } = {}
				for _, it in g or {} do
					nodes[it.row.id] = it
				end
				local parent: { [string]: string } = {}
				for id, it in nodes do
					parent[id] = it.pos.parent
				end
				local reverted: { [string]: boolean } = {}
				while true do
					-- Each node goes up until the top, or something already known to reach it, or a loop.
					local state: { [string]: number } = {} -- 1 on the way, 2 reaches the top, 3 hangs from nothing
					local loop: { string }? = nil
					local ids: { string } = {}
					for id in nodes do
						table.insert(ids, id)
					end
					table.sort(ids)
					for _, start in ids do
						local path: { string } = {}
						local at = start
						while true do
							if at == ZERO then
								break
							end
							local st = state[at]
							if st == 2 or st == 3 then
								break
							end
							if st == 1 then
								local cycle = {}
								local inside = false
								for _, p in path do
									inside = inside or p == at
									if inside then
										table.insert(cycle, p)
									end
								end
								loop = cycle
								break
							end
							if not nodes[at] then
								for _, p in path do
									state[p] = 3
								end
								path = {}
								break
							end
							state[at] = 1
							table.insert(path, at)
							at = parent[at]
						end
						if loop then
							break
						end
						local final = if at == ZERO then 2 else (state[at] or 3)
						for _, p in path do
							state[p] = final
						end
					end
					if not loop then
						for id in nodes do
							if state[id] ~= 2 then
								nodes[id] = nil
							end
						end
						break
					end
					local last: string = loop[1]
					for _, id in loop do
						if nodes[id].pos.stamp > nodes[last].pos.stamp then
							last = id
						end
					end
					parent[last] = if reverted[last] then ZERO else nodes[last].pos.from
					reverted[last] = true
				end
				local children: { [string]: { { row: any, pos: Pos } } } = {}
				for id, it in nodes do
					local p = parent[id]
					local c = children[p]
					if not c then
						c = {}
						children[p] = c
					end
					table.insert(c, it)
				end
				local tree: { [string]: { parent: string, ids: { string } } } = {}
				local function level(under: string): any
					local items = sorted(children[under], key, under)
					local ids, parts = {}, {}
					for i, it in items do
						local id = it.row.id
						ids[i] = id
						local node = read_map(s.of :: Schema, it.row, id)
						local kids = level(id)
						parts[i] = share(`{id}\0children`, { node, kids }, function()
							local out = table.clone(node)
							out.children = kids
							return table.freeze(out)
						end)
					end
					tree[under] = { parent = under, ids = ids }
					return share(`{key}\0{under}`, parts, function()
						return table.freeze(table.clone(parts))
					end)
				end
				local top = level(ZERO)
				index[key] = { nodes = tree }
				return top
			end
		end

		local root = derive("")
		local out = read_map(schema, byid[root], root)
		memo = seen
		return out
	end

	local function refresh()
		if stopped then
			return
		end
		local was = current
		current = read()
		if observer and not rawequal(was, current) then
			observer(current)
		end
	end

	window = client:window({ scope = scope, list = list, table = { [POS_NAME] = POS_COLUMN }, size = 0, from = "start" }, function()
		if window then
			refresh()
		end
	end)
	entries = window.entries
	current = read()
	if observer then
		observer(current)
	end

	-- ------------------------------------------------ writing

	local function now_order(): number
		return math.floor(client.host.now() * 1000)
	end

	-- Orders for a sequence of rows, keeping as many as are in order already; nil for those that keep theirs.
	local function orders(old: { [string]: number }, seq: { string }): ({ [string]: number }, boolean)
		-- The longest run, in the new order, of rows whose old orders rise.
		local tails: { number } = {}
		local tail_at: { number } = {}
		local prev: { number } = {}
		for i, id in seq do
			local o = old[id]
			if o then
				local lo, hi = 1, #tails + 1
				while lo < hi do
					local mid = (lo + hi) // 2
					if old[seq[tail_at[mid]]] < o then
						lo = mid + 1
					else
						hi = mid
					end
				end
				tails[lo] = o
				tail_at[lo] = i
				prev[i] = if lo > 1 then tail_at[lo - 1] else 0
			end
		end
		local keep: { [number]: boolean } = {}
		local at = tail_at[#tails]
		while at and at > 0 do
			keep[at] = true
			at = prev[at]
		end
		local out: { [string]: number } = {}
		local i = 1
		local renumber = false
		while i <= #seq do
			if keep[i] then
				i += 1
			else
				local j = i
				while j <= #seq and not keep[j] do
					j += 1
				end
				local lo = if i > 1 then old[seq[i - 1]] or out[seq[i - 1]] else nil
				local hi = if j <= #seq then old[seq[j]] else nil
				local n = j - i
				for k = 0, n - 1 do
					local o
					if lo and hi then
						o = lo + (hi - lo) * (k + 1) / (n + 1)
						if not (o > lo and o < hi) then
							renumber = true
						end
					elseif lo then
						o = lo + SPACING * (k + 1)
					elseif hi then
						o = hi - SPACING * (n - k)
					else
						o = SPACING * (k + 1)
					end
					out[seq[i + k]] = o
				end
				i = j
			end
		end
		if renumber then
			for k, id in seq do
				out[id] = SPACING * k
			end
		end
		return out, renumber
	end

	local function writing_of(s: any): { [string]: Column }
		columns_of(s)
		return writing[s]
	end

	local function present(id: string): boolean
		local row = client.rows[id]
		return row ~= nil and not row.dead and row.slots[POS] ~= nil
	end

	local function set(state: any)
		assert(not stopped, "the document is closed")
		assert(client:may(scope, "write"), "this client may not write there, or does not know yet that it may")
		local texts: { { id: string, column: Column, was: string, now: string } } = {}
		client:write(scope, function(change)
			-- Where rows are in order now, read only of those asked about.
			local old_orders: { [string]: number } = setmetatable({}, {
				__index = function(_, id: string): number?
					local row = client.rows[id]
					local p = if row then pos_of(row) else nil
					return if p then p.order else nil
				end,
			}) :: any

			-- Everything in a row goes with it.
			local delete_row: any
			delete_row = function(s: any, id: string)
				change.delete(id)
				if s.slot then
					return
				end
				for name, f in s.fields do
					if not f.slot then
						local x = index[`{id}\0{name}`]
						if f.kind == "map" then
							if present(derive(id, name)) then
								delete_row(f, derive(id, name))
							end
						elseif x and x.ids then
							for _, child in x.ids do
								delete_row(f.of, child)
							end
						elseif x and x.keys then
							for _, child in x.keys do
								delete_row(f.of, child)
							end
							for _, child in x.losers or {} do
								delete_row(f.of, child)
							end
						elseif x and x.nodes then
							for _, level in x.nodes do
								for _, child in level.ids do
									delete_row(f.of, child)
								end
							end
						end
					end
				end
			end

			local write_map: any
			local write_container: any

			-- A new row, where it is to be, and what is in it.
			local function make(of: any, value: any, where: string): string
				if of.slot then
					return change.insert({ [POS_NAME] = POS_COLUMN, v = of }, list, 0, { [POS_NAME] = where, v = value })
				end
				local id = change.insert(writing_of(of), list, 0, { [POS_NAME] = where })
				write_map(of, nil, value, id, true)
				return id
			end

			local function write_value(of: any, old: any, new: any, id: string, where: string?)
				if of.slot then
					local values: { [string]: any } = {}
					if new ~= old then
						values.v = if new == nil then "" else new
					end
					if where then
						values[POS_NAME] = where
					end
					if next(values) then
						change.set(id, { [POS_NAME] = POS_COLUMN, v = of }, values)
					end
				else
					write_map(of, old, new, id, false, where)
				end
			end

			write_map = function(s: Schema, old: any, new: any, id: string, made: boolean, where: string?)
				if rawequal(old, new) and not made and not where then
					return -- the very table that was read: nothing in it has changed
				end
				new = new or {}
				local values: { [string]: any } = {}
				if where then
					values[POS_NAME] = where
				end
				for name, c in columns_of(s) do
					local nv, ov = new[name], if old then old[name] else nil
					if c.who then
						continue
					elseif c.text and not made and type(nv) == "string" and type(ov) == "string" then
						if nv ~= ov then
							table.insert(texts, { id = id, column = c, was = ov, now = nv })
						end
					elseif nv ~= ov or (made and nv ~= nil) then
						values[name] = if nv == nil then "" else nv -- nothing, but in a column of text or a string
					end
				end
				if next(values) then
					change.set(id, writing_of(s), values)
				end
				for name, f in s.fields :: any do
					if not f.slot then
						write_container(f, if old then old[name] else nil, new[name], id, name)
					end
				end
			end

			write_container = function(s: Schema, old: any, new: any, owner: string, field: string)
				if rawequal(old, new) and old ~= nil then
					return
				end
				local x: any = index[`{owner}\0{field}`] or {}
				if s.kind == "map" then
					local id = derive(owner, field)
					local exists = present(id)
					if not exists then
						if new == nil then
							return
						end
						change.set(id, writing_of(s), { [POS_NAME] = pos_encode(owner, field, 0) })
						change.place(id, list, 0)
					end
					write_map(s, if exists then old else nil, new, id, not exists)
				elseif s.kind == "list" then
					new = new or {}
					old = old or {}
					local old_ids = x.ids or {}
					local of = s.of
					local seq: { string } = {} -- the new order, by row; new ones by a name of their own
					local fresh: { [string]: any } = {}
					local was: { [string]: any } = {}
					if of.slot then
						-- Values: the same at either end stay, those between are written over, and the rest come or go.
						local a, b = 0, 0
						while a < #old and a < #new and old[a + 1] == new[a + 1] do
							a += 1
						end
						while b < #old - a and b < #new - a and old[#old - b] == new[#new - b] do
							b += 1
						end
						for i = 1, a do
							table.insert(seq, old_ids[i])
						end
						for k = 1, #new - a - b do
							if k <= #old - a - b then
								local id = old_ids[a + k]
								was[id] = old[a + k]
								table.insert(seq, id)
							else
								fresh[`\1{k}`] = true
								table.insert(seq, `\1{k}`)
							end
						end
						for k = #new - a - b + 1, #old - a - b do
							delete_row(of, old_ids[a + k])
						end
						for i = #old - b + 1, #old do
							table.insert(seq, old_ids[i])
						end
					else
						-- Maps, by their ids.
						for i, id in old_ids do
							was[id] = old[i]
						end
						local kept: { [string]: boolean } = {}
						for i, item in new do
							local id = item.id
							if id and was[id] ~= nil and not kept[id] then
								kept[id] = true
								table.insert(seq, id)
							else
								fresh[`\1{i}`] = true
								table.insert(seq, `\1{i}`)
							end
						end
						for _, id in old_ids do
							if not kept[id] then
								delete_row(of, id)
							end
						end
					end
					local same = #seq == #old_ids
					for i, id in seq do
						same = same and id == old_ids[i]
					end
					local o = if same then {} else orders(old_orders, seq)
					for i, id in seq do
						local where = if o[id] then pos_encode(owner, field, o[id]) else nil
						if fresh[id] then
							make(of, new[i], where :: string)
						elseif was[id] ~= nil or where then
							write_value(of, was[id], new[i], id, where)
						end
					end
				elseif s.kind == "record" then
					new = new or {}
					old = old or {}
					local rows = x.keys or {}
					for _, loser in x.losers or {} do
						delete_row(s.of, loser)
					end
					for k, id in rows do
						if new[k] == nil then
							delete_row(s.of, id)
						end
					end
					for k, v in new do
						assert(type(k) == "string", "a record's keys are strings")
						if rows[k] then
							write_value(s.of, old[k], v, rows[k])
						else
							make(s.of, v, pos_encode(owner, field, now_order(), k))
						end
					end
				else
					-- A tree: every node where the new one has it, and those not in it gone, with all in them.
					new = new or {}
					local levels = x.nodes or {}
					local under: { [string]: string } = {}
					local was: { [string]: any } = {}
					local function walk(level: any, parent: string)
						for _, n in level or {} do
							was[n.id] = n
							under[n.id] = parent
							walk(n.children, n.id)
						end
					end
					walk(old, ZERO)
					local kept: { [string]: boolean } = {}
					local function mark(level: any)
						for _, n in level or {} do
							if n.id and was[n.id] and not kept[n.id] then
								kept[n.id] = true
							end
							mark(n.children)
						end
					end
					mark(new)
					for id in was do
						if not kept[id] then
							delete_row(s.of, id)
						end
					end
					local placed: { [string]: boolean } = {}
					local function place(level: any, parent: string)
						local seq: { string } = {}
						local fresh: { [string]: any } = {}
						local mine: { [string]: number } = {}
						for _, id in if levels[parent] then levels[parent].ids else {} do
							mine[id] = old_orders[id]
						end
						for i, n in level or {} do
							if n.id and kept[n.id] and not placed[n.id] then
								placed[n.id] = true
								table.insert(seq, n.id)
							else
								fresh[`\1{i}`] = true
								table.insert(seq, `\1{i}`)
							end
						end
						local o = orders(mine, seq)
						for i, id in seq do
							local n = level[i]
							if fresh[id] then
								local made = make(s.of, n, pos_encode(owner, field, o[id] :: number, parent .. ZERO))
								place(n.children, made)
							else
								local where = nil
								if o[id] or under[id] ~= parent then
									-- Where it came from goes with it: should this make a loop, it goes back.
									where = pos_encode(owner, field, o[id] or old_orders[id], parent .. under[id])
								end
								write_map(s.of :: Schema, was[id], n, id, false, where)
								place(n.children, id)
							end
						end
					end
					place(new, ZERO)
				end
			end

			local root = derive("")
			local exists = present(root)
			if not exists then
				change.set(root, writing_of(schema), { [POS_NAME] = pos_encode(ZERO, "", 0) })
				change.place(root, list, 0)
			end
			write_map(schema, if exists then current else nil, state, root, not exists)
		end)
		-- Texts, as edits: whoever else writes in them meanwhile keeps what they wrote.
		for _, t in texts do
			local a, b = 0, 0
			local was, now = t.was, t.now
			while a < #was and a < #now and string.byte(was, a + 1) == string.byte(now, a + 1) do
				a += 1
			end
			while b < #was - a and b < #now - a and string.byte(was, #was - b) == string.byte(now, #now - b) do
				b += 1
			end
			local editor = client:text(t.id, t.column)
			if #was - a - b > 0 then
				editor.delete(a, #was - a - b)
			end
			if #now - a - b > 0 then
				editor.insert(a, string.sub(now, a + 1, #now - b))
			end
			editor.close()
		end
		refresh()
	end

	-- A copy that may be changed, all the way down.
	local function thaw(v: any): any
		if type(v) ~= "table" then
			return v
		end
		local out = {}
		for k, x in v do
			out[k] = thaw(x)
		end
		return out
	end

	return table.freeze({
		state = function(): any
			return current
		end,
		status = function(): string
			return if client.ready then "ready" else "loading"
		end,
		set = set,
		update = function(f: (draft: any) -> ())
			local draft = thaw(current)
			f(draft)
			set(draft)
		end,
		stop = function()
			stopped = true
			window.stop()
		end,
	})
end

return table.freeze(mirror)
