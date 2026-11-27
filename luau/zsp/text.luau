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
	dead: boolean,
	label: number, -- greater than that of any span before it: so where two elements are is found in a few steps
	block: Block, -- that holds it
}

-- Some of the spans, in document order, dead ones included: so a span's place, and where a position falls, are found by
-- way of the blocks, as zsp/text.odin has it, rather than along every span.
type Block = {
	spans: { Span },
	at: number, -- among the blocks
	visible: number, -- bytes
}
local BLOCK = 64

-- Elements made at once: the first hangs beneath what its operation says, and each of the rest beneath the one before.
type Run = {
	piece: string,
	offset: number, -- of its first element; it lasts until the piece's next run
	ppiece: string, -- what the first hangs beneath: "" for the start of the document
	poffset: number,
	right: boolean,
	depth: number,
	hops: number,
	up: Run?,
	jump: Run?,
}

type Piece = {
	count: number,
	rpiece: string, -- the last insertion's right neighbour
	roffset: number,
	fed: number,
	stamp: string, -- "" while only live
	shown: string, -- what was consumed while only live, to hold the sealed piece to
	runs: { Run },
	spans: { Span }, -- its spans, by offset
}

export type Text = {
	blocks: { Block },
	count: number, -- spans
	counts: { number }, -- of spans in the blocks, and
	visibles: { number }, -- of their bytes, each as a Fenwick tree: how many come before a block is a few steps away
	visible: number, -- bytes that are there
	pieces: { [string]: Piece },
	waiting: { { piece: string, rest: string, at: number } },
	base: string,
	open: string,
	ops: { string },
	size: number, -- bytes of ops
	flushed: number,
	cache: string?,
	version: number, -- counts changes, that whoever reads it may know whether to again
}

export type Result = "same" | "changed" | "waiting" | "rebuild"

local text = {}

local INSERT, EXTEND, DELETE = 1, 2, 3
local NOBODY = string.rep("\0", 8)

function text.new(): Text
	return {
		blocks = {},
		count = 0,
		counts = {},
		visibles = {},
		visible = 0,
		pieces = {},
		waiting = {},
		base = "",
		open = "",
		ops = {},
		size = 0,
		flushed = 0,
		cache = nil,
		version = 0,
	}
end

local function piece_of(t: Text, id: string): Piece
	local p = t.pieces[id]
	if not p then
		p = { count = 0, rpiece = "", roffset = 0, fed = 0, stamp = "", shown = "", runs = {}, spans = {} }
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

-- A piece's span holding an element, and where it is among them.
local function span_of(p: Piece, offset: number): (Span?, number)
	local list = p.spans
	local lo, hi = 1, #list
	while lo <= hi do
		local mid = (lo + hi) // 2
		local s = list[mid]
		if offset < s.offset then
			hi = mid - 1
		elseif offset >= s.offset + s.len then
			lo = mid + 1
		else
			return s, mid
		end
	end
	return nil, lo
end

-- ---------------------------------------------------------------- the document, in blocks

-- Adds to a block's entry in a Fenwick tree.
local function grow(tree: { number }, at: number, n: number)
	local i, last = at, #tree
	while i <= last do
		tree[i] += n
		i += bit32.band(i, -i)
	end
end

-- The sum of the first so many blocks' entries.
local function sum(tree: { number }, blocks: number): number
	local n, i = 0, blocks
	while i > 0 do
		n += tree[i]
		i -= bit32.band(i, -i)
	end
	return n
end

-- How many whole blocks come before the entry that first takes the sum past n, or that reaches it; and what is left of n
-- in that block.
local function block_at(tree: { number }, n: number, reach: boolean): (number, number)
	local last = #tree
	local b = 0
	local step = if last > 0 then bit32.lshift(1, 31 - bit32.countlz(last)) else 0
	while step > 0 do
		local next = b + step
		if next <= last and (if reach then tree[next] < n else tree[next] <= n) then
			b = next
			n -= tree[next]
		end
		step //= 2
	end
	return b, n
