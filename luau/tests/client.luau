--!strict
-- The client against a node made of nothing: what it says, and what it makes of what it is told.

local codec = require("../zsp/codec")
local zsp = require("../zsp")

-- `./x selftest` sets ZSP_FAIL, to see that ./x test says this failed.
if require("@lune/process").env.ZSP_FAIL then
	error("failing, as ZSP_FAIL asks")
end

local HELLO, ROSTER, WATCH, CELLS, ACK, SYNCED, ERROR = 1, 2, 3, 7, 8, 10, 13
local ANSWER, FETCH = 34, 35

type Said = { kind: number, body: string }

local function harness()
	local self = { said = {} :: { Said }, receive = nil :: any, closed = nil :: any, deferred = {} :: { any }, later = {} :: { any }, waits = {} :: { number }, timers = 0, closes = 0, connects = 0, sizes = {} :: { number }, partial = "" }
	local function run()
		while #self.deferred > 0 do
			(table.remove(self.deferred, 1) :: any)()
		end
	end
	local client = zsp.connect({
		credential = "x",
		now = function(): number
			return 1800000000
		end,
		random = function(n: number): string
			local out = {}
			for i = 1, n do
				out[i] = string.char(math.random(0, 255))
			end
			return table.concat(out)
		end,
		defer = function(f: () -> ())
			table.insert(self.deferred, f)
		end,
		after = function(seconds: number, f: () -> ())
			-- Of what is to be done later, how much is neither done nor cancelled.
			local live = true
			self.timers += 1
			table.insert(self.later, function()
				if live then
					live = false
					self.timers -= 1
					f()
				end
			end)
			table.insert(self.waits, seconds)
			return function()
				if live then
					live = false
					self.timers -= 1
				end
			end
		end,
		connect = function(receive: any, closed: any)
			self.connects += 1
			self.receive, self.closed = receive, closed
			return {
				send = function(data: buffer)
					-- A stream of bytes, in pieces of no more than a mebibyte, and frames whole only once all of each has come.
					assert(buffer.len(data) <= 1048576, `a message of {buffer.len(data)} bytes`)
					table.insert(self.sizes, buffer.len(data))
					local all = self.partial .. buffer.tostring(data)
					local at = 1
					while true do
						local n, shift, p = 0, 0, at
						while p <= #all and string.byte(all, p) >= 128 do
							n += (string.byte(all, p) - 128) * 2 ^ shift
							shift += 7
							p += 1
						end
						if p > #all then
							break
						end
						n += string.byte(all, p) * 2 ^ shift
						p += 1
						if p + n - 1 > #all then
							break
						end
						local body = string.sub(all, p, p + n - 1)
						table.insert(self.said, { kind = string.byte(body), body = string.sub(body, 2) })
						at = p + n
					end
					self.partial = string.sub(all, at)
				end,
				close = function()
					self.closes += 1
				end,
			}
		end,
	})
	local function tell(kind: number, body: string)
		local w = codec.writer()
		codec.put_bytes(w, string.char(kind) .. body)
		self.receive(codec.string(w))
		run()
	end
	local function greet()
		tell(ROSTER, string.rep("\0", 8) .. "\1\7" .. string.rep("k", 32))
	end
	local function last(kind: number): Said?
		for i = #self.said, 1, -1 do
			if self.said[i].kind == kind then
				return self.said[i]
			end
		end
		return nil
	end
	local function laters()
		local due = self.later
		self.later = {}
		for _, f in due do
			f()
		end
	end
	return { client = client, self = self, run = run, tell = tell, greet = greet, last = last, laters = laters }
end

local Note = { title = zsp.string(16), body = zsp.text(17) }

local function watch_of(said: any): (number, number, string, string, number)
	local r = codec.reader(said.body)
	return codec.varint(r), codec.u8(r), codec.key(r), codec.key(r), codec.varint(r)
end

local function synced(h: any, id: number, flags: number, lo: string, hi: string, before: number?, after: number?)
	local w = codec.writer()
	codec.put_varint(w, id)
	codec.put_u8(w, flags)
	codec.put_key(w, lo)
	codec.put_key(w, hi)
	codec.put_varint(w, before or 0)
	codec.put_varint(w, after or 0)
	h.tell(SYNCED, codec.string(w))
end

-- A pipe that breaks while a page is still owed is asked for the same page, not for everything.
do
	local h = harness()
	h.run()
	h.greet()
	h.client:window({ scope = 1, list = "a", table = Note, size = 50 }, function() end)
	h.run()
	local _, flags, _, _, limit = watch_of(h.last(WATCH))
	assert(limit == 50 and bit32.btest(flags, 4))
	h.self.closed()
	h.run()
	for _, f in h.self.later do
		f()
	end
	h.run()
	h.greet()
	_, flags, _, _, limit = watch_of(h.last(WATCH))
	assert(limit == 50 and bit32.btest(flags, 4), `asked for {limit}`)
end

-- A window begins at the end unless it is said to begin at the start, whatever its list is called.
do
	local h = harness()
	h.run()
	h.greet()
	h.client:window({ scope = 1, list = "a/start/b", table = Note }, function() end)
	h.run()
	local _, flags = watch_of(h.last(WATCH))
	assert(bit32.btest(flags, 4), "it began at the start")
	h.client:window({ scope = 1, list = "a/end/b", table = Note, from = "start" }, function() end)
	h.run()
	_, flags = watch_of(h.last(WATCH))
	assert(not bit32.btest(flags, 4), "it began at the end")
end

