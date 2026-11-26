--!strict
--!native
--!optimize 2
-- Structured state as plain tables: maps, lists, records and trees, nested as deep as wanted, and texts in them. What
-- an application sets is compared with what there was, and only what differs is written; what others write comes back
-- as new tables where something changed and the very same ones where nothing did. See docs/mirror.md.
--
-- Nothing here is new to the protocol. A document is the rows of one list. Each row says, in a column of its own,
-- what it is in. A list keeps its order, and a tree each node's children's, as a text of markers in a column of the
-- row that holds them, so that order merges as text does: whoever inserts where, nothing interleaves and nothing runs
-- out of room. A list of values is a text of the values themselves.

local codec = require("./codec")
local where = require("./ask").where
local sha256 = require("./sha256")
local text = require("./text")

export type Column = {
	read slot: number,
	read text: boolean,
	read is: string,
	read encode: (any) -> string,
	read decode: (string) -> any,
	read who: ("last" | "all")?,
}
export type Schema = any

local WHERE = 255 -- the slot that says what a row is in
local W = "\0where"
local ZERO = string.rep("\0", 16)
local NIL = table.freeze({}) -- in place of nothing, where something must be
local MAP, ITEM, ENTRY, NODE = 0, 1, 2, 3
local MARK = "\0" -- a marker in a list's order
local NOWHERE = string.rep("\0", 12) -- no marker

local function same(v: any): any
	return v
end

-- Whether two values are one: as the very same, and so NaN with NaN, which a writer may put in any number column.
local function alike(a: any, b: any): boolean
	return rawequal(a, b) or (a ~= a and b ~= b)
end

local WHERE_COLUMN: Column = table.freeze({ slot = WHERE, text = false, is = "string", encode = same, decode = same, who = nil })
local WINDOW = table.freeze({ [W] = WHERE_COLUMN }) -- one shape, so that all who open a document share its window

local mirror = {}

-- For tests: every shortcut off, so that what is read and written is read and written the long way, to be held to the
-- same as the short.
local plain = false
function mirror._plain(on: boolean)
	plain = on
end

-- ---------------------------------------------------------------- schemas

-- Named columns, and whatever is nested under other names. Each column has a slot of its own, from 16 to 254, as has
-- each list and tree, which keeps its order there.
function mirror.map(fields: { [string]: any }): Schema
	local columns, boxes, names, slots = {}, {}, {}, {}
	local function claim(slot: number, name: string)
		assert(type(slot) == "number" and slot >= 16 and slot < WHERE, `{name}: a mirror's slots are 16 to 254`)
		assert(not slots[slot], `{name}: slot {slot} is taken`)
		slots[slot] = true
	end
	for name, f in fields do
		assert(type(name) == "string" and name ~= "id" and name ~= "children", `{name} is not a name for a field`)
		if f.kind then
			boxes[name] = f
			if f.kind == "list" or f.kind == "tree" then
				claim(f.slot, name)
			end
		else
			assert(f.encode, `{name} is neither a column nor a schema`)
			-- Whose what is in a slot is says so of another's slot: it has none of its own.
			if not f.who then
				claim(f.slot, name)
			end
			columns[name] = f
		end
		table.insert(names, name)
	end
	table.sort(names)
	return table.freeze({ kind = "map", columns = columns, boxes = boxes, names = names, slots = slots })
end

-- Maps or values in an order, which may be moved about; its order is kept in `slot` of the row that holds it. Maps in
-- it have their ids, by which they are known when it is set again; values are kept in that slot themselves.
function mirror.list(slot: number, of: any): Schema
	assert(type(slot) == "number", "a list says which slot keeps its order")
	assert(of.kind == "map" or (not of.kind and of.encode), "a list is of maps or of values")
	return table.freeze({ kind = "list", slot = slot, of = of })
end

-- Maps or values by keys that are not known beforehand.
function mirror.record(of: any): Schema
	assert(of.kind == "map" or (not of.kind and of.encode), "a record is of maps or of values")
	return table.freeze({ kind = "record", of = of })
end

-- Maps, each with its children, in order, kept in `slot` of the row of each node, and of the row that holds the tree;
-- any node may be moved under any other.
function mirror.tree(slot: number, node: Schema): Schema
	assert(type(slot) == "number" and node.kind == "map", "a tree says which slot keeps its order, and is of maps")
	assert(not node.slots[slot], "a tree's nodes keep their children's order in that slot")
	return table.freeze({ kind = "tree", slot = slot, of = node })
end

-- ---------------------------------------------------------------- what a row is in

type Where = {
	owner: string,
	field: string,
	kind: number,
	marker: string, -- of an item or a node: its place in the order
	present: boolean, -- of an entry
	key: string, -- of an entry
	parent: string, -- of a node: ZERO for the top
	from: string, -- of a node: what it was moved from,
	back: string, -- and its marker there
	body: string,
	stamp: string,
}

local function where_encode(owner: string, field: string, kind: number, extra: string?): string
	local w = codec.writer()
	codec.put(w, owner)
	codec.put_bytes(w, field)
	codec.put_u8(w, kind)
	codec.put(w, extra or "")
	return codec.string(w)
end

local function where_decode(body: string, stamp: string): Where?
	local ok, w = pcall(function(): Where?
		local r = codec.reader(body)
		local out: Where = {
			owner = codec.take(r, 16),
			field = codec.bytes(r),
			kind = codec.u8(r),
			marker = "",
			present = false,
			key = "",
			parent = ZERO,
			from = ZERO,
			back = "",
			body = body,
			stamp = stamp,
		}
		local rest = codec.rest(r)
		if out.kind == ITEM and #rest == 12 then
			out.marker = rest
		elseif out.kind == ENTRY and #rest >= 1 then
			out.present = string.byte(rest) ~= 0
			out.key = string.sub(rest, 2)
		elseif out.kind == NODE and #rest == 56 then
			out.parent, out.marker = string.sub(rest, 1, 16), string.sub(rest, 17, 28)
			out.from, out.back = string.sub(rest, 29, 44), string.sub(rest, 45, 56)
		elseif out.kind ~= MAP or rest ~= "" then
			return nil
		end
		return out
	end)
	return if ok then w else nil
end

-- A marker's name, and the one after it in the same piece.
local function next_marker(id: string, by: number): string
	return string.sub(id, 1, 8) .. string.pack(">I4", (string.unpack(">I4", id, 9) :: any) + by)
end

-- Values in a list, each as long as it is.
local function frame(c: Column, v: any): string
	local body = c.encode(v)
	local w = codec.writer()
	codec.put_bytes(w, body)
	return codec.string(w)
end

-- A value's elements: as one run, which is how anyone who minds writes it; or, as a forger may, scattered, each named.
type Frame = { value: any, first: string, count: number, last: string, scattered: { string }? }

-- The values of a list from its text, with where each is. What does not read as one is not.
local function frames_of(c: Column, t: text.Text?): ({ any }, { Frame }, { string })
	local values, frames, junk = {}, {}, {}
	if not t then
		return values, frames, junk
	end
	local bytes = text.read(t)
	local ids = text.ids(t)
	local at = 1
	while at <= #bytes do
		local ok, n, used = pcall(function()
			local r = codec.reader(string.sub(bytes, at, at + 9))
			local n = codec.varint(r)
			return n, r.pos
		end)
		if not ok or at + used + n - 1 > #bytes then
			for k = at, #bytes do
				table.insert(junk, ids[k])
			end
			break
		end
		local fine, v = pcall(c.decode, string.sub(bytes, at + used, at + used + n - 1))
		if fine and v ~= nil then
			local count = used + n
			local scattered: { string }? = nil
			for k = 1, count - 1 do
				if ids[at + k] ~= next_marker(ids[at], k) then
					scattered = table.move(ids, at, at + count - 1, 1, {})
					break
				end
			end
			table.insert(values, v)
			table.insert(frames, { value = v, first = ids[at], count = count, last = ids[at + count - 1], scattered = scattered })
		else
			for k = at, at + used + n - 1 do
				table.insert(junk, ids[k])
			end
		end
		at += used + n
	end
	return values, frames, junk
end

