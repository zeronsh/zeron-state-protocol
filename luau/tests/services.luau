--!strict
-- Streams and services against a node made of nothing, which plays the device called: what the client says, what it
-- makes of what it is told, and that it credits only what is done with, so that a reader that never reads holds no
-- more than its window.

local codec = require("../zsp/codec")
local services = require("../zsp/services")
local sha256 = require("../zsp/sha256")
local transfer = require("../zsp/transfer")
local zsp = require("../zsp")

local ROSTER, CALL, FLOW, AUTHOR = 2, 15, 16, 17
local F_DATA, F_END, F_FAULT, F_CANCEL, F_CREDIT = 0, 1, 2, 3, 4
local WINDOW = 262144
local CHUNK = transfer.CHUNK
local DEVICE = string.rep("d", 32)
local ME = string.rep("m", 32)

-- A call as the device called sees it.
type Remote = {
	id: number,
	device: string,
	scope: number,
	method: string,
	first: string,
	granted: number, -- what it may send yet
	got: { string }, -- what the client sent, in order
	taken: number, -- of those, looked at
	credited: number, -- all the client has credited
	ended: boolean, -- the client said End
	cancelled: boolean,
	over: boolean, -- this side said End or faulted
}

local function harness(files: transfer.Files?)
	local self = {
		receive = nil :: any,
		closed = nil :: any,
		deferred = {} :: { () -> () },
		remotes = {} :: { Remote },
		by_id = {} :: { [number]: Remote },
		pumps = {} :: { () -> boolean },
		clock = 1800000000,
	}
	local function said(kind: number, r: codec.Reader)
		if kind == CALL then
			local id = codec.varint(r)
			local device = codec.take(r, 32)
			local scope = codec.varint(r)
			local method = codec.bytes(r)
			codec.bytes(r) -- for whom
			local remote: Remote = {
				id = id,
				device = device,
				scope = scope,
				method = method,
				first = codec.rest(r),
				granted = WINDOW,
				got = {},
				taken = 0,
				credited = 0,
				ended = false,
				cancelled = false,
				over = false,
			}
			table.insert(self.remotes, remote)
			self.by_id[id] = remote
		elseif kind == FLOW then
			local tag = codec.varint(r)
			local flow = codec.u8(r)
			local remote = self.by_id[tag // 2]
			assert(tag % 2 == 0 and remote, "a flow of a call the client did not make")
			if flow == F_DATA then
				table.insert(remote.got, codec.rest(r))
			elseif flow == F_CREDIT then
				local n = codec.varint(r)
				remote.granted += n
				remote.credited += n
			elseif flow == F_END then
				assert(not remote.ended, "End said twice")
				remote.ended = true
			elseif flow == F_CANCEL then
				remote.cancelled = true
			end
		end
	end
	local client = zsp.connect({
		credential = "x",
		files = files,
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
						local body = codec.bytes(r)
						local b = codec.reader(body)
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
		h.tell(AUTHOR, "\0" .. ME .. "\3ann")
		h.run()
	end
	local function flow(r: Remote, kind: number, payload: string)
		local w = codec.writer()
		codec.put_varint(w, r.id * 2 + 1)
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

local function data_of(size: number, seed: number): buffer
	local b = buffer.create(size)
	for i = 0, size - 1 do
		buffer.writeu8(b, i, (i * 7 + i // 251 + seed) % 256)
	end
	return b
end

-- ---------------------------------------------------------------- credit

-- What on_data keeps is not credited until it is done with; what it is done with is, at once.
do
	local h = harness()
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
	local h = harness()
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
	local h = harness()
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

-- ---------------------------------------------------------------- services

do
	local h = harness()
	h.greet()
	local offered: { services.Service } = {
		{ kind = "shell", terminal = true, commands = false },
		{ kind = "files", name = "docs", read = true, write = false },
		{ kind = "tcp", port = 5432, host = "10.0.0.7", name = "db" },
	}
	local run = h.spawn(function()
		return h.client:services(DEVICE, 1)
	end)
	h.run()
	local r = h.last("zsp.services")
	assert(r.first == "" and r.ended, "asked, with nothing more to say")
	local listing = services.status_of("ok", services.listed(offered))
	h.reply(r, string.sub(listing, 1, 5)) -- however it is divided
	h.reply(r, string.sub(listing, 6))
	h.finish(r)
	h.run()
	assert(run.done)
	local list = run.values[1]
	assert(#list == 3 and list[1].terminal and not list[1].commands and list[2].name == "docs" and not list[2].write)
	assert(list[3].port == 5432 and list[3].host == "10.0.0.7" and list[3].name == "db")

	run = h.spawn(function()
		return h.client:services(DEVICE, 2)
	end)
	h.run()
	r = h.last("zsp.services")
	h.reply(r, services.status_of("denied", "not for you"))
	h.finish(r)
	h.run()
	assert(run.values[1] == nil and run.values[2] == "denied" and run.values[3] == "not for you")

	-- The shares are this device's own: asked of its host, in a scope this client may call in.
	run = h.spawn(function()
		return h.client:shares()
	end)
	h.run()
	r = h.last("zsp.share")
	assert(r.device == ME and r.scope == 1 and r.first == "")
	h.reply(r, services.status_of("ok", "shell 1 terminal\n"))
	h.finish(r)
	h.run()
	assert(run.values[1] == "shell 1 terminal\n")
	run = h.spawn(function()
		return h.client:set_shares("")
	end)
	h.run()
	r = h.last("zsp.share")
	assert(r.first == "\n", "no shares at all is still something")
	h.reply(r, services.status_of("ok"))
	h.finish(r)
	h.run()
	assert(run.values[1] == true)
	run = h.spawn(function()
		return h.client:set_shares("nonsense")
	end)
	h.run()
	r = h.last("zsp.share")
	h.reply(r, services.status_of("malformed", "a share makes no sense"))
	h.finish(r)
	h.run()
	assert(run.values[1] == false and run.values[2] == "malformed" and run.values[3] == "a share makes no sense")

	-- A listing, in as many messages as it takes.
	run = h.spawn(function()
		return h.client:list(DEVICE, 1, "docs/sub")
	end)
	h.run()
	r = h.last("zsp.list")
	assert(r.first == services.list("docs/sub"))
	h.reply(r, services.status_of("ok"))
	h.reply(r, services.entry({ name = "a.txt", kind = "file", size = 3, modified = 5 }) .. services.entry({ name = "b", kind = "folder", size = 0, modified = 6 }))
	h.reply(r, services.entry({ name = "c", kind = "other", size = 0, modified = 7 }))
	h.finish(r)
	h.run()
	local entries = run.values[1]
	assert(#entries == 3 and entries[1].name == "a.txt" and entries[1].size == 3 and entries[2].kind == "folder" and entries[3].kind == "other")
end

-- ---------------------------------------------------------------- processes

do
	local h = harness()
	h.greet()
	local p = h.client:exec(DEVICE, 1, { "ls", "-l", "/tmp" }, { env = { "LANG=C", "HOME" }, folder = "/srv" })
	local out, err, exit = {}, {}, nil :: { number }?
	p.on_output = function(d: string)
		table.insert(out, d)
	end
	p.on_error = function(d: string)
		table.insert(err, d)
	end
	p.on_exit = function(code: number, signal: number)
		exit = { code, signal }
	end
	p.send("ls\n")
	p.signal("interrupt")
	p.kill()
	p.resize(50, 132)
	p.close_input()
	h.run()
	local r = h.last("zsp.exec")
	assert(r.first == services.exec({ "ls", "-l", "/tmp" }, { "LANG=C", "HOME" }, "/srv"))
	assert(h.next(r) == services.input("ls\n") and h.next(r) == services.signal(2) and h.next(r) == services.signal(9))
	assert(h.next(r) == services.resize(50, 132) and r.ended)
	h.reply(r, services.status_of("ok"))
	h.reply(r, services.output("hi"))
	h.reply(r, services.errors("no"))
	h.reply(r, services.exit(1, 0))
	h.finish(r)
	h.run()
	assert(table.concat(out) == "hi" and table.concat(err) == "no" and exit and exit[1] == 1 and exit[2] == 0)

	-- Input too big for a message goes in several; output kept is credited, but for its tag, only once done with.
	p = h.client:exec(DEVICE, 1, { "cat" })
	local held = {}
	p.on_output = function(d: string)
		table.insert(held, d)
		return false
	end
	p.send(string.rep("i", 150000))
	h.run()
	r = h.last("zsp.exec")
	assert(#r.got == 3 and #r.got[1] == 65537 and #r.got[3] == 150000 - 2 * 65536 + 1)
	h.reply(r, services.status_of("ok"))
	h.run()
	local before = r.credited
	assert(before == 1, "the status is done with")
	h.reply(r, services.output(string.rep("o", 1000)))
	h.run()
	assert(r.credited == before + 1)
	p.consumed(1000)
	h.run()
	assert(r.credited == before + 1001)

	-- One that cannot be run says why; one whose pipe breaks is lost.
	local failed: { string }? = nil
	p = h.client:exec(DEVICE, 1, { "nothing" })
	p.on_fail = function(why: string, reason: string)
		failed = { why, reason }
	end
	h.run()
	r = h.last("zsp.exec")
	h.reply(r, services.status_of("not found", "no such program"))
	h.finish(r)
	h.run()
	assert(failed and failed[1] == "not found" and failed[2] == "no such program")
	assert(r.ended, "and the client ends its side, so that the host may let it go")

	-- run gives all it wrote, and how it ended.
	local run = h.spawn(function()
		return h.client:run(DEVICE, 1, { "sh", "-c", "cat; exit 3" }, { input = "abc" })
	end)
	h.run()
	r = h.last("zsp.exec")
	assert(h.next(r) == services.input("abc") and r.ended)
	h.reply(r, services.status_of("ok"))
	h.reply(r, services.output("ab"))
	h.reply(r, services.output("c"))
	h.reply(r, services.errors("e"))
	h.reply(r, services.exit(3, 0))
	h.finish(r)
	h.run()
	assert(run.done and run.values[1] == 3 and run.values[2] == 0 and run.values[3] == "abc" and run.values[4] == "e")
	run = h.spawn(function()
		return h.client:run(DEVICE, 1, { "x" })
	end)
	h.run()
	h.fault(h.last("zsp.exec"), 1)
	h.run()
	assert(run.done and run.values[1] == nil and run.values[5] == "denied")

	-- A terminal: its size and kind, and hung up when closed.
	local t = h.client:terminal(DEVICE, 1, { rows = 24, columns = 80, env = { "COLORTERM=truecolor" } })
	local shown = {}
	t.on_output = function(d: string)
		table.insert(shown, d)
	end
	local ended: { number }? = nil
	t.on_exit = function(code: number, signal: number)
		ended = { code, signal }
	end
	t.write("echo hi\r")
	t.close()
	h.run()
	r = h.last("zsp.pty")
	assert(r.first == services.pty(24, 80, "xterm-256color", { "COLORTERM=truecolor" }))
	assert(h.next(r) == services.input("echo hi\r") and h.next(r) == services.signal(1) and r.ended)
	h.reply(r, services.status_of("ok"))
	h.reply(r, services.output("hi\r\n"))
	h.reply(r, services.exit(0, 1))
	h.finish(r)
	h.run()
	assert(table.concat(shown) == "hi\r\n" and ended and ended[2] == 1)

	-- The pipe breaks: whatever runs is lost to it.
	p = h.client:exec(DEVICE, 1, { "sleep" })
	failed = nil
	p.on_fail = function(why: string, reason: string)
		failed = { why, reason }
	end
	h.run()
	h.self.closed()
	h.run()
	assert(failed and failed[1] == "lost")
end

-- ---------------------------------------------------------------- streams

do
	local h = harness()
	h.greet()
	local s = h.client:connect(DEVICE, 1, 5432, "10.0.0.7")
	local opened, got, ended = false, 0, false
	local closed: { any }? = nil
	s.on_open = function()
		opened = true
	end
	s.on_data = function(d: string)
		got += #d
		return false -- a reader that never reads
	end
	s.on_end = function()
		ended = true
	end
	s.on_close = function(why: string?, reason: string)
		closed = { why or "fine", reason }
	end
	s.send("GET / HTTP/1.0\r\n\r\n") -- what speaks first need not wait
	h.run()
	local r = h.last("zsp.tcp")
	assert(r.first == services.tcp(5432, "10.0.0.7") and h.next(r) == "GET / HTTP/1.0\r\n\r\n")
	h.reply(r, services.status_of("ok"))
	h.run()
	assert(opened)
	-- The other end sends all it may; the client holds no more than its window.
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
	s.consumed(got)
	h.run()
	assert(got == 2 * WINDOW, `held {got}`)
	s.on_data = nil
	s.consumed(WINDOW)
	h.run()
	assert(sent == 8 * WINDOW)
	-- Half-closed each way, in turn.
	h.finish(r)
	h.run()
	assert(ended and not closed)
	s.close()
	h.run()
	assert(r.ended and closed and closed[1] == "fine")

	-- What may not be reached says why; a reset is a reset.
	s = h.client:connect(DEVICE, 1, 22)
	closed = nil
	s.on_close = function(why: string?, reason: string)
		closed = { why or "fine", reason }
	end
	h.run()
	r = h.last("zsp.tcp")
	assert(r.first == "\0\22")
	h.reply(r, services.status_of("refused"))
	h.finish(r)
	h.run()
	assert(closed and closed[1] == "refused" and r.ended)
	s = h.client:connect(DEVICE, 1, 22)
	closed = nil
	s.on_close = function(why: string?, reason: string)
		closed = { why or "fine", reason }
	end
	h.run()
	r = h.last("zsp.tcp")
	h.reply(r, services.status_of("ok"))
	h.cancel(r)
	h.run()
	assert(closed and closed[1] == "reset")
	-- Big writes go as messages of 64 KiB, as credit allows.
	s = h.client:connect(DEVICE, 1, 22)
	h.run()
	r = h.last("zsp.tcp")
	h.reply(r, services.status_of("ok"))
	s.send(string.rep("w", 300000))
	h.run()
	assert(#r.got == 3 and #r.got[1] == 65536, `{#r.got} messages`)
	h.credit(r, 300000)
	h.run()
	assert(#r.got == 5 and #r.got[5] == 300000 - 4 * 65536)
end

-- ---------------------------------------------------------------- files

-- What a device that has a file does with zsp.get: from where the asker broke off if it is the file it was, each
-- chunk's hash after it, and the file's at the end unless resumed. Breaks off after `stop` bytes, or lies about a chunk.
local function serve_get(h: any, r: Remote, file: buffer, identity: string, modified: number, stop: number?, lie: number?)
	local rd = codec.reader(r.first)
	local _path = codec.bytes(rd)
	local offset = codec.varint(rd)
	local known = codec.bytes(rd)
	local size = buffer.len(file)
	local from = if offset > 0 and offset % CHUNK == 0 and offset <= size and known == identity then offset else 0
	h.reply(r, services.status_of("ok", services.got_of({ size = size, modified = modified, identity = identity, from = from })))
	local at = from
	local hashed = from -- the end of the last chunk whose hash went
	local hashes = {}
	for i = 0, (size - 1) // CHUNK do
		hashes[i + 1] = sha256(buffer.readstring(file, i * CHUNK, math.min(CHUNK, size - i * CHUNK)))
	end
	local done = false
	h.pump(function(): boolean
		if done or r.over or r.cancelled or r.granted < 1 + 32 + 2 + 32 then
			return false
		end
		if at > hashed and (at % CHUNK == 0 or at == size) then
			local i = (at - 1) // CHUNK + 1
			h.reply(r, services.chunk(if lie == i then string.rep("\0", 32) else hashes[i]))
			hashed = at
			return true
		end
		if stop and at >= stop then
			done = true
			h.fault(r, 4)
			return true
		end
		if at < size then
			local n = math.min(r.granted - 1, 65536, size - at, CHUNK - at % CHUNK)
			h.reply(r, services.bytes(buffer.readstring(file, at, n)))
			at += n
			return true
		end
		local whole = sha256(table.concat(hashes))
		h.reply(r, services.done("ok", if from == 0 then whole else nil))
		h.finish(r)
		done = true
		return true
	end)
end

-- What a device does with zsp.put: takes up from `from`, checks each chunk and the whole, and gives its verdict.
local function serve_put(h: any, r: Remote, from: number, into: { data: buffer?, verdict: string? })
	local rd = codec.reader(r.first)
	local _path = codec.bytes(rd)
	local size = codec.varint(rd)
	h.reply(r, services.status_of("ok", services.number_of(from)))
	local data = buffer.create(size)
	local at = from
	local chunk = sha256.stream()
	local hashes = {}
	for i = 1, from // CHUNK do
		hashes[i] = "" -- had before, and not looked at again here
	end
	local verdict: string? = nil
	h.pump(function(): boolean
		local message = h.next(r)
		if not message then
			if r.ended and verdict and not r.over then
				h.reply(r, services.status_of(verdict))
				h.finish(r)
				into.verdict = verdict
				return true
			end
			return false
		end
		h.credit(r, #message)
		local kind, payload = string.byte(message), string.sub(message, 2)
		if verdict then
			return true
		elseif kind == 1 then
			buffer.writestring(data, at, payload)
			chunk.update(payload)
			at += #payload
		elseif kind == 2 then
			local mine = chunk.final()
			chunk = sha256.stream()
			table.insert(hashes, mine)
			if payload ~= mine then
				verdict = "changed"
			end
		elseif kind == 3 then
			verdict = if at == size then services.status(payload) else "malformed"
			into.data = data
		end
		return true
	end)
end

-- Into memory: whole, broken off, taken up again, and begun afresh when the file is another.
do
	local h = harness()
	h.greet()
	local file = data_of(2 * CHUNK + CHUNK // 2, 0)
	local _, whole = transfer.hashes(file)
	local t = h.client:get(DEVICE, 1, "docs/report.pdf")
	local progress = 0
	t.on_progress = function(done: number, size: number)
		assert(size == buffer.len(file))
		progress = done
	end
	h.run()
	local r = h.last("zsp.get")
	assert(r.first == services.get("docs/report.pdf", 0, ""))
	serve_get(h, r, file, "id1", 1700000000123)
	h.run()
	local result = t.result :: transfer.Result
	assert(result.status == "ok", result.status)
	assert(buffer.tostring(result.data :: buffer) == buffer.tostring(file) and result.hash == whole and progress == buffer.len(file))
	assert(result.modified == 1700000000123 and result.resumed == 0 and result.bytes == buffer.len(file) and r.ended)

	t = h.client:get(DEVICE, 1, "docs/report.pdf")
	h.run()
	serve_get(h, h.last("zsp.get"), file, "id1", 1, CHUNK + CHUNK // 2)
	h.run()
	result = t.result :: transfer.Result
	local resume = result.resume :: transfer.Resume
	assert(result.status == "failed" and result.reason == "lost" and #resume.hashes == 1)
	t = h.client:get(DEVICE, 1, "docs/report.pdf", resume)
	h.run()
	r = h.last("zsp.get")
	assert(r.first == services.get("docs/report.pdf", CHUNK, "id1"), "asked from the end of the chunks it had")
	serve_get(h, r, file, "id1", 1)
	h.run()
	result = t.result :: transfer.Result
	assert(result.status == "ok" and result.resumed == CHUNK and result.bytes == buffer.len(file) - CHUNK)
	assert(result.hash == whole and buffer.tostring(result.data :: buffer) == buffer.tostring(file))

	-- What broke off is taken up from again; but the file there is another now, and is had afresh.
	t = h.client:get(DEVICE, 1, "docs/report.pdf")
	h.run()
	serve_get(h, h.last("zsp.get"), file, "id1", 1, 2 * CHUNK)
	h.run()
	local other = data_of(buffer.len(file), 1)
	t = h.client:get(DEVICE, 1, "docs/report.pdf", (t.result :: transfer.Result).resume)
	h.run()
	r = h.last("zsp.get")
	assert(r.first == services.get("docs/report.pdf", 2 * CHUNK, "id1"))
	serve_get(h, r, other, "id2", 1)
	h.run()
	result = t.result :: transfer.Result
	assert(result.status == "ok" and result.resumed == 0 and buffer.tostring(result.data :: buffer) == buffer.tostring(other))

	-- A chunk that is not what its hash says fails it, and nothing of it is taken up from.
	t = h.client:get(DEVICE, 1, "docs/report.pdf")
	h.run()
	r = h.last("zsp.get")
	serve_get(h, r, file, "id1", 1, nil, 2)
	h.run()
	result = t.result :: transfer.Result
	assert(result.status == "changed" and result.resume == nil and r.cancelled, "and the call is given up on")

	-- A refusal, and a wait for one.
	local run = h.spawn(function()
		return h.client:get(DEVICE, 1, "docs/../secret").wait()
	end)
	h.run()
	r = h.last("zsp.get")
	h.reply(r, services.status_of("denied"))
	h.finish(r)
	h.run()
	assert(run.done and run.values[1].status == "denied")
	t = h.client:get(DEVICE, 1, "docs/report.pdf", resume)
	h.run()
	r = h.last("zsp.get")
	h.reply(r, services.status_of("timed out"))
	h.finish(r)
	h.run()
	result = t.result :: transfer.Result
	assert(result.status == "timed out" and result.resume == resume, "what it had, it has still")
end

-- From memory: sent as credit allows, chunk by chunk, and taken up where the other end says.
do
	local h = harness()
	h.greet()
	local file = data_of(2 * CHUNK + 12345, 3)
	local chunks, whole = transfer.hashes(file)
	local t = h.client:put(DEVICE, 1, file, "docs/new/report.pdf", { replace = true, modified = 1700000000123 })
	h.run()
	local r = h.last("zsp.put")
	assert(r.first == services.put("docs/new/report.pdf", buffer.len(file), 1700000000123, whole, true, true), "known by its hash")
	local got: { data: buffer?, verdict: string? } = {}
	serve_put(h, r, 0, got)
	h.run()
	local result = t.result :: transfer.Result
	assert(result.status == "ok" and got.verdict == "ok" and result.hash == whole and result.bytes == buffer.len(file))
	assert(buffer.tostring(got.data :: buffer) == buffer.tostring(file))
	assert(#chunks == 3)

	t = h.client:put(DEVICE, 1, file, "docs/new/report.pdf")
	h.run()
	r = h.last("zsp.put")
	got = {}
	serve_put(h, r, 2 * CHUNK, got)
	h.run()
	result = t.result :: transfer.Result
	assert(result.status == "ok" and result.resumed == 2 * CHUNK and result.bytes == 12345)
	assert(buffer.readstring(got.data :: buffer, 2 * CHUNK, 12345) == buffer.readstring(file, 2 * CHUNK, 12345))

	-- An ok before all of it has gone, from a device that means harm or is wrong, is no success.
	t = h.client:put(DEVICE, 1, file, "docs/new/report.pdf")
	h.run()
	r = h.last("zsp.put")
	h.reply(r, services.status_of("ok", services.number_of(0)))
	h.reply(r, services.status_of("ok"))
	h.finish(r)
	h.run()
	assert((t.result :: transfer.Result).status ~= "ok", "an early verdict was taken")

	-- What the other end will not have.
	t = h.client:put(DEVICE, 1, file, "docs/new/report.pdf")
	h.run()
	r = h.last("zsp.put")
	h.reply(r, services.status_of("exists"))
	h.finish(r)
	h.run()
	assert((t.result :: transfer.Result).status == "exists")

	-- Without the host's files, there are no paths to send from.
	t = h.client:put(DEVICE, 1, "here.txt", "docs/x")
	h.run()
	assert((t.result :: transfer.Result).status == "failed")
end

-- Through the host's files: the part beside where it goes, its record of progress, taken up from, and put in place.
type Entry = { data: buffer, size: number, modified: number, serial: number }
local function memory_files(): (transfer.Files, { [string]: Entry })
	local store: { [string]: Entry } = {}
	local serial = 0
	local files: transfer.Files = {
		open = function(path: string, mode: "read" | "write"): transfer.File?
			local e = store[path]
			if not e then
				if mode == "read" then
					return nil
				end
				serial += 1
				e = { data = buffer.create(0), size = 0, modified = 0, serial = serial }
				store[path] = e
			end
			local entry = e :: Entry
			local function room(need: number)
				if buffer.len(entry.data) < need then
					local grown = buffer.create(math.max(need, 2 * buffer.len(entry.data)))
					buffer.copy(grown, 0, entry.data, 0, entry.size)
					entry.data = grown
				end
			end
			return {
				read = function(at: number, n: number): string?
					if at >= entry.size then
						return ""
					end
					return buffer.readstring(entry.data, at, math.min(n, entry.size - at))
				end,
				write = function(at: number, s: string): boolean
					if mode ~= "write" or at > entry.size then
						return false
					end
					room(at + #s)
					buffer.writestring(entry.data, at, s)
					entry.size = math.max(entry.size, at + #s)
					serial += 1
					entry.serial = serial
					return true
				end,
				size = function(): number
					return entry.size
				end,
				truncate = function(n: number): boolean
					room(n)
					if n > entry.size then
						buffer.fill(entry.data, entry.size, 0, n - entry.size)
					end
					entry.size = n
					return true
				end,
				sync = function(): boolean
					return true
				end,
				close = function() end,
			}
		end,
		stat = function(path: string): transfer.Stat?
			local e = store[path]
			if not e then
				return nil
			end
			return { kind = "file", size = e.size, modified = e.modified, identity = tostring(e.serial) }
		end,
		rename = function(from: string, to: string): boolean
			store[to], store[from] = store[from], nil
			return store[to] ~= nil
		end,
		remove = function(path: string)
			store[path] = nil
		end,
		touch = function(path: string, modified: number)
			store[path].modified = modified
		end,
	}
	return files, store
end

do
	local files, store = memory_files()
	local h = harness(files)
	h.greet()
	local file = data_of(3 * CHUNK + 7, 5)
	local _, whole = transfer.hashes(file)
	local t = h.client:get(DEVICE, 1, "docs/big.bin", "dl/big.bin")
	h.run()
	serve_get(h, h.last("zsp.get"), file, "big", 1700000000999, 2 * CHUNK + 100)
	h.run()
	assert((t.result :: transfer.Result).status == "failed" and not store["dl/big.bin"])
	local part, meta = store["dl/big.bin.zsp-part"], store["dl/big.bin.zsp-part.meta"]
	assert(part.size == 2 * CHUNK + 65536, `{part.size}`)
	local w = codec.writer()
	codec.put_bytes(w, "big")
	assert(meta.size == w.pos + 2 * 32 and buffer.readstring(meta.data, 0, w.pos) == codec.string(w), "which file it is, and its chunks' hashes")

	t = h.client:get(DEVICE, 1, "docs/big.bin", "dl/big.bin")
	h.run()
	local r = h.last("zsp.get")
	assert(r.first == services.get("docs/big.bin", 2 * CHUNK, "big"))
	serve_get(h, r, file, "big", 1700000000999)
	h.run()
	local result = t.result :: transfer.Result
	assert(result.status == "ok" and result.resumed == 2 * CHUNK and result.hash == whole)
	local done = store["dl/big.bin"]
	assert(done and buffer.readstring(done.data, 0, done.size) == buffer.tostring(file) and done.modified == 1700000000999)
	assert(not store["dl/big.bin.zsp-part"] and not store["dl/big.bin.zsp-part.meta"], "its record let go")

	-- A part changed here since is taken up only as far as it still proves.
	t = h.client:get(DEVICE, 1, "docs/big.bin", "dl/again.bin")
	h.run()
	serve_get(h, h.last("zsp.get"), file, "big", 1, 3 * CHUNK)
	h.run()
	part = store["dl/again.bin.zsp-part"]
	buffer.writeu8(part.data, CHUNK + 5, 255 - buffer.readu8(part.data, CHUNK + 5))
	t = h.client:get(DEVICE, 1, "docs/big.bin", "dl/again.bin")
	h.run()
	r = h.last("zsp.get")
	assert(r.first == services.get("docs/big.bin", CHUNK, "big"), "from the first chunk alone")
	serve_get(h, r, file, "big", 1)
	h.run()
	assert((t.result :: transfer.Result).status == "ok" and buffer.readstring(store["dl/again.bin"].data, 0, buffer.len(file)) == buffer.tostring(file))

	-- And sent from them: known by what the host says of the file, and changed if it changes on the way.
	local src = files.open("up/src.bin", "write") :: transfer.File
	src.write(0, buffer.tostring(file))
	store["up/src.bin"].modified = 1600000000000
	local identity = (files.stat("up/src.bin") :: transfer.Stat).identity
	t = h.client:put(DEVICE, 1, "up/src.bin", "docs/src.bin")
	h.run()
	r = h.last("zsp.put")
	assert(r.first == services.put("docs/src.bin", buffer.len(file), 1600000000000, identity, false, true))
	local got: { data: buffer?, verdict: string? } = {}
	serve_put(h, r, CHUNK, got)
	h.run()
	result = t.result :: transfer.Result
	assert(result.status == "ok" and result.hash == whole and result.resumed == CHUNK)
	t = h.client:put(DEVICE, 1, "up/src.bin", "docs/src.bin")
	h.run()
	r = h.last("zsp.put")
	got = {}
	src.write(5, "!") -- while it is being sent
	serve_put(h, r, 0, got)
	h.run()
	assert((t.result :: transfer.Result).status == "changed" and got.verdict == "changed", "it said its file changed")
end

print("ok")
