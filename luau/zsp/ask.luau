--!strict
--!native
-- Questions, as tables to be composed, and as the bytes a node reads: SPEC.md 15.

local codec = require("./codec")

local BYTES, FOLD, NUMBER, BOOL, ID, WORDS, CREATED, MODIFIED, ORDER, AUTHOR = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
local SUM, MIN, MAX, COUNT, FACET = 1, 2, 3, 4, 5

export type Columns = { [string]: { read slot: number, read is: string } }
-- A condition: made by the functions below, and put together with all, any and none.
export type Where = { read op: string, read [number]: any }

export type Match = {
	any: boolean?, -- one of the words will do
	phrase: boolean?, -- in a row
	prefix: boolean?, -- the last may be only begun
	inside: boolean?, -- they may be parts of words
	typos: number?, -- letters that may be wrong in each: 1 to 3
}
export type Total = { read [number]: any } -- { "sum", column }, or min, max, count; or { "facet", column, how many: 100 }

local ask = {}

local function where(op: string, ...: any): Where
	return table.freeze({ op = op, ... } :: any)
end

function ask.all(...: Where): Where
	return where("all", ...)
end
function ask.any(...: Where): Where
	return where("any", ...)
end
function ask.none(w: Where): Where
	return where("none", w)
end
-- A value that is this, whatever the case of text; and one of these.
function ask.is(column: string, value: any): Where
	return where("is", column, value)
end
function ask.among(column: string, values: { any }): Where
	return where("among", column, values)
end
-- Byte for byte.
function ask.exactly(column: string, value: any): Where
	return where("exactly", column, value)
end
-- From one to the other, both included. Either may be nil.
function ask.between(column: string, lo: any, hi: any): Where
	return where("between", column, lo, hi)
end
function ask.over(column: string, than: any): Where
	return where("over", column, than)
end
function ask.under(column: string, than: any): Where
	return where("under", column, than)
end
function ask.begins(column: string, with: string): Where
	return where("begins", column, with)
end
function ask.contains(column: string, what: string): Where
	return where("contains", column, what)
end
function ask.has(column: string): Where
	return where("has", column)
end
function ask.matches(column: string, text: string, how: Match?): Where
	return where("matches", column, text, how or {})
end
function ask.in_list(name: string): Where
	return where("list", name)
end
function ask.ids(of: { string }): Where
	return where("ids", of)
end
-- That refers to a row of a scope that …, by a column of row ids; and that is referred to by so many that ….
function ask.refers(column: string, scope: number, to: Where, columns: Columns?): Where
	return where("refers", column, scope, to, columns)
end
function ask.referred(scope: number, column: string, by: Where, least: number?, most: number?, columns: Columns?): Where
	return where("referred", column, scope, by, least or 1, most or math.huge, columns)
end

table.freeze(ask)

-- ---------------------------------------------------------------- as bytes

type Writing = { w: codec.Writer, columns: Columns, tag: (string) -> string, scope_tag: (number, string) -> string }

local KINDS: { [string]: number } = { string = FOLD, text = FOLD, number = NUMBER, boolean = BOOL, id = ID, row = ID, bytes = BYTES }

-- A column by its name in the table; "@created" and "@modified"; or name.path, into JSON, with what is wanted of
-- it after a colon, as in meta.size:number, where no value says.
local function find(x: Writing, name: string): (number, string, string?)
	if name == "@created" then
		return -1, "", "created"
	elseif name == "@modified" then
		return -1, "", "modified"
	end
	local c = x.columns[name]
	if c then
		return c.slot, "", c.is
	end
	local dot = string.find(name, ".", 1, true)
	local head = if dot then string.sub(name, 1, dot - 1) else name
	c = x.columns[head]
	assert(c and dot, `no column {name}`)
	local path, is = string.sub(name, dot + 1), nil :: string?
	local colon = string.find(path, ":", 1, true)
	if colon then
		path, is = string.sub(path, 1, colon - 1), string.sub(path, colon + 1)
		assert(KINDS[is :: any], `no kind {is}`)
	end
	return c.slot, path, is
end