-- The longest run of a sequence, by places it had before, that is still in order: those stay where they are.
local function staying(seq: { string }, before: { [string]: number }): { [number]: boolean }
	local tails, prev = {}, {}
	for i, id in seq do
		local o = before[id]
		if o then
			local lo, hi = 1, #tails + 1
			while lo < hi do
				local mid = (lo + hi) // 2
				if before[seq[tails[mid]]] < o then
					lo = mid + 1
				else
					hi = mid
				end
			end
			tails[lo] = i
			prev[i] = if lo > 1 then tails[lo - 1] else 0
		end
	end
	local keep = {}
	local at = tails[#tails]
	while at and at > 0 do
		keep[at] = true
		at = prev[at]
	end
	return keep
end

-- ---------------------------------------------------------------- the document

export type Doc = {
	read state: () -> any,
	read status: () -> string,
	read set: (state: any) -> (),
	read update: (f: (draft: any) -> ()) -> (),
	read stop: () -> (),
}

function mirror.open(client: any, options: { scope: number, name: string, schema: Schema, _held: boolean? }, observer: ((any) -> ())?): Doc
	local scope, schema = options.scope, options.schema
	assert(schema.kind == "map", "a document is a map")
	-- Read over whatever rows the client holds, not over the whole document: what is not held is not known, rather than
	-- gone. So it is for what is asked about (mirror.ask), which is read and not written.
	local held = options._held == true
	local list = "mirror/" .. options.name

	-- Ids that are the same for everyone: of the document, of a map within a map, and of a record's entry.
	local function derive(...: string): string
		local s = client.scopes[scope]
		if not s then
			return ZERO -- not yet known, or not to be read here: there is nothing, until there is
		end
		return string.pack(">I4I4", scope, 0) .. string.sub(sha256(s.key .. "zsp-mirror\0" .. options.name .. "\0" .. table.concat({ ... }, "\0")), 1, 8)
	end
	local function key_of(owner: string, field: string): string
		return owner .. field
	end

	-- What is known of the document's rows, kept as they change.
	local wheres: { [string]: Where } = {}
	local members: { [string]: { [string]: boolean } } = {} -- of each list, record or tree, and map: what says it is in it
	local owned: { [string]: { [string]: boolean } } = {} -- of each row: the keys of what is in it
	local hangs: { [string]: { [string]: boolean } } = {} -- of each tree node: what says it hangs from it
	local schema_of: { [string]: Schema } = {} -- of each map row, as last read
	local tree_up: { [string]: string } = {} -- of each tree node, as last read: the node it hangs from
	local losing: { [string]: boolean } = {} -- trees with nodes beneath what is not there
	local standing_in: { [string]: string } = {} -- of each map within a map: where it is, which its id says, row or no row
	local versions: { [string]: any } = {} -- of each text that keeps an order, as last read
	local dirty_rows: { [string]: boolean } = {}
	local moved_in: { [string]: { [string]: any } } = {} -- of each list: what came, went or moved, and from which marker
	local garbage: { [string]: { [string]: boolean } } = {} -- of each list: markers nothing has
	local dead_rows: { [string]: boolean } = {} -- seen to be deleted: what is in them is no longer anywhere
	local emptied: { [string]: boolean } = {} -- keys let go of: what is put in them meanwhile is not anywhere either
	local dirty_node: { [string]: boolean } = {}
	local dirty_box: { [string]: boolean } = {} -- true if what is in it or its order may have changed; false if only its members
	local nodes: { [string]: any } = {} -- maps, as last read, by id
	local boxes: { [string]: any } = {} -- lists, records and trees, as last read
	local tnodes: { [string]: any } = {} -- tree nodes with their children
	local current: any = nil
	local stopped = false
	local tag: string? = nil
	local ME = {} -- what is read of a row, kept with it until it changes

	local function ours(id: string): boolean
		if wheres[id] ~= nil then
			return true
		end
		local row = client:held(id)
		if not row then
			return false
		end
		if not tag then
			if not client.scopes[scope] then
				return false
			end
			tag = client:_tag(scope, list)
		end
		for slot = 1, 15 do
			for _, c in row.slots[slot] or {} :: any do
				if string.sub(c.body, 1, 16) == tag then
					return true
				end
			end
		end
		return false
	end

	-- ------------------------------------------------ what has changed

	local mark_node: any
	local changed_in: { [string]: { [string]: boolean } } = {} -- of each list and record: members that changed
	local function mark_box(key: string, structural: boolean, member: string?)
		if member then
			changed_in[key] = changed_in[key] or {}
			changed_in[key][member] = true
		end
		if structural then
			dirty_box[key] = true
		elseif dirty_box[key] == nil then
			dirty_box[key] = false
		end
		mark_node(string.sub(key, 1, 16))
	end
	local marked: { [string]: boolean } = {} -- in this pass: passed on to what it is in already
	mark_node = function(id: string)
		if id == ZERO or marked[id] then
			return
		end
		marked[id] = true
		dirty_node[id] = true
		local up = tree_up[id]
		if up and up ~= ZERO then
			mark_node(up)
		end
		local w = wheres[id]
		local box = if w then key_of(w.owner, w.field) else nil
		if box then
			mark_box(box, false, id)
		end
		-- A map within a map is there whether its own row has come or not, and is where its id says.
		local within = standing_in[id]
		if within and within ~= box then
			mark_box(within, false, id)
		end
	end

	local function latest(row: any, slot: number): any
		local best: any = nil
		for _, cell in row.slots[slot] or {} :: any do
			if cell.kind == 3 and (not best or cell.stamp > best.stamp) then
				best = cell
			end
		end
		return best
	end

	local function where_of(row: any): Where?
		local c = latest(row, WHERE)
		return if c then where_decode(c.body, c.stamp) else nil
	end

	-- Whether a text that keeps an order has changed since it was last read.
	local remade: { [string]: boolean } = {} -- texts of order made anew: what was in them may be gone
	local function moved(id: string, slot: number): boolean
		local t = client:held_text(id, slot)
		local k = id .. string.char(slot)
		local was = versions[k]
		if not was or was.t ~= t or was.v ~= (if t then t.version else 0) then
			if not was or was.t ~= t then
				remade[k] = true -- a text made again is another, as when a value was written over it
			end
			versions[k] = { t = t, v = if t then t.version else 0 }
			return true
		end
		return false
	end

	local function absorb()
		table.clear(marked)
		for id in dirty_rows do
			local row = client:held(id)
			local w = if row and not row.dead then where_of(row) else nil
			local old = wheres[id]
			if old and old.kind == NODE and hangs[old.parent] and (not w or w.parent ~= old.parent) then
				hangs[old.parent][id] = nil
			end
			if w and w.kind == NODE and w.parent ~= ZERO then
				hangs[w.parent] = hangs[w.parent] or {}
				hangs[w.parent][id] = true
			end
			if old and (not w or old.body ~= w.body) then
				local k = key_of(old.owner, old.field)
				if members[k] then
					members[k][id] = nil
				end
				-- Where it was when the list was last read, to find it there: true if it was not in it then.
				moved_in[k] = moved_in[k] or {}
				if moved_in[k][id] == nil then
					moved_in[k][id] = if old.kind == ITEM then old.marker else true
				end
				if old.kind == ITEM and (not w or w.marker ~= old.marker) then
					-- A marker no longer anyone's, if it is still there: let go of when the list is next written.
					local box = boxes[k]
					local t = if box and box.ids and box.slot then client:held_text(old.owner, box.slot) else nil
					if t and text.standing(t, old.marker) then
						garbage[k] = garbage[k] or {}
						garbage[k][old.marker] = true
					end
				end
				mark_box(k, true)
			end
			wheres[id] = w :: any
			if w then
				dead_rows[id] = nil -- it was only out of the list a while, and is back
			end
			emptied[id] = if w and w.kind == ENTRY and not w.present then true else nil
			if w and (not old or old.body ~= w.body) then
				local k = key_of(w.owner, w.field)
				members[k] = members[k] or {}
				members[k][id] = true
				owned[w.owner] = owned[w.owner] or {}
				owned[w.owner][k] = true
				moved_in[k] = moved_in[k] or {}
				if moved_in[k][id] == nil then
					moved_in[k][id] = true
				end
				mark_box(k, true)
			end
			mark_node(id)
			local s = schema_of[id]
			if s then
				for name, b in s.boxes do
					if (b.kind == "list" or b.kind == "tree") and moved(id, b.slot) then
						mark_box(key_of(id, name), true)
					end
				end
			end
			if w and w.kind == NODE then
				local tree = boxes[key_of(w.owner, w.field)]
				if tree and tree.tree and moved(id, tree.slot) then
					mark_box(key_of(w.owner, w.field), true)
				end
			end
			-- What was in a row that is gone is gone with it, wherever it is. Where only some rows are held, one that is not
			-- held is not known to be gone.
			if old and not w and (if held then row ~= nil and row.dead else (not row or row.dead)) then
				dead_rows[id] = true -- deleted, and perhaps let go of from memory already
			end
			-- What is in a row that comes or goes is there or not with it.
			if (old == nil) ~= (w == nil) then
				for k in owned[id] or {} :: any do
					mark_box(k, true)
				end
			end
		end
		table.clear(dirty_rows)
	end

	-- ------------------------------------------------ reading

	-- A value as a column holds it: a text is always one, empty or not; otherwise what is empty is nothing.
	local function decode(c: Column, row: any): any
		if c.who then
			-- Whose what is in the slot is, as the client says it: whoever wrote there last, or all who have, by name.
			local last: any = nil
			local names: { [string]: boolean } = {}
			for _, cell in row.slots[c.slot] or {} :: any do
				if not last or cell.stamp > last.stamp then
					last = cell
				end
				if cell.author and cell.author.subject ~= "" then
					names[cell.author.subject] = true
				end
			end
			if c.who == "all" then
				local all = {}
				for name in names do
					table.insert(all, name)
				end
				table.sort(all)
				return table.freeze(all)
			end
			return if last and last.author and last.author.subject ~= "" then last.author.subject else nil
		elseif c.text then
			return text.read(client:held_text(row.id, c.slot) :: any)
		end
		local cell = latest(row, c.slot)
		if not cell or cell.body == "" then
			return nil
		end
		local ok, v = pcall(c.decode, cell.body)
		return if ok then v else nil
	end

	local function values_of(s: Schema, row: any): { any }
		local c = row.views[ME]
		if not c then
			c = {}
			row.views[ME] = c
		end
		local v = c[s]
		if not v then
			v = {}
			for i, name in s.names do
				local col = s.columns[name]
				if col then
					local x = decode(col, row)
					v[i] = if x == nil then NIL else x
				end
			end
			c[s] = v
		end
		return v
	end

	local function alive(id: string): any
		local row = client:held(id)
		return if row and not row.dead then row else nil
	end

	-- The document, and maps within maps, are there for everyone whether their own rows have come or not: what is in
	-- them is. Whatever else holds anything holds it only while it is there itself.
	local standing: { [string]: boolean } = {}
	local function holds(owner: string): boolean
		return standing[owner] == true or alive(owner) ~= nil
	end

	local build_box: any

	-- A map: the same table as before if nothing in it is other than it was.
	local function build_map(s: Schema, id: string): any
		-- A map read as another's schema, as every map is while the scope is not known and all ids are nothing, is not this one.
		local was = if schema_of[id] == s then nodes[id] else nil
		if was and not dirty_node[id] and not plain then
			return was
		end
		dirty_node[id] = nil
		schema_of[id] = s
		local row = alive(id)
		local vals = if row then values_of(s, row) else nil
		local parts = {}
		local changed = was == nil
		for i, name in s.names do
			local b = s.boxes[name]
			local v = if b then build_box(b, id, name) else (if vals then vals[i] else NIL)
			if v == nil then
				v = NIL
			end
			parts[i] = v
			if not changed then
				local pv = was[name]
				changed = not alike(if pv == nil then NIL else pv, v)
			end
		end
		if not changed then
			return was
		end
		local out: { [string]: any } = { id = id }
		for i, name in s.names do
			if parts[i] ~= NIL then
				out[name] = parts[i]
			end
		end
		table.freeze(out)
		nodes[id] = out
		return out
	end

	-- Items that share a marker with the one before them, which only a writer who minds nothing makes: whoever writes
	-- the list next gives each one of its own, so that anything can be put between them.
	local function sharing(ids: { string }): { [string]: boolean }
		local out = {}
		for i = 2, #ids do
			local a, b = wheres[ids[i - 1]], wheres[ids[i]]
			if a and b and a.marker == b.marker then
				out[ids[i]] = true
			end
		end
		return out
	end

	-- Where each is in a list of ids.
	local function index_of(ids: { string }): { [string]: number }
		local out = {}
		for i, id in ids do
			out[id] = i
		end
		return out
	end

	local function same_list(a: { any }?, b: { any }): boolean
		if not a or #a ~= #b then
			return false
		end
		for i, v in b do
			if not alike(a[i], v) then
				return false
			end
		end
		return true
	end

	-- A record's entry, or a map or a value as it is in a row, whether that is in anything or not.
	local function build_value(of: any, id: string): any
		if of.kind then
			return build_map(of, id)
		end
		local row = alive(id)
		return if row then decode(of, row) else nil
	end

	build_box = function(b: Schema, owner: string, field: string): any
		local key = key_of(owner, field)
		local st = boxes[key]
		local d = dirty_box[key]
		if st and d == nil and not plain then
			return st.out
		end
		local structural = d == true or st == nil or plain
		dirty_box[key] = nil
		if b.kind == "map" then
			local id = derive(owner, field)
			standing[id] = true
			standing_in[id] = key
			local out = build_map(b, id)
			boxes[key] = { out = out }
			return out
		elseif b.kind == "list" and b.of.kind then
			local ids = if st then st.ids else {}
			local hidden = if st then st.hidden else {}
			local living = holds(owner)
			if structural then
				local t = if living then client:held_text(owner, b.slot) else nil
				-- The text read, to know later whether it is still the one.
				versions[owner .. string.char(b.slot)] = { t = t, v = if t then t.version else 0 }
				local function pos(id: string): (number?, number)
					local w = wheres[id]
					if not (t and w and w.kind == ITEM and alive(id)) then
						return nil, 0
					end
					return text.position(t :: any, w.marker)
				end
				local function before(x: string, y: string): boolean
					local lx, ox = pos(x)
					local ly, oy = pos(y)
					if lx ~= ly then
						return (lx :: number) < (ly :: number)
					elseif ox ~= oy then
						return ox < oy
					end
					return x < y
				end
				local redo = moved_in[key] or {}
				moved_in[key] = nil
				local mine = members[key] or {}
				local again = remade[owner .. string.char(b.slot)]
				remade[owner .. string.char(b.slot)] = nil
				if st and st.living == living and not again and not plain then
					-- What did not move keeps its order, for the order of what is there never changes; what came,
					-- moved, or had nowhere to be yet, is taken out and put in its place, in arrays as they were.
					for id in hidden do
						redo[id] = true
					end
					-- Each is found where it was, by the marker it had: that still has its place, gone or not.
					local index = st.index or nil
					local function at_of(id: string, was: any): number?
						if index then
							return index[id]
						elseif was == true then
							return nil -- it was not in the list as last read
						end
						if type(was) == "string" and t then
							local lw, ow = text.position(t :: any, was)
							if lw then
								local lo, hi = 1, #ids
								while lo <= hi do
									local mid = (lo + hi) // 2
									local m = ids[mid]
									if m == id then
										return mid
									end
									-- In the order as it was: what moved is where it was.
									local lm, om
									if type(redo[m]) == "string" then
										lm, om = text.position(t :: any, redo[m])
									else
										lm, om = pos(m)
									end
									if lm == nil then
										break
									end
									local less = if lm ~= lw then (lm :: number) < lw elseif om ~= ow then om < ow else m < id
									if less then
										lo = mid + 1
									else
										hi = mid - 1
									end
								end
							end
						end
						index = index_of(ids)
						return (index :: any)[id]
					end
					local gone = {}
					for id, was in redo do
						local at = at_of(id, was)
						if at then
							table.insert(gone, at)
						end
					end
					table.sort(gone, function(x: number, y: number): boolean
						return x > y
					end)
					local new_ids = table.clone(ids)
					local parts = table.clone(st.out)
					for _, at in gone do
						table.remove(new_ids, at)
						table.remove(parts, at)
					end
					hidden = {}
					-- Where each put back is, so long as they are few enough to keep count of as more go in.
					local put: { number }? = {}
					for id in redo do
						if mine[id] and alive(id) then
							if pos(id) then
								local lo, hi = 1, #new_ids + 1
								while lo < hi do
									local mid = (lo + hi) // 2
									if before(new_ids[mid], id) then
										lo = mid + 1
									else
										hi = mid
									end
								end
								table.insert(new_ids, lo, id)
								table.insert(parts, lo, build_map(b.of, id))
								if put then
									if #put >= 64 then
										put = nil
									else
										for i, at in put do
											if at >= lo then
												put[i] = at + 1
											end
										end
										table.insert(put, lo)
									end
								end
							else
								hidden[id] = true
							end
						end
					end
					-- What changed in place, too; where things are is known again when next it is asked.
					local touched = changed_in[key]
					changed_in[key] = nil
					local fresh_index = nil
					for id in touched or {} :: any do
						if not redo[id] then
							fresh_index = fresh_index or index_of(new_ids)
							local at = fresh_index[id]
							if at then
								parts[at] = build_map(b.of, id)
							end
						end
					end
					local out = if #gone == 0 and #new_ids == #ids and same_list(st.out, parts) then st.out else table.freeze(parts)
					-- Sharing a marker is looked for only beside what was put back: what moved is looked at again.
					local dups = table.clone(st.dups or {})
					for id in redo do
						dups[id] = nil
					end
					local function beside(i: number)
						for j = i, i + 1 do
							local x, y = new_ids[j - 1], new_ids[j]
							if x and y and wheres[x] and wheres[y] and wheres[x].marker == wheres[y].marker then
								dups[y] = true
							end
						end
					end
					if put then
						for _, i in put do
							beside(i)
						end
					else
						for i, id in new_ids do
							if redo[id] then
								beside(i)
							end
						end
					end
					boxes[key] = { out = out, ids = new_ids, hidden = hidden, living = living, index = fresh_index or false, slot = b.slot, dups = dups }
					return out
				end
				ids, hidden = {}, {}
				local at: { any } = {}
				for id in mine do
					if alive(id) then
						local l, o = pos(id)
						if l then
							table.insert(at, { id = id, l = l, o = o })
						else
							hidden[id] = true
						end
					end
				end
				table.sort(at, function(x: any, y: any): boolean
					if x.l ~= y.l then
						return x.l < y.l
					elseif x.o ~= y.o then
						return x.o < y.o
					end
					return x.id < y.id
				end)
				for i, x in at do
					ids[i] = x.id
				end
			end
			local touched = changed_in[key]
			changed_in[key] = nil
			if not structural and st then
				-- In the same order: only what changed is read again.
				local index = st.index or index_of(ids)
				local parts = nil
				for id in touched or {} :: any do
					local i = index[id]
					if i then
						local v = build_map(b.of, id)
						if not rawequal(v, st.out[i]) then
							parts = parts or table.clone(st.out)
							parts[i] = v
						end
					end
				end
				local out = if parts then table.freeze(parts) else st.out
				boxes[key] = { out = out, ids = ids, hidden = hidden, living = living, index = index, slot = b.slot, dups = st.dups }
				return out
			end
			local parts = {}
			for i, id in ids do
				parts[i] = build_map(b.of, id)
			end
			local out = if st and same_list(st.out, parts) then st.out else table.freeze(parts)
			boxes[key] = { out = out, ids = ids, hidden = hidden, living = living, index = false, slot = b.slot, dups = sharing(ids) }
			return out
		elseif b.kind == "list" then
			if not structural and st then
				return st.out
			end
			local values, frames, junk = frames_of(b.of, if holds(owner) then client:held_text(owner, b.slot) else nil)
			local out = if st and same_list(st.out, values) then st.out else table.freeze(values)
			boxes[key] = { out = out, frames = frames, junk = junk }
			return out
		elseif b.kind == "record" then
			local keys = if st then st.keys else {}
			if structural then
				keys = {}
				if holds(owner) then
					for id in members[key] or {} :: any do
						local w = wheres[id]
						if w and w.kind == ENTRY and w.present and alive(id) and id == derive(owner, field, w.key) then
							keys[w.key] = id
						end
					end
				end
			end
			local touched = changed_in[key]
			changed_in[key] = nil
			if not structural and st then
				local out = nil
				for id in touched or {} :: any do
					local w = wheres[id]
					if w and keys[w.key] == id then
						local v = build_value(b.of, id)
						if not rawequal(v, st.out[w.key]) then
							out = out or table.clone(st.out)
							out[w.key] = v
						end
					end
				end
				local result = if out then table.freeze(out) else st.out
				boxes[key] = { out = result, keys = keys }
				return result
			end
			local out = {}
			local changed = st == nil
			local count = 0
			for k, id in keys do
				local v = build_value(b.of, id)
				if v ~= nil then
					out[k] = v
					count += 1
					changed = changed or not rawequal(st.out[k], v)
				end
			end
			if not changed then
				for _ in st.out do
					count -= 1
				end
				changed = count ~= 0
			end
			local result = if changed then table.freeze(out) else st.out
			boxes[key] = { out = result, keys = keys }
			return result
		else
			-- A tree. Each node says what it hangs from; where that makes a loop, the node of the loop that moved last
			-- goes back to where it came from, and failing that to the top. What hangs from nothing there is, is not.
			local kids = if st then st.kids else {}
			local up = if st then st.up else {}
			local sits = if st then st.sits else {}
			local lost: { [string]: string } = if st then st.lost else {} -- of each node not shown: the node, not there, it is beneath
			if structural then
				local here: { [string]: Where } = {}
				if holds(owner) then
					for id in members[key] or {} :: any do
						local w = wheres[id]
						if w and w.kind == NODE and alive(id) then
							here[id] = w
						end
					end
				end
				local parent: { [string]: string } = {}
				local marker: { [string]: string } = {}
				for id, w in here do
					parent[id] = w.parent
					marker[id] = w.marker
				end
				local ids: { string } = {}
				for id in here do
					table.insert(ids, id)
				end
				table.sort(ids)
				local reverted: { [string]: boolean } = {}
				while true do
					local state: { [string]: number } = {} -- 1 on the way up, 2 reaches the top, 3 hangs from nothing
					local loop: { string }? = nil
					lost = {}
					for _, start in ids do
						local path = {}
						local at = start
						local final = 2
						local missing: string? = nil
						while at ~= ZERO do
							local st2 = state[at]
							if st2 == 2 or st2 == 3 then
								final = st2
								missing = lost[at]
								break
							elseif st2 == 1 then
								local cycle, inside = {}, false
								for _, p in path do
									inside = inside or p == at
									if inside then
										table.insert(cycle, p)
									end
								end
								loop = cycle
								break
							elseif not here[at] then
								final = 3
								missing = at
								break
							end
							state[at] = 1
							table.insert(path, at)
							at = parent[at]
						end
						if loop then
							break
						end
						for _, p in path do
							state[p] = final
							lost[p] = missing
						end
					end
					if not loop then
						for _, id in ids do
							if state[id] ~= 2 then
								here[id] = nil
							end
						end
						break
					end
					local last: string = loop[1]
					for _, id in loop do
						if here[id].stamp > here[last].stamp then
							last = id
						end
					end
					-- Back where it was, by the marker it left there; or, if that will not do either, last at the top.
					parent[last] = if reverted[last] then ZERO else here[last].from
					marker[last] = if reverted[last] then "" else here[last].back
					reverted[last] = true
				end
				-- Children, in the order of their markers in what they hang from.
				local by: { [string]: { any } } = {}
				local texts: { [string]: any } = {}
				for id in here do
					local p = parent[id]
					local holder = if p == ZERO then owner else p
					local t = texts[holder]
					if t == nil then
						t = client:held_text(holder, b.slot) or false
						texts[holder] = t
					end
					local l, off = nil, 0
					if marker[id] == "" then
						l = math.huge
					elseif t then
						l, off = text.position(t, marker[id])
					end
					if l then
						by[p] = by[p] or {}
						table.insert(by[p], { id = id, at = l, off = off })
					end
				end
				for id in up do
					tree_up[id] = nil
				end
				kids, up, sits = {}, {}, {}
				for p, items in by do
					table.sort(items, function(x: any, y: any): boolean
						if x.at ~= y.at then
							return x.at < y.at
						elseif x.off ~= y.off then
							return x.off < y.off
						end
						return x.id < y.id
					end)
					local ids2 = {}
					for i, it in items do
						ids2[i] = it.id
						up[it.id] = p
						tree_up[it.id] = p
						sits[it.id] = marker[it.id]
					end
					kids[p] = ids2
				end
			end
			local levels = if st then st.levels else {}
			local fresh_levels = {}
			local function level(under: string): any
				local parts = {}
				for i, id in kids[under] or {} do
					local was0 = tnodes[id]
					if not structural and was0 and not dirty_node[id] then
						parts[i] = was0.out -- nothing in it, nor beneath it, has changed
						continue
					end
					local node = build_map(b.of, id)
					local children = level(id)
					local was = tnodes[id]
					if was and rawequal(was.node, node) and rawequal(was.out.children, children) then
						parts[i] = was.out
					else
						local out = table.clone(node)
						out.children = children
						table.freeze(out)
						tnodes[id] = { node = node, out = out }
						parts[i] = out
					end
				end
				local prev = levels[under]
				local out = if same_list(prev, parts) then prev else table.freeze(parts)
				fresh_levels[under] = out
				return out
			end
			-- Levels not reached again are as they were.
			if not structural then
				for under, l in levels do
					fresh_levels[under] = l
				end
			end
			local out = level(ZERO)
			boxes[key] = { out = out, kids = kids, up = up, sits = sits, lost = lost, levels = fresh_levels, slot = b.slot, tree = true }
			losing[key] = if next(lost) ~= nil then true else nil
			return out
		end
	end

	local function read(): any
		absorb()
		-- What is not reached now stays to be read when it is.
		standing[derive("")] = true
		return build_map(schema, derive(""))
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

	local window = if held
		then nil
		else client:window({ scope = scope, list = list, table = WINDOW, size = 0, from = "start", bare = true }, function()
			refresh()
		end)
	local unfollow = client:follow(function(id: string)
		if not stopped and ours(id) then
			dirty_rows[id] = true
		end
	end)
	for _, e in if window then window.entries() else {} do
		dirty_rows[e.row.id] = true
	end
	refresh()

	-- ------------------------------------------------ writing

	-- A column that writes what it is given as it is: an empty value is no value.
	local raws: { [number]: Column } = {}
	local function raw(slot: number): Column
		local c = raws[slot]
		if not c then
			c = table.freeze({ slot = slot, text = false, is = "raw", encode = same, decode = same, who = nil })
			raws[slot] = c
		end
		return c :: any
	end

	local writing: { [Schema]: { [string]: Column } } = {}
	local function writing_of(s: Schema): { [string]: Column }
		local w = writing[s]
		if not w then
			w = { [W] = WHERE_COLUMN }
			for name, c in s.columns do
				if not c.who then
					w[name] = c
					w["\1" .. name] = raw(c.slot)
				end
			end
			writing[s] = w
		end
		return w :: any
	end

	local function set(state: any)
		assert(not held, "what is asked about is read, not written")
		assert(not stopped, "the document is closed")
		assert(client:may(scope, "write"), "this client may not write there, or does not know yet that it may")
		refresh()
		client:write(scope, function(change)
			-- A row and everything in it, wherever that is, shown or not.
			local deleting: { [string]: boolean } = {}
			local spared: { [string]: boolean } = {} -- nodes the new state has, wherever they hung before
			local function delete_row(id: string)
				if deleting[id] or spared[id] then
					return
				end
				deleting[id] = true
				change.delete(id)
				for k in owned[id] or {} :: any do
					for m in members[k] or {} :: any do
						delete_row(m)
					end
				end
				for m in hangs[id] or {} :: any do
					delete_row(m) -- and what hangs from it, as a node of a tree
				end
			end
			local function delete_derived(id: string, s: Schema)
				if client:held(id) then
					delete_row(id)
				end
				for name, b in s.boxes do
					if b.kind == "map" then
						delete_derived(derive(id, name), b)
					end
				end
			end

			local write_map: any

			local function write_value(of: any, old: any, new: any, id: string, made: boolean, where: string?)
				if of.kind then
					write_map(of, old, new, id, made, where)
					return
				end
				local values: { [string]: any } = {}
				if not alike(new, old) or made then
					if new == nil then
						values.e = ""
					else
						values.v = new
					end
				end
				if where then
					values[W] = where
				end
				if next(values) then
					change.set(id, { [W] = WHERE_COLUMN, v = of, e = raw(of.slot) }, values)
				end
			end

			local function make(of: any, value: any, where: string): string
				if of.kind then
					local id = change.insert(writing_of(of), list, 0, { [W] = where })
					write_map(of, nil, value, id, true)
					return id
				end
				return change.insert({ [W] = WHERE_COLUMN, v = of }, list, 0, { [W] = where, v = value })
			end

			local write_box: any

			write_map = function(s: Schema, old: any, new: any, id: string, made: boolean, where: string?)
				if rawequal(old, new) and not made and not where and not plain then
					return -- the very table that was read: nothing in it has changed
				end
				new = new or {}
				local values: { [string]: any } = {}
				if where then
					values[W] = where
				end
				for name, c in s.columns do
					local nv, ov = new[name], if old then old[name] else nil
					if c.who then
						continue
					elseif c.text and not made and (nv == nil or type(nv) == "string") then
						-- As edits, so that what others type meanwhile is kept. A text left out is empty, as it reads.
						nv = nv or ""
						if nv ~= (ov or "") then
							change.edit(id, c.slot, function(t, fresh)
								local was = text.read(t)
								local a, z = 0, 0
								while a < #was and a < #nv and string.byte(was, a + 1) == string.byte(nv, a + 1) do
									a += 1
								end
								while z < #was - a and z < #nv - a and string.byte(was, #was - z) == string.byte(nv, #nv - z) do
									z += 1
								end
								if #was - a - z > 0 then
									text.delete(t, a, #was - a - z, fresh)
								end
								if #nv - a - z > 0 then
									text.insert(t, a, string.sub(nv, a + 1, #nv - z), fresh)
								end
							end)
						end
					elseif not alike(nv, ov) or made then
						if nv ~= nil then
							values[name] = nv
						elseif ov ~= nil or (made and old ~= nil) then
							values["\1" .. name] = ""
						end
					end
				end
				if next(values) then
					change.set(id, writing_of(s), values)
				end
				for name, b in s.boxes do
					write_box(b, if old then old[name] else nil, new[name], id, name)
				end
			end

			write_box = function(b: Schema, old: any, new: any, owner: string, field: string)
				if rawequal(old, new) and old ~= nil and not plain then
					return
				end
				local key = key_of(owner, field)
				local st = boxes[key] or {}
				if b.kind == "map" then
					local id = derive(owner, field)
					local exists = alive(id) ~= nil and wheres[id] ~= nil
					if not exists then
						change.set(id, writing_of(b), { [W] = where_encode(owner, field, MAP) })
						change.place(id, list, 0)
					end
					write_map(b, old, new, id, not exists)
				elseif b.kind == "list" and b.of.kind then
					new = new or {}
					local old_ids: { string } = st.ids or {}
					local oldl: { any } = (old or {}) :: any
					local dups = st.dups or {}
					local shared = next(dups) ~= nil
					-- What is the same at either end stays where it is, and is only written if it changed; what is
					-- between is compared, and only what moved there moves.
					local function same_at(n: number, o: number): boolean
						local item = new[n]
						return rawequal(item, oldl[o]) or (type(item) == "table" and item.id ~= nil and item.id == old_ids[o])
					end
					-- The very same tables first, which is most of them when a state is built from the last.
					local a, z = 0, 0
					local nn, no = #new, #old_ids
					local least = if shared or plain then 0 else math.min(nn, no)
					while a < least and rawequal(new[a + 1], oldl[a + 1]) do
						a += 1
					end
					while a < least and same_at(a + 1, a + 1) do
						a += 1
						while a < least and rawequal(new[a + 1], oldl[a + 1]) do
							a += 1
						end
					end
					while z < least - a and rawequal(new[nn - z], oldl[no - z]) do
						z += 1
					end
					while z < least - a and same_at(nn - z, no - z) do
						z += 1
						while z < least - a and rawequal(new[nn - z], oldl[no - z]) do
							z += 1
						end
					end
					for k = 1, a do
						if not rawequal(new[k], oldl[k]) then
							write_map(b.of, oldl[k], new[k], old_ids[k], false)
						end
					end
					for k = 0, z - 1 do
						local n, o = #new - k, #old_ids - k
						if not rawequal(new[n], oldl[o]) then
							write_map(b.of, oldl[o], new[n], old_ids[o], false)
						end
					end
					-- One moved from one end of what is between to the other: it alone moves.
					local mid_old, mid_new = #old_ids - z - a, #new - z - a
					if mid_old == mid_new and mid_old >= 2 and next(garbage[key] or {}) == nil and not shared and not plain then
						local first = same_at(a + mid_new, a + 1) -- the first went last
						local last = same_at(a + 1, a + mid_old) -- the last went first
						for k = 1, mid_old - 1 do
							if not (first and same_at(a + k, a + k + 1)) then
								first = false
							end
							if not (last and same_at(a + k + 1, a + k)) then
								last = false
							end
							if not first and not last then
								break
							end
						end
						if first or last then
							local o = if first then a + 1 else a + mid_old
							local n = if first then a + mid_new else a + 1
							local id = old_ids[o]
							local marker = ""
							change.edit(owner, b.slot, function(t, fresh)
								text.remove(t, wheres[id].marker, 1, fresh)
								local after = if first then wheres[old_ids[a + mid_old]].marker elseif a > 0 then wheres[old_ids[a]].marker else ""
								marker = text.after(t, after, MARK, fresh)
							end)
							write_map(b.of, oldl[o], new[n], id, false, where_encode(owner, field, ITEM, marker))
							for k = 1, mid_old - 1 do
								local nk, oo = if first then a + k else a + k + 1, if first then a + k + 1 else a + k
								if not rawequal(new[nk], oldl[oo]) then
									write_map(b.of, oldl[oo], new[nk], old_ids[oo], false)
								end
							end
							return
						end
					end
					local was: { [string]: any } = {}
					local before: { [string]: number } = {}
					for o = a + 1, #old_ids - z do
						local id = old_ids[o]
						was[id] = oldl[o]
						if not dups[id] then
							before[id] = o
						end
					end
					local seq: { string } = {}
					local kept: { [string]: boolean } = {}
					for n = a + 1, #new - z do
						local id = new[n].id
						if id and was[id] ~= nil and not kept[id] then
							kept[id] = true
							table.insert(seq, id)
						else
							table.insert(seq, `\1{n}`)
						end
					end
					local dirt = next(garbage[key] or {}) ~= nil
					if #seq == 0 and #old_ids - z == a and not dirt then
						return -- nothing between
					end
					local stay = staying(seq, before)
					local markers: { [string]: string } = {}
					change.edit(owner, b.slot, function(t, fresh)
						-- What is no longer, or is to move, gives up its marker; and markers nothing has are let go.
						for mid in garbage[key] or {} :: any do
							if text.has(t, mid) then
								text.remove(t, mid, 1, fresh)
							end
						end
						garbage[key] = nil
						for id in was do
							if not kept[id] then
								text.remove(t, wheres[id].marker, 1, fresh)
							end
						end
						for k, id in seq do
							if not stay[k] and was[id] ~= nil then
								text.remove(t, wheres[id].marker, 1, fresh)
							end
						end
						local prev = if a > 0 then wheres[old_ids[a]].marker else ""
						local k = 1
						while k <= #seq do
							if stay[k] then
								prev = wheres[seq[k]].marker
								k += 1
							else
								local j = k
								while j <= #seq and not stay[j] do
									j += 1
								end
								local first = text.after(t, prev, string.rep(MARK, j - k), fresh)
								for m = k, j - 1 do
									markers[seq[m]] = next_marker(first, m - k)
								end
								prev = markers[seq[j - 1]]
								k = j
							end
						end
					end)
					for id in was do
						if not kept[id] then
							delete_row(id)
						end
					end
					for k, id in seq do
						local item = new[a + k]
						local where = if markers[id] then where_encode(owner, field, ITEM, markers[id]) else nil
						if was[id] == nil then
							make(b.of, item, where :: string)
						else
							write_map(b.of, was[id], item, id, false, where)
						end
					end
				elseif b.kind == "list" then
					new = (new or {}) :: any
					old = (old or {}) :: any
					local frames: { Frame } = st.frames or {}
					local a, z = 0, 0
					while a < #old and a < #new and alike(old[a + 1], new[a + 1]) do
						a += 1
					end
					while z < #old - a and z < #new - a and alike(old[#old - z], new[#new - z]) do
						z += 1
					end
					change.edit(owner, b.slot, function(t, fresh)
						for _, id in st.junk or {} do
							text.remove(t, id, 1, fresh)
						end
						for k = a + 1, #old - z do
							local f = frames[k]
							if f.scattered then
								for _, id in f.scattered do
									text.remove(t, id, 1, fresh)
								end
							else
								text.remove(t, f.first, f.count, fresh)
							end
						end
						if #new - a - z > 0 then
							local parts = {}
							for k = a + 1, #new - z do
								table.insert(parts, frame(b.of, new[k]))
							end
							local prev = if a > 0 then frames[a].last else ""
							text.after(t, prev, table.concat(parts), fresh)
						end
					end)
				elseif b.kind == "record" then
					new = (new or {}) :: any
					old = (old or {}) :: any
					local keys = st.keys or {}
					for k, id in keys do
						if new[k] == nil then
							-- Gone, and what it held with it, so that it takes no room and comes back as it is set.
							write_value(b.of, old[k], if b.of.kind then {} else nil, id, false, where_encode(owner, field, ENTRY, "\0" .. k))
						end
					end
					for k, v in new do
						assert(type(k) == "string", "a record's keys are strings")
						local id = derive(owner, field, k)
						if keys[k] then
							write_value(b.of, old[k], v, id, false)
						else
							local held = alive(id) ~= nil
							if not held then
								change.place(id, list, 0)
							end
							-- What it held before, if it was once, is written over.
							local stale = if held then build_value(b.of, id) else nil
							write_value(b.of, stale, v, id, true, where_encode(owner, field, ENTRY, "\1" .. k))
						end
					end
				else
					-- A tree: every node where the new one has it, those not in it gone with all in them, and new ones made.
					new = new or {}
					local kids: { [string]: { string } } = st.kids or {}
					local up: { [string]: string } = st.up or {}
					local sits: { [string]: string } = st.sits or {}
					local was: { [string]: any } = {}
					local function walk(level: any)
						for _, n in level or {} do
							was[n.id] = n
							walk(n.children)
						end
					end
					walk(old)
					local kept: { [string]: boolean } = {}
					local function mark(level: any)
						for _, n in level or {} do
							if type(n) == "table" and n.id and was[n.id] and not kept[n.id] then
								kept[n.id] = true
							end
							if type(n) == "table" then
								mark(n.children)
							end
						end
					end
					mark(new)
					for id in kept do
						spared[id] = true
					end
					local gone: { [string]: { string } } = {} -- markers to let go, by the row whose order they are in
					local function let_go(parent: string, marker: string)
						local row = if parent == ZERO then owner else parent
						gone[row] = gone[row] or {}
						table.insert(gone[row], marker)
					end
					for id in members[key] or {} :: any do
						local w = wheres[id]
						if not kept[id] and w and (was[id] or dead_rows[w.parent]) then
							if up[id] and sits[id] ~= "" and alive(if up[id] == ZERO then owner else up[id]) then
								let_go(up[id], sits[id])
							end
							delete_row(id)
						end
					end
					-- Where each kept node is to be, to see which move.
					local target: { [string]: string } = {}
					local function aim(level: any, parent: string)
						for _, n in level or {} do
							if kept[n.id] then
								target[n.id] = parent
							end
							aim(n.children, if kept[n.id] then n.id else "\1")
						end
					end
					aim(new, ZERO)
					for id, p in target do
						if up[id] ~= nil and up[id] ~= p and sits[id] and sits[id] ~= "" then
							let_go(up[id], sits[id])
						end
					end
					local placed: { [string]: boolean } = {}
					local function place(level: any, parent: string)
						local row = if parent == ZERO then owner else parent
						local seq: { string } = {}
						local before: { [string]: number } = {}
						local siblings = kids[parent] or {}
						for i, id in siblings do
							-- One without a marker of its own, or sharing one, is given one.
							if sits[id] ~= "" and not (i > 1 and sits[siblings[i - 1]] == sits[id]) then
								before[id] = i
							end
						end
						for i, n in level or {} do
							if n.id and kept[n.id] and not placed[n.id] then
								placed[n.id] = true
								seq[i] = n.id
							else
								seq[i] = `\1{i}`
							end
						end
						local same = not plain and gone[row] == nil and #seq == #siblings
						for i, id in seq do
							same = same and before[id] == i
						end
						local stay = if same then {} else staying(seq, before)
						local markers: { [string]: string } = {}
						if not same then
						change.edit(row, b.slot, function(t, fresh)
							for _, m in gone[row] or {} do
								text.remove(t, m, 1, fresh)
							end
							gone[row] = nil
							for i, id in seq do
								if not stay[i] and before[id] then
									text.remove(t, sits[id], 1, fresh)
								end
							end
							local prev = ""
							local i = 1
							while i <= #seq do
								if stay[i] then
									prev = sits[seq[i]]
									i += 1
								else
									local j = i
									while j <= #seq and not stay[j] do
										j += 1
									end
									local first = text.after(t, prev, string.rep(MARK, j - i), fresh)
									for k = i, j - 1 do
										markers[seq[k]] = next_marker(first, k - i)
									end
									prev = markers[seq[j - 1]]
									i = j
								end
							end
						end)
						end
						for i, id in seq do
							local n = level[i]
							local marker = markers[id]
							if was[id] == nil then
								local made = make(b.of, n, where_encode(owner, field, NODE, parent .. (marker :: string) .. ZERO .. NOWHERE))
								place(n.children, made)
							else
								local where = nil
								local w = wheres[id]
								if not marker and w and (w.parent ~= parent or w.marker ~= sits[id]) then
									-- It shows where it does because a move of it was undone: it is written there, so
									-- that it stays there whatever becomes of where it was moved to.
									where = where_encode(owner, field, NODE, parent .. sits[id] .. ZERO .. NOWHERE)
								end
								if marker then
									-- Where it came from goes with it: should this make a loop, it goes back.
									local back = if up[id] and sits[id] ~= "" then sits[id] else NOWHERE
									where = where_encode(owner, field, NODE, parent .. marker .. (up[id] or ZERO) .. back)
								end
								write_map(b.of, was[id], n, id, false, where)
								place(n.children, id)
							end
						end
					end
					place(new, ZERO)
					for row, markers in gone do
						if alive(row) then
							change.edit(row, b.slot, function(t, fresh)
								for _, m in markers do
									text.remove(t, m, 1, fresh)
								end
							end)
						end
					end
				end
			end

			local root = derive("")
			local exists = alive(root) ~= nil and wheres[root] ~= nil
			if not exists then
				change.set(root, writing_of(schema), { [W] = where_encode(ZERO, "", MAP) })
				change.place(root, list, 0)
			end
			-- What is in the document is there whether its own row is or not, so what is written is what differs from that.
			write_map(schema, current, state, root, not exists)
			-- What others put in keys that were being let go of meanwhile goes too; but not a map within it, which
			-- is that key's for ever, and only emptied.
			local function empty(id: string)
				for k in owned[id] or {} :: any do
					for m in members[k] or {} :: any do
						local w = wheres[m]
						if w and w.kind == MAP then
							empty(m)
						else
							delete_row(m)
						end
					end
				end
			end
			for id in emptied do
				empty(id)
			end
			-- What others put in rows that were being deleted meanwhile is let go of too.
			for id in dead_rows do
				for k in owned[id] or {} :: any do
					for m in members[k] or {} :: any do
						delete_row(m)
					end
				end
				for m in hangs[id] or {} :: any do
					delete_row(m)
				end
			end
			-- And what is beneath a deleted node only where loops are undone, which shows nowhere and never will. What is
			-- beneath a node that has not come yet waits for it.
			for key in losing do
				local st = boxes[key]
				for id, missing in if st and st.lost then st.lost else {} do
					if dead_rows[missing] then
						delete_row(id)
					end
				end
			end
		end)
		refresh()
	end

	-- ------------------------------------------------ drafts

	-- A draft is the state as it is, until something in it is changed: then that, and what leads to it, is copied.
	-- So what was not changed is the very same table, and costs nothing to write.
	-- Each draft keeps, under keys no one else has, what it is a draft of and what has been done to it: in itself, not in tables
	-- on the side, which would cost a lookup each time and the collector a weak table of every draft.
	local ORIGIN, WRITTEN = {}, {}
	local thawed: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
	local metas: { [Schema]: { [any]: any } } = {}
	local drafted: { [any]: boolean } = {}
	local thaw: any
	-- One empty table to each map of the state that is looked at, and nothing more until it is changed.
	local function meta(s: Schema, tree: Schema?): any
		local by = metas[s]
		if not by then
			by = {}
			metas[s] = by
		end
		local k = tree or false
		local mt = by[k]
		if mt then
			return mt
		end
		mt = {}
		mt.__index = function(p: any, key: any): any
			local w: any = rawget(p, WRITTEN)
			local x = if w then w[key] else nil
			if x ~= nil then
				return if x == NIL then nil else x
			end
			local o: any = rawget(p, ORIGIN)
			local v = if o then o[key] else nil
			local b = s.boxes[key] or (if key == "children" then tree else nil)
			if b then
				local t = thaw(b, v)
				if not w then
					w = {}
					rawset(p, WRITTEN, w)
				end
				w[key] = if t == nil then NIL else t
				return t
			end
			return v
		end
		mt.__newindex = function(p: any, key: any, v: any)
			local w: any = rawget(p, WRITTEN)
			if not w then
				w = {}
				rawset(p, WRITTEN, w)
			end
			w[key] = if v == nil then NIL else v
		end
		mt.__iter = function(p: any)
			local all = {}
			for key in rawget(p, ORIGIN) or {} do
				all[key] = p[key]
			end
			for key, x in rawget(p, WRITTEN) or {} do
				all[key] = if x == NIL then nil else x
			end
			return next, all
		end
		by[k] = mt
		drafted[mt] = true
		return mt
	end
	local function draft_map(s: Schema, orig: any, tree: Schema?): any
		return setmetatable({ [ORIGIN] = orig }, meta(s, tree))
	end
	thaw = function(b: Schema, v: any): any
		if v == nil then
			return nil
		end
		local out: any
		if b.kind == "map" then
			return draft_map(b, v)
		elseif b.kind == "list" then
			if not b.of.kind then
				out = table.clone(v)
			else
				local mt = meta(b.of)
				out = table.create(#v)
				for i, x in v do
					out[i] = setmetatable({ [ORIGIN] = x }, mt)
				end
			end
		elseif b.kind == "record" then
			out = {}
			if b.of.kind then
				local mt = meta(b.of)
				for k, x in v do
					out[k] = setmetatable({ [ORIGIN] = x }, mt)
				end
			else
				for k, x in v do
					out[k] = x
				end
			end
		else
			local mt = meta(b.of, b)
			out = table.create(#v)
			for i, x in v do
				out[i] = setmetatable({ [ORIGIN] = x }, mt)
			end
		end
		thawed[out] = v
		return out
	end

	local finish: any
	local function finish_map(v: any, s: Schema, tree: Schema?): any
		if type(v) ~= "table" or not drafted[getmetatable(v) :: any] then
			-- Made anew; but what is in it may be drafts, moved there.
			if type(v) ~= "table" then
				return v
			end
			local out = table.clone(v)
			for name, b in s.boxes do
				if out[name] ~= nil then
					out[name] = finish(out[name], b)
				end
			end
			if tree and out.children ~= nil then
				out.children = finish(out.children, tree)
			end
			return out
		end
		local orig: any = rawget(v, ORIGIN)
		local writes: any = rawget(v, WRITTEN)
		if writes == nil then
			return orig
		end
		local out: { [string]: any } = { id = if orig then orig.id else nil }
		for _, name in s.names do
			local w = writes[name]
			if w == nil then
				out[name] = if orig then orig[name] else nil
			elseif w ~= NIL then
				out[name] = if s.boxes[name] then finish(w, s.boxes[name]) else w
			end
		end
		if tree then
			local w = writes.children
			if w == nil then
				out.children = if orig then orig.children else nil
			elseif w ~= NIL then
				out.children = finish(w, tree)
			end
		end
		return out
	end
	finish = function(v: any, b: Schema): any
		if b.kind == "map" then
			return finish_map(v, b)
		end
		if type(v) ~= "table" then
			return v
		end
		local out = {}
		local whole = true
		local orig = thawed[v]
		if not b.of.kind then
			for k, x in v do
				out[k] = x
				whole = whole and orig ~= nil and rawequal(orig[k], x)
			end
		else
			-- A draft of a map no one changed is what it is a draft of: seen to here, without a call.
			local mt = meta(b.of, if b.kind == "tree" then b else nil)
			local tree = if b.kind == "tree" then b else nil
			for k, x in v do
				local y
				if getmetatable(x) == mt and rawget(x, WRITTEN) == nil then
					y = rawget(x, ORIGIN)
				else
					y = finish_map(x, b.of, tree)
				end
				out[k] = y
				whole = whole and orig ~= nil and rawequal(orig[k], y)
			end
		end
		if whole and orig then
			for k in orig do
				if out[k] == nil then
					whole = false
					break
				end
			end
		end
		return if whole then orig else out
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
			-- From the state as it is now, with all that has come read: a draft of an older one would write it back.
			assert(not held, "what is asked about is read, not written")
			assert(not stopped, "the document is closed")
			refresh()
			local d = draft_map(schema, current)
			f(d)
			set(finish_map(d, schema))
		end,
		stop = function()
			stopped = true
			unfollow()
			if window then
				window.stop()
			end
		end,
		-- For mirror.ask: read again what has changed among the rows held; the ids that are the same for everyone.
		_refresh = refresh,
		_derive = derive,
		_mark = function(id: string)
			dirty_rows[id] = true
		end,
	})
end

-- ---------------------------------------------------------------- asking

-- The list, record or tree at a path: names of fields; a record's key or an item's or node's id after the name of what
-- holds it. As { "tasks" }, { "people", "ann", "pets" }, { "tasks", id, "subtasks" }.
type Place = {
	owner: string, -- the row that holds it
	field: string,
	box: Schema,
	chain: { string }, -- the rows on the way to it, the document's first
	trees: { { owner: string, field: string } }, -- trees on the way, or it, all of whose nodes are needed to know which are there
}

local function place_of(schema: Schema, path: { string }, derive: (...string) -> string): Place
	assert(#path > 0, "a path names what is asked about")
	local s, owner = schema, derive("")
	local chain, trees = { owner }, {}
	local i = 1
	while true do
		local name = path[i]
		local b = s.boxes[name]
		assert(type(name) == "string" and b, `there is no {tostring(name)} to ask about`)
		if b.kind == "map" then
			assert(i < #path, "a map is not asked about, but what is in it")
			owner = derive(owner, name)
			table.insert(chain, owner)
			s = b
			i += 1
		elseif i == #path then
			assert(b.of.kind or b.kind == "record", "a list of values is in one row: it is read, not asked about")
			if b.kind == "tree" then
				table.insert(trees, { owner = owner, field = name })
			end
			return { owner = owner, field = name, box = b, chain = chain, trees = trees }
		else
			assert(b.of.kind == "map", `what is in {name} holds nothing`)
			local k = path[i + 1]
			assert(type(k) == "string", `{name} is followed by a key or an id`)
			local id = if b.kind == "record" then derive(owner, name, k) else k
			if b.kind == "tree" then
				table.insert(trees, { owner = owner, field = name })
			end
			table.insert(chain, id)
			owner = id
			s = b.of
			i += 2
		end
	end
end

-- What a path comes to in a state: the list, record or tree, if it is there.
local function at_path(schema: Schema, state: any, path: { string }): any
	local s, v = schema, state
	local i = 1
	local function find(level: any, id: string): any
		for _, n in level or {} do
			if n.id == id then
				return n
			end
			local inside = if n.children then find(n.children, id) else nil
			if inside then
				return inside
			end
		end
		return nil
	end
	while v ~= nil and i <= #path do
		local name = path[i]
		local b = s.boxes[name]
		v = v[name]
		if b.kind == "map" then
			s = b
			i += 1
		elseif i == #path then
			return v
		else
			local k = path[i + 1]
			v = if v == nil then nil elseif b.kind == "record" then v[k] else find(v, k)
			s = b.of
			i += 2
		end
	end
	return v
end

local BYTES_COLUMN: Column = table.freeze({ slot = WHERE, text = false, is = "bytes", encode = same, decode = same, who = nil })

-- Whether what is under a name is of rows of its own, which are asked about by their path rather than given with what holds them.
local function of_rows(b: Schema): boolean
	return b.kind == "record" or b.kind == "tree" or (b.kind == "list" and b.of.kind ~= nil)
end

-- The ids of the maps within a map, and within those, made from its id.
local function maps_within(s: Schema, id: string, derive: (...string) -> string, into: { string })
	for name, b in s.boxes do
		if b.kind == "map" then
			local inner = derive(id, name)
			table.insert(into, inner)
			maps_within(b, inner, derive, into)
		end
	end
end
local KIND_OF = { list = ITEM, record = ENTRY, tree = NODE }

export type Asking = {
	read where: any?, -- conditions on the columns of what is asked about, by their names: zsp.where
	read order: { string }?,
	read offset: number?,
	read limit: number?,
	read from_end: boolean?,
	read totals: { [string]: any }?,
}

-- What is in a list, record or tree of a document, as a node finds it: the rows that answer, as the maps (or values) the
-- document shows, in the order asked for, and kept up as they change. Nothing needs to be open, nor is anything more held
-- than the rows on the way and those that answer. A list's items are found by what their rows say they are in; whether
-- they are, the rows on the way say, as they do when the document is open: what a node finds that the document would not
-- show (rows written by one who minds nothing, or in what was deleted and not yet let go of) is not given, though a node
-- counts it in `total` and `totals`. For a record, `keys` says whose each is.
function mirror.ask(
	client: any,
	options: { scope: number, name: string, schema: Schema },
	path: { string },
	asking: Asking,
	observer: (any) -> ()
)
	local scope, schema = options.scope, options.schema
	local list = "mirror/" .. options.name
	local doc: any = mirror.open(client, { scope = scope, name = options.name, schema = schema, _held = true })
	local stopped = false
	-- What is given of a map: what is in its own row and its maps, its children if it is a node; not its lists, records
	-- and trees of rows. The same table for the same map.
	local given: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
	local function give(s: Schema, v: any, tree: Schema?): any
		if type(v) ~= "table" then
			return v
		end
		local out = given[v]
		if out then
			return out
		end
		out = {}
		for k, x in v do
			local b = s.boxes[k]
			if k == "children" and tree then
				local kids = {}
				for i, n in x do
					kids[i] = give(tree.of, n, tree)
				end
				out.children = table.freeze(kids)
			elseif b and b.kind == "map" then
				out[k] = give(b, x)
			elseif not (b and of_rows(b)) then
				out[k] = x
			end
		end
		table.freeze(out)
		given[v] = out
		return out
	end
	local questions: { any } = {} -- what is asked, to be stopped
	local answers: { [string]: any } = {} -- the latest of each: the rows that answer, the rows on the way, all of a tree's
	local place: Place? = nil
	local last: any = nil
	local was_named: { [string]: boolean } = {}

	local function tell()
		if stopped or not place then
			return
		end
		local p = place :: Place
		-- What the answers name is read again, come or gone: a row held already is not necessarily sent again.
		local named: { [string]: boolean } = {}
		for _, a in answers do
			for _, r in a.rows do
				named[r.id] = true
				doc._mark(r.id)
			end
		end
		for id in was_named do
			if not named[id] then
				doc._mark(id)
			end
		end
		was_named = named
		doc._refresh()
		local found = answers.found
		local status = if found then found.status else "loading"
		for name, a in answers do
			if a.status ~= "ready" and status == "ready" then
				status = if a.status == "denied" or a.status == "faulty" then a.status else "loading"
			end
			local _ = name
		end
		-- What the document shows there, by row id.
		local shown: { [string]: any } = {}
		local key_of: { [string]: string } = {}
		local box = at_path(schema, doc.state(), path)
		if p.box.kind == "record" then
			for k, v in box or {} do
				local id = doc._derive(p.owner, p.field, k)
				shown[id] = v
				key_of[id] = k
			end
		else
			local function walk(level: any)
				for _, n in level or {} do
					shown[n.id] = n
					if n.children then
						walk(n.children)
					end
				end
			end
			walk(box)
		end
		local rows: { any }, keys: { string } = {}, {}
		local of = p.box.of
		for _, r in if found then found.rows else {} do
			local v = shown[r.id]
			if v ~= nil then
				table.insert(rows, if of.kind then give(of, v, if p.box.kind == "tree" then p.box else nil) else v)
				if key_of[r.id] then
					table.insert(keys, key_of[r.id])
				end
			end
		end
		local answer = table.freeze({
			rows = table.freeze(rows),
			keys = if p.box.kind == "record" then table.freeze(keys) else nil,
			status = status,
			total = if found then found.total else 0,
			first = if found then found.first else 0,
			totals = if found then found.totals else {},
		})
		if last and last.status == answer.status and last.total == answer.total and last.first == answer.first and rawequal(last.totals, answer.totals) and #last.rows == #rows then
			local same = true
			for i, v in rows do
				same = same and rawequal(last.rows[i], v) and (not last.keys or last.keys[i] == keys[i])
			end
			if same then
				return
			end
		end
		last = answer
		observer(answer)
	end

	local function prefix(owner: string, field: string, kind: number): string
		local w = codec.writer()
		codec.put(w, owner)
		codec.put_bytes(w, field)
		codec.put_u8(w, kind)
		return codec.string(w)
	end

	-- Rows asked for by id, a thousand to a question, asked again only when they change.
	local by_id: { any } = {}
	local by_id_of: { string } = {}
	local function within_maps(ids: { string })
		table.sort(ids)
		local now = table.concat(ids)
		if now == table.concat(by_id_of) then
			return
		end
		by_id_of = ids
		for _, q in by_id do
			q.stop()
		end
		by_id = {}
		for k in answers do
			if string.sub(k, 1, 5) == "maps " then
				answers[k] = nil
			end
		end
		for n = 1, math.ceil(#ids / 1000) do
			local part = table.move(ids, (n - 1) * 1000 + 1, math.min(#ids, n * 1000), 1, {})
			local q: any = client:ask({ scope = scope, table = { ["\0where"] = BYTES_COLUMN }, where = where.ids(part), limit = 1000 }, function(a: any)
				answers[`maps {n}`] = a
				tell()
			end)
			table.insert(by_id, q)
		end
	end
	-- The maps within each that answers, which are there whether their rows are or not, but say what they hold; and, in a
	-- tree, within every node, since a node is given with all beneath it.
	local function maps_of_given()
		local p = place
		if not p or not p.box.of.kind then
			return
		end
		local ids: { string } = {}
		for _, r in if answers.found then answers.found.rows else {} do
			maps_within(p.box.of, r.id, doc._derive, ids)
		end
		if p.box.kind == "tree" then
			local mine = `tree {#p.trees} `
			for name, a in answers do
				if string.sub(name, 1, #mine) == mine then
					for _, r in a.rows do
						maps_within(p.box.of, r.id, doc._derive, ids)
					end
				end
			end
		end
		within_maps(ids)
	end
	local found_handle: any = nil
	local moved: { offset: number, limit: number? }? = nil -- asked for before there was anything to move
	local function start(): boolean
		if place or stopped then
			return true
		end
		if not client.scopes[scope] then
			return false
		end
		local p = place_of(schema, path, doc._derive)
		place = p
		local b = p.box
		local columns: { [string]: any } = { ["\0where"] = BYTES_COLUMN }
		if b.of.kind then
			for name, c in b.of.columns do
				columns[name] = c
			end
		else
			columns.value = b.of
		end
		local within = prefix(p.owner, p.field, KIND_OF[b.kind]) .. (if b.kind == "record" then "\1" else "")
		local condition = where.all(where.in_list(list), where.begins("\0where", within), asking.where or where.all())
		found_handle = client:ask({
			scope = scope,
			table = columns,
			where = condition,
			order = asking.order,
			offset = asking.offset,
			limit = asking.limit,
			from_end = asking.from_end,
			totals = asking.totals,
		}, function(a: any)
			answers.found = a
			maps_of_given()
			tell()
		end)
		table.insert(questions, found_handle)
		if moved then
			found_handle.move(moved.offset, moved.limit)
		end
		-- The rows on the way: whether what answers is there is theirs to say.
		local on_the_way: any = client:ask({ scope = scope, table = { ["\0where"] = BYTES_COLUMN }, where = where.ids(p.chain), limit = 1000 }, function(a: any)
			answers.chain = a
			tell()
		end)
		table.insert(questions, on_the_way)
		-- Every node of a tree on the way: which are there, and where, is known only from all of them.
		for i, t in p.trees do
			local pages: { any } = {}
			local function page(n: number)
				pages[n] = true
				local q: any
				q = client:ask({
					scope = scope,
					table = { ["\0where"] = BYTES_COLUMN },
					where = where.all(where.in_list(list), where.begins("\0where", prefix(t.owner, t.field, NODE))),
					offset = (n - 1) * 1000,
					limit = 1000,
				}, function(a: any)
					answers[`tree {i} {n}`] = a
					local more = math.ceil(a.total / 1000)
					for k = n + 1, more do
						if not pages[k] then
							page(k)
						end
					end
					maps_of_given()
					tell()
				end)
				table.insert(questions, q)
			end
			page(1)
		end
		return true
	end

	-- Ids are made with the scope's key: what is on the way is known once that is.
	local waiting: { stop: (() -> ())? } = { stop = nil }
	if not start() then
		waiting.stop = client:on("status", function()
			local unwait = waiting.stop
			if start() and unwait then
				waiting.stop = nil
				unwait()
			end
		end)
	end
	observer(table.freeze({ rows = table.freeze({}), status = "loading", total = 0, first = 0, totals = {} }))

	return table.freeze({
		-- Another stretch of what answers.
		move = function(offset: number, limit: number?)
			if found_handle then
				found_handle.move(offset, limit)
			else
				moved = { offset = offset, limit = limit }
			end
		end,
		stop = function()
			if stopped then
				return
			end
			stopped = true
			local unwait = waiting.stop
			if unwait then
				waiting.stop = nil
				unwait()
			end
			for _, q in questions do
				q.stop()
			end
			for _, q in by_id do
				q.stop()
			end
			doc.stop()
		end,
	})
end

return table.freeze(mirror)
