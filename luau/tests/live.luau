--!strict
-- Two clients on two devices: lune run live <address> <token> <address> <token>

local datetime = require("@lune/datetime")
local net = require("@lune/net")
local process = require("@lune/process")
local task = require("@lune/task")

local zsp = require("../zsp")

local Message = {
	author = zsp.string(16),
	body = zsp.text(17),
	stars = zsp.number(18),
}

local function random(n: number): string
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, math.random(0, 255))
	end
	return buffer.tostring(b)
end

math.randomseed(os.time())
local sockets: { any } = {}

local function host(address: string, token: string)
	return {
		credential = token,
		linger = 0.2,
		now = function(): number
			return datetime.now().unixTimestampMillis / 1000
		end,
		random = random,
		defer = function(f: () -> ())
			task.defer(f)
		end,
		after = function(seconds: number, f: () -> ())
			local thread = task.delay(seconds, f)
			return function()
				pcall(task.cancel, thread)
			end
		end,
		connect = function(receive: (any) -> (), closed: () -> ())
			local ok, socket = pcall(net.socket, "ws://" .. address)
			if not ok then
				return nil
			end
			table.insert(sockets, socket)
			task.spawn(function()
				while true do
					local message = socket:next()
					if message == nil then
						closed()
						return
					end
					receive(message)
				end
			end)
			return {
				send = function(data: buffer)
					pcall(socket.send, socket, data, true)
				end,
				close = function()
					socket:close()
				end,
			}
		end,
	}
end

local function eventually(what: string, f: () -> boolean)
	for _ = 1, 500 do
		if f() then
			return
		end
		task.wait(0.01)
	end
	print("never: " .. what, debug.info(2, "l"))
	process.exit(1)
end

local args = process.args
local a = zsp.connect(host(args[1], args[2]))
local b = zsp.connect(host(args[3], args[4]))
eventually("both connect", function()
	return a.ready and b.ready
end)

-- A window opens at the end, follows it, and knows what lies before.
local ids = {}
for i = 1, 300 do
	a:write(1, function(change)
		ids[i] = change.insert(Message, "chat", i, { author = "wing", stars = i })
	end)
end
local durable = false
a:write(1, function(change)
	change.set(ids[300], Message, { stars = 1000 })
end, function()
	durable = true
end)
eventually("writes are durable", function()
	return durable
end)

local state: any
local told = 0
local all = b:window({ scope = 1, list = "chat", table = Message, size = 400, from = "start" }, function(s)
	state = s
end)
eventually("everything reaches b", function()
	return #state.rows == 300
end)
all.stop()
task.wait(0.3)
local window = b:window({ scope = 1, list = "chat", table = Message, size = 50 }, function(s)
	state = s
	told += 1
end)
eventually("the tail arrives", function()
	return state.status == "ready" and #state.rows == 50 and state.before == 250
end)
assert(state.rows[50].stars == 1000 and state.rows[1].stars == 251 and state.after == 0)
assert(told < 20, `one turn, one telling, not {told}`)

-- Scrolling up loads before; far enough, and the bottom is let go.
local seen = {}
local top = 1
for _ = 1, 40 do
	window.visible(top, top + 20)
	task.wait(0.02)
	for _, row in state.rows do
		seen[row.stars] = true
	end
	if state.before == 0 and state.status ~= "loading" then
		break
	end