end

-- Both trees made again, as when a block is put among the others.
local function remake(t: Text)
	local blocks = t.blocks
	local last = #blocks
	local counts, visibles = table.create(last, 0), table.create(last, 0)
	for k, b in blocks do
		b.at = k
		counts[k] += #b.spans
		visibles[k] += b.visible
		local up = k + bit32.band(k, -k)
		if up <= last then
			counts[up] += counts[k]
			visibles[up] += visibles[k]
		end
	end
	t.counts, t.visibles = counts, visibles
end

-- The span at a place in the document, from 1: in the first block, as all of a short text is, at once. (Assigned, as
-- shown is, rather than declared, so that it is called rather than copied into every caller: the copies cost more to
-- load than they save.)
local span_at: (Text, number) -> Span
span_at = function(t: Text, i: number): Span
	local first = t.blocks[1].spans
	if i <= #first then
		return first[i]
	end
	local b, rest = block_at(t.counts, i - 1, false)
	return t.blocks[b + 1].spans[rest + 1]
end

-- Where a span is in the document: its block's place, and then its label among the labels of that block, which go up
-- along it.
local function index_of(t: Text, s: Span): number
	local b = s.block
	local spans, label = b.spans, s.label
	local lo, hi = 1, #spans
	while lo <= hi do
		local mid = (lo + hi) // 2
		local l = spans[mid].label
		if l < label then
			lo = mid + 1
		elseif l > label then
			hi = mid - 1
		else
			return (if b.at > 1 then sum(t.counts, b.at - 1) else 0) + mid
		end
	end
	error("a span is not where its label says")
end

-- A visible span's bytes have grown, or shrunk, by n, or gone.
local shown: (Text, Span, number) -> ()
shown = function(t: Text, s: Span, n: number)
	s.block.visible += n
	grow(t.visibles, s.block.at, n)
end

