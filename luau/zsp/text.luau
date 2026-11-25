--!strict
--!native
--!optimize 2
-- The text column of SPEC.md, operation for operation. See zsp/text.odin for the reasoning.

local codec = require("./codec")

type Ref = { piece: string, offset: number } -- piece "" is the edge of the document

type Span = {
	piece: string,
	offset: number,
	len: number,
	parts: { string },
	lpiece: string,
	loffset: number,
	rpiece: string,
	roffset: number,
	dead: boolean,
}

type Piece = {
	count: number,
	rpiece: string, -- the last insertion's right neighbour
	roffset: number,
	fed: number,
	stamp: string, -- "" while only live
	shown: string, -- what was consumed while only live, to hold the sealed piece to
}

export type Text = {
	spans: { Span },
	pieces: { [string]: Piece },
	waiting: { { piece: string, rest: string, at: number } },
	base: string,
	hint: number,
	open: string,
	ops: { string },
	size: number, -- bytes of ops
	flushed: number,
	cache: string?,
}

export type Result = "same" | "changed" | "waiting" | "rebuild"

local text = {}

local INSERT, EXTEND, DELETE = 1, 2, 3
local NOBODY = string.rep("\0", 8)

function text.new(): Text
	return {
		spans = {},
		pieces = {},
		waiting = {},
		base = "",
		hint = 1,
		open = "",
		ops = {},
		size = 0,
		flushed = 0,
		cache = nil,
	}
end

local function piece_of(t: Text, id: string): Piece
	local p = t.pieces[id]
	if not p then
		p = { count = 0, rpiece = "", roffset = 0, fed = 0, stamp = "", shown = "" }
		t.pieces[id] = p
	end
	return p
end

local function has(t: Text, piece: string, offset: number, n: number): boolean
	if piece == "" then
		return true
	end
	local p = t.pieces[piece]
	return p ~= nil and offset + n <= p.count
end

local function joined(s: Span): string
	if #s.parts > 1 then
		s.parts = { table.concat(s.parts) }
	end
	return s.parts[1]
end

