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
		assert(started < 0.1, string.format("tokens are seen at once, not %.1f ms after", started * 1000))
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

-- Questions, asked of one device about what another writes.
do
	local w = zsp.where
	local serde = require("@lune/serde")
	local Track = {
		name = zsp.string(16),
		words = zsp.text(17),
		length = zsp.number(18),
		liked = zsp.boolean(19),
		album = zsp.row(20),
		meta = zsp.custom(21, function(v)
			return serde.encode("json", v)
		end, function(s)
			return serde.decode("json", s)
		end),
	}
	local Album = { title = zsp.string(24), year = zsp.number(25) }
	local albums, tracks, records = {}, {}, {}
	local titles = { "Blue", "Red", "Green" }
	local names = { "alpha", "Beta", "gamma", "Delta", "ALPHA" }
	a:write(1, function(change)
		for i, title in titles do
			albums[i] = change.insert(Album, "albums", i, { title = title, year = 1990 + i })
		end
		for i = 1, 60 do
			local at = i % 4
			local t = {
				name = names[i % 5 + 1],
				words = if i % 7 == 0 then "The quick brown foxes" elseif i % 3 == 0 then "a lazy dog, quick to sleep" else nil,
				length = i * 10,
				liked = if i % 2 == 0 then true elseif i % 5 == 0 then nil else false,
				album = albums[at],
				meta = { tags = { `t{i % 6}`, "all" }, size = { mb = i / 4 } },
			}
			tracks[i] = change.insert(Track, "tracks", i, t)
			records[tracks[i]] = t
		end
	end)
	local function text_of(t: any): string
		return string.lower(t.words or "")
	end
	-- Each condition against what it means.
	local checks: { { any } } = {
		{ w.is("name", "Alpha"), function(t)
			return string.lower(t.name) == "alpha"
		end },
		{ w.exactly("name", "ALPHA"), function(t)
			return t.name == "ALPHA"
		end },
		{ w.among("length", { 10, 20, 30, 5 }), function(t)
			return t.length <= 30
		end },
		{ w.among("name", { "beta", "DELTA" }), function(t)
			return t.name == "Beta" or t.name == "Delta"
		end },
		{ w.between("length", 100, 200), function(t)
			return t.length >= 100 and t.length <= 200
		end },
		{ w.over("length", 500), function(t)
			return t.length > 500
		end },
		{ w.under("length", 50), function(t)
			return t.length < 50
		end },
		{ w.between("length", nil, 50), function(t)
			return t.length <= 50
		end },
		{ w.is("liked", true), function(t)
			return t.liked == true
		end },
		{ w.is("liked", false), function(t)
			return t.liked == false
		end },
		{ w.has("liked"), function(t)
			return t.liked ~= nil
		end },
		{ w.none(w.has("album")), function(t)
			return t.album == nil
		end },
		{ w.is("album", albums[2]), function(t)
			return t.album == albums[2]
		end },
		{ w.begins("name", "AL"), function(t)
			return string.lower(t.name) == "alpha"
		end },
		{ w.contains("name", "ELT"), function(t)
			return t.name == "Delta"
		end },
		{ w.is("meta.tags", "t3"), function(t)
			return t.meta.tags[1] == "t3"
		end },
		{ w.over("meta.size.mb", 10), function(t)
			return t.meta.size.mb > 10
		end },
		{ w.matches("words", "quick"), function(t)
			return string.find(text_of(t), "quick") ~= nil
		end },
		{ w.matches("words", "lazy fox", { any = true, prefix = true }), function(t)
			return t.words ~= nil
		end },
		{ w.matches("words", "brown quick"), function(t)
			return string.find(text_of(t), "brown") ~= nil
		end },
		{ w.matches("words", "brown quick", { phrase = true }), function(_)
			return false
		end },
		{ w.matches("words", "quick brown", { phrase = true }), function(t)
			return string.find(text_of(t), "brown") ~= nil
		end },
		{ w.matches("words", "qiuck", { typos = 2 }), function(t)
			return t.words ~= nil
		end },
		{ w.matches("words", "oxe", { inside = true }), function(t)
			return string.find(text_of(t), "foxes") ~= nil
		end },
		{ w.in_list("tracks"), function(_)
			return true
		end },
		{ w.ids({ tracks[3], tracks[9], albums[1] }), function(t)
			return t == records[tracks[3]] or t == records[tracks[9]]
		end },
		{ w.refers("album", 1, w.over("year", 1991), Album), function(t)
			return t.album == albums[2] or t.album == albums[3]
		end },
		{ w.any(w.under("length", 20), w.all(w.is("liked", true), w.over("length", 580))), function(t)
			return t.length < 20 or (t.liked == true and t.length > 580)
		end },
		{ w.all(), function(_)
			return true
		end },
	}
	for i, check in checks do
		local want = {}
		for j = 60, 1, -1 do
			if check[2](records[tracks[j]]) then
				table.insert(want, tracks[j])
			end
		end
		local got: any
		local asked = b:ask(
			{ scope = 1, table = Track, where = w.all(w.in_list("tracks"), check[1]), order = { "-length" }, limit = 100 },
			function(s)
				got = s
			end
		)
		eventually(`question {i}`, function()
			if got.status ~= "ready" or got.total ~= #want or #got.rows ~= #want then
				return false
			end
			for j, row in got.rows do
				if row.id ~= want[j] or row.length ~= records[want[j]].length then
					return false
				end
			end
			return true
		end)
		asked.stop()
	end

	local got: any
	local asked = b:ask({
		scope = 1,
		table = Track,
		where = w.in_list("tracks"),
		order = { "name", "-meta.size.mb:number" },
		limit = 3,
		offset = 2,
		totals = {
			whole = { "sum", "length" },
			least = { "min", "length" },
			most = { "max", "name" },
			liked = { "facet", "liked" },
			size = { "max", "meta.size.mb:number" },
			by_name = { "facet", "name", 2 },
			known = { "count", "album" },
		},
	}, function(s)
		got = s
	end)
	eventually("totals", function()
		return got.status == "ready" and got.total == 60
	end)
	assert(got.first == 2 and #got.rows == 3 and got.rows[1].id == tracks[55] and got.rows[2].id == tracks[54])
	local t = got.totals
	assert(t.whole == 18300 and t.least == 10 and string.lower(t.most) == "gamma" and t.size == 15 and t.known == 45)
	assert(#t.by_name == 2 and t.by_name[1].count == 24 and string.lower(t.by_name[1].value) == "alpha" and t.by_name[2].count == 12)
	assert(#t.liked == 2 and t.liked[1].value == true and t.liked[1].count == 30 and t.liked[2].count == 24)
	asked.move(0, 1)
	eventually("another stretch", function()
		return got.status == "ready" and got.first == 0 and #got.rows == 1 and got.rows[1].id == tracks[60]
	end)
	-- And it stays true.
	a:write(1, function(change)
		change.set(tracks[60], Track, { name = "zeta" })
	end)
	eventually("what is written is answered", function()
		return got.rows[1].id == tracks[59] and got.totals.most == "zeta"
	end)
	a:write(1, function(change)
		change.set(tracks[59], Track, { liked = true })
	end)
	eventually("what is shown is kept up", function()
		return got.rows[1].liked == true and got.totals.liked[1].count == 31
	end)
	local of: any
	local counted = b:ask({
		scope = 1,
		table = Album,
		where = w.referred(1, "album", w.is("liked", true), 10, nil, Track),
		order = { "title" },
	}, function(s)
		of = s
	end)
	eventually("albums with ten liked", function()
		return of.status == "ready" and of.total == 2 and of.rows[1].title == "Blue" or of.total == 1
	end)
	counted.stop()
	asked.stop()
	local best: any
	local searched = b:ask({ scope = 1, table = Track, where = w.matches("words", "quick foxes", { any = true }), order = { "best" }, limit = 20 }, function(s)
		best = s
	end)
	eventually("the best come first", function()
		return best.status == "ready" and #best.rows == 20 and best.rows[1].words == "The quick brown foxes"
	end)
	local typed = best.rows[1].id
	assert(not a.rows[typed])
	-- Once, with what was written just before, and no more than once.
	a:write(1, function(change)
		change.insert(Track, "tracks", 61, { name = "just now", length = 7000 })
	end)
	local once = a:fetch({ scope = 1, table = Track, where = w.is("name", "just now"), totals = { most = { "max", "length" } } })
	assert(once.status == "ready" and #once.rows == 1 and once.rows[1].length == 7000 and once.totals.most == 7000)
	eventually("it is known there too", function()
		return b:fetch({ scope = 1, table = Track, where = w.over("length", 6000), limit = 1 }).total == 1
	end)
	a:write(1, function(change)
		change.delete(once.rows[1].id)
	end)
	assert(once.rows[1].name == "just now" and a:fetch({ scope = 1, table = Track, where = w.is("name", "just now") }).total == 0)
	local editor = a:text(typed, Track.words)
	editor.append(" ju") -- before it is here
	eventually("what is being edited is had", function()
		return editor.read() == "The quick brown foxes ju"
	end)
	task.wait(0.1)
	local began = os.clock()
	editor.append("mp")
	eventually("live text shows in an answer", function()
		for _, row in best.rows do
			if row.id == typed then
				return row.words == "The quick brown foxes jump"
			end
		end
		return false
	end)
	assert(os.clock() - began < 0.5, "as it is typed, not once it is sealed")
	local other = b:text(typed, Track.words)
	other.append("!")
	eventually("and what others write there is heard", function()
		return editor.read() == "The quick brown foxes jump!"
	end)
	other.close()
	editor.close()
	local brief = a:text(tracks[1], Track.words)
	brief.append("typed and gone")
	brief.close()
	local shown: any
	local shows = b:ask({ scope = 1, table = Track, where = w.matches("words", "typed and gone", { phrase = true }) }, function(s)
		shown = s
	end)
	eventually("even if closed at once", function()
		return #shown.rows == 1 and shown.rows[1].id == tracks[1]
	end)
	shows.stop()
	searched.stop()
	eventually("nothing is held for those who edit no more", function()
		return next(a.asked) == nil
	end)
	eventually("nothing is asked", function()
		return next(b.asked) == nil
	end)
end

-- Whose a row is, on the other device, and as a question.
do
	local News = { title = zsp.string(16), by = zsp.author(16), body = zsp.text(17), writers = zsp.authors(17) }
	eventually("both may write there", function()
		return a:may(2, "write") and b:may(2, "write")
	end)
	local id = ""
	a:write(2, function(change)
		id = change.insert(News, "news", 1, { title = "from ann" })
	end)
	local there: any
	local w = b:window({ scope = 2, list = "news", table = News }, function(s)
		there = s
	end)
	eventually("it says whose it is", function()
		return #there.rows == 1 and there.rows[1].by == "ann"
	end)
	local editor = b:text(id, News.body)
	editor.append("and bob")
	editor.close()
	local more = a:text(id, News.body)
	more.append("and ann")
	more.close()
	eventually("and who wrote in a text", function()
		return table.concat(there.rows[1].writers, " ") == "ann bob"
	end)
	local of: any
	local asked = b:ask({ scope = 2, table = News, where = zsp.where.is("by", "ann"), totals = { whose = { "facet", "writers" } } }, function(s)
		of = s
	end)
	eventually("it can be asked for", function()
		return of.status == "ready" and #of.rows == 1 and #of.totals.whose == 2
	end)
	asked.stop()
	local other = b:ask({ scope = 2, table = News, where = zsp.where.is("by", "bob") }, function(s)
		of = s
	end)
	eventually("and is nobody else's", function()
		return of.status == "ready" and #of.rows == 0
	end)
	other.stop()
	w.stop()
end

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