-- Labels go up along the document, with room between them; when there is none, they are made again.
local GAP = 2 ^ 20
local function label(t: Text, b: Block, k: number)
	local spans = b.spans
	local before: Span? = spans[k - 1]
	if not before and b.at > 1 then
		local prev = t.blocks[b.at - 1].spans
		before = prev[#prev]
	end
	local after: Span? = spans[k + 1]
	if not after and b.at < #t.blocks then
		after = t.blocks[b.at + 1].spans[1]
	end
	local lo = if before then before.label else 0
	local l = if after then (lo + after.label) / 2 else lo + GAP
	if after and not (l > lo and l < after.label) then
		local n = 0
		for _, x in t.blocks do
			for _, y in x.spans do
				n += 1
				y.label = n * GAP
			end
		end
		return
	end
	spans[k].label = l
end

-- Puts a span at a place in the document, from 1, and labels it.
local function put(t: Text, i: number, s: Span)
	local blocks = t.blocks
	local b: Block, k: number
	if #blocks == 0 then
		b = { spans = {}, at = 1, visible = 0 }
		table.insert(blocks, b)
		k = 1
		remake(t)
	elseif i > t.count then
		b = blocks[#blocks]
		k = #b.spans + 1
	else
		local before, rest = block_at(t.counts, i - 1, false)
		b, k = blocks[before + 1], rest + 1
	end
	local whole = false
	if #b.spans == BLOCK then
		-- What is written at the end fills blocks, and elsewhere halves them.
		local keep = if k == BLOCK + 1 then BLOCK else BLOCK // 2
		local more: Block = { spans = table.move(b.spans, keep + 1, BLOCK, 1, table.create(BLOCK) :: { Span }), at = b.at + 1, visible = 0 }
		for x = BLOCK, keep + 1, -1 do
			b.spans[x] = nil
		end
		for _, x in more.spans do
			x.block = more
			if not x.dead then
				more.visible += x.len
			end
		end
		b.visible -= more.visible
		table.insert(blocks, b.at + 1, more)
		if k > keep then
			b, k = more, k - keep
		end
		whole = true
	end
	table.insert(b.spans, k, s)
	s.block = b
	t.count += 1
	local n = if s.dead then 0 else s.len
	b.visible += n
	if whole then
		remake(t)
	else
		grow(t.counts, b.at, 1)
		if n > 0 then
			grow(t.visibles, b.at, n)
		end
	end
	label(t, b, k)
end

-- The first span at or after which the visible bytes reach pos (from 1), or one past the last; and the visible bytes
-- before it. By the blocks' bytes, and then along one block.
local function seek(t: Text, pos: number): (number, number, Span?)
	local b, rest = block_at(t.visibles, pos, true)
	if b == #t.blocks then
		return t.count + 1, 0, nil
	end
	local spans = t.blocks[b + 1].spans
	local before = pos - rest
	local k = 1
	while true do
		local s = spans[k]
		local n = if s.dead then 0 else s.len
		if before + n >= pos then
			return (if b > 0 then sum(t.counts, b) else 0) + k, before, s
		end
		before += n
		k += 1
	end
end

local function find(t: Text, piece: string, offset: number): (number, Span)
	-- By the piece's spans, and the block of the one found, as text.ts does.
	local p = t.pieces[piece]
	local s = if p then span_of(p, offset) else nil
	if s then
		return index_of(t, s), s
	end
	-- Not there only if the piece's spans are out of order, which typing nothing with `after` brings about: it is looked
	-- for along the whole document.
	local i = 0
	for _, b in t.blocks do
		for _, x in b.spans do
			i += 1
			if x.piece == piece and offset >= x.offset and offset < x.offset + x.len then
				return i, x
			end
		end
	end
	error("a reference that was checked is missing")
end

-- Splits the span at a place in the document, s, so that its first n bytes stand alone. Returns what follows them.
local function split(t: Text, i: number, n: number, s: Span): Span
	if n == 0 or n >= s.len then
		return s
	end
	local body = joined(s)
	local tail: Span = {
		piece = s.piece,
		offset = s.offset + n,
		len = s.len - n,
		parts = { string.sub(body, n + 1) },
		dead = s.dead,
		label = 0,
		block = s.block,
	}
	if not s.dead then
		shown(t, s, -tail.len)
	end
	s.parts = { string.sub(body, 1, n) }
	s.len = n
	put(t, i + 1, tail)
	local p = piece_of(t, s.piece)
	local _, at = span_of(p, s.offset)
	table.insert(p.spans, at + 1, tail)
	return tail
end

-- Index of the span ending with the element; 0 for the document's start.
local function left_of(t: Text, piece: string, offset: number): number
	if piece == "" then
		return 0
	end
	local i, s = find(t, piece, offset)
	split(t, i, offset - s.offset + 1, s)
	return i
end

-- Index of the span beginning with the element, and the span; one past the last for the document's end.
local function right_of(t: Text, piece: string, offset: number): (number, Span?)
	if piece == "" then
		return t.count + 1, nil
	end
	local i, s = find(t, piece, offset)
	local n = offset - s.offset
	if n > 0 then
		return i + 1, split(t, i, n, s)
	end
	return i, s
end

-- ---------------------------------------------------------------- the tree

local function run_of(t: Text, piece: string, offset: number): Run
	local runs = (t.pieces[piece] :: Piece).runs
	local lo, hi = 1, #runs
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if runs[mid].offset <= offset then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return runs[lo]
end

local function depth_of(t: Text, piece: string, offset: number): number
	if piece == "" then
		return 0
	end
	local r = run_of(t, piece, offset)
	return r.depth + offset - r.offset
end

local steps = 0 -- taken in finding places, which tests count

-- What an element hangs beneath at a depth no greater than its own, in a few steps however deep.
local function ancestor(t: Text, piece: string, offset: number, depth: number): (string, number)
	if depth == 0 then
		return "", 0
	end
	local r = run_of(t, piece, offset)
	while r.depth > depth do
		steps += 1
		local j = r.jump
		r = if j and j.depth > depth then j else r.up :: Run
	end
	return r.piece, r.offset + depth - r.depth
end

-- Whether one element hangs beneath another; everything beneath the start, and nothing beneath the end.
local function below(t: Text, xp: string, xo: number, ap: string, ao: number): boolean
	if xp == "" then
		return false
	elseif ap == "" then
		return true
	end
	local dx, da = depth_of(t, xp, xo), depth_of(t, ap, ao)
	if dx <= da then
		return false
	end
	local p, o = ancestor(t, xp, xo, da)
	return p == ap and o == ao
end

-- Siblings go by piece and then by number.
local function key_less(ap: string, ao: number, bp: string, bo: number): boolean
	return ap < bp or (ap == bp and ao < bo)
end

type Probe = { piece: string, offset: number, depth: number, kpiece: string, koffset: number, right: boolean }

-- Whether a span hangs beneath the parent, beneath a sibling before what is inserted on the right, or after it on the
-- left. Going away from the parent such spans come first, and then none.
local function probe(t: Text, i: number, q: Probe): boolean
	steps += 1
	local s = span_at(t, i)
	if not below(t, s.piece, s.offset, q.piece, q.offset) then
		return false
	end
	local cp, co = ancestor(t, s.piece, s.offset, q.depth + 1)
	if q.right then
		return key_less(cp, co, q.kpiece, q.koffset)
	end
	return key_less(q.kpiece, q.koffset, cp, co)
end

-- The first index from i on of which the probe is false (or one past the last), by doubling and halving.
local function seek_forward(t: Text, i: number, q: Probe): number
	local n = t.count
	if i > n or not probe(t, i, q) then
		return i
	end
	local lo, step = i, 1
	while lo + step <= n and probe(t, lo + step, q) do
		lo += step
		step *= 2
	end
	local hi = math.min(lo + step, n + 1)
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if probe(t, mid, q) then
			lo = mid
		else
			hi = mid
		end
	end
	return hi
end

-- The last index from i back of which the probe is false, or 0.
local function seek_back(t: Text, i: number, q: Probe): number
	if i < 1 or not probe(t, i, q) then
		return i
	end
	local hi, step = i, 1
	while hi - step >= 1 and probe(t, hi - step, q) do
		hi -= step
		step *= 2
	end
	local lo = math.max(hi - step, 0)
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if probe(t, mid, q) then
			hi = mid
		else
			lo = mid
		end
	end
	return lo
end

local function insert_run(t: Text, id: string, bytes: string, lpiece: string, loffset: number, rpiece: string, roffset: number)
	t.cache = nil
	t.version += 1
	local p = piece_of(t, id)
	local offset = p.count
	p.count += #bytes
	p.rpiece, p.roffset = rpiece, roffset

	-- Beneath the right neighbour if that is beneath the left, and otherwise beneath the left.
	local under = below(t, rpiece, roffset, lpiece, loffset)
	local ppiece, poffset = lpiece, loffset
	if under then
		ppiece, poffset = rpiece, roffset
	end
	local chain = not under and ppiece == id and poffset == offset - 1
	if not chain then
		local up = if ppiece ~= "" then run_of(t, ppiece, poffset) else nil
		local run: Run = { piece = id, offset = offset, ppiece = ppiece, poffset = poffset, right = not under, depth = depth_of(t, ppiece, poffset) + 1, hops = 1, up = up, jump = up }
		if up then
			run.hops = up.hops + 1
			local j = up.jump
			if j then
				local jj = j.jump
				if up.hops - j.hops == j.hops - (if jj then jj.hops else 0) then
					run.jump = jj
				end
			end
		end
		table.insert(p.runs, run)
	end

	-- Among its siblings, each with all beneath it: on the right, after the parent; on the left, before it.
	local q: Probe = { piece = ppiece, offset = poffset, depth = depth_of(t, ppiece, poffset), kpiece = id, koffset = offset, right = not under }
	local at
	if under then
		at = seek_back(t, (right_of(t, ppiece, poffset)) - 1, q) + 1
	else
		at = seek_forward(t, left_of(t, ppiece, poffset) + 1, q)
	end
	if at > 1 and chain then
		local b = span_at(t, at - 1)
		if b.piece == id and b.offset + b.len == offset and not b.dead then
			table.insert(b.parts, bytes)
			b.len += #bytes
			t.visible += #bytes
			shown(t, b, #bytes)
			return
		end
	end
	local made: Span = { piece = id, offset = offset, len = #bytes, parts = { bytes }, dead = false, label = 0, block = nil :: any }
	put(t, at, made)
	t.visible += #bytes
	table.insert(p.spans, made) -- the newest of its piece, so the last
end

local function kill(t: Text, piece: string, offset: number, count: number)
	t.cache = nil
	t.version += 1
	while count > 0 do
		local i, at = right_of(t, piece, offset)
		local s = at :: Span
		split(t, i, count, s)
		if not s.dead then
			t.visible -= s.len
			shown(t, s, -s.len)
		end
		s.dead = true
		offset += s.len
		count -= s.len
	end
end

-- No offset or count is so large: what says one is nonsense, as zsp/text.odin has it.
local MOST = 2 ^ 30

local function malformed()
	error(codec.Malformed, 0)
end

local function read_ref(r: codec.Reader, id: string): (string, number)
	local tag = codec.u8(r)
	if tag == 0 then
		return "", 0
	end
	local piece = id
	if tag == 2 then
		piece = codec.take(r, 8)
	elseif tag ~= 1 then
		malformed()
	end
	local offset = codec.varint(r)
	if piece == NOBODY or offset > MOST then
		malformed()
	end
	return piece, offset
end

-- What a reference to what is not here says: to wait for another piece, or, of this one, nonsense.
local function own(piece: string, id: string): boolean
	if piece == id then
		malformed()
	end
	return false
end

-- One operation: the reader is left after it, or false is returned if it refers to what is not here. What is not an
-- operation at all raises codec.Malformed.
local function apply_op(t: Text, id: string, r: codec.Reader): boolean
	local op = codec.u8(r)
	if op == INSERT then
		local lp, lo = read_ref(r, id)
		local rp, ro = read_ref(r, id)
		local bytes = codec.bytes(r)
		-- What this piece has yet to make, it never will before it is wanted: that is nonsense, not something to wait for.
		if not has(t, lp, lo, 1) then
			return own(lp, id)
		elseif not has(t, rp, ro, 1) then
			return own(rp, id)
		end
		if #bytes > 0 then
			insert_run(t, id, bytes, lp, lo, rp, ro)
		end
	elseif op == EXTEND then
		local bytes = codec.bytes(r)
		local p = piece_of(t, id)
		if p.count == 0 then
			malformed() -- what it would extend comes before it, or never
		end
		if #bytes > 0 then
			insert_run(t, id, bytes, id, p.count - 1, p.rpiece, p.roffset)
		end
	elseif op == DELETE then
		local fp, fo = read_ref(r, id)
		local count = codec.varint(r)
		if fp == "" or count > MOST then
			malformed()
		end
		if not has(t, fp, fo, count) then
			return own(fp, id)
		end
		kill(t, fp, fo, count)
	else
		malformed() -- no such operation
	end
	return true
end

-- Applies operations in order until one refers to what is not here. Returns the bytes consumed, and whether it stopped at
-- what does not read as an operation: then the rest of its piece is nothing, and waits for nothing, since nothing that
-- comes could make it read.
local function apply_ops(t: Text, id: string, ops: string): (number, boolean)
	local r = codec.reader(ops)
	local done = 0
	while r.pos < r.len do
		local ok, applied: any = pcall(apply_op, t, id, r)
		if not ok then
			if applied ~= codec.Malformed then
				error(applied, 0)
			end
			return done, true
		elseif not applied then
			break
		end
		local p = piece_of(t, id)
		if p.stamp == "" and id ~= t.open then
			p.shown ..= string.sub(ops, done + 1, r.pos)
		end
		p.fed += r.pos - done
		done = r.pos
	end
	return done, false
end

local function retry(t: Text)
	local i = 1
	while i <= #t.waiting do
		local w = t.waiting[i]
		local n, bad = apply_ops(t, w.piece, string.sub(w.rest, w.at + 1))
		w.at += n
		-- Done, or the rest is nothing: what was after it is looked at next, rather than passed over until the next time.
		if w.at == #w.rest or bad then
			table.remove(t.waiting, i)
		elseif n == 0 then
			i += 1
		end
		if n > 0 then
			i = 1
		end
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
	local fed = piece.fed
	local n, bad = apply_ops(t, id, string.sub(ops, fed + 1))
	local at = fed + n
	if at < #ops and not bad then -- only what refers to what is not here waits
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
		if #body < 4 then
			return "same"
		end
		local r = codec.reader(body)
		local n: number = string.unpack(">I4", body) :: any
		if n == 0 or 4 + n * 16 > #body then
			return "same"
		end
		-- Nor anything later than the last it names, as nothing put together of what it names is: it would be taken for
		-- written before the bundle was.
		local last = string.sub(body, 5 + (n - 1) * 16, 4 + n * 16)
		r.pos = 4 + n * 16
		local out: Result = "same"
		while r.pos < r.len do
			-- Each piece as far as the bundle holds one whole: what follows one that runs past its end is not read.
			if r.pos + 24 > r.len then
				break
			end
			local inner = codec.take(r, 16)
			local id = codec.take(r, 8)
			local fine, ops = pcall(codec.bytes, r)
			if not fine then
				break
			end
			if inner > t.base and inner <= last then
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
	for _, b in t.blocks do
		if b.visible > 0 then
			for _, s in b.spans do
				if not s.dead then
					table.insert(out, joined(s))
				end
			end
		end
	end
	local s = table.concat(out)
	t.cache = s
	return s
end

-- How many bytes are there.
function text.len(t: Text): number
	return t.visible
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

-- Writes an insertion of bytes between two elements, and makes it.
local function typed(t: Text, bytes: string, lp: string, lo: number, rp: string, ro: number)
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

-- Writes a deletion of a span, which is dead.
local function deleted(t: Text, s: Span)
	local w = codec.writer()
	codec.put_u8(w, DELETE)
	put_ref(w, t.open, s.piece, s.offset)
	codec.put_varint(w, s.len)
	record(t, w)
end

-- Types bytes before the visible byte at `pos` (zero-based). `fresh` draws eight random bytes.
function text.insert(t: Text, pos: number, bytes: string, fresh: () -> string)
	if bytes == "" then
		return
	end
	begin(t, fresh)
	local lp, lo, rp, ro = "", 0, "", 0
	local i = 1
	if pos > 0 then
		-- The span the byte before it is in; past the end, it is put between the start and the end.
		local before, s
		i, before, s = seek(t, pos)
		if s then
			split(t, i, pos - before, s)
			lp, lo = s.piece, s.offset + s.len - 1
			i += 1
		end
	end
	if i <= t.count then
		local s = span_at(t, i)
		rp, ro = s.piece, s.offset
	end
	typed(t, bytes, lp, lo, rp, ro)
end

-- Deletes visible bytes from `pos` (zero-based); short of `most` bytes of the open piece's operations, if said, when it
-- stops there and says how many it has yet to delete.
local DELETE_MOST = 1 + 1 + 8 + 5 + 5 -- bytes of a deletion's operation, at most
function text.delete(t: Text, pos: number, count: number, fresh: () -> string, most: number?): number
	if count <= 0 then
		return 0
	end
	begin(t, fresh)
	t.cache = nil
	t.version += 1
	-- From the span the first byte is in.
	local i, before, first = seek(t, pos + 1)
	if first then
		pos -= before
	end
	while i <= t.count and count > 0 do
		local s = if first then first else span_at(t, i)
		first = nil
		if s.dead then
			i += 1
		elseif pos >= s.len then
			pos -= s.len
			i += 1
		elseif pos > 0 then
			first = split(t, i, pos, s)
			pos = 0
			i += 1
		else
			if most and t.size + DELETE_MOST > most then
				return count
			end
			split(t, i, count, s)
			s.dead = true
			t.visible -= s.len
			shown(t, s, -s.len)
			deleted(t, s)
			count -= s.len
			i += 1
		end
	end
	return 0
end

-- ---------------------------------------------------------------- elements by name

-- An element's name: its piece, and its offset in it.
local function eid(piece: string, offset: number): string
	return piece .. string.pack(">I4", offset)
end

local function uneid(id: string): (string, number)
	return string.sub(id, 1, 8), (string.unpack(">I4", id, 9) :: any) :: number
end

-- The elements that are there, in order: one name for each visible byte.
function text.ids(t: Text): { string }
	local out = {}
	for _, b in t.blocks do
		for _, s in b.spans do
			if not s.dead then
				for k = 0, s.len - 1 do
					table.insert(out, eid(s.piece, s.offset + k))
				end
			end
		end
	end
	return out
end

-- Where every element is, deleted or not, by name: what was inserted next to one stays next to it.
function text.order(t: Text): { [string]: number }
	local out = {}
	local n = 0
	for _, b in t.blocks do
		for _, s in b.spans do
			for k = 0, s.len - 1 do
				n += 1
				out[eid(s.piece, s.offset + k)] = n
			end
		end
	end
	return out
end

-- Types bytes just after an element, deleted or not ("" for the start), and says what the first is called.
function text.after(t: Text, after: string, bytes: string, fresh: () -> string): string
	if bytes == "" then
		return "" -- nothing is put, and nothing named
	end
	begin(t, fresh)
	local lp, lo = "", 0
	local i = 1
	if after ~= "" then
		lp, lo = uneid(after)
		i = left_of(t, lp, lo) + 1
	end
	local rp, ro = "", 0
	if i <= t.count then
		local s = span_at(t, i)
		rp, ro = s.piece, s.offset
	end
	local id = t.open
	local first = piece_of(t, id).count
	typed(t, bytes, lp, lo, rp, ro)
	return eid(id, first)
end

-- Deletes elements by name: so many from one on, of one piece, those still there.
function text.remove(t: Text, id: string, count: number, fresh: () -> string)
	begin(t, fresh)
	t.cache = nil
	t.version += 1
	local piece, offset = uneid(id)
	while count > 0 do
		local i, at = right_of(t, piece, offset)
		local s = at :: Span
		split(t, i, count, s)
		if not s.dead then
			s.dead = true
			t.visible -= s.len
			shown(t, s, -s.len)
			deleted(t, s)
		end
		offset += s.len
		count -= s.len
	end
end

-- Where an element is, deleted or not, as two numbers to compare in order; nil if it is not here.
function text.position(t: Text, id: string): (number?, number)
	local piece, offset = uneid(id)
	local p = t.pieces[piece]
	if not p then
		return nil, 0
	end
	local s = span_of(p, offset)
	if not s then
		return nil, 0
	end
	return s.label, offset
end

-- Whether an element is here, and not deleted.
function text.standing(t: Text, id: string): boolean
	local piece, offset = uneid(id)
	local p = t.pieces[piece]
	local s = if p then span_of(p, offset) else nil
	return s ~= nil and not s.dead
end

-- Whether an element is here, deleted or not.
function text.has(t: Text, id: string): boolean
	local piece, offset = uneid(id)
	return has(t, piece, offset, 1)
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

-- Steps taken so far in finding places: for tests.
function text.steps(): number
	return steps
end

return table.freeze(text)