local function find(t: Text, piece: string, offset: number): number
	local spans = t.spans
	for i = math.max(t.hint - 2, 1), math.min(t.hint + 2, #spans) do
		local s = spans[i]
		if s.piece == piece and offset >= s.offset and offset < s.offset + s.len then
			return i
		end
	end
	for i, s in spans do
		if s.piece == piece and offset >= s.offset and offset < s.offset + s.len then
			t.hint = i
			return i
		end
	end
	error("a reference that was checked is missing")
end

local function split(t: Text, i: number, n: number)
	local s = t.spans[i]
	if n == 0 or n >= s.len then
		return
	end
	local body = joined(s)
	table.insert(t.spans, i + 1, {
		piece = s.piece,
		offset = s.offset + n,
		len = s.len - n,
		parts = { string.sub(body, n + 1) },
		lpiece = s.piece,
		loffset = s.offset + n - 1,
		rpiece = s.rpiece,
		roffset = s.roffset,
		dead = s.dead,
	})
	s.parts = { string.sub(body, 1, n) }
	s.len = n
end

-- Index of the span ending with the element; 0 for the document's start.
local function left_of(t: Text, piece: string, offset: number): number
	if piece == "" then
		return 0
	end
	local i = find(t, piece, offset)
	split(t, i, offset - t.spans[i].offset + 1)
	return i
end

-- Index of the span beginning with the element; one past the last for the document's end.
local function right_of(t: Text, piece: string, offset: number): number
	if piece == "" then
		return #t.spans + 1
	end
	local i = find(t, piece, offset)
	local n = offset - t.spans[i].offset
	if n > 0 then
		split(t, i, n)
		return i + 1
	end
	return i
end

local function insert_run(t: Text, id: string, bytes: string, lpiece: string, loffset: number, rpiece: string, roffset: number)
	t.cache = nil
	local p = piece_of(t, id)
	local offset = p.count
	p.count += #bytes
	p.rpiece, p.roffset = rpiece, roffset

	local l = left_of(t, lpiece, loffset)
	local r = right_of(t, rpiece, roffset)
	local spans = t.spans
	local at = l + 1
	local scanning = false
	local i = at
	while true do
		if not scanning then
			at = i
		end
		if i > #spans or i == r then
			break
		end
		local o = spans[i]
		local ol = if o.lpiece == "" then 0 else find(t, o.lpiece, o.loffset)
		local same_left = o.lpiece == lpiece and (lpiece == "" or o.loffset == loffset)
		if ol < l or (ol == l and not same_left) then
			break
		end
		if same_left then
			local same_right = o.rpiece == rpiece and (rpiece == "" or o.roffset == roffset)
			if same_right and id < o.piece then
				break
			end
			local rr = if o.rpiece == "" then #spans + 1 else find(t, o.rpiece, o.roffset)
			scanning = rr < r
		end
		i += 1
	end
	if at > 1 then
		local b = spans[at - 1]
		if
			b.piece == id
			and b.offset + b.len == offset
			and lpiece == id
			and loffset == offset - 1
			and b.rpiece == rpiece
			and b.roffset == roffset
			and not b.dead
		then
			table.insert(b.parts, bytes)
			b.len += #bytes
			t.hint = at - 1
			return
		end
	end
	table.insert(spans, at, {
		piece = id,
		offset = offset,
		len = #bytes,
		parts = { bytes },
		lpiece = lpiece,
		loffset = loffset,
		rpiece = rpiece,
		roffset = roffset,
		dead = false,
	})
	t.hint = at
end

local function kill(t: Text, piece: string, offset: number, count: number)
	t.cache = nil
	while count > 0 do
		local i = right_of(t, piece, offset)
		split(t, i, count)
		local s = t.spans[i]
		s.dead = true
		offset += s.len
		count -= s.len
	end
end

local function read_ref(r: codec.Reader, id: string): (string, number)
	local tag = codec.u8(r)
	if tag == 0 then
		return "", 0
	elseif tag == 1 then
		return id, codec.varint(r)
	elseif tag == 2 then
		local piece = codec.take(r, 8)
		return piece, codec.varint(r)
	end
	error("bad reference")
end

-- One operation: the reader is left after it, or false is returned if it refers to what is not here.
local function apply_op(t: Text, id: string, r: codec.Reader): boolean
	local op = codec.u8(r)
	if op == INSERT then
		local lp, lo = read_ref(r, id)
		local rp, ro = read_ref(r, id)
		local bytes = codec.bytes(r)
		if not has(t, lp, lo, 1) or not has(t, rp, ro, 1) then
			return false
		end
		if #bytes > 0 then
			insert_run(t, id, bytes, lp, lo, rp, ro)
		end
	elseif op == EXTEND then
		local bytes = codec.bytes(r)
		local p = piece_of(t, id)
		if p.count == 0 then
			return false
		end
		if #bytes > 0 then
			insert_run(t, id, bytes, id, p.count - 1, p.rpiece, p.roffset)
		end
	elseif op == DELETE then
		local fp, fo = read_ref(r, id)
		local count = codec.varint(r)
		if fp == "" or not has(t, fp, fo, count) then
			return false
		end
		kill(t, fp, fo, count)
	else
		return false
	end
	return true
end

local function apply_ops(t: Text, id: string, ops: string): number
	local r = codec.reader(ops)
	local done = 0
	while r.pos < r.len do
		local ok, applied = pcall(apply_op, t, id, r)
		if not ok or not applied then
			break
		end
		local p = piece_of(t, id)
		if p.stamp == "" and id ~= t.open then
			p.shown ..= string.sub(ops, done + 1, r.pos)
		end
		p.fed += r.pos - done
		done = r.pos
	end
	return done
end

local function retry(t: Text)
	local i = 1
	while i <= #t.waiting do
		local w = t.waiting[i]
		local n = apply_ops(t, w.piece, string.sub(w.rest, w.at + 1))
		w.at += n
		if w.at == #w.rest then
			table.remove(t.waiting, i)
		end
		i = if n > 0 then 1 else i + 1
	end
end

local function apply_piece(t: Text, name: string, stamp: string, ops: string): Result
	local id = name
	if id == NOBODY then
		return "same" -- the edge of the document is nobody's piece
	end
	local p = t.pieces[id]
	if p and p.stamp == stamp then
		return "same"
	end
	if p and p.stamp ~= "" then
		if stamp < p.stamp then
			return "rebuild"
		end
		id = string.sub(stamp, 9)
		if id == NOBODY or t.pieces[id] then
			return "same"
		end
	end
	local piece = piece_of(t, id)
	if piece.fed > #ops or piece.shown ~= string.sub(ops, 1, piece.fed) then
		return "rebuild"
	end
	piece.shown = ""
	piece.stamp = stamp
	local at = piece.fed + apply_ops(t, id, string.sub(ops, piece.fed + 1))
	if at < #ops then
		table.insert(t.waiting, { piece = id, rest = string.sub(ops, at + 1), at = 0 })
	end
	retry(t)
	for _, w in t.waiting do
		if w.piece == id then
			return "waiting"
		end
	end
	return "changed"
end

-- Applies the body of a cell in this text's slot. Kinds are the protocol's: 3 value, 4 piece, 5 bundle.
function text.apply(t: Text, kind: number, stamp: string, body: string): Result
	if stamp <= t.base then
		return "same"
	end
	if kind == 3 then
		if next(t.pieces) ~= nil then
			return "rebuild"
		end
		t.base = stamp
		local id = string.sub(stamp, 9)
		if id == NOBODY then
			id = string.rep("\0", 7) .. "\1"
		end
		piece_of(t, id).stamp = stamp
		if #body > 0 then
			insert_run(t, id, body, "", 0, "", 0)
		end
		return "changed"
	elseif kind == 4 then
		if #body < 8 then
			return "same"
		end
		return apply_piece(t, string.sub(body, 1, 8), stamp, string.sub(body, 9))
	elseif kind == 5 then
		local r = codec.reader(body)
		local n: number = string.unpack(">I4", body) :: any
		r.pos = 4 + n * 16
		local out: Result = "same"
		while r.pos < r.len do
			local inner = codec.take(r, 16)
			local id = codec.take(r, 8)
			local ops = codec.bytes(r)
			if inner > t.base then
				local result = apply_piece(t, id, inner, ops)
				if result == "rebuild" then
					return "rebuild"
				elseif result == "changed" or (result == "waiting" and out == "same") then
					out = result
				end
			end
		end
		return out
	end
	return "same"
end

function text.live(t: Text, piece: string, offset: number, bytes: string): Result
	local p = t.pieces[piece]
	local fed = if p then p.fed else 0
	if (p and p.stamp ~= "") or piece == t.open or piece == NOBODY or offset > fed or offset + #bytes <= fed then
		return "same"
	end
	if apply_ops(t, piece, string.sub(bytes, fed - offset + 1)) == 0 then
		return "same"
	end
	retry(t)
	return "changed"
end

-- Whether anything here rests on frames no cell has confirmed.
function text.provisional(t: Text): boolean
	for id, p in t.pieces do
		if p.stamp == "" and id ~= t.open and p.fed > 0 then
			return true
		end
	end
	return false
end

function text.read(t: Text): string
	if t.cache then
		return t.cache
	end
	local out = {}
	for _, s in t.spans do
		if not s.dead then
			table.insert(out, joined(s))
		end
	end
	local s = table.concat(out)
	t.cache = s
	return s
end

function text.len(t: Text): number
	local n = 0
	for _, s in t.spans do
		if not s.dead then
			n += s.len
		end
	end
	return n
end

local function begin(t: Text, fresh: () -> string)
	if t.open == "" then
		t.open = fresh()
		piece_of(t, t.open)
	end
end

local function put_ref(w: codec.Writer, id: string, piece: string, offset: number)
	if piece == "" then
		codec.put_u8(w, 0)
	elseif piece == id then
		codec.put_u8(w, 1)
		codec.put_varint(w, offset)
	else
		codec.put_u8(w, 2)
		codec.put(w, piece)
		codec.put_varint(w, offset)
	end
end

local function record(t: Text, w: codec.Writer)
	local s = codec.string(w)
	table.insert(t.ops, s)
	t.size += #s
end

-- Types bytes before the visible byte at `pos` (zero-based). `fresh` draws eight random bytes.
function text.insert(t: Text, pos: number, bytes: string, fresh: () -> string)
	if bytes == "" then
		return
	end
	begin(t, fresh)
	local lp, lo, rp, ro = "", 0, "", 0
	local seen, i = 0, 1
	while i <= #t.spans and seen < pos do
		local s = t.spans[i]
		if not s.dead then
			if seen + s.len >= pos then
				split(t, i, pos - seen)
				s = t.spans[i]
				lp, lo = s.piece, s.offset + s.len - 1
				i += 1
				break
			end
			seen += s.len
		end
		i += 1
	end
	if i <= #t.spans then
		rp, ro = t.spans[i].piece, t.spans[i].offset
	end
	local id = t.open
	local p = piece_of(t, id)
	local w = codec.writer()
	if p.count > 0 and lp == id and lo == p.count - 1 and rp == p.rpiece and ro == p.roffset then
		codec.put_u8(w, EXTEND)
	else
		codec.put_u8(w, INSERT)
		put_ref(w, id, lp, lo)
		put_ref(w, id, rp, ro)
	end
	codec.put_bytes(w, bytes)
	record(t, w)
	insert_run(t, id, bytes, lp, lo, rp, ro)
end

function text.delete(t: Text, pos: number, count: number, fresh: () -> string)
	if count <= 0 then
		return
	end
	begin(t, fresh)
	t.cache = nil
	local i = 1
	while i <= #t.spans and count > 0 do
		local s = t.spans[i]
		if s.dead then
			i += 1
		elseif pos >= s.len then
			pos -= s.len
			i += 1
		elseif pos > 0 then
			split(t, i, pos)
			pos = 0
			i += 1
		else
			split(t, i, count)
			s = t.spans[i]
			s.dead = true
			local w = codec.writer()
			codec.put_u8(w, DELETE)
			put_ref(w, t.open, s.piece, s.offset)
			codec.put_varint(w, s.len)
			record(t, w)
			count -= s.len
			i += 1
		end
	end
end

-- What has been written since the last call: piece, offset, bytes.
function text.flush(t: Text): (string, number, string)
	local ops = if #t.ops > 1 then table.concat(t.ops) else (t.ops[1] or "")
	t.ops = { ops }
	local from = t.flushed
	t.flushed = #ops
	return t.open, from, string.sub(ops, from + 1)
end

-- Ends the open piece and yields its cell's body, or nil if nothing is open.
function text.close(t: Text, stamp: string): string?
	if t.open == "" then
		return nil
	end
	local body = table.concat(t.ops)
	local p = piece_of(t, t.open)
	p.stamp = stamp
	p.fed = #body
	local out = t.open .. body
	t.open = ""
	t.ops = {}
	t.size = 0
	t.flushed = 0
	return out
end

return table.freeze(text)