-- A range said over again without a row takes it from that window and no other, and spares what is typed.
do
	local h = harness()
	h.run()
	h.greet()
	local a, b
	h.client:window({ scope = 1, list = "a", table = Note }, function(s)
		a = s
	end)
	h.client:window({ scope = 1, list = "b", table = Note }, function(s)
		b = s
	end)
	h.run()
	local id = ""
	h.client:write(1, function(change)
		id = change.insert(Note, "a", 1, { title = "t" })
		change.place(id, "b", 1, 2)
	end)
	h.run()
	local w = codec.writer()
	codec.put_varint(w, 1)
	h.tell(ACK, codec.string(w))
	local editor = h.client:text(id, Note.body)
	editor.append("hello world")
	h.run()
	assert(#a.rows == 1 and #b.rows == 1)
	local first: any = nil
	for _, s in h.self.said do
		if s.kind == WATCH and not first then
			first = s
		end
	end
	local page, _, lo, hi = watch_of(first)
	synced(h, page, 2, lo, hi)
	synced(h, page, 1, lo, hi)
	assert(#a.rows == 0, "gone from the one")
	assert(#b.rows == 1 and b.rows[1].body == "hello world", "and not from the other")
	assert(editor.read() == "hello world")
	local mine
	h.client:window({ scope = 1, list = "b", table = { other = zsp.string(16) } }, function(s)
		mine = s
	end)
	assert(mine, "another shape of row is another window")
end

-- A page a partial replica answered at once, from what it held, may end sooner once a full replica has said where it ends:
-- what the window showed beyond it is not let go of unseen, but asked for again as the page that follows.
do
	local h = harness()
	h.run()
	h.greet()
	local st
	local window = h.client:window({ scope = 1, list = "a", table = Note, size = 2 }, function(s)
		st = s
	end)
	h.run()
	for i = 1, 3 do
		h.client:write(1, function(change)
			change.insert(Note, "a", i, { title = `t{i}` })
		end)
	end
	h.run()
	local w = codec.writer()
	codec.put_varint(w, 3)
	h.tell(ACK, codec.string(w))
	local page, _, lo, hi = watch_of(h.last(WATCH))
	synced(h, page, 0, lo, hi) -- what is held: all three, to the end
	assert(#st.rows == 3)
	local keys = {}
	for i, e in window.entries() do
		keys[i] = e.key
	end
	local function watches(): { any }
		local out = {}
		for _, x in h.self.said do
			if x.kind == WATCH then
				table.insert(out, x)
			end
		end
		return out
	end
	local before = #watches()
	synced(h, page, 1, keys[1], keys[3], 0, 1) -- as a full replica says: two, and one more after
	local asked = watches()
	assert(#asked == before + 1, "the rest is asked for")
	local _, _, from = watch_of(asked[#asked])
	assert(from == keys[3], "from where the page now ends")
end

-- A window of all of a list is one page, however long: nothing of it is split, loaded or let go of as it is scrolled.
do
	local h = harness()
	h.run()
	h.greet()
	local st: any
	local all = h.client:window({ scope = 1, list = "all", table = Note, size = 0 }, function(x)
		st = x
	end)
	h.run()
	for i = 1, 10 do
		h.client:write(1, function(change)
			change.insert(Note, "all", i, { title = `t{i}` })
		end)
	end
	h.run()
	h.tell(ACK, "\10")
	local page, _, lo, hi = watch_of(h.last(WATCH))
	synced(h, page, 1, lo, hi)
	local function watches(): number
		local n = 0
		for _, x in h.self.said do
			n += if x.kind == WATCH then 1 else 0
		end
		return n
	end
	local before = watches()
	for _ = 1, 5 do
		all.visible(1, 10)
		h.run()
	end
	all.visible(1, 3)
	h.run()
	assert(watches() == before, "pages were made of it")
	assert(#st.rows == 10, "rows were let go of")
end

-- Many rows placed at once, while a follower moves or deletes one of them as it hears of it: every row is where it is held
-- to be, once, and the one deleted nowhere.
do
	for _, what in { "move", "delete" } do
		local h = harness()
		h.run()
		h.greet()
		local list = h.client:window({ scope = 1, list = "items", table = Note, size = 100 }, function() end)
		h.run()
		local first, heard = "", 0
		h.client:follow(function(id)
			heard += 1
			if heard == 1 then
				first = id
			elseif heard == 2 then
				h.client:write(1, function(change)
					if what == "move" then
						change.place(first, "items", 999)
					else
						change.delete(first)
					end
				end)
			end
		end)
		h.client:write(1, function(change)
			for i = 1, 70 do
				change.insert(Note, "items", i, { title = `r{i}` })
			end
		end)
		h.run()
		local entries = list.entries()
		local window = (next(h.client.windows) and select(2, next(h.client.windows))) :: any
		local at = 0
		for _ in window.at do
			at += 1
		end
		assert(at == #entries, "held where it is not")
		for i, e in entries do
			assert(i == 1 or entries[i - 1].key < e.key, "out of order")
			assert(window.at[e.row] == e.key, "held where it is not")
		end
		if what == "move" then
			assert(#entries == 70 and entries[70].row.id == first, "not moved")
		else
			assert(#entries == 69, "deleted, and still there")
			for _, e in entries do
				assert(e.row.id ~= first, "deleted, and still there")
			end
		end
	end
end

-- More said at once than a WebSocket of zspd's takes in one message, 8 MiB, goes in pieces, and arrives whole; and so it
-- does again on a pipe dialled anew, which would otherwise break every time it was said.
do
	local h = harness()
	h.run()
	h.greet()
	for i = 1, 12 do
		h.client:write(1, function(change)
			change.insert({ v = zsp.string(16) }, "big", i, { v = string.rep(string.char(i), 900000) })
		end)
	end
	h.run()
	local function cells(): number
		local n = 0
		for _, x in h.self.said do
			n += if x.kind == CELLS then 1 else 0
		end
		return n
	end
	assert(cells() == 12, "every write arrived whole")
	local total, most = 0, 0
	for _, n in h.self.sizes do
		total += n
		most = math.max(most, n)
	end
	assert(total > 10 * 1048576 and most <= 1048576)
	h.self.closed()
	h.run()
	for _, f in h.self.later do
		f()
	end
	h.run()
	h.greet()
	assert(cells() == 24, "and again, whole, on the next pipe")
end

-- A pipe that breaks as the first piece of a long burst is sent is sent no more of it, and the burst goes, whole, to the
-- pipe dialled next.
do
	local sends, connects = 0, 0
	local closed: any, receive: any = nil, nil
	local deferred, later = {}, {}
	local function run()
		while #deferred > 0 do
			(table.remove(deferred, 1) :: any)()
		end
	end
	local client = zsp.connect({
		credential = "x",
		now = function(): number
			return 1800000000
		end,
		random = function(n: number): string
			return string.rep("\7", n)
		end,
		defer = function(f: () -> ())
			table.insert(deferred, f)
		end,
		after = function(_: number, f: () -> ())
			table.insert(later, f)
			return function() end
		end,
		connect = function(r: any, c: any)
			connects += 1
			receive, closed = r, c
			local first = connects == 1
			return {
				send = function(data: buffer)
					sends += 1
					if first and buffer.len(data) == 1048576 then
						closed() -- as the pipe breaks, there and then
					end
				end,
				close = function() end,
			}
		end,
	})
	local function greet()
		local w = codec.writer()
		codec.put_bytes(w, string.char(ROSTER) .. string.rep("\0", 8) .. "\1\7" .. string.rep("k", 32))
		receive(codec.string(w))
		run()
	end
	run()
	greet()
	client:write(1, function(change)
		change.insert({ v = zsp.string(16) }, "big", 1, { v = string.rep("a", 900000) })
		change.insert({ v = zsp.string(16) }, "big", 2, { v = string.rep("b", 900000) })
	end)
	assert(pcall(run), "a pipe that broke as it was sent to")
	local before = sends
	for _, f in later do
		f()
	end
	run()
	greet()
	assert(connects == 2)
	assert(sends - before >= 2, "the burst went again, to the next pipe")
end

-- A text of a row not held, that nobody can say more of than that it is not held here, as a partial replica with nobody
-- to ask who can read says: what is typed is kept, and written once it is closed, not held back for ever.
do
	local h = harness()
	h.run()
	h.greet()
	local id = "\0\0\0\1" .. "\106\11\28\45" .. "\1\2\3\4\5\6\7\8"
	local editor = h.client:text(id, Note.body)
	h.run()
	editor.append("typed offline")
	h.run()
	local fetched = h.last(FETCH)
	assert(fetched, "the row was not asked for once")
	local w = codec.writer()
	codec.put_varint(w, codec.varint(codec.reader(fetched.body)))
	codec.put_u8(w, 32) -- the last, and not settled: what is held, which is nothing
	for _ = 1, 4 do
		codec.put_varint(w, 0)
	end
	h.tell(ANSWER, codec.string(w))
	assert(editor.read() == "typed offline")
	local function cells(): number
		local n = 0
		for _, x in h.self.said do
			n += if x.kind == CELLS then 1 else 0
		end
		return n
	end
	local before = cells()
	editor.close()
	h.run()
	assert(cells() > before, "what was typed was never written")
end

-- An editor of a row not yet here, closed before it came: what is no place in any text is refused at once; an edit at a
-- place the text did not have once it came is not made, and the rest are; and the row is then let go of, and nothing
-- is left asked for its sake.
local function cell_of(row: string, kind: number, slot: number, n: number, body: string): string
	local w = codec.writer()
	codec.put(w, string.char(kind) .. row .. string.char(slot) .. string.rep("\0", 15) .. string.char(n))
	codec.put_bytes(w, body)
	return codec.string(w)
end
local function answer_fetch(h: any, row: string)
	local w = codec.writer()
	codec.put_varint(w, codec.varint(codec.reader(h.last(FETCH).body)))
	codec.put(w, "\1\1\0\1" .. row .. "\0")
	h.tell(ANSWER, codec.string(w))
end
do
	local h = harness()
	h.run()
	h.greet()
	local id = "\0\0\0\1" .. string.pack(">I4", 1800000000) .. "\1\2\3\4\5\6\7\8"
	local editor = h.client:text(id, Note.body)
	h.run()
	assert(not pcall(editor.insert, -5, "x"), "a place no text has was taken")
	assert(not pcall(editor.delete, 0, 1.5), "a place no text has was taken")
	assert(not pcall(editor.insert, 0, nil :: any), "what is not a string was typed")
	editor.insert(10, "x")
	editor.append("!")
	editor.close()
	h.tell(CELLS, "\0" .. cell_of(id, 3, 17, 2, "hello"))
	local said = #h.self.said
	answer_fetch(h, id)
	h.run()
	local row = h.client:held(id)
	assert(row and next(row.held) == nil and row.asking == nil, "it is held for ever")
	assert(h.last(33), "and asked for for ever")
	assert(zsp.Text.read(h.client:held_text(id, 17) :: any) == "hello!", "what was typed is not what was asked")
	local written = false
	for k = said + 1, #h.self.said do
		written = written or h.self.said[k].kind == CELLS
	end
	assert(written, "and was not written")
end

-- Two editors of a row not yet here: what each does waits for it, and is done, in turn, to the text that came.
do
	local h = harness()
	h.run()
	h.greet()
	local id = "\0\0\0\1" .. string.pack(">I4", 1800000000) .. "\1\2\3\4\5\6\7\9"
	local one, two = h.client:text(id, Note.body), h.client:text(id, Note.body)
	h.run()
	for _, pair in { { one, "X" }, { two, "Y" } } do
		local editor = pair[1] :: any
		editor.delete(0, 1)
		editor.insert(2, pair[2])
	end
	h.tell(CELLS, "\0" .. cell_of(id, 3, 17, 2, "HELLO"))
	answer_fetch(h, id)
	h.run()
	assert(one.read() == "LXYLO", one.read())
	assert(two.read() == "LXYLO", two.read())
	one.close()
	two.close()
end

-- Writing nothing is still done; clearing a text says so.
do
	local h = harness()
	h.run()
	h.greet()
	local done = 0
	h.client:write(1, function() end, function()
		done += 1
	end)
	h.run()
	assert(done == 1)
	local id = ""
	h.client:write(1, function(change)
		id = change.insert(Note, "a", 1, { title = "t", body = "x" })
	end)
	h.run()
	local before = #h.self.said
	h.client:write(1, function(change)
		change.set(id, Note, { body = "" })
	end)
	h.run()
	assert(#h.self.said > before and (h.last(CELLS) :: any), "said")
	assert(not pcall(function()
		h.client:write(1, function(change)
			change.set(id, Note, { title = string.rep("x", 1048576) })
		end)
	end), "too much is refused before it is written")
end

-- Nonsense from the pipe ends the pipe and nothing else: a length longer than any frame's, a frame of nothing, a frame cut
-- short, a varint of more bytes than any. And it is as lost as any pipe: dialled again, and all is as it was.
do
	for _, nonsense in { string.rep("\128", 310) .. "\0", "\0", "\3\2\0\0", "\12\8" .. string.rep("\129", 10) .. "\1" } do
		local h = harness()
		h.run()
		h.greet()
		h.self.receive(nonsense)
		assert(h.self.closes == 1, "the pipe was not let go of")
		assert(not h.client.ready, "and it is not connected")
		h.laters()
		h.run()
		assert(h.self.connects == 2, "dialled again")
		h.greet()
		assert(h.client.ready)
		local call = h.client:call(string.rep("d", 32), 1, "m", "")
		assert(not pcall(call.send, string.rep("x", 262145)), "a message too big for any window is refused at once")
	end
	-- What does not decode is said to be so, as nothing else is: so that it is told from a fault of the reader's own.
	local function malformed(f: (codec.Reader) -> any, bytes: string): boolean
		local fine, why = pcall(f, codec.reader(bytes))
		return not fine and why == codec.Malformed
	end
	assert(malformed(codec.varint, string.rep("\129", 200) .. "\1"), "a varint of more than ten bytes")
	assert(malformed(codec.varint, string.rep("\255", 7) .. "\16"), "a varint beyond 2^53")
	assert(not malformed(codec.varint, string.rep("\255", 7) .. "\15"), "and not one below it")
	assert(malformed(codec.key, string.char(50) .. string.rep("A", 50)), "a key longer than 40 bytes")
	assert(malformed(codec.u8, ""), "a byte that is not there")
	local w = codec.writer()
	codec.put(w, string.rep("x", 120))
	assert(not pcall(codec.put_varint, w, 2 ^ 56), "no varint is written of what none is read as")
	codec.put_varint(w, 2 ^ 53 - 1)
	assert(codec.varint({ buf = w.buf, pos = 120, len = w.pos }) == 2 ^ 53 - 1)
end

-- What a pipe says after it was let go of, as by whoever was told of an error, is not heard: a client that was closed is
-- not connected again by a roster that followed.
do
	local h = harness()
	h.run()
	h.greet()
	h.client:on("error", function()
		h.client:close()
	end)
	local function frame(kind: number, body: string): string
		local w = codec.writer()
		codec.put_bytes(w, string.char(kind) .. body)
		return codec.string(w)
	end
	h.self.receive(frame(ERROR, "\4") .. frame(ROSTER, string.rep("\0", 8) .. "\1\7" .. string.rep("k", 32)))
	h.run()
	assert(not h.client.ready, "connected by what was said after it was closed")
end

-- A cell no node could have sent is nonsense, and ends the pipe rather than be looked through: a bundle that says it holds
-- more stamps than it has, or is too short to say how many; a placement too short to say where; a value where only
-- placements go. What came before it is shown, as it is held.
do
	local function cell(row: string, kind: number, slot: number, n: number, body: string): string
		local w = codec.writer()
		codec.put(w, string.char(kind) .. row .. string.char(slot) .. string.rep("\0", 15) .. string.char(n))
		codec.put_bytes(w, body)
		return codec.string(w)
	end
	for _, bad in {
		function(row: string): string
			return cell(row, 4, 17, 2, string.rep("p", 8)) .. cell("", 5 + 128, 17, 3, "\128\0\0\0")
		end,
		function(row: string): string
			return cell(row, 5, 17, 3, "ab")
		end,
		function(row: string): string
			return cell(row, 2, 1, 3, string.rep("t", 10))
		end,
		function(row: string): string
			return cell(row, 3, 3, 3, "x")
		end,
	} do
		local h = harness()
		h.run()
		h.greet()
		local seen: any
		h.client:window({ scope = 1, list = "a", table = Note }, function(st)
			seen = st
		end)
		h.run()
		local one, two = "\0\0\0\1" .. string.rep("1", 12), "\0\0\0\1" .. string.rep("2", 12)
		h.tell(CELLS, "\0" .. cell(one, 2, 1, 1, h.client:_tag(1, "a") .. codec.u64(1)) .. bad(two))
		assert(h.self.closes == 1, "the pipe was not let go of")
		assert(#seen.rows == 1, "what came before it was not shown")
	end
end

-- A client that is closed leaves nothing to be done later, whatever was to be: a window to let go of, a piece to seal,
-- live text to give up on. What an editor had typed is said first, sealed.
do
	local h = harness()
	h.run()
	h.greet()
	local list = h.client:window({ scope = 1, list = "a", table = Note }, function() end)
	h.run()
	local id = ""
	h.client:write(1, function(change)
		id = change.insert(Note, "a", 1, { title = "t" })
	end)
	h.run()
	local editor = h.client:text(id, Note.body)
	editor.append("typed")
	h.run()
	-- Live text, which is given up on if never sealed.
	h.tell(9, id .. "\17" .. string.rep("v", 8) .. "\0" .. string.rep("\0", 16) .. "\1\0\0\2hi")
	list.stop()
	assert(h.self.timers >= 3, `{h.self.timers} things to do`)
	local function cells(): number
		local n = 0
		for _, x in h.self.said do
			n += if x.kind == CELLS then 1 else 0
		end
		return n
	end
	local before = cells()
	h.client:close()
	assert(h.self.timers == 0, "something was left to be done")
	assert(cells() == before + 1, "what was typed was not said")
end

-- A node that refuses this client, or speaks another language, closes it: questions asked once are answered as far as
-- they got, and nothing is left to be done later, nor dialled again.
do
	for _, code in { 2, 3 } do
		local h = harness()
		h.run()
		h.greet()
		local got: any = nil
		coroutine.wrap(function()
			got = h.client:fetch({ scope = 1, table = Note })
		end)()
		h.run()
		h.tell(ERROR, string.char(code))
		assert(got and got.status == "loading", "what was asked once was never answered")
		assert(not h.client.ready and h.self.timers == 0, "something was left to be done")
		h.laters()
		h.run()
		assert(h.self.connects == 1, "and it was dialled again")
	end
end

-- A call made before the node has said what this client may do cannot be made, and is told so as it was when it was
-- made, though the node says it before the call is told.
do
	local h = harness()
	h.run()
	local call = h.client:call(string.rep("d", 32), 1, "m", "")
	local fault = ""
	call.on_fault = function(f)
		fault = f
	end
	h.greet()
	assert(fault == "unreachable", `told {fault}`)
end

-- A client that is closed is not connected, says so, and what it was calling is lost, at once: whether or not its host
-- says the pipe closed, as this one does not.
do
	local h = harness()
	h.run()
	h.greet()
	local told = {}
	h.client:on("status", function(up)
		table.insert(told, tostring(up))
	end)
	local call = h.client:call(string.rep("d", 32), 1, "m", "x")
	local fault = ""
	call.on_fault = function(f)
		fault = f
	end
	h.run()
	h.client:close()
	h.run()
	assert(not h.client.ready, "it is connected")
	assert(table.concat(told :: any, " ") == "true false", "and does not say otherwise")
	assert(fault == "lost", `what it was calling is {fault}`)
	h.laters()
	h.run()
	assert(h.self.connects == 1, "and it dials again")
end

-- One function that observes, hears or follows twice is two that do: stopping one leaves the other.
do
	local h = harness()
	h.run()
	h.greet()
	local heard, seen, followed = 0, 0, 0
	local function hear()
		heard += 1
	end
	local function see()
		seen += 1
	end
	local function follow()
		followed += 1
	end
	local stop_hearing = h.client:on("error", hear)
	h.client:on("error", hear)
	local one = h.client:window({ scope = 1, list = "a", table = Note }, see)
	h.client:window({ scope = 1, list = "a", table = Note }, see)
	local stop_following = h.client:follow(follow)
	h.client:follow(follow)
	h.run()
	stop_hearing()
	one.stop()
	stop_following()
	heard, seen, followed = 0, 0, 0
	h.client:write(1, function(change)
		change.insert(Note, "a", 1, { title = "t" })
	end)
	h.tell(ERROR, "\4")
	h.run()
	assert(heard == 1 and seen == 1 and followed == 1, `heard {heard}, seen {seen}, followed {followed}`)
end

-- What is sent for an answer waits for it, and what another answer shows outlives the one that stops.
do
	local ASK, UNASK, ANSWER = 32, 33, 34
	local h = harness()
	h.run()
	h.greet()
	local function row(id: string, n: number): string
		local w = codec.writer()
		codec.put_u8(w, 3) -- a value, and a row first named
		codec.put(w, id)
		codec.put_u8(w, 16)
		codec.put(w, string.rep("\0", 15) .. string.char(n))
		codec.put_bytes(w, "title " .. n)
		return codec.string(w)
	end
	local function answer(id: number, ids: { string })
		local w = codec.writer()
		codec.put_varint(w, id)
		codec.put_u8(w, 1)
		codec.put_varint(w, #ids)
		codec.put_varint(w, 0)
		codec.put_varint(w, #ids)
		codec.put(w, table.concat(ids))
		codec.put_varint(w, 0)
		h.tell(ANSWER, codec.string(w))
	end
	local function flags(id: number, f: number)
		h.tell(ANSWER, string.char(id, f) .. if f == 8 then "\42" else "")
	end
	local one, two = string.rep("1", 16), string.rep("2", 16)
	local a, b
	local first = h.client:ask({ scope = 1, table = Note }, function(s)
		a = s
	end)
	local second = h.client:ask({ scope = 1, table = Note, where = zsp.where.is("title", "x"), limit = 7 }, function(s)
		b = s
	end)
	h.run()
	assert(a.status == "loading" and h.last(ASK))
	flags(1, 8)
	assert(a.status == "indexing" and a.progress == 0.42)
	h.tell(CELLS, "\0" .. row(one, 1) .. row(two, 2))
	assert(#a.rows == 0)
	answer(1, { one })
	assert(a.status == "ready" and #a.rows == 1 and a.rows[1].title == "title 1" and a.total == 1)
	assert(h.client.rows[two] == nil, "what no answer shows is not held")
	local was = a
	h.tell(CELLS, "\0" .. row(one, 9))
	assert(a ~= was and a.rows[1].title == "title 9", "and what one does is kept up")
	first.stop()
	h.run()
	assert(h.last(UNASK))
	answer(2, { one }) -- the node says this before it knows, so it does not send the row
	assert(b.rows[1].title == "title 9")
	flags(1, 16)
	assert(b.rows[1].title == "title 9" and h.client.rows[one])
	-- Asked again down a new pipe, and over what was.
	h.self.closed()
	h.run()
	assert(b.status == "stale" and #b.rows == 1)
	local before = #h.self.said
	for _, f in h.self.later do
		f()
	end
	h.run()
	h.greet()
	local again = 0
	for i = before + 1, #h.self.said do
		again += if h.self.said[i].kind == ASK then 1 else 0
	end
	assert(again == 1)
	second.move(7)
	h.run()
	local r = codec.reader((h.last(ASK) :: any).body)
	assert(codec.varint(r) == 2 and string.sub((h.last(ASK) :: any).body, -3) == "\7\7\0")
	flags(2, 2)
	assert(b.status == "denied" and #b.rows == 0 and next(h.client.rows) == nil)
	second.stop()
	second.stop()
	flags(2, 16)
	assert(next(h.client.asked) == nil)
	-- One that is stopped is not asked again when it might have been.
	local third = h.client:ask({ scope = 1, table = Note }, function(s)
		a = s
	end)
	flags(3, 2)
	third.stop()
	h.run()
	local said = #h.self.said
	local function scopes(...: number)
		local w = codec.writer()
		codec.put(w, string.rep("\0", 8))
		for _, scope in { ... } do
			codec.put_varint(w, scope)
			codec.put(w, "\7" .. string.rep("k", 32))
		end
		h.tell(ROSTER, codec.string(w))
	end
	scopes(1)
	for i = said + 1, #h.self.said do
		assert(h.self.said[i].kind ~= ASK)
	end
	flags(3, 17)
	assert(next(h.client.asked) == nil)
	-- One that needs to read what cannot be is denied, and asked once it can.
	local w = zsp.where
	local joined = h.client:ask({ scope = 1, table = Note, where = w.refers("title", 2, w.in_list("inbox"), Note) }, function(s)
		a = s
	end)
	h.run()
	assert(a.status == "denied")
	said = #h.self.said
	scopes(1, 2)
	h.run()
	assert(h.self.said[#h.self.said].kind == ASK and #h.self.said == said + 1)
	joined.stop()
	flags(4, 16)
	-- A question that makes no sense here is an error here.
	assert(not pcall(function()
		h.client:ask({ scope = 1, table = Note, where = zsp.where.is("nothing", 1) }, function() end)
	end))
	assert(next(h.client.asked) == nil)
	-- What is asked once is answered once, down whichever pipe, and let go of.
	local got: any
	local function fetch()
		coroutine.wrap(function()
			got = h.client:fetch({ scope = 1, table = Note })
		end)()
		h.run()
	end
	fetch()
	local FETCH = 35
	assert(not got and h.last(FETCH))
	local id = codec.varint(codec.reader((h.last(FETCH) :: any).body))
	flags(id, 8)
	assert(not got)
	h.self.closed()
	h.run()
	before = #h.self.said
	for _, f in h.self.later do
		f()
	end
	h.run()
	h.greet()
	assert(h.self.said[#h.self.said].kind == FETCH)
	h.tell(CELLS, "\0" .. row(one, 4))
	do
		local w = codec.writer()
		codec.put_varint(w, id)
		codec.put(w, "\33\1\0\1" .. one .. "\0")
		h.tell(ANSWER, codec.string(w))
	end
	assert(got.status == "ready" and got.rows[1].title == "title 4" and got.total == 1)
	assert(h.client.rows[one] == nil and h.client.asked[id] == nil)
	got = nil
	fetch()
	flags(id + 1, 2)
	assert(got.status == "denied" and #got.rows == 0)
	coroutine.wrap(function()
		got = h.client:fetch({ scope = 5, table = Note })
	end)()
	assert(got.status == "denied")
	-- A scope that cannot be read is known to be.
	h.client:ask({ scope = 5, table = Note }, function(s)
		a = s
	end)
	assert(a.status == "denied")
end

-- Whose a row is, is shown and can be asked about; and when it is another's after all, or by another name, so shown.
do
	local AUTHOR, CALL, SERVE, ASK = 17, 15, 14, 32
	local Signed = { title = zsp.string(16), by = zsp.author(16), body = zsp.text(17), writers = zsp.authors(17) }
	local h = harness()
	h.run()
	assert(string.sub(h.self.said[1].body, 1, 2) == "\1\4", "it wants to be told")
	h.tell(ROSTER, string.rep("\0", 8) .. "\1\7" .. string.rep("k", 32) .. "\2\135" .. string.rep("k", 32))
	local me: any
	h.client:on("self", function(who)
		me = who
	end)
	h.tell(AUTHOR, "\0" .. string.rep("d", 32) .. "\2me")
	assert(me.subject == "me" and me.id == string.rep("d", 32))
	local shown: any, plain: any
	h.client:window({ scope = 2, list = "a", table = Signed }, function(s)
		shown = s
	end)
	h.client:window({ scope = 1, list = "a", table = Signed }, function(s)
		plain = s
	end)
	h.run()
	local mine, theirs = "", ""
	h.client:write(2, function(change)
		mine = change.insert(Signed, "a", 1, { title = "t" })
	end)
	h.client:write(1, function(change)
		theirs = change.insert(Signed, "a", 1, { title = "t" })
	end)
	h.run()
	assert(shown.rows[1].by == "me" and #shown.rows[1].writers == 0)
	assert(plain.rows[1].by == nil, "where nobody is told, neither is this")
	local editor = h.client:text(mine, Signed.body)
	editor.append("typed")
	editor.close()
	h.run()
	assert(shown.rows[1].writers[1] == "me")
	-- And in a document: whose its title and its text are, by name, not what is in them.
	local doc = zsp.mirror.open(h.client, {
		scope = 2,
		name = "signed",
		schema = zsp.mirror.map({ title = zsp.string(16), by = zsp.author(16), body = zsp.text(17), writers = zsp.authors(17) }),
	})
	h.run()
	doc.set({ title = "t", body = "typed" })
	h.run()
	local st = doc.state()
	assert(st.title == "t" and st.body == "typed")
	assert(st.by == "me", `the title is mine, not {tostring(st.by)}`)
	assert(#st.writers == 1 and st.writers[1] == "me", "and the text")
	doc.stop()
	assert(not pcall(function()
		h.client:write(2, function(change)
			change.set(mine, Signed, { by = "you" })
		end)
	end))

	local row = "\0\0\0\2" .. string.rep("r", 12)
	local function cell(kind: number, slot: number, n: number, body: string, author: string): string
		local w = codec.writer()
		codec.put(w, string.char(kind + 64) .. row .. string.char(slot) .. string.rep("\0", 15) .. string.char(n))
		codec.put_bytes(w, body)
		codec.put(w, author)
		return codec.string(w)
	end
	local function send(a: string, b: string)
		h.tell(CELLS, "\0" .. cell(2, 1, 1, h.client:_tag(2, "a") .. codec.u64(2), a) .. cell(3, 16, 2, "theirs", b) .. cell(3, 17, 3, "x", a) .. cell(4, 17, 4, codec.u64(1) .. "\1\0\0\1y", b))
	end
	h.tell(AUTHOR, "\1" .. string.rep("e", 32) .. "\3zoe")
	h.tell(AUTHOR, "\2" .. string.rep("e", 32) .. "\3ann")
	send("\1", "\2")
	assert(shown.rows[2].by == "ann" and table.concat(shown.rows[2].writers, " ") == "ann zoe")
	local before = shown.rows[2]
	send("\1", "\2")
	assert(shown.rows[2] == before, "nothing has changed")
	h.tell(AUTHOR, "\3" .. string.rep("e", 32) .. "\9ann smith")
	send("\1", "\3")
	assert(shown.rows[2].by == "ann smith" and table.concat(shown.rows[2].writers, " ") == "ann smith zoe")
	h.tell(AUTHOR, "\4" .. string.rep("f", 32) .. "\0")
	send("\4", "\4")
	assert(shown.rows[2].by == nil and #shown.rows[2].writers == 0, "a device that is nobody's")

	h.client:ask({ scope = 2, table = Signed, where = zsp.where.begins("by", "an"), order = { "-by" }, totals = { whose = { "facet", "by" } } }, function() end)
	h.run()
	local asked = (h.last(ASK) :: any).body
	assert(string.find(asked, "\6\10\16\2an", 1, true) and string.find(asked, "\0\1\10\16\0", 1, true) and string.find(asked, "\5\10\16\100", 1, true))

	local caller: any
	h.client:serve(2, "m", function(call)
		caller = call.subject
	end)
	h.run()
	h.tell(CALL, "\1" .. string.rep("e", 32) .. "\2\1m\3zoehello")
	assert(caller == "zoe")
	h.client:call(string.rep("e", 32), 2, "m", "hello")
	h.run()
	assert(string.sub((h.last(CALL) :: any).body, -9) == "\1m\0\3hello", "and for whom is not for it to say; its urgency is 3")
	assert(h.last(SERVE))
end

-- What a change types in a text, in a scope that says whose things are, is this client's at once, as what it sets is.
do
	local Signed = { title = zsp.string(16), by = zsp.author(16), body = zsp.text(17), writers = zsp.authors(17) }
	local h = harness()
	h.run()
	h.tell(ROSTER, string.rep("\0", 8) .. "\2\135" .. string.rep("k", 32))
	h.tell(17, "\0" .. string.rep("d", 32) .. "\2me")
	local seen: any
	h.client:window({ scope = 2, list = "a", table = Signed }, function(x)
		seen = x
	end)
	h.run()
	h.client:write(2, function(change)
		local id = change.insert(Signed, "a", 1, { title = "t" })
		change.edit(id, Signed.body.slot, function(t, fresh)
			zsp.Text.insert(t, 0, "typed", fresh)
		end)
	end)
	h.run()
	local row = seen.rows[1]
	assert(row.body == "typed" and row.by == "me")
	assert(#row.writers == 1 and row.writers[1] == "me", "what was typed is nobody's until the node says")
end

-- What a roster has made unlawful goes from the rows it was in, as they are said over again; and no more than that.
do
	local ANSWER = 34
	local h = harness()
	h.run()
	h.greet()
	local shown: any, found: any
	h.client:window({ scope = 1, list = "a", table = Note }, function(s)
		shown = s
	end)
	h.client:ask({ scope = 1, table = Note }, function(s)
		found = s
	end)
	h.run()
	local one, two = "\0\0\0\1" .. string.rep("1", 12), "\0\0\0\1" .. string.rep("2", 12)
	local function cell(row: string, kind: number, slot: number, n: number, body: string): string
		local w = codec.writer()
		codec.put(w, string.char(kind) .. row .. string.char(slot) .. string.rep("\0", 15) .. string.char(n))
		codec.put_bytes(w, body)
		return codec.string(w)
	end
	local function place(row: string): string
		return cell(row, 2, 1, 1, h.client:_tag(1, "a") .. codec.u64(1))
	end
	local function piece(n: number, ...: string): string
		local out = {}
		for i, s in { ... } do
			table.insert(out, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" .. string.char(n + i) .. codec.u64(n + i) .. string.char(4 + #s) .. "\1\0\0" .. string.char(#s) .. s)
		end
		return "\0\0\0\1" .. string.rep("\0", 15) .. string.char(n) .. table.concat(out)
	end
	local function answer(...: string)
		h.tell(ANSWER, "\1\1" .. string.char(select("#", ...)) .. "\0" .. string.char(select("#", ...)) .. table.concat({ ... }) .. "\0")
	end
	h.tell(CELLS, "\0" .. place(one) .. cell(one, 3, 16, 2, "kept") .. cell(one, 3, 17, 3, "gone"))
	h.tell(CELLS, "\0" .. place(two) .. cell(two, 3, 16, 2, "gone") .. cell(two, 5, 17, 9, piece(4, "a", "b")))
	answer(one, two)
	assert(#shown.rows == 2 and #found.rows == 2 and shown.rows[1].body == "gone" and #shown.rows[2].body == 2)
	local page, _, lo, hi = watch_of(h.last(WATCH))
	synced(h, page, 1, lo, hi)
	-- A range, from its beginning.
	synced(h, page, 2, lo, hi)
	h.tell(CELLS, "\0" .. place(one) .. cell(one, 3, 16, 2, "kept"))
	h.tell(CELLS, "\0" .. place(two) .. cell(two, 3, 16, 2, "gone") .. cell(two, 5, 17, 9, piece(4, "a", "b")))
	synced(h, page, 1, lo, hi)
	assert(shown.rows[1].title == "kept" and shown.rows[1].body == "" and shown.rows[2].title == "gone")
	-- An answer, when what may be read has changed. One that says nothing over again says nothing of what is gone.
	h.greet()
	answer(one, two)
	assert(found.rows[2].title == "gone")
	h.greet()
	h.tell(CELLS, "\0" .. place(two) .. cell(two, 5, 17, 9, piece(4, "a")))
	h.tell(CELLS, "\0" .. place(one) .. cell(one, 3, 16, 2, "kept"))
	answer(one, two)
	assert(found.rows[2].title == nil and found.rows[2].body == "a" and found.rows[1].title == "kept", "and of some of it, only that")
	h.tell(CELLS, "\0" .. cell(one, 3, 17, 8, "new"))
	answer(one, two)
	assert(found.rows[1].title == "kept" and found.rows[1].body == "new", "it is as it was before from then on")
end

-- A change is all or nothing: one that fails partway leaves nothing of itself, here or anywhere.
do
	local h = harness()
	h.greet()
	local shown: any
	h.client:window({ scope = 1, list = "a", table = Note }, function(st)
		shown = st
	end)
	h.run()
	local id = ""
	h.client:write(1, function(change)
		id = change.insert(Note, "a", 1, { title = "kept", body = "hello" })
	end)
	h.run()
	assert(#shown.rows == 1 and shown.rows[1].body == "hello")
	local said = #h.self.said
	local ok, why = pcall(function()
		h.client:write(1, function(change)
			change.set(id, Note, { title = "changed" })
			change.edit(id, 17, function(t, fresh)
				zsp.Text.insert(t, 0, "oh, ", fresh)
			end)
			change.delete(id)
			change.insert(Note, "a", 2, { title = "new" })
			error("not after all")
		end)
	end)
	assert(not ok and string.find(tostring(why), "not after all", 1, true), "what went wrong is said")
	h.run()
	assert(#shown.rows == 1, `{#shown.rows} rows, not the one there was`)
	assert(shown.rows[1].title == "kept" and shown.rows[1].body == "hello", "it is as it was")
	for k = said + 1, #h.self.said do
		assert(h.self.said[k].kind ~= CELLS, "and nothing of it was sent")
	end
	-- And what is written after is written as if it never was.
	h.client:write(1, function(change)
		change.edit(id, 17, function(t, fresh)
			zsp.Text.insert(t, 5, "!", fresh)
		end)
	end)
	h.run()
	assert(shown.rows[1].body == "hello!", shown.rows[1].body)

	-- What an editor typed and had not yet sealed is its own: a change that fails after touching that text does not take
	-- it back, here or anywhere.
	local editor = h.client:text(id, Note.body)
	editor.insert(6, "typed")
	local before = #h.self.said
	assert(not pcall(function()
		h.client:write(1, function(change)
			change.set(id, Note, { body = "written over" })
			error("not after all")
		end)
	end))
	h.run()
	assert(shown.rows[1].body == "hello!typed", `the typing is kept: {shown.rows[1].body}`)
	local sent = false
	for k = before + 1, #h.self.said do
		sent = sent or h.self.said[k].kind == CELLS
	end
	assert(sent, "and sent, as typing is")
	-- And so when another slot of the row was touched first.
	editor.insert(11, "more")
	assert(not pcall(function()
		h.client:write(1, function(change)
			change.set(id, Note, { title = "other" })
			change.set(id, Note, { body = "written over" })
			error("not after all")
		end)
	end))
	h.run()
	assert(shown.rows[1].body == "hello!typedmore", `the typing is kept when another slot was touched first: {shown.rows[1].body}`)
	editor.close()
	h.run()
	assert(shown.rows[1].body == "hello!typedmore", shown.rows[1].body)

	-- A value that cannot be read as its column's kind is no value, and all else is shown as ever.
	local Strict = { title = zsp.string(16), body = zsp.text(17), n = zsp.custom(18, function(v: any): string
		return tostring(v)
	end, function(s: string): any
		return assert(tonumber(s), "not a number")
	end) }
	local strict: any
	h.client:window({ scope = 1, list = "a", table = Strict }, function(st)
		strict = st
	end)
	h.client:write(1, function(change)
		change.set(id, { raw = zsp.string(18) }, { raw = "twelve" })
	end)
	h.run()
	assert(strict.rows[1].n == nil and strict.rows[1].title == "kept", "what is not a number is nothing")
	assert(shown.rows[1].title == "kept", "and the rest goes on")

	-- A bundle whose piece runs past its end: what does not fit is not read, and nothing else is the worse for it.
	local w = codec.writer()
	codec.put(w, "\0\0\0\0") -- no pieces before
	codec.put(w, string.rep("\254", 15) .. "\9") -- a piece's stamp, later than anything,
	codec.put(w, string.rep("\7", 8)) -- its name,
	codec.put_varint(w, 100) -- and a hundred bytes of it, of which there are three
	codec.put(w, "abc")
	local body = codec.string(w)
	local c = codec.writer()
	codec.put_u8(c, 5)
	codec.put(c, id)
	codec.put_u8(c, 17)
	codec.put(c, string.rep("\254", 14) .. "\1\1")
	codec.put_bytes(c, body)
	h.tell(CELLS, "\0" .. codec.string(c))
	assert(shown.rows[1].body == "hello!typedmore", "the text is as it was")
end

-- What a node would refuse, and end the pipe for, never leaves the client, and throws where it is asked for: a row of
-- another scope, whatever this client may do there; one made later than any clock may yet say; a cell where a column made
-- by hand puts one that no node takes; a place no row goes in. Nothing of the change is done.
do
	local h = harness()
	h.run()
	h.tell(ROSTER, string.rep("\0", 8) .. "\1\7" .. string.rep("k", 32) .. "\2\1" .. string.rep("k", 32) .. "\3\7" .. string.rep("k", 32))
	h.client:window({ scope = 1, list = "a", table = Note }, function() end)
	h.run()
	local mine = ""
	h.client:write(1, function(change)
		mine = change.insert(Note, "a", 1, { title = "t" })
	end)
	h.run()
	local theirs, other = "\0\0\0\2" .. string.pack(">I4", 1800000000) .. "12345678", "\0\0\0\3" .. string.pack(">I4", 1800000000) .. "12345678"
	local said = #h.self.said
	-- What is held of the rows, cell by cell.
	local function held(): string
		local out = {}
		for _, id in { mine, theirs, other } do
			local row = h.client:held(id)
			table.insert(out, if row then "row" else "none")
			for slot, cells in row and row.slots or {} :: any do
				for stamp in cells do
					table.insert(out, `{slot}:{stamp}`)
				end
			end
		end
		table.sort(out)
		return table.concat(out, ",")
	end
	local function refused(scope: number, f: (any) -> (), why: string)
		local before = held()
		local fine, err = pcall(function()
			h.client:write(scope, f)
		end)
		assert(not fine and string.find(tostring(err), why, 1, true), `refused for {err}, not {why}`)
		assert(held() == before, "something of it was done")
	end
	for _, case in { { 1, theirs }, { 1, other }, { 3, mine } } do
		local scope, id = case[1] :: number, case[2] :: string
		refused(scope, function(change)
			change.set(id, Note, { title = "x" })
		end, "another scope")
		refused(scope, function(change)
			change.place(id, "a", 2)
		end, "another scope")
		refused(scope, function(change)
			change.delete(id)
		end, "another scope")
		refused(scope, function(change)
			change.edit(id, 17, function(t, fresh)
				zsp.Text.insert(t, 0, "x", fresh)
			end)
		end, "another scope")
	end
	local later = "\0\0\0\1" .. string.pack(">I4", 1800000000 + 15 * 60 + 1) .. "12345678"
	refused(1, function(change)
		change.set(later, Note, { title = "x" })
	end, "made later")
	refused(1, function(change)
		change.set(mine, { odd = table.freeze({ slot = 3, text = false, is = "string", encode = tostring, decode = tostring }) } :: any, { odd = "x" })
	end, "slot 3")
	refused(1, function(change)
		change.place(mine, "a", 2, 0)
	end, "slots 1 to 15")
	refused(1, function(change)
		change.place(mine, "a", -1)
	end, "whole number")
	refused(1, function(change)
		change.set("short", Note, { title = "x" })
	end, "16 bytes")
	local editor = h.client:text(theirs, Note.body)
	assert(not pcall(editor.append, "x"), "typed where it may not write")
	editor.close()
	h.run()
	for k = said + 1, #h.self.said do
		assert(h.self.said[k].kind ~= CELLS, "and something was written")
	end
	assert(h.client:held(later) == nil, "and is held")
	-- A row made a little later than this client's clock, as by a device whose clock runs ahead, is written at a stamp
	-- no earlier than it was made.
	local soon = "\0\0\0\1" .. string.pack(">I4", 1800000060) .. "12345678"
	h.client:write(1, function(change)
		change.set(soon, Note, { title = "x" })
	end)
	h.run()
	local written = (h.last(CELLS) :: Said).body
	assert(codec.from_u64(string.sub(written, 20, 27)) >= 1800000060000 * 65536, "it was written before it was made")
end

-- What was written where this client may no longer write, since it was written, is not said again to the next pipe:
-- a node would refuse it, and this client with it, for good.
do
	local h = harness()
	h.run()
	h.greet()
	h.client:window({ scope = 1, list = "a", table = Note }, function() end)
	h.run()
	h.self.closed()
	h.run()
	h.client:write(1, function(change)
		change.insert(Note, "a", 1, { title = "offline" })
	end)
	h.run()
	h.laters()
	h.run()
	local said = #h.self.said
	h.tell(ROSTER, string.rep("\0", 8) .. "\1\5" .. string.rep("k", 32)) -- read and call, and no more
	for k = said + 1, #h.self.said do
		assert(h.self.said[k].kind ~= CELLS, "it was said")
	end
	h.self.closed()
	h.run()
	h.laters()
	h.run()
	h.greet()
	for k = said + 1, #h.self.said do
		assert(h.self.said[k].kind ~= CELLS, "it was said once it might be")
	end
end

-- A pipe the node found fault with is dialled again later and later, as what this client says it would say again; one
-- that was well, soon.
do
	local h = harness()
	h.run()
	local waits = {}
	for _ = 1, 5 do
		h.greet()
		h.tell(ERROR, "\1")
		h.self.closed()
		h.run()
		table.insert(waits, h.self.waits[#h.self.waits])
		h.laters()
		h.run()
	end
	assert(table.concat(waits, " ") == "0.1 0.2 0.4 0.8 1.6", `it was dialled again at once: {table.concat(waits, " ")}`)
	h.greet()
	h.self.closed()
	h.run()
	assert(h.self.waits[#h.self.waits] == 0.1, "and was slow to after a pipe that was well")
end

-- A change that edits a row not held, and fails, leaves nothing held of it; and one that writes over what an editor has
-- typed and not sealed writes over it here as at the node, where what the editor typed comes first.
do
	local h = harness()
	h.run()
	h.greet()
	h.client:window({ scope = 1, list = "a", table = Note }, function() end)
	h.run()
	local unheld = "\0\0\0\1" .. string.pack(">I4", 1800000000) .. "unheld!!"
	assert(not pcall(function()
		h.client:write(1, function(change)
			change.edit(unheld, 17, function(t, fresh)
				zsp.Text.insert(t, 0, "x", fresh)
			end)
			error("not after all")
		end)
	end))
	assert(h.client:held(unheld) == nil, "what failed left a row held")
	local id = ""
	h.client:write(1, function(change)
		id = change.insert(Note, "a", 1, { title = "t", body = "start" })
	end)
	h.run()
	local editor = h.client:text(id, Note.body)
	editor.append(" typed")
	h.client:write(1, function(change)
		change.set(id, Note, { body = "over" })
	end)
	h.run()
	assert(editor.read() == "over", `what was written over is {editor.read()}`)
	local cells = 0
	for _, c in (h.client:held(id) :: any).slots[17] do
		cells += 1
		assert(c.kind == 3, "what was typed outlived what was written over it")
	end
	assert(cells == 1)
	editor.close()
end

-- Before the scope is known every map's id is nothing: two maps are not taken for one another meanwhile.
do
	local h = harness()
	local m = zsp.mirror
	local doc = m.open(h.client, {
		scope = 1,
		name = "early",
		schema = m.map({ a = m.map({ x = zsp.string(16) }), b = m.map({ y = zsp.number(17) }) }),
	})
	h.run()
	local st = doc.state()
	assert(not rawequal(st.a, st.b), "a and b are not one map")
	doc.stop()
end

-- How many letters may be wrong is a whole number: a part of one is not another flag.
do
	local ask = require("../zsp/ask")
	local function asked(how: any): string
		return (ask.write({ scope = 1, table = Note, where = zsp.where.matches("title", "x", how) }, function()
			return string.rep("\0", 16)
		end))
	end
	assert(asked({ typos = 1.5 }) == asked({ typos = 1 }), "one and a half is one")
	assert(asked({ typos = 1.5 }) ~= asked({ typos = 1, inside = true }), "and not one inside words")
end

-- Typing in a long text, anywhere in it, looks at a few of its spans, however many it has: where a place is, is found by
-- way of blocks of them, not by counting them all. What is counted is how often whether a span is dead is asked.
do
	local Text = zsp.Text
	local seed = 7
	local function rnd(n: number): number
		seed = (seed * 16807) % 2147483647
		return seed % n
	end
	local n = 0
	local function fresh(): string
		n += 1
		return string.pack(">I8", n)
	end
	local t: any = Text.new()
	for k = 1, 32000 do
		Text.insert(t, rnd(Text.len(t) + 1), "a", fresh)
		Text.close(t, string.pack(">I8I8", k * 65536, k))
	end
	local asked = 0
	local function count(s: any)
		local dead = s.dead
		s.dead = nil
		setmetatable(s, {
			__index = function(_, k)
				if k == "dead" then
					asked += 1
					return dead
				end
				return nil
			end,
			__newindex = function(x, k, v)
				if k == "dead" then
					dead = v
				else
					rawset(x, k, v)
				end
			end,
		})
	end
	for _, b in t.blocks or { { spans = t.spans } } do
		for _, s in b.spans do
			count(s)
		end
	end
	for _ = 1, 2000 do
		Text.insert(t, Text.len(t), "x", fresh)
	end
	local at = Text.len(t) // 2
	for k = 0, 1999 do
		Text.insert(t, at + k, "y", fresh)
	end
	for _ = 1, 1000 do
		Text.delete(t, at + 1000, 1, fresh)
	end
	for _ = 1, 2000 do
		Text.insert(t, rnd(Text.len(t) + 1), "z", fresh)
		Text.delete(t, rnd(Text.len(t)), 1, fresh)
	end
	assert(asked / 9000 < 100, `{asked / 9000} spans looked at for each of 9000 edits of a text of {Text.len(t)} bytes`)
end

-- ---------------------------------------------------------------- calls

-- Calls against a node made of nothing, which plays the device called and whoever calls this client: what the client
-- says, what it makes of what it is told, and that it credits only what is done with, so that a reader that never reads
-- holds no more than its window.

local CALL, FLOW, AUTHOR = 15, 16, 17
local F_DATA, F_END, F_FAULT, F_CANCEL, F_CREDIT = 0, 1, 2, 3, 4
local WINDOW = 262144
local DEVICE = string.rep("d", 32)

-- A call as the other end sees it: one the client made, or one made of it.
type Remote = {
	id: number,
	device: string,
	scope: number,
	method: string,
	urgency: number,
	first: string,
	granted: number, -- what it may send yet
	got: { string }, -- what the client sent, in order
	taken: number, -- of those, looked at
	credited: number, -- all the client has credited
	ended: boolean, -- the client said End
	cancelled: boolean,
	fault: number?, -- the client faulted it, with this code
	over: boolean, -- this side said End or faulted
	side: number, -- what this end speaks as: 1 for a call the client made, 0 for one made of it
}

local function remote(id: number, side: number): Remote
	return {
		id = id,
		device = DEVICE,
		scope = 0,
		method = "",
		urgency = -1,
		first = "",
		granted = WINDOW,
		got = {},
		taken = 0,
		credited = 0,
		ended = false,
		cancelled = false,
		fault = nil,
		over = false,
		side = side,
	}
end

local function call_harness()
	local self = {
		receive = nil :: any,
		closed = nil :: any,
		deferred = {} :: { () -> () },
		remotes = {} :: { Remote },
		mine = {} :: { [number]: Remote }, -- calls the client made, by id
		theirs = {} :: { [number]: Remote }, -- calls made of the client, by id
		calls = 0, -- frames that opened one
		pumps = {} :: { () -> boolean },
		clock = 1800000000,
	}
	local function said(kind: number, r: codec.Reader)
		if kind == CALL then
			self.calls += 1
			local c = remote(codec.varint(r), 1)
			c.device = codec.take(r, 32)
			c.scope = codec.varint(r)
			c.method = codec.bytes(r)
			assert(codec.bytes(r) == "", "for whom is for the node to say")
			c.urgency = codec.u8(r)
			c.first = codec.rest(r)
			table.insert(self.remotes, c)
			self.mine[c.id] = c
		elseif kind == FLOW then
			local tag = codec.varint(r)
			local flow = codec.u8(r)
			local c = if tag % 2 == 0 then self.mine[tag // 2] else self.theirs[tag // 2]
			assert(c, "a flow of a call there is none of")
			if flow == F_DATA then
				table.insert(c.got, codec.rest(r))
			elseif flow == F_CREDIT then
				local n = codec.varint(r)
				c.granted += n
				c.credited += n
			elseif flow == F_END then
				assert(not c.ended, "End said twice")
				c.ended = true
			elseif flow == F_CANCEL then
				c.cancelled = true
			elseif flow == F_FAULT then
				c.fault = codec.u8(r)
			end
		end
	end
	local client = zsp.connect({
		credential = "x",
		now = function(): number
			return self.clock
		end,
		random = function(n: number): string
			return string.rep("r", n)
		end,
		defer = function(f: () -> ())
			table.insert(self.deferred, f)
		end,
		after = function(_: number, _f: () -> ())
			return function() end
		end,
		connect = function(receive: any, closed: any)
			self.receive, self.closed = receive, closed
			return {
				send = function(data: buffer)
					local r = codec.reader(data)
					while r.pos < r.len do
						local b = codec.reader(codec.bytes(r))
						said(codec.u8(b), b)
					end
				end,
				close = function() end,
			}
		end,
	})
	local h = {}
	-- Runs what was put off, and whatever plays the other end, until nothing more happens.
	function h.run()
		while true do
			local moved = false
			while #self.deferred > 0 do
				(table.remove(self.deferred, 1) :: () -> ())()
				moved = true
			end
			for _, pump in table.clone(self.pumps) do
				if pump() then
					moved = true
				end
			end
			if not moved then
				return
			end
		end
	end
	function h.tell(kind: number, body: string)
		local w = codec.writer()
		codec.put_bytes(w, string.char(kind) .. body)
		self.receive(codec.string(w))
	end
	function h.greet()
		h.tell(ROSTER, string.rep("\0", 8) .. "\1\7" .. string.rep("k", 32))
		h.tell(AUTHOR, "\0" .. string.rep("m", 32) .. "\3ann")
		h.run()
	end
	local function flow(r: Remote, kind: number, payload: string)
		local w = codec.writer()
		codec.put_varint(w, r.id * 2 + r.side)
		codec.put_u8(w, kind)
		codec.put(w, payload)
		h.tell(FLOW, codec.string(w))
	end
	-- What the other end says: only what it has credit for.
	function h.reply(r: Remote, message: string)
		assert(not r.over, "said after the end")
		assert(#message <= r.granted, `overrun: {#message} with {r.granted} granted`)
		r.granted -= #message
		flow(r, F_DATA, message)
	end
	function h.finish(r: Remote)
		r.over = true
		flow(r, F_END, "")
	end
	function h.fault(r: Remote, code: number)
		r.over = true
		flow(r, F_FAULT, string.char(code))
	end
	function h.cancel(r: Remote)
		r.over = true
		flow(r, F_CANCEL, "")
	end
	function h.credit(r: Remote, n: number)
		local w = codec.writer()
		codec.put_varint(w, n)
		flow(r, F_CREDIT, codec.string(w))
	end
	-- Someone calls the client, as the node passes a call on: with no urgency, which was the caller's to say.
	function h.call_in(id: number, scope: number, method: string, subject: string, first: string): Remote
		local c = remote(id, 0)
		c.scope, c.method, c.first = scope, method, first
		c.granted -= #first
		self.theirs[id] = c
		local w = codec.writer()
		codec.put_varint(w, id)
		codec.put(w, DEVICE)
		codec.put_varint(w, scope)
		codec.put_bytes(w, method)
		codec.put_bytes(w, subject)
		codec.put(w, first)
		h.tell(CALL, codec.string(w))
		return c
	end
	-- The next of what the client sent that has not been looked at.
	function h.next(r: Remote): string?
		if r.taken < #r.got then
			r.taken += 1
			return r.got[r.taken]
		end
		return nil
	end
	function h.last(method: string?): Remote
		for i = #self.remotes, 1, -1 do
			if not method or self.remotes[i].method == method then
				return self.remotes[i]
			end
		end
		error(`no call of {method}`)
	end
	function h.pump(f: () -> boolean)
		table.insert(self.pumps, f)
	end
	-- Runs f as a coroutine, as an application would, and says whether it is done and what it returned.
	function h.spawn(f: () -> ...any): { done: boolean, values: { any } }
		local out = { done = false, values = {} :: { any } }
		local thread = coroutine.create(function()
			out.values = table.pack(f())
			out.done = true
		end)
		local ok, why = coroutine.resume(thread)
		assert(ok, why)
		return out
	end
	h.client = client
	h.self = self
	return h
end

-- What on_data keeps is not credited until it is done with; what it is done with is, at once.
do
	local h = call_harness()
	h.greet()
	local call = h.client:call(DEVICE, 1, "m", "hi")
	local got = 0
	call.on_data = function(d: string)
		got += #d
		return false
	end
	h.run()
	local r = h.last("m")
	assert(r.first == "hi" and r.device == DEVICE and r.scope == 1)
	local piece = string.rep("x", 65536)
	for _ = 1, 4 do
		h.reply(r, piece)
	end
	h.run()
	assert(got == WINDOW and r.granted == 0 and r.credited == 0, "nothing kept is credited")
	assert(not pcall(h.reply, r, "x"), "and the other end can send no more")
	call.consumed(65536)
	h.run()
	assert(r.credited == 65536 and r.granted == 65536)
	call.on_data = nil -- told to nobody: done with
	h.reply(r, piece)
	h.run()
	assert(r.credited == 2 * 65536)
end

-- A reader that keeps up has its window grown, to 4 MiB ahead and no more.
do
	local h = call_harness()
	h.greet()
	local call = h.client:call(DEVICE, 1, "m", "")
	local got = 0
	call.on_data = function(d: string)
		got += #d
	end
	h.run()
	local r = h.last("m")
	local piece = string.rep("y", 65536)
	for _ = 1, 400 do
		h.reply(r, piece)
		h.run()
	end
	assert(got == 400 * 65536)
	assert(r.credited - got == 16 * WINDOW - WINDOW, `ahead by {r.credited - got}`)
	-- One that is slow does not.
	local slow = h.client:call(DEVICE, 1, "m", "")
	slow.on_data = function() end
	h.run()
	local s = h.last("m")
	for _ = 1, 40 do
		h.reply(s, piece)
		h.self.clock += 1
		h.run()
	end
	assert(s.credited == 40 * 65536, `credited {s.credited}`)
end

-- What is sent waits for credit, and room says how much may go at once.
do
	local h = call_harness()
	h.greet()
	local call = h.client:call(DEVICE, 1, "m", string.rep("f", 1000))
	assert(call.room() == WINDOW - 1000, "the first message counts")
	local roomed = 0
	call.on_room = function()
		roomed += 1
	end
	for _ = 1, 5 do
		call.send(string.rep("z", 65536))
	end
	h.run()
	local r = h.last("m")
	assert(#r.got == 3 and call.room() == 0)
	call.finish()
	h.run()
	assert(not r.ended, "End waits behind what waits for credit")
	h.credit(r, 200000)
	h.run()
	assert(#r.got == 5 and r.ended and roomed == 1)
end

-- The other end sends all it may, as fast as it may; a reader that never reads holds no more than its window, and one
-- that reads slowly is given no more than it reads. Then each end says it is done, in turn.
do
	local h = call_harness()
	h.greet()
	local call = h.client:call(DEVICE, 1, "m", "hello")
	local got, ended, faulted = 0, false, false
	call.on_data = function(d: string)
		got += #d
		return false -- a reader that never reads
	end
	call.on_end = function()
		ended = true
	end
	call.on_fault = function()
		faulted = true
	end
	call.send("what speaks first need not wait") -- for an answer, before it
	h.run()
	local r = h.last("m")
	assert(r.first == "hello" and h.next(r) == "what speaks first need not wait")
	local sent = 0
	h.pump(function(): boolean
		if r.over or r.granted == 0 or sent >= 8 * WINDOW then
			return false
		end
		local n = math.min(r.granted, 65536)
		h.reply(r, string.rep("s", n))
		sent += n
		return true
	end)
	h.run()
	assert(got == WINDOW and sent == got, `held {got}`)
	h.self.clock += 1 -- slowly: its window stays as it is
	call.consumed(got)
	h.run()
	assert(got == 2 * WINDOW, `held {got}`)
	call.on_data = nil
	call.consumed(WINDOW)
	h.run()
	assert(sent == 8 * WINDOW)
	-- Half-closed each way, in turn: the call is over once both have said so.
	h.finish(r)
	h.run()
	assert(ended and not r.ended and h.client.calls[r.id], "theirs is done, and not mine")
	call.send("still")
	call.finish()
	h.run()
	assert(h.next(r) == "still" and r.ended and h.client.calls[r.id] == nil and not faulted)
	call.send("too late")
	h.run()
	assert(h.next(r) == nil, "nothing is sent after the end")
end

-- A request: every message that came, put together however it was divided; or nil and why not.
do
	local h = call_harness()
	h.greet()
	local run = h.spawn(function()
		return h.client:request(DEVICE, 1, "list", "docs")
	end)
	h.run()
	local r = h.last("list")
	assert(r.first == "docs" and r.ended, "asked, with nothing more to say")
	h.reply(r, "one, ")
	h.reply(r, "two, ")
	h.reply(r, "three")
	assert(not run.done)
	h.finish(r)
	h.run()
	assert(run.done and run.values[1] == "one, two, three" and run.values[2] == nil)
	assert(h.client.calls[r.id] == nil, "and let go of")
	for code, why in { "denied", "unreachable", "unserved", "lost", "overrun", "busy" } do
		run = h.spawn(function()
			return h.client:request(DEVICE, 1, "list", "")
		end)
		h.run()
		h.reply(h.last("list"), "partly")
		h.fault(h.last("list"), code)
		h.run()
		assert(run.done and run.values[1] == nil and run.values[2] == why, `{code} is {why}, not {run.values[2]}`)
	end
	run = h.spawn(function()
		return h.client:request(DEVICE, 1, "list", "")
	end)
	h.run()
	h.cancel(h.last("list"))
	h.run()
	assert(run.done and run.values[1] == nil and run.values[2] == "cancelled")
	-- Before there is a pipe, there is nobody to ask.
	local h2 = call_harness()
	run = h2.spawn(function()
		return h2.client:request(DEVICE, 1, "list", "")
	end)
	h2.run()
	assert(run.done and run.values[1] == nil and run.values[2] == "unreachable" and h2.self.calls == 0)
	-- And a first message too big for any window is overrun, and never sent.
	run = h.spawn(function()
		return h.client:request(DEVICE, 1, "list", string.rep("x", WINDOW + 1))
	end)
	local calls = h.self.calls
	h.run()
	assert(run.done and run.values[2] == "overrun" and h.self.calls == calls)
end

-- How urgent a call is, is the caller's to say, 0 to 7: 3 if it says nothing. What is not one of those is refused at
-- once, and nothing is sent.
do
	local h = call_harness()
	h.greet()
	h.client:call(DEVICE, 1, "m", "")
	h.run()
	assert(h.last("m").urgency == 3)
	for _, u in { 0, 1, 6, 7 } do
		h.client:call(DEVICE, 1, "m", "x", { urgency = u })
		h.run()
		assert(h.last("m").urgency == u and h.last("m").first == "x", `urgency {u}`)
	end
	h.client:call(DEVICE, 1, "m", "", {})
	h.run()
	assert(h.last("m").urgency == 3)
	local run = h.spawn(function()
		return h.client:request(DEVICE, 1, "q", "y", { urgency = 6 })
	end)
	h.run()
	local r = h.last("q")
	assert(r.urgency == 6 and r.first == "y")
	h.reply(r, "z")
	h.finish(r)
	h.run()
	assert(run.values[1] == "z")
	local calls = h.self.calls
	for _, u in { 8, -1, 1.5, 0 / 0, math.huge, "1" :: any, true :: any } do
		assert(not pcall(function()
			h.client:call(DEVICE, 1, "m", "", { urgency = u })
		end), `urgency {tostring(u)} is refused`)
		assert(not pcall(function()
			h.client:request(DEVICE, 1, "m", "", { urgency = u })
		end), `and by request: {tostring(u)}`)
	end
	h.run()
	assert(h.self.calls == calls, "and nothing was sent")
end

-- Calls made of the client: the handler is given the call, its first message and whom its caller goes by; it answers as
-- far as it is credited; what it is sent is credited as it is done with; a method nobody serves is unserved.
do
	local h = call_harness()
	h.greet()
	local served: any, first: string?, held = nil, nil, {}
	local stop = h.client:serve(1, "echo", function(call, data)
		served, first = call, data
		call.on_data = function(d: string)
			table.insert(held, d)
			return false
		end
	end)
	h.run()
	local r = h.call_in(5, 1, "echo", "zoe", "hello")
	h.run()
	assert(first == "hello" and served.subject == "zoe" and served.method == "echo" and served.device == DEVICE)
	assert(r.credited == 5, "the first message is always taken")
	h.reply(r, string.rep("i", 1000))
	h.run()
	assert(#held == 1 and r.credited == 5, "what is kept is not credited")
	served.consumed(1000)
	h.run()
	assert(r.credited == 1005)
	for _ = 1, 5 do
		served.send(string.rep("o", 65536))
	end
	served.finish()
	h.run()
	assert(#r.got == 4 and not r.ended, "no more than its credit")
	h.credit(r, 65536)
	h.run()
	assert(#r.got == 5 and r.ended)
	h.finish(r)
	h.run()
	assert(h.client.answers[5] == nil, "over both ways, and let go of")
	-- Cancelled by the caller: told so, and nothing more goes.
	local why: string? = nil
	r = h.call_in(6, 1, "echo", "", "")
	h.run()
	served.on_fault = function(f: string)
		why = f
	end
	h.cancel(r)
	h.run()
	assert(why == "cancelled" and h.client.answers[6] == nil)
	served.send("gone")
	h.run()
	assert(#r.got == 0)
	-- Another scope, another method, or one no longer served: unserved.
	for i, c in { { scope = 2, method = "echo" }, { scope = 1, method = "other" } } do
		r = h.call_in(10 + i, c.scope, c.method, "", "x")
		h.run()
		assert(r.fault == 3, `{c.scope}/{c.method} is unserved`)
	end
	stop()
	h.run()
	r = h.call_in(20, 1, "echo", "", "x")
	h.run()
	assert(r.fault == 3, "no longer served")
end

-- The pipe breaks: every call, made or answered, is lost to it; and what is served is served again down the next one.
do
	local h = call_harness()
	h.greet()
	local faults: { string } = {}
	local made = h.client:call(DEVICE, 1, "m", "")
	made.on_fault = function(f: string)
		table.insert(faults, "made " .. f)
	end
	h.client:serve(1, "echo", function(call)
		call.on_fault = function(f: string)
			table.insert(faults, "answered " .. f)
		end
	end)
	h.run()
	h.call_in(1, 1, "echo", "", "")
	h.run()
	h.self.closed()
	h.run()
	table.sort(faults)
	assert(table.concat(faults, ", ") == "answered lost, made lost", table.concat(faults, ", "))
	assert(next(h.client.calls) == nil and next(h.client.answers) == nil)
end

print("ok")
