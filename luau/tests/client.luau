--!strict
-- The client against a node made of nothing: what it says, and what it makes of what it is told.

local codec = require("../zsp/codec")
local zsp = require("../zsp")

local HELLO, ROSTER, WATCH, CELLS, ACK, SYNCED = 1, 2, 3, 7, 8, 10

type Said = { kind: number, body: string }

local function harness()
	local self = { said = {} :: { Said }, receive = nil :: any, closed = nil :: any, deferred = {} :: { any }, later = {} :: { any }, closes = 0 }
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
		after = function(_: number, f: () -> ())
			table.insert(self.later, f)
			return function() end
		end,
		connect = function(receive: any, closed: any)
			self.receive, self.closed = receive, closed
			return {
				send = function(data: buffer)
					local r = codec.reader(data)
					while r.pos < r.len do
						local body = codec.bytes(r)
						table.insert(self.said, { kind = string.byte(body), body = string.sub(body, 2) })
					end
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
	return { client = client, self = self, run = run, tell = tell, greet = greet, last = last }
end

local Note = { title = zsp.string(16), body = zsp.text(17) }

local function watch_of(said: any): (number, number, string, string, number)
	local r = codec.reader(said.body)
	return codec.varint(r), codec.u8(r), codec.key(r), codec.key(r), codec.varint(r)
end

local function synced(h: any, id: number, flags: number, lo: string, hi: string)
	local w = codec.writer()
	codec.put_varint(w, id)
	codec.put_u8(w, flags)
	codec.put_key(w, lo)
	codec.put_key(w, hi)
	codec.put_varint(w, 0)
	codec.put_varint(w, 0)
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

-- Nonsense from the pipe ends the pipe and nothing else.
do
	local h = harness()
	h.run()
	h.greet()
	h.self.receive(string.rep("\128", 310) .. "\0")
	assert(h.self.closes == 1)
	local call = h.client:call(string.rep("d", 32), 1, "m", "")
	assert(not pcall(call.send, string.rep("x", 262145)), "a message too big for any window is refused at once")
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
	assert(string.sub((h.last(CALL) :: any).body, -8) == "\1m\0hello", "and for whom is not for it to say")
	assert(h.last(SERVE))
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

print("ok")