local function kind_of(is: string?, value: any): number
	if is and KINDS[is] then
		return KINDS[is]
	end
	local t = type(value)
	return if t == "number" then NUMBER elseif t == "boolean" then BOOL else FOLD
end

local function put_column(x: Writing, kind: number, slot: number, path: string)
	codec.put_u8(x.w, kind)
	codec.put_u8(x.w, slot)
	codec.put_bytes(x.w, path)
end

-- Writes a column, read as a kind of value, and says which.
local function column(x: Writing, name: string, value: any, want: number?): number
	local slot, path, is = find(x, name)
	if is == "created" or is == "modified" then
		local kind = if is == "created" then CREATED else MODIFIED
		codec.put_u8(x.w, kind)
		return kind
	elseif is == "author" then
		codec.put_u8(x.w, AUTHOR)
		codec.put_u8(x.w, slot)
		return AUTHOR
	end
	local kind = want or kind_of(is, value)
	put_column(x, kind, slot, path)
	return kind
end

local function put_value(x: Writing, kind: number, value: any)
	if kind == NUMBER or kind == CREATED or kind == MODIFIED then
		codec.put_bytes(x.w, string.pack(">d", value))
	elseif kind == BOOL then
		codec.put_bytes(x.w, if value then "\1" else "\0")
	else
		codec.put_bytes(x.w, value)
	end
end

local function put_range(x: Writing, name: string, lo: any, hi: any, lo_in: boolean, hi_in: boolean, want: number?)
	codec.put_u8(x.w, 4)
	local kind = column(x, name, if lo ~= nil then lo else hi, want)
	codec.put_u8(x.w, (if lo ~= nil then 1 else 0) + (if hi ~= nil then 2 else 0) + (if lo_in then 4 else 0) + (if hi_in then 8 else 0))
	if lo ~= nil then
		put_value(x, kind, lo)
	end
	if hi ~= nil then
		put_value(x, kind, hi)
	end
end

local put_where: (Writing, Where) -> ()