end
assert(state.before == 0 and state.rows[1].stars == 1, `reached {state.rows[1].stars} with {state.before} before`)
assert(#state.rows <= 250, `holds {#state.rows}`)
assert(state.after == 300 - #state.rows, `{state.after} after {#state.rows}`)
for i = 1, 299 do
	assert(seen[i], `row {i} never seen`)
end
for i = 2, #state.rows do
	assert(state.rows[i].order > state.rows[i - 1].order, "out of order")
end
-- What lies beyond is kept true, though none of it is here.
local beyond = state.after
a:write(1, function(change)
	change.insert(Message, "chat", 250.0, { author = "far", stars = 0.5 })
end)
eventually("a row out of sight is counted", function()
	return state.after == beyond + 1
end)
-- And back down again.
for _ = 1, 40 do
	window.visible(#state.rows - 20, #state.rows)
	task.wait(0.02)
	if state.after == 0 and state.status ~= "loading" then
		break
	end
end
assert(state.after == 0 and state.rows[#state.rows].stars == 1000, "the bottom came back")
assert(state.before == 301 - #state.rows)

-- Rows that have not changed are the same tables.
local before = state.rows[#state.rows - 1]
a:write(1, function(change)
	change.set(ids[300], Message, { author = "edited" })
end)
eventually("an edit arrives", function()
	return state.rows[#state.rows].author == "edited"
end)
assert(state.rows[#state.rows - 1] == before, "identity is kept")

-- Text streams live, before any of it is durable, and ends up the same on both sides.
local id
a:write(1, function(change)
	id = change.insert(Message, "chat", 301, { author = "model" })
end)
eventually("the row arrives", function()
	return state.rows[#state.rows].author == "model"
end)
local started = 0
local editor = a:text(id, Message.body)
local said = ""
for i = 1, 100 do
	local token = `token{i} `
	said ..= token
	editor.append(token)
	if i == 10 then
		local clock = os.clock()
		while state.rows[#state.rows].body ~= said and os.clock() - clock < 5 do
			task.wait()
		end
		started = os.clock() - clock
		assert(started < 0.1, "tokens are seen at once")
	end
	if i % 10 == 0 then
		task.wait(0.005)
	end
end
eventually("the whole text arrives", function()
	return state.rows[#state.rows].body == said
end)
editor.close()
print(string.format("     a streamed token shows on the other device in %.1f ms", started * 1000))

-- Both edit at once, each watching.
local theirs = a:window({ scope = 1, list = "chat", table = Message, size = 10 }, function() end)
task.wait(0.1)
local ea, eb = a:text(id, Message.body), b:text(id, Message.body)
ea.insert(0, "[a]")
eb.insert(0, "[b]")
eb.delete(10, 5)
task.wait(0.3)
ea.close()
eb.close()
task.wait(0.3)
local ea2, eb2 = a:text(id, Message.body), b:text(id, Message.body)
eventually("the edits meet", function()
	return ea2.read() == eb2.read()
end)
assert(string.find(eb2.read(), "[a]", 1, true) and string.find(eb2.read(), "[b]", 1, true))

-- Moves and deletions.
a:write(1, function(change)
	change.place(ids[250], "chat", 999)
	change.delete(ids[299])
end)
eventually("a move and a deletion arrive", function()
	local gone = true
	for _, row in state.rows do
		gone = gone and row.id ~= ids[299]
	end
	return gone and state.rows[#state.rows].id == ids[250]
end)

-- Calls.
b:serve(1, "shout", function(call, data)
	call.send(string.upper(data))
	call.finish()
end)
b:serve(1, "count", function(call, data)
	local n = tonumber(data) :: number
	for i = 1, n do
		call.send(string.rep(tostring(i % 10), 1000))
	end
	call.finish()
end)
eventually("b is reachable", function()
	return #a.devices == 2 and #b.devices == 2
end)
local answer, fault = a:request(a.devices[2].id, 1, "shout", "hello")
assert(answer == "HELLO", `{answer} {fault}`)
local _, unserved = a:request(a.devices[2].id, 1, "whisper", "")
assert(unserved == "unserved", unserved)
local long = a:request(a.devices[2].id, 1, "count", "2000")
assert(long and #long == 2000000, "two megabytes flow through a window of a quarter") 
local self_answer = b:request(b.devices[1].id, 1, "shout", "me")
assert(self_answer == "ME")

-- The pipe breaks; nothing is lost and nothing needs saying again.
for _, s in sockets do
	pcall(s.close, s)
end
a:write(1, function(change)
	change.insert(Message, "chat", 2000, { author = "offline" })
end)
eventually("what was written while away arrives", function()
	return a.ready and b.ready and state.status == "ready" and state.rows[#state.rows].author == "offline"
end)
assert(b:request(b.devices[1].id, 1, "shout", "again") == "AGAIN")

-- A window nobody observes is let go.
theirs.stop()
window.stop()
assert(next(b.windows) ~= nil)
task.wait(0.3)
assert(next(b.windows) == nil and next(b.pages) == nil)
local held = 0
for _ in b.rows do
	held += 1
end
assert(held <= 1, `{held} rows linger`)
print("ok")
process.exit(0)
