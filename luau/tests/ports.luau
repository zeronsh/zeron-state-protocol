--!strict
-- Names, ports and exposures, as a client asks its host: lune run ports <address> <token> <address> <token> <port>
-- The first device offers and exposes; the second is offered.

local datetime = require("@lune/datetime")
local net = require("@lune/net")
local process = require("@lune/process")
local task = require("@lune/task")

local zsp = require("../zsp")

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

local function main()
local args = process.args
local a = zsp.connect(host(args[1], args[2]))
local b = zsp.connect(host(args[3], args[4]))
local port = tonumber(args[5]) :: number
eventually("both connect", function()
	return a.ready and b.ready and #a.devices == 2 and #b.devices == 2
end)

local function check<T>(value: T?, fault: string?): T
	if value == nil then
		print("refused: " .. tostring(fault), debug.info(2, "l"))
		process.exit(1)
	end
	return value :: T
end

-- Every device, by name and address: this one here, the other reachable.
local nodes = check(b:nodes())
assert(#nodes == 2, "two devices")
local me, other = nodes[1], nodes[2]
if not me.here then
	me, other = other, me
end
assert(me.here and me.address == "127.0.0.1" and string.sub(me.name, -#".id.zsp.internal") == ".id.zsp.internal")
assert(other.reachable and not other.here and other.id == a.devices[1].id, "the other is the one that offers")

-- Nothing is offered unless it is; then it is, and listed as it listens.
assert(#check(a:offers()) == 0)
local offers = check(a:offer({ lo = port, scope = 1, name = "web" }))
assert(#offers == 1 and offers[1].lo == port and offers[1].hi == port and offers[1].name == "web" and offers[1].device == nil)
assert(#check(a:offer({ lo = 1000, hi = 2000, scope = 1, host = "10.0.0.4" })) == 2)
local _, refused = a:offer({ lo = 22, scope = 1, host = "127.0.0.1" })
assert(refused == "denied", "this machine is no host")
local _, unserved = b:offer({ lo = 22, scope = 9 }) -- no such scope: refused, not served wrongly
assert(unserved == "denied")
local seen = false
for _ = 1, 300 do -- what a device offers is asked when it is wanted: here, by asking for nodes until it is heard
	for _, n in check(b:nodes()) do
		for _, p in n.ports do
			seen = seen or (p.port == port and p.name == "web" and p.scope == 1)
		end
	end
	if seen then
		break
	end
	task.wait(0.02)
end
assert(seen, "the offer is heard")
assert(#check(a:unoffer({ lo = 1000, hi = 2000, scope = 1, host = "10.0.0.4" })) == 1)

-- Exposed to the public, under a fresh name, and taken back.
local exposed = check(a:expose(port, { name = "web", proxy = true }))
assert(#exposed == 1 and exposed[1].port == port and exposed[1].proxy and string.sub(exposed[1].label, 1, 4) == "web-")
local again = check(a:expose(port + 1))
assert(#again == 2 and again[2].label ~= exposed[1].label)
local _, twice = a:expose(port)
assert(twice == "denied", "exposed already")
assert(#check(a:unexpose(port)) == 1 and #check(a:unexpose(port + 1)) == 0)
local _, never = a:unexpose(port)
assert(never == "denied")
-- No port that is not one, rather than one it wraps round to.
for _, bad in { 65616, 0, 1.5, -80 } do
	assert(not pcall(a.offer, a, { lo = bad, scope = 1 }), `offered {bad}`)
	assert(not pcall(a.expose, a, bad), `exposed {bad}`)
	assert(not pcall(a.unexpose, a, bad), `unexposed {bad}`)
end
print("ok")
end

-- Whatever fails says so and ends: the sockets would keep it waiting for ever.
local ok, why = pcall(main) -- pcall, which lets main yield as it waits for answers; xpcall would not
if not ok then
	print(why)
	process.exit(1)
end
process.exit(0)
