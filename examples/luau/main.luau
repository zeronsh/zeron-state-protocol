--!strict
-- An application that keeps to its places: lune run examples/luau/main.luau <address> <token>
-- organization.py runs it on Bob's device.

local datetime = require("@lune/datetime")
local net = require("@lune/net")
local process = require("@lune/process")
local task = require("@lune/task")

local workspace = require("./workspace")
local zsp = require("../../luau/zsp")

local Task = { title = zsp.string(16), owner = zsp.string(17), done = zsp.boolean(18) }

local address, token = process.args[1], process.args[2]
local socket = net.socket("ws://" .. address)
local client = zsp.connect({
	credential = token,
	now = function(): number
		return datetime.now().unixTimestampMillis / 1000
	end,
	random = function(n: number): string
		local out = table.create(n)
		for i = 1, n do
			out[i] = string.char(math.random(0, 255)) -- an application of yours would use a cryptographic source
		end
		return table.concat(out)
	end,
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
})

task.spawn(function()
	while not client.ready or not client.devices[1] do
		task.wait(0.01)
	end
	local everyone = 1
	workspace.name(client, everyone, "engineering", 2)
	workspace.name(client, everyone, "news", 3)

	local user = workspace.user(client)
	assert(user == "bob", user)
	local shared = workspace.place(client, everyone, "everyone")
	local news = workspace.place(client, everyone, "news")
	assert(shared and shared.writable)
	assert(news and not news.writable)
	assert(workspace.place(client, everyone, "engineering") == nil, "Bob is no engineer")
	assert(workspace.place(client, everyone, "nowhere") == nil)

	-- Whose a row is, within a place that all may read, is a column like any other: it divides, and does not protect.
	shared.insert(Task, "tasks", 1, { title = "order lunch", owner = user, done = false })
	shared.insert(Task, "tasks", 2, { title = "water the plants", owner = "hana", done = false })
	local mine = shared.fetch({ table = Task, where = zsp.where.all(zsp.where.in_list("tasks"), zsp.where.is("owner", user)) })
	assert(mine.total == 1 and mine.rows[1].title == "order lunch")
	print("  an application names its places, and has only those that are its user's")
	process.exit(0)
end)