local function put_many(x: Writing, op: number, of: Where)
	codec.put_u8(x.w, op)
	codec.put_varint(x.w, #of)
	for _, w in ipairs(of) do
		put_where(x, w)
	end
end

function put_where(x: Writing, c: Where)
	local op, a, b, d = c.op, c[1], c[2], c[3]
	local w = x.w
	if op == "all" then
		if #c == 0 then
			codec.put_u8(w, 0)
		else
			put_many(x, 1, c)
		end
	elseif op == "any" then
		put_many(x, 2, c)
	elseif op == "none" then
		codec.put_u8(w, 3)
		put_where(x, a)
	elseif op == "is" then
		put_range(x, a, b, b, true, true)
	elseif op == "exactly" then
		put_range(x, a, b, b, true, true, if type(b) == "string" then BYTES else nil)
	elseif op == "between" then
		put_range(x, a, b, d, true, true)
	elseif op == "over" then
		put_range(x, a, b, nil, false, true)
	elseif op == "under" then
		put_range(x, a, nil, b, true, false)
	elseif op == "among" then
		codec.put_u8(w, 5)
		local kind = column(x, a, b[1])
		codec.put_varint(w, #b)
		for _, v in b do
			put_value(x, kind, v)
		end
	elseif op == "begins" or op == "contains" then
		codec.put_u8(w, if op == "begins" then 6 else 7)
		-- A column of bytes is compared byte for byte; any other as text, without case or marks.
		local _, _, is = find(x, a)
		column(x, a, b, if is == "bytes" then BYTES else FOLD)
		codec.put_bytes(w, b)
	elseif op == "has" then
		codec.put_u8(w, 8)
		column(x, a, nil)
	elseif op == "list" then
		codec.put_u8(w, 9)
		codec.put(w, x.tag(a))
	elseif op == "matches" then
		local how: Match = d
		codec.put_u8(w, 10)
		column(x, a, b, WORDS)
		codec.put_u8(w, if how.phrase then 2 elseif how.any then 1 else 0)
		codec.put_u8(w, (if how.prefix then 1 else 0) + (if how.inside then 2 else 0) + math.clamp(how.typos or 0, 0, 3) * 4)
		codec.put_bytes(w, b)
	elseif op == "ids" then
		codec.put_u8(w, 11)
		codec.put_varint(w, #a)
		for _, id in a do
			codec.put(w, id)
		end
	elseif op == "refers" or op == "referred" then
		local columns = if op == "refers" then c[4] else c[6]
		local inner: Writing = {
			w = w,
			columns = columns or x.columns,
			scope_tag = x.scope_tag,
			tag = function(name: string): string
				return x.scope_tag(b, name)
			end,
		}
		codec.put_u8(w, if op == "refers" then 12 else 13)
		column(if op == "refers" then x else inner, a, nil, ID)
		codec.put_varint(w, b)
		if op == "referred" then
			codec.put_varint(w, c[4])
			local most: number = c[5]
			if most >= 2 ^ 53 then
				codec.put(w, "\255\255\255\255\255\255\255\255\255\1")
			else
				codec.put_varint(w, most)
			end
		end
		put_where(inner, d)
	else
		error(`{op} is no condition`)
	end
end

export type Question = {
	scope: number,
	table: Columns,
	where: Where?,
	-- "best", "newest", "oldest", a column, or one after a minus for the greatest first: in order of weight.
	order: { string }?,
	offset: number?,
	limit: number?, -- 50
	from_end: boolean?, -- offset and limit count back from the end
	totals: { [string]: Total }?,
}

export type Told = { read name: string, read facet: boolean, read read: (string) -> any }

local function as_written(v: string): any
	return v
end

local READ: { [number]: (string) -> any } = {
	[NUMBER] = function(v)
		return (string.unpack(">d", v))
	end,
	[BOOL] = function(v)
		return v == "\1"
	end,
}
READ[CREATED], READ[MODIFIED] = READ[NUMBER], READ[NUMBER]

-- The question, and its totals in the order they will be answered in.
local function write(q: Question, scope_tag: (number, string) -> string): (string, { Told })
	local w = codec.writer()
	local x: Writing = {
		w = w,
		columns = q.table,
		scope_tag = scope_tag,
		tag = function(name: string): string
			return scope_tag(q.scope, name)
		end,
	}
	codec.put_varint(w, q.scope)
	put_where(x, q.where or ask.all())
	local order = q.order or { "newest" }
	codec.put_varint(w, #order)
	for _, name in order do
		local desc = string.sub(name, 1, 1) == "-"
		if name == "best" then
			codec.put(w, "\1\0")
		elseif name == "newest" or name == "oldest" then
			codec.put(w, if name == "newest" then "\2\1" else "\2\0")
		elseif string.sub(name, 1, 6) == "@list:" or string.sub(name, 1, 7) == "-@list:" then
			codec.put(w, if desc then "\0\1" else "\0\0")
			codec.put_u8(w, ORDER)
			codec.put(w, x.tag(string.sub(name, if desc then 8 else 7)))
		else
			codec.put(w, if desc then "\0\1" else "\0\0")
			column(x, if desc then string.sub(name, 2) else name, nil)
		end
	end
	codec.put_u8(w, if q.from_end then 1 else 0)
	codec.put_varint(w, q.offset or 0)
	codec.put_varint(w, q.limit or 50)
	local names = {}
	for name in q.totals or {} :: any do
		table.insert(names, name)
	end
	table.sort(names)
	codec.put_varint(w, #names)
	local FN: { [string]: number } = { sum = SUM, min = MIN, max = MAX, count = COUNT, facet = FACET }
	local told: { Told } = {}
	for _, name in names do
		local t = (q.totals :: any)[name]
		codec.put_u8(w, assert(FN[t[1]], "no such total"))
		local kind = column(x, t[2], nil, if t[1] == "sum" then NUMBER else nil)
		table.insert(told, { name = name, facet = t[1] == "facet", read = READ[kind] or as_written })
		codec.put_varint(w, t[3] or (if t[1] == "facet" then 100 else 0))
	end
	return codec.string(w), told
end

return table.freeze({ where = ask, write = write })
