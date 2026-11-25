--!strict
-- Structured state on two devices: lune run mirror <address> <token> <address> <token>

local datetime = require("@lune/datetime")
local net = require("@lune/net")
local process = require("@lune/process")
local task = require("@lune/task")

local zsp = require("../zsp")
local m = zsp.mirror

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


local function equal(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not equal(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function show(v: any, depth: number?): string
	if type(v) ~= "table" then
		return if type(v) == "string" and #v == 16 and string.find(v, "[^%w%s%p]") then "<id>" else tostring(v)
	end
	local parts = {}
	for k, x in v do
		if k ~= "id" then
			table.insert(parts, `{tostring(k)}={show(x)}`)
		end
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ", ") .. "}"
end

local Task = m.map({ title = zsp.string(16), done = zsp.boolean(17), notes = zsp.text(18), tags = m.list(zsp.string(19)) })
local Node = m.map({ name = zsp.string(16) })
local Board = m.map({
	title = zsp.string(16),
	count = zsp.number(17),
	meta = m.map({ owner = zsp.string(16), created = zsp.number(17) }),
	tasks = m.list(Task),
	scores = m.record(zsp.number(16)),
	people = m.record(m.map({ role = zsp.string(16), bio = zsp.text(17) })),
	outline = m.tree(Node),
})

local args = process.args
local ca = zsp.connect(host(args[1], args[2]))
local cb = zsp.connect(host(args[3], args[4]))
-- Opened before it is connected, it is empty, and then as it is.
local early: any = nil
local b = m.open(cb, { scope = 1, name = "board", schema = Board }, function(state)
	early = state
end)
assert(early and #early.tasks == 0 and early.title == nil)
eventually("both connect", function()
	return ca.ready and cb.ready and ca:may(1, "write") and cb:may(1, "write")
end)
local a = m.open(ca, { scope = 1, name = "board", schema = Board })
local function level(what: string)
	eventually(what, function()
		return equal(a.state(), b.state())
	end)
end

-- What one sets, the other has, as it was set.
assert(a.state().title == nil and #a.state().tasks == 0, "nothing yet")
a.set({
	title = "Launch",
	count = 3,
	meta = { owner = "ann", created = 1700000000 },
	tasks = {
		{ title = "write it", done = true, notes = "the first draft", tags = { "doc", "now" } },
		{ title = "test it", done = false, notes = "", tags = {} },
		{ title = "ship it", done = false, tags = { "later" } },
	},
	scores = { ann = 3, bob = 5 },
	people = { ann = { role = "lead", bio = "writes" } },
	outline = {
		{ name = "plan", children = { { name = "goals" }, { name = "risks" } } },
		{ name = "do" },
	},
})
local mine = a.state()
assert(mine.title == "Launch" and #mine.tasks == 3 and mine.tasks[1].tags[2] == "now" and mine.outline[1].children[2].name == "risks", show(mine))
assert(mine.tasks[1].id and mine.outline[1].id, "what is made has an id")
level("the other has it")
assert(rawequal(early, b.state()), "and the one opened early is told")
assert(b.state().scores.bob == 5 and b.state().people.ann.bio == "writes" and b.state().meta.owner == "ann")

-- What did not change is the very same table.
local before = a.state()
a.update(function(d)
	d.tasks[2].done = true
end)
local after = a.state()
assert(after.tasks[2].done == true and not rawequal(after.tasks[2], before.tasks[2]), "what changed is new")
assert(rawequal(after.tasks[1], before.tasks[1]) and rawequal(after.tasks[3], before.tasks[3]), "and the rest is not")
assert(rawequal(after.meta, before.meta) and rawequal(after.outline, before.outline) and rawequal(after.scores, before.scores))
level("a change goes over")

-- Moves, deletions, keys, and a node moved elsewhere in a tree.
a.update(function(d)
	local last = table.remove(d.tasks)
	table.insert(d.tasks, 1, last)
	table.remove(d.tasks, 3)
	d.scores.bob = nil
	d.scores.cy = 1
	local risks = table.remove(d.outline[1].children, 2)
	table.insert(d.outline[2].children or {}, risks)
	d.outline[2].children = d.outline[2].children or { risks }
	d.tasks[1].tags = { "first", "later", "last" }
end)
local s = a.state()
assert(s.tasks[1].title == "ship it" and s.tasks[2].title == "write it" and #s.tasks == 2, show(s.tasks))
assert(s.scores.bob == nil and s.scores.cy == 1 and s.outline[2].children[1].name == "risks" and #s.outline[1].children == 1, show(s))
assert(s.tasks[1].tags[3] == "last")
level("moves go over")

-- Both at once, neither having heard of the other.
a.update(function(d)
	table.insert(d.tasks, 1, { title = "from a" })
	d.tasks[3].title = "write it well" -- "write it", now third
	d.scores.cy = 10
	d.tasks[2].notes = "a: " .. (d.tasks[2].notes or "")
	-- plan under do
	local plan = table.remove(d.outline, 1)
	table.insert(d.outline[1].children, plan)
end)
b.update(function(d)
	table.insert(d.tasks, 1, { title = "from b" })
	d.tasks[3].done = true -- the same task, by b's reckoning second
	d.scores.cy = 20
	d.tasks[2].notes = (d.tasks[2].notes or "") .. " :b"
	-- do under plan
	local done = table.remove(d.outline, 2)
	table.insert(d.outline[1].children, done)
	-- and one deleted that the other edits
	d.people.ann = nil
end)
a.update(function(d)
	if d.people.ann then
		d.people.ann.role = "boss"
	end
end)
level("both at once come to one")
local s2 = a.state()
local titles = {}
for _, t in s2.tasks do
	titles[t.title] = t
end
assert(titles["from a"] and titles["from b"], "both are there")
assert(titles["write it well"] and titles["write it well"].done == true, "each change to one task is kept " .. show(s2.tasks))
assert(s2.scores.cy == 10 or s2.scores.cy == 20)
assert(s2.people.ann == nil, "what is gone is gone, whatever was done to it meanwhile")
local count = 0
local function walk(level: any)
	for _, n in level do
		count += 1
		walk(n.children)
	end
end
walk(s2.outline)
assert(count == 4, `every node somewhere, and no loop: {show(s2.outline)}`)
local notes = titles["ship it"].notes
assert(string.find(notes, "a: ", 1, true) and string.find(notes, " :b", 1, true), `text kept from both: {notes}`)

-- One place, written into again and again: room is made, and the order is as it was written.
local Squeeze = m.map({ items = m.list(zsp.number(16)) })
local sa = m.open(ca, { scope = 1, name = "squeeze", schema = Squeeze })
local sb = m.open(cb, { scope = 1, name = "squeeze", schema = Squeeze })
sa.set({ items = { 0, 1000 } })
local want = { 0 }
for i = 1, 80 do
	sa.update(function(d)
		table.insert(d.items, i + 1, i)
	end)
	table.insert(want, i)
end
table.insert(want, 1000)
assert(equal(sa.state().items, want), show(sa.state().items))
eventually("the other has the same order", function()
	return equal(sb.state().items, want)
end)
sa.stop()
sb.stop()

-- Any changes, by both, at once: one state, and a tree without loops.
local words = { "alpha", "beta", "gamma", "delta", "eps" }
local function mutate(d: any)
	for _ = 1, math.random(1, 4) do
		local r = math.random(9)
		if r == 1 then
			table.insert(d.tasks, math.random(1, #d.tasks + 1), { title = words[math.random(#words)], done = math.random(2) == 1, tags = { words[math.random(#words)] } })
		elseif r == 2 and #d.tasks > 0 then
			table.remove(d.tasks, math.random(#d.tasks))
		elseif r == 3 and #d.tasks > 1 then
			local t = table.remove(d.tasks, math.random(#d.tasks))
			table.insert(d.tasks, math.random(1, #d.tasks + 1), t)
		elseif r == 4 and #d.tasks > 0 then
			local t = d.tasks[math.random(#d.tasks)]
			t.title = words[math.random(#words)]
			t.notes = (t.notes or "") .. words[math.random(#words)]
			table.insert(t.tags, math.random(1, #t.tags + 1), words[math.random(#words)])
		elseif r == 5 then
			d.scores[words[math.random(#words)]] = if math.random(3) == 1 then nil else math.random(100)
		elseif r == 6 then
			d.people[words[math.random(#words)]] = if math.random(3) == 1 then nil else { role = words[math.random(#words)] }
		elseif r == 7 then
			-- a node, new or moved, anywhere
			local all = {}
			local function collect(level: any)
				for _, n in level do
					table.insert(all, n)
					n.children = n.children or {}
					collect(n.children)
				end
			end
			collect(d.outline)
			if #all > 0 and math.random(2) == 1 then
				local target = all[math.random(#all)]
				local function take(level: any): any
					for i, n in level do
						if n == target then
							return table.remove(level, i)
						end
						local found = take(n.children)
						if found then
							return found
						end
					end
					return nil
				end
				local node = take(d.outline)
				local rest = {}
				local function gather(level: any)
					for _, n in level do
						table.insert(rest, n)
						gather(n.children)
					end
				end
				gather(d.outline)
				if #rest > 0 and math.random(3) > 1 then
					local into = rest[math.random(#rest)]
					table.insert(into.children, node)
				else
					table.insert(d.outline, node)
				end
			else
				table.insert(d.outline, { name = words[math.random(#words)], children = {} })
			end
		elseif r == 8 then
			d.count = math.random(1000)
			d.meta.owner = words[math.random(#words)]
		elseif r == 9 and #d.tasks > 0 then
			d.tasks[math.random(#d.tasks)].tags = {}
		end
	end
end
math.randomseed(7)
for round = 1, 40 do
	a.update(mutate)
	b.update(mutate)
	level(`round {round}`)
	local seen: { [string]: boolean } = {}
	local function check(level: any)
		for _, n in level do
			assert(not seen[n.id], "a node twice")
			seen[n.id] = true
			check(n.children)
		end
	end
	check(a.state().outline)
end

-- A document of thousands: what one change costs, writing and reading.
local Big = m.map({ items = m.list(m.map({ n = zsp.number(16), label = zsp.string(17) })) })
local big = m.open(ca, { scope = 1, name = "big", schema = Big })
local items = {}
for i = 1, 2000 do
	items[i] = { n = i, label = `item {i}` }
end
local t0 = os.clock()
big.set({ items = items })
local made = os.clock() - t0
t0 = os.clock()
for _ = 1, 20 do
	big.update(function(d)
		d.items[math.random(#d.items)].n += 1
	end)
end
local one = (os.clock() - t0) / 20
-- And as a new state that shares what did not change.
t0 = os.clock()
for _ = 1, 20 do
	local now = big.state()
	local list = table.clone(now.items)
	local i = math.random(#list)
	local item = table.clone(list[i])
	item.n += 1
	list[i] = item
	local next = table.clone(now)
	next.items = list
	big.set(next)
end
local shared = (os.clock() - t0) / 20
local other = m.open(cb, { scope = 1, name = "big", schema = Big })
eventually("the other has all of it", function()
	return #other.state().items == 2000
end)
assert(other.state().items[1].label == "item 1")
print(string.format("     2000 rows made in %.0f ms; one change among them, written and read again, %.1f ms by update, %.1f ms by set", made * 1000, one * 1000, shared * 1000))

for _, d in { a, b, big, other } do
	d.stop()
end
print("ok")
process.exit(0)
