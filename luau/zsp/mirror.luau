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
local cells = require("./client")
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

-- Each row's word on what it is in, as little as it says: only what its kind has, the rest as WHERE_NONE has it. Nothing
-- of the cell itself is kept, which is read again whenever the row changes.
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
	stamp: string, -- of a node: of the cell, the later of two moves that make a loop being undone
}
local WHERE_NONE = table.freeze({ marker = "", present = false, key = "", parent = ZERO, from = ZERO, back = "", stamp = "" })
local WHERE_META = table.freeze({ __index = WHERE_NONE })

local function where_encode(owner: string, field: string, kind: number, extra: string?): string
	local w = codec.writer()
	codec.put(w, owner)
	codec.put_bytes(w, field)
	codec.put_u8(w, kind)
	codec.put(w, extra or "")
	return codec.string(w)
end

-- What a cell in slot 255 says, from byte `at` of `c` on (the cell's body), or nil if it says nothing that can be read.
local function where_decode(c: string, at: number, stamp: string): Where?
	local n = #c
	if n < at + 17 then
		return nil
	end
	local owner = string.sub(c, at, at + 15)
	local p = at + 16
	local len, scale = 0, 1
	for k = 1, 11 do
		local b = string.byte(c, p)
		if not b or k == 11 then
			return nil -- no more, or a length of more than ten bytes
		end
		p += 1
		len += bit32.band(b, 127) * scale
		if b < 128 then
			break
		end
		scale *= 128
	end
	if len > 9007199254740991 or p + len > n then -- the field, and the kind after it
		return nil
	end
	local field = string.sub(c, p, p + len - 1)
	p += len
	local kind = string.byte(c, p)
	p += 1
	local rest = n - p + 1
	local out: any
	if kind == ITEM and rest == 12 then
		out = { owner = owner, field = field, kind = kind, marker = string.sub(c, p) }
	elseif kind == ENTRY and rest >= 1 then
		out = { owner = owner, field = field, kind = kind, present = string.byte(c, p) ~= 0, key = string.sub(c, p + 1) }
	elseif kind == NODE and rest == 56 then
		out = {
			owner = owner,
			field = field,
			kind = kind,
			parent = string.sub(c, p, p + 15),
			marker = string.sub(c, p + 16, p + 27),
			from = string.sub(c, p + 28, p + 43),
			back = string.sub(c, p + 44, p + 55),
			stamp = stamp,
		}
	elseif kind == MAP and rest == 0 then
		out = { owner = owner, field = field, kind = kind }
	else
		return nil
	end
	return (setmetatable :: any)(out, WHERE_META)
end

-- Whether two say the same: as their bodies would, but for how a writer chose to write a length; and, of a node, when it was
-- said, for of two moves that make a loop the later is undone.
local function same_where(a: Where, b: Where): boolean
	return a.kind == b.kind
		and (a.kind ~= NODE or a.stamp == b.stamp)
		and a.owner == b.owner
		and a.field == b.field
		and a.marker == b.marker
		and a.present == b.present
		and a.key == b.key
		and a.parent == b.parent
		and a.from == b.from
		and a.back == b.back
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
	-- The document's own is asked for at every read: it is made once, while the scope's key is the same. (A map within a
	-- map keeps its own with what is read of it.)
	local root_id, root_from = ZERO, ""
	local function derive(...: string): string
		local s = client.scopes[scope]
		if not s then
			return ZERO -- not yet known, or not to be read here: there is nothing, until there is
		end
		local parts = table.concat({ ... }, "\0")
		if parts == "" and root_from == s.key then
			return root_id
		end
		local id = string.pack(">I4I4", scope, 0) .. string.sub(sha256(s.key .. "zsp-mirror\0" .. options.name .. "\0" .. parts), 1, 8)
		if parts == "" then
			root_id, root_from = id, s.key
		end
		return id
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
	local versions: { [string]: { [number]: any } } = {} -- of each row, of each text in it that keeps an order, by slot, as last read
	local remade: { [string]: { [number]: boolean } } = {} -- of each row, texts of order made anew: what was in them may be gone
	local function set_version(id: string, slot: number, t: any)
		local of = versions[id]
		if not of then
			of = {}
			versions[id] = of
		end
		of[slot] = { t = t, v = if t then t.version else 0 }
	end
	-- Whether a text was made anew since it was last read: once, as it is read.
	local function was_remade(id: string, slot: number): boolean
		local of = remade[id]
		if not (of and of[slot]) then
			return false
		end
		of[slot] = nil
		if next(of) == nil then
			remade[id] = nil
		end
		return true
	end
	local seen: { [string]: number } = {} -- of each map row: the version of it last read
	-- The document, and maps within maps, are there for everyone whether their own rows have come or not: what is in
	-- them is. Whatever else holds anything holds it only while it is there itself.
	local standing: { [string]: boolean } = {}
	local dirty_rows: { [string]: boolean } = {}
	local moved_in: { [string]: { [string]: any } } = {} -- of each list: what came, went or moved, and from which marker
	local garbage: { [string]: { [string]: boolean } } = {} -- of each list: markers nothing has
	local dead_rows: { [string]: boolean } = {} -- seen to be deleted: what is in them is no longer anywhere
	local cleaning: { [string]: boolean } = {} -- of those, any that may still have something in them, to let go of
	local emptied: { [string]: boolean } = {} -- keys let go of: what is put in them meanwhile is not anywhere either
	local dirty_node: { [string]: boolean } = {}
	local dirty_box: { [string]: boolean } = {} -- true if what is in it or its order may have changed; false if only its members
	local nodes: { [string]: any } = {} -- maps, as last read, by id
	local boxes: { [string]: any } = {} -- lists, records and trees, as last read
	local tnodes: { [string]: any } = {} -- tree nodes with their children
	local current: any = nil
	local stopped = false
	local tag: string? = nil

	local rows_held: { [string]: any } = client.rows -- as the client holds them, read straight
	local function ours(id: string): boolean
		if wheres[id] ~= nil then
			return true
		end
		local row = rows_held[id]
		if not row then
			return false
		end
		if not tag then
			if not client.scopes[scope] then
				return false
			end
			tag = client:_tag(scope, list)
		end
		for slot, v in row do
			if type(slot) == "number" and slot >= 1 and slot <= 15 then
				if type(v) == "string" then
					if string.find(v, tag :: string, 18, true) == 18 then
						return true
					end
				else
					for _, c in v do
						if string.find(c, tag :: string, 18, true) == 18 then
							return true
						end
					end
				end
			end
		end
		return false
	end

	-- ------------------------------------------------ what has changed

	local mark_node: any
	local changed_in: { [string]: { [string]: boolean } } = {} -- of each list and record: members that changed
	local function mark_box(key: string, structural: boolean, member: string?)
		-- Of a box not read yet, everything is read when it is: only of one that has been is anything marked. Which members
		-- changed is read only by a list of maps or a record.
		local st = boxes[key]
		if st then
			if member and (st.ids or st.keys) then
				local set = changed_in[key]
				if not set then
					set = {}
					changed_in[key] = set
				end
				set[member] = true
			end
			if structural then
				dirty_box[key] = true
			elseif dirty_box[key] == nil then
				dirty_box[key] = false
			end
		end
		mark_node(string.sub(key, 1, 16))
	end
	local marked: { [string]: boolean } = {} -- in this pass: passed on to what it is in already
	mark_node = function(id: string)
		if id == ZERO or marked[id] then
			return
		end
		marked[id] = true
		if nodes[id] ~= nil or tnodes[id] ~= nil then
			dirty_node[id] = true -- of one not read yet, everything is read when it is
		end
		local up = tree_up[id]
		if up and up ~= ZERO then
			mark_node(up)
		end
		local w = wheres[id]
		local box = if w then w.owner .. w.field else nil
		if box then
			mark_box(box, false, id)
		end
		-- A map within a map is there whether its own row has come or not, and is where its id says.
		local within = standing_in[id]
		if within and within ~= box then
			mark_box(within, false, id)
		end
	end

	local latest = cells.latest
	local as_is, as_number = cells.same, cells.decode_number

	local function where_of(row: any): Where?
		local c = latest(row, WHERE)
		return if c then where_decode(c, 18, string.sub(c, 2, 17)) else nil
	end

	-- Whether a text that keeps an order has changed since it was last read.
	local function moved(id: string, slot: number): boolean
		local t = client:held_text(id, slot)
		local of = versions[id]
		local was = if of then of[slot] else nil
		if not was or was.t ~= t or was.v ~= (if t then t.version else 0) then
			if not was or was.t ~= t then
				-- A text made again is another, as when a value was written over it.
				local r = remade[id]
				if not r then
					r = {}
					remade[id] = r
				end
				r[slot] = true
			end
			set_version(id, slot, t)
			return true
		end
		return false
	end

	-- Where it was when the list was last read, to find it there: true if it was not in it then. Only of a list of maps
	-- that has been read: one that has not is read whole.
	local function moving(k: string, id: string, from: any)
		local st = boxes[k]
		if st and st.ids then
			local mv = moved_in[k]
			if not mv then
				mv = {}
				moved_in[k] = mv
			end
			if mv[id] == nil then
				mv[id] = from
			end
		end
	end

	-- What was read of a row that is in nothing any more, and gone, and of what was in it: none of it is shown, and should the
	-- row come again it is read anew. (What says what was in it is kept, for whoever writes next to let go of.)
	local function clear(t: { [string]: any }, k: string)
		if t[k] ~= nil then
			t[k] = nil
		end
	end
	local forget_map: (id: string, s: Schema) -> ()
	-- What was read of what is in a row, or a map within one, by its schema: its lists, records, trees and maps.
	local function forget_boxes(id: string, s: Schema)
		for name, b in s.boxes do
			local k = key_of(id, name)
			for _, t in { boxes, dirty_box, changed_in, moved_in, losing, garbage } :: { { [string]: any } } do
				clear(t, k)
			end
			if b.kind == "map" then
				forget_map(derive(id, name), b)
			end
		end
	end
	local function forget_read(id: string)
		for _, t in { nodes, schema_of, seen, tnodes, dirty_node, tree_up, versions, remade } :: { { [string]: any } } do
			clear(t, id)
		end
	end
	-- A map within a map of what is gone, which is there only while that is: whether its own row has come or not.
	forget_map = function(id: string, s: Schema)
		if standing[id] then
			clear(standing, id)
			clear(standing_in, id)
			forget_read(id)
			forget_boxes(id, s)
		end
	end
	local function forget(id: string, old: Where)
		local s = schema_of[id]
		forget_read(id)
		if s then
			forget_boxes(id, s)
		end
		for k in owned[id] or {} :: any do
			for _, t in { boxes, dirty_box, changed_in, moved_in, losing, garbage } :: { { [string]: any } } do
				clear(t, k)
			end
		end
	end
	-- What is deleted needs, once nothing is in it, nothing more than to be known to be deleted.
	local function cleaned(id: string)
		local any = hangs[id] ~= nil
		for k in owned[id] or {} :: any do
			any = any or members[k] ~= nil
		end
		if not any then
			clear(cleaning, id)
			clear(owned, id)
		end
	end
	local forgotten: { [string]: Where } = {} -- in this pass: let go of once all that came has been read

	local function absorb()
		table.clear(marked)
		for id in dirty_rows do
			local row = rows_held[id]
			local w = if row and not row.dead then where_of(row) else nil
			local old = wheres[id]
			if old and old.kind == NODE and hangs[old.parent] and (not w or w.parent ~= old.parent) then
				local h = hangs[old.parent]
				h[id] = nil
				if next(h) == nil then
					hangs[old.parent] = nil
				end
			end
			if w and w.kind == NODE and w.parent ~= ZERO then
				hangs[w.parent] = hangs[w.parent] or {}
				hangs[w.parent][id] = true
				if dead_rows[w.parent] then
					cleaning[w.parent] = true -- hung from what is deleted: let go of by whoever next writes
				end
			end
			local differs = old ~= nil and (w == nil or not same_where(old, w))
			if differs then
				local o = old :: Where
				local k = o.owner .. o.field
				local m = members[k]
				if m then
					m[id] = nil
					if next(m) == nil then
						-- Nothing says it is in it: neither it nor its owner need say so.
						members[k] = nil
						local ks = owned[o.owner]
						if ks then
							ks[k] = nil
							if next(ks) == nil then
								owned[o.owner] = nil
							end
						end
					end
				end
				moving(k, id, if o.kind == ITEM then o.marker else true)
				if o.kind == ITEM and (not w or w.marker ~= o.marker) then
					-- A marker no longer anyone's, if it is still there: let go of when the list is next written.
					local box = boxes[k]
					local t = if box and box.ids and box.slot then client:held_text(o.owner, box.slot) else nil
					if t and text.standing(t, o.marker) then
						garbage[k] = garbage[k] or {}
						garbage[k][o.marker] = true
					end
				end
				mark_box(k, true)
			end
			wheres[id] = w :: any
			-- A row that is here is not gone, whatever was seen of it, as when it was let go of from memory while it was
			-- elsewhere, and is back.
			if row and not row.dead and dead_rows[id] then
				dead_rows[id] = nil
				cleaning[id] = nil
			end
			if w then
				if w.kind == ENTRY and not w.present then
					emptied[id] = true
				elseif emptied[id] then
					emptied[id] = nil
				end
			elseif emptied[id] then
				emptied[id] = nil
			end
			if w and (old == nil or differs) then
				local k = w.owner .. w.field
				local m = members[k]
				if not m then
					m = {}
					members[k] = m
				end
				m[id] = true
				if dead_rows[w.owner] then
					cleaning[w.owner] = true -- put in what is deleted: let go of by whoever next writes
				end
				local o = owned[w.owner]
				if not o then
					o = {}
					owned[w.owner] = o
				end
				o[k] = true
				moving(k, id, true)
				mark_box(k, true)
			end
			-- What is in it is marked as having changed, and so on up. A row heard of for the first time is in nothing yet
			-- but what it says, which is marked already, unless it is a map within a map or a node.
			if old ~= nil or nodes[id] ~= nil or tnodes[id] ~= nil or standing_in[id] ~= nil or tree_up[id] ~= nil then
				mark_node(id)
			end
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
				cleaning[id] = true
			end
			-- What is in a row that comes or goes is there or not with it.
			if (old == nil) ~= (w == nil) then
				local ks = owned[id]
				if ks then
					for k in ks do
						mark_box(k, true)
					end
				end
			end
			if old and not w and (not row or row.dead) and not standing[id] then
				forgotten[id] = old
			end
		end
		table.clear(dirty_rows)
		-- What was in what went may have been marked as it went, too.
		for id, old in forgotten do
			forget(id, old)
		end
		table.clear(forgotten)
		if next(cleaning) ~= nil then
			for id in table.clone(cleaning) do
				cleaned(id)
			end
		end
	end

	-- ------------------------------------------------ reading

	-- A value as a column holds it: a text is always one, empty or not; otherwise what is empty is nothing.
	local function decode(c: Column, row: any): any
		if c.who then
			-- Whose what is in the slot is, as the client says it: whoever wrote there last, or all who have, by name.
			return cells.whose(row, c.slot, c.who == "all")
		elseif c.text then
			return client:_read_text(row, c.slot)
		end
		local cell = latest(row, c.slot)
		if not cell or #cell == 17 then
			return nil
		end
		local how = c.decode
		if how == as_is then
			return string.sub(cell, 18)
		elseif how == as_number then
			-- As the column reads its value: the first eight bytes, which there must be.
			return if #cell >= 25 then string.unpack(">d", cell, 18) else nil
		end
		local ok, v = pcall(how, string.sub(cell, 18))
		return if ok then v else nil
	end

	local function alive(id: string): any
		local row = client:held(id)
		return if row and not row.dead then row else nil
	end

	-- The document, and maps within maps, are there for everyone whether their own rows have come or not: what is in
	-- them is. Whatever else holds anything holds it only while it is there itself.
	local function holds(owner: string): boolean
		return standing[owner] == true or alive(owner) ~= nil
	end

	local build_box: any

	-- A map: the same table as before if nothing in it is other than it was. What is in its own row is read again only if the
	-- row has changed since it was last read, which its version says: versions are never the same for two states of rows.
	-- A table with room for every field of a map and its id, and nothing in it: what a map is made from, so that it is made
	-- once, as big as it will be, rather than grown field by field.
	local shapes: { [Schema]: { [string]: any } } = {}
	local function shape_of(s: Schema): { [string]: any }
		local shape = shapes[s]
		if not shape then
			shape = { id = false }
			for _, name in s.names do
				shape[name] = false
			end
			for name in shape do
				shape[name] = nil -- the room stays
			end
			shapes[s] = shape
		end
		return shape :: any
	end
	local function build_map(s: Schema, id: string): any
		-- A map read as another's schema, as every map is while the scope is not known and all ids are nothing, is not this one.
		local was = if schema_of[id] == s then nodes[id] else nil
		if was and not dirty_node[id] and not plain then
			return was
		end
		if dirty_node[id] then
			dirty_node[id] = nil
		end
		if schema_of[id] ~= s then
			schema_of[id] = s
		end
		local row = rows_held[id]
		if row and row.dead then
			row = nil
		end
		local again = row ~= nil and (was == nil or plain or seen[id] ~= row.version) -- read the long way, read again
		seen[id] = if row then row.version else nil
		local names, inner, columns = s.names, s.boxes, s.columns
		if was == nil then
			-- Made for the first time: straight into what is given, which is made as big as it will be.
			local out: { [string]: any } = table.clone(shape_of(s))
			out.id = id
			for _, name in names do
				local b = inner[name]
				local v = if b then build_box(b, id, name) elseif row then decode(columns[name], row) else nil
				if v ~= nil and v ~= NIL then
					out[name] = v
				end
			end
			table.freeze(out)
			nodes[id] = out
			return out
		end
		local parts = table.create(#names)
		local changed = false
		for i, name in names do
			local b = inner[name]
			local pv = was[name]
			local v
			if b then
				v = build_box(b, id, name)
			elseif not row then
				v = nil
			elseif again then
				v = decode(columns[name], row)
			else
				v = pv
			end
			if v == nil then
				v = NIL
			end
			parts[i] = v
			if not changed then
				changed = not alike(if pv == nil then NIL else pv, v)
			end
		end
		if not changed then
			return was
		end
		local out: { [string]: any } = table.clone(shape_of(s))
		out.id = id
		for i, name in names do
			local v = parts[i]
			out[name] = if v == NIL then nil else v
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
	-- Where an item is among a list's ids, found by where its marker is, as they are in order: by place, and then by id. Nil
	-- if it cannot be found so, as when what it is compared with has no place.
	local function seek(ids: { string }, id: string, t: any): number?
		local w = wheres[id]
		if not (t and w and w.kind == ITEM) then
			return nil
		end
		local l, o = text.position(t, w.marker)
		if not l then
			return nil
		end
		local lo, hi = 1, #ids
		while lo <= hi do
			local mid = (lo + hi) // 2
			local m = ids[mid]
			if m == id then
				return mid
			end
			local wm = wheres[m]
			local lm: number?, om: number = nil, 0
			if wm and wm.kind == ITEM then
				lm, om = text.position(t, wm.marker)
			end
			if lm == nil then
				return nil
			end
			local less = if lm ~= l then (lm :: number) < l elseif om ~= o then om < o else m < id
			if less then
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
		return nil
	end

	-- The last found, which is found again first: what is typed in, or heard of, is often the same item again and again.
	local last_ids: { string }?, last_id, last_at = nil, "", 0
	local function find_in(ids: { string }, id: string, t: any): number?
		if ids == last_ids and id == last_id and ids[last_at] == id then
			return last_at
		end
		local at = seek(ids, id, t)
		if at then
			last_ids, last_id, last_at = ids, id, at
		end
		return at
	end

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

	-- The items of a list from nothing, in order: by where their markers are, and then by id. Each one's place is made one
	-- number, the place of its marker's span among the text's spans and the offset in it, so that they are sorted as numbers
	-- are, with no call for each comparison; and so are the few that share a place, by id.
	local function order_of(mine: { [string]: boolean }, t: any): ({ string }, { [string]: boolean }, { [string]: boolean })
		local hidden, dups = {}, {}
		local ordinal: ((string) -> number?)?, total = nil, 0
		if t then
			ordinal, total = text.ordinals(t)
		end
		local n = 0
		local of: { string }, at: { number } = {}, {}
		for id in mine do
			local row = rows_held[id]
			if row and not row.dead then
				local w = wheres[id]
				local k = if ordinal and w and w.kind == ITEM then (ordinal :: any)(w.marker) else nil
				if k then
					n += 1
					of[n], at[n] = id, k
				else
					hidden[id] = true
				end
			end
		end
		-- Each where its marker is: in an array as long as the text, if that is not much longer than the list; or else by
		-- those places sorted, as numbers. Those that share a marker, which only a writer who minds nothing makes, by id.
		-- (Made as long as they will be, as what is kept and copied is all of an array, however much of it is used.)
		local ids: { string } = table.create(n) :: any
		local by: { [number]: any }
		local places: { number }
		if total <= 4 * n + 64 then
			by = table.create(total) :: any
			places = nil :: any
		else
			by = {}
			places = table.create(n) :: any
		end
		for i = 1, n do
			local k = at[i]
			local x = by[k]
			if x == nil then
				by[k] = of[i]
				if places then
					table.insert(places, k)
				end
			elseif type(x) == "string" then
				by[k] = { x, of[i] }
			else
				table.insert(x, of[i])
			end
		end
		local j = 0
		local function put(x: any)
			if type(x) == "string" then
				j += 1
				ids[j] = x
			else
				-- Sharing a marker: all but the first are given one of their own when the list is next written.
				table.sort(x)
				for i, id in x do
					j += 1
					ids[j] = id
					if i > 1 then
						dups[id] = true
					end
				end
			end
		end
		if places then
			table.sort(places)
			for _, k in places do
				put(by[k])
			end
		else
			for k = 1, total do
				local x = by[k]
				if x ~= nil then
					put(x)
				end
			end
		end
		return ids, hidden, dups
	end

	build_box = function(b: Schema, owner: string, field: string): any
		local key = key_of(owner, field)
		local st = boxes[key]
		local d = dirty_box[key]
		if st and d == nil and not plain then
			return st.out
		end
		local structural = d == true or st == nil or plain
		if d ~= nil then
			dirty_box[key] = nil
		end
		if b.kind == "map" then
			local scoped = client.scopes[scope]
			local from = if scoped then scoped.key else ""
			local id = if st and st.from == from then st.id else derive(owner, field)
			standing[id] = true
			standing_in[id] = key
			local out = build_map(b, id)
			boxes[key] = { out = out, id = id, from = from }
			return out
		elseif b.kind == "list" and b.of.kind then
			local ids = if st then st.ids else {}
			local hidden = if st then st.hidden else {}
			local fresh_dups: { [string]: boolean }? = nil
			local living = holds(owner)
			if structural then
				local t = if living then client:held_text(owner, b.slot) else nil
				-- The text read, to know later whether it is still the one.
				set_version(owner, b.slot, t)
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
				local again = was_remade(owner, b.slot)
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
					-- The ids are this list's own, and changed where they are; what is shown is a new array.
					local count = #ids
					local new_ids = ids
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
					-- Each found where it is, by its marker; failing that, by a table of where each is, made once.
					local fresh_index = nil
					for id in touched or {} :: any do
						if not redo[id] and not hidden[id] then
							local at = find_in(new_ids, id, t)
							if not at then
								fresh_index = fresh_index or index_of(new_ids)
								at = fresh_index[id]
							end
							if at then
								parts[at] = build_map(b.of, id)
							end
						end
					end
					local out = if #gone == 0 and #new_ids == count and same_list(st.out, parts) then st.out else table.freeze(parts)
					-- Sharing a marker is looked for only beside what was put back: what moved is looked at again.
					local dups = table.clone(st.dups or {})
					for id in redo do
						dups[id] = nil
					end
					-- What shared a marker with one that is gone, or has moved, may not now: each, of those few, is looked at again
					-- beside what is before it now.
					for id in dups do
						local i = find_in(new_ids, id, t)
						local before_it = if i and i > 1 then wheres[new_ids[i - 1]] else nil
						if i and not (before_it and before_it.marker == wheres[id].marker) then
							dups[id] = nil
						end
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
				ids, hidden, fresh_dups = order_of(mine, t)
			end
			local touched = changed_in[key]
			changed_in[key] = nil
			if not structural and st then
				-- In the same order: only what changed is read again, each found where it is by its marker, in the text as it was
				-- read; failing that, by a table of where each is, made once and kept.
				local index = st.index or nil
				local read = if versions[owner] then versions[owner][b.slot] else nil
				local t = if read then read.t else nil
				local parts = nil
				for id in touched or {} :: any do
					local i = nil
					if index then
						i = index[id]
					elseif not hidden[id] then
						i = find_in(ids, id, t)
						if not i then
							index = index_of(ids)
							i = (index :: any)[id]
						end
					end
					if i then
						local v = build_map(b.of, id)
						if not rawequal(v, st.out[i]) then
							parts = parts or table.clone(st.out)
							parts[i] = v
						end
					end
				end
				local out = if parts then table.freeze(parts) else st.out
				boxes[key] = { out = out, ids = ids, hidden = hidden, living = living, index = index or false, slot = b.slot, dups = st.dups }
				return out
			end
			local parts = table.create(#ids) -- as long as it will be: a copy of it is all of it, used or not
			for i, id in ids do
				parts[i] = build_map(b.of, id)
			end
			local out = if st and same_list(st.out, parts) then st.out else table.freeze(parts)
			boxes[key] = { out = out, ids = ids, hidden = hidden, living = living, index = false, slot = b.slot, dups = fresh_dups or sharing(ids) }
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
			local written: { [string]: boolean } = {} -- rows the new state has, as written here: none is let go of after
			local emptying: { [string]: boolean } = {} -- each once, whatever says it is in what
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
				written[id] = true
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
				written[id] = true
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
								-- Never parting a character's bytes: what others write meanwhile is of whole characters too.
								while
									a > 0
									and (
										(a < #was and bit32.band(string.byte(was, a + 1), 0xC0) == 0x80)
										or (a < #nv and bit32.band(string.byte(nv, a + 1), 0xC0) == 0x80)
									)
								do
									a -= 1
								end
								while z < #was - a and z < #nv - a and string.byte(was, #was - z) == string.byte(nv, #nv - z) do
									z += 1
								end
								while z > 0 and bit32.band(string.byte(was, #was - z + 1), 0xC0) == 0x80 do
									z -= 1
								end
								if #was - a - z > 0 then
									text.delete(t, a, #was - a - z, fresh)
								end
								if #nv - a - z > 0 then
									text.insert(t, a, string.sub(nv, a + 1, #nv - z), fresh)
								end
							end)
						end
					elseif c.text and made and (nv == nil or nv == "") and (ov == nil or ov == "") then
						-- Nor is an empty text written where the row is made here: one with no cells is empty, and an empty
						-- value written over one not come yet would wipe what another typed in it meanwhile.
						continue
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
			-- is that key's for ever, and only emptied. A key of a record within is let go of as any key is, and not
			-- deleted, which would be for ever, as its id is its key's: so that it can be set again. Nothing the new state
			-- has is let go of, as a key set again here is not.
			local function empty(id: string)
				if written[id] or emptying[id] then
					return
				end
				emptying[id] = true
				for k in owned[id] or {} :: any do
					for m in members[k] or {} :: any do
						local w = wheres[m]
						if written[m] then
							continue
						elseif w and w.kind == MAP then
							empty(m)
						elseif w and w.kind == ENTRY and m == derive(w.owner, w.field, w.key) then
							if w.present then
								change.set(m, { [W] = WHERE_COLUMN }, { [W] = where_encode(w.owner, w.field, ENTRY, "\0" .. w.key) })
							end
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
			-- What others put in rows that were being deleted meanwhile is let go of too: of those that may have anything in
			-- them, not of every row ever deleted.
			for id in cleaning do
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
		-- For tests: how much is kept of what was read, that it may be seen not to grow without end.
		_sizes = function(): { [string]: number }
			local out = {}
			for name, t in { nodes = nodes, schema_of = schema_of, seen = seen, tnodes = tnodes, boxes = boxes, changed_in = changed_in, moved_in = moved_in, dirty_box = dirty_box, versions = versions, dirty_node = dirty_node, owned = owned, members = members, hangs = hangs, cleaning = cleaning, standing = standing, standing_in = standing_in, tree_up = tree_up, garbage = garbage, remade = remade } :: { [string]: { [string]: any } } do
				local n = 0
				for _ in t do
					n += 1
				end
				out[name] = n
			end
			local keys = 0
			for _, ks in owned do
				for _ in ks do
					keys += 1
				end
			end
			out.owned_keys = keys
			return out
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
		if
			last
			and last.status == answer.status
			and last.total == answer.total
			and last.first == answer.first
			and (rawequal(last.totals, answer.totals) or (next(last.totals) == nil and next(answer.totals) == nil))
			and #last.rows == #rows
		then
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

	-- A question asked, kept to be stopped; or stopped at once, where what answered at once had this stopped.
	local function kept(into: { any }, q: any): any
		if stopped then
			q.stop()
		else
			table.insert(into, q)
		end
		return q
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
			local q: any = client:ask({ scope = scope, table = { ["\0where"] = BYTES_COLUMN }, where = where.all(where.in_list(list), where.ids(part)), limit = 1000 }, function(a: any)
				answers[`maps {n}`] = a
				tell()
			end)
			kept(by_id, q)
			if stopped then
				return
			end
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
		kept(questions, found_handle)
		if stopped then
			return true
		end
		if moved then
			found_handle.move(moved.offset, moved.limit)
		end
		-- The rows on the way: whether what answers is there is theirs to say.
		local on_the_way: any = client:ask({ scope = scope, table = { ["\0where"] = BYTES_COLUMN }, where = where.all(where.in_list(list), where.ids(p.chain)), limit = 1000 }, function(a: any)
			answers.chain = a
			tell()
		end)
		kept(questions, on_the_way)
		if stopped then
			return true
		end
		-- Every node of a tree on the way: which are there, and where, is known only from all of them.
		for i, t in p.trees do
			local pages: { any } = {}
			local function page(n: number)
				if stopped then
					return
				end
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
				kept(questions, q)
			end
			page(1)
		end
		return true
	end

	-- Ids are made with the scope's key: what is on the way is known once that is. A client that knows what it may do, and
	-- may not read there, is told so, as a question of its own would be; and what answers comes should that change.
	-- Said first, before what answers, which may come at once: as a record's are, with its keys.
	local kind = place_of(schema, path, function()
		return string.rep("\0", 16)
	end).box.kind -- or an error, here rather than later
	local none = if kind == "record" then table.freeze({}) else nil
	local loading = table.freeze({ rows = table.freeze({}), keys = none, status = "loading", total = 0, first = 0, totals = table.freeze({}) })
	local refused = table.freeze({ rows = table.freeze({}), keys = none, status = "denied", total = 0, first = 0, totals = table.freeze({}) })
	local function say(what: any) -- and what is said is what what answers is the same as or not
		last = what
		observer(what)
	end
	local function denied(): boolean
		return client.ready == true and not client.scopes[scope]
	end
	local waiting: { stop: (() -> ())? } = { stop = nil }
	local said_denied = denied()
	say(if said_denied then refused else loading)
	if not start() then
		waiting.stop = client:on("status", function()
			if stopped then
				return
			end
			if not start() then
				if denied() ~= said_denied then
					said_denied = not said_denied
					say(if said_denied then refused else loading)
				end
				return
			end
			local unwait = waiting.stop
			if unwait then
				waiting.stop = nil
				unwait()
			end
		end)
	end

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
