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

print("ok")
