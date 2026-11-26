--!strict
-- Agreement with vectors/vectors.json.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local codec = require("../zsp/codec")
local services = require("../zsp/services")
local sha256 = require("../zsp/sha256")
local text = require("../zsp/text")
local transfer = require("../zsp/transfer")

local vectors = serde.decode("json", fs.readFile(process.args[1]))

local function bytes(hex: string): string
	return (string.gsub(hex, "..", function(two)
		return string.char(tonumber(two, 16) :: number)
	end))
end

local function hex(s: string): string
	return (string.gsub(s, ".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

assert(hex(sha256("")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
assert(hex(sha256(string.rep("a", 1000))) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")

for _, v in vectors.keys do
	local w = codec.writer()
	codec.put_key(w, bytes(v.key))
	assert(hex(codec.string(w)) == v.wire, v.key)
	assert(codec.key(codec.reader(bytes(v.wire))) == bytes(v.key))
end

for _, v in vectors.lists do
	local tag = string.pack(">I4", v.scope) .. string.sub(sha256(bytes(v.list_key) .. v.name), 1, 12)
	assert(hex(tag) == v.tag, v.name)
end

for i, v in vectors.texts do
	for round = 1, 6 do -- in any order: the text is of the cells alone
		local cells = table.clone(v.cells)
		if round > 1 then
			for j = #cells, 2, -1 do
				local k = math.random(j)
				cells[j], cells[k] = cells[k], cells[j]
			end
		end
		local t = text.new()
		for _, c in cells do
			text.apply(t, c.kind, bytes(c.stamp), bytes(c.body))
		end
		assert(#t.waiting == 0, `text {i} still waits`)
		assert(text.read(t) == v.text, `text {i}: {text.read(t)} should be {v.text}`)
	end
end

-- Writers here agree with each other, live frames and all.
local function random(): string
	return string.pack(">I4I4", math.random(0, 2147483647) * 2 + 1, math.random(0, 2147483647) * 2 + 1)
end
for seed = 1, 60 do
	math.randomseed(seed)
	local writers = { text.new(), text.new(), text.new() }
	local all = {}
	local clock = 0
	local function seal(t: text.Text)
		clock += 1
		local stamp = codec.u64(clock) .. random()
		local body = text.close(t, stamp)
		if body then
			table.insert(all, { stamp = stamp, body = body })
		end
	end
	for _ = 1, 200 do
		local t = writers[math.random(3)]
		local n = text.len(t)
		local r = math.random(10)
		if r <= 5 then
			text.insert(t, math.random(0, n), string.rep(string.char(math.random(97, 122)), math.random(4)), random)
		elseif r == 6 and n > 0 then
			local pos = math.random(0, n - 1)
			text.delete(t, pos, math.min(math.random(5), n - pos), random)
		elseif r == 7 then
			local piece, offset, ops = text.flush(t)
			for _, o in writers do
				if o ~= t and piece ~= "" and math.random(2) == 1 then
					text.live(o, piece, offset, ops)
				end
			end
		elseif r == 8 then
			seal(t)
		elseif #all > 0 then
			local c = all[math.random(#all)]
			text.apply(t, 4, c.stamp, c.body)
		end
	end
	for _, t in writers do
		seal(t)
	end
	for _, t in writers do
		for j = #all, 2, -1 do
			local k = math.random(j)
			all[j], all[k] = all[k], all[j]
		end
		for _, c in all do
			text.apply(t, 4, c.stamp, c.body)
		end
		assert(#t.waiting == 0 and text.read(t) == text.read(writers[1]), `seed {seed}`)
	end
end
-- However deep or wide someone makes a text, a place in it is found in a few steps.
do
	local t = text.new()
	local ids: { string } = {}
	local took = { 0, 0 }
	local N = 12000
	for i = 1, N do
		local id = random()
		local function ref(of: string): string
			return "\2" .. of .. "\0"
		end
		local where
		if i == 1 then
			where = "\0\0"
		elseif i % 3 == 0 then
			where = "\0" .. ref(ids[#ids - 2] or ids[1])
		elseif i % 3 == 1 then
			where = ref(ids[1]) .. "\0"
		else
			where = ref(ids[math.random(#ids)]) .. ref(ids[math.random(#ids)])
		end
		local before = text.steps()
		assert(text.apply(t, 4, codec.u64(i) .. random(), id .. "\1" .. where .. "\1x") == "changed")
		if i <= 1000 then
			took[1] += text.steps() - before
		elseif i > N - 1000 then
			took[2] += text.steps() - before
		end
		table.insert(ids, id)
	end
	assert(took[2] < 3 * took[1], `the last took {took[2]} steps, the first {took[1]}`)
end

-- Hashed piece by piece as at once, across blocks and their ends.
do
	local s = string.rep("abcdefghij", 50)
	for _, pieces in { { 1 }, { 63, 1, 64 }, { 55 }, { 56 }, { 64, 64 }, { 7, 200 } } do
		local h = sha256.stream()
		local at, i = 1, 1
		while at <= #s do
			local n = pieces[(i - 1) % #pieces + 1]
			h.update(if i % 2 == 0 then buffer.fromstring(string.sub(s, at, at + n - 1)) else string.sub(s, at, at + n - 1))
			at += n
			i += 1
		end
		assert(h.final() == sha256(s), `in pieces of {table.concat(pieces, ", ")}`)
	end
	for n = 50, 70 do
		local h = sha256.stream()
		h.update(string.rep("x", n))
		assert(h.final() == sha256(string.rep("x", n)), `{n} bytes`)
	end
end

-- Files hashed in chunks, fed in pieces of every kind, each chunk's hash and the file's as vectors.json has them.
for _, v in vectors.files do
	local data = buffer.create(v.size)
	for i = 0, v.size - 1 do
		buffer.writeu8(data, i, (i * 7 + i // 251) % 256)
	end
	for _, piece in { 65536, 1000003, 777 } do
		if piece == 777 and v.size > transfer.CHUNK + 1 then
			continue -- as well hashed by the others, and slow in pieces so small
		end
		local chunks, file = transfer.hashes(data, piece)
		assert(#chunks == #v.chunks, `{v.size} bytes: {#chunks} chunks`)
		for i, c in chunks do
			assert(hex(c) == v.chunks[i], `{v.size} bytes: chunk {i}`)
		end
		assert(hex(file) == v.file, `{v.size} bytes in pieces of {piece}`)
	end
end

-- What services say, byte for byte: written as they should be, and read back.
do
	local said: { [string]: string } = {}
	for _, v in vectors.services do
		said[v.message] = bytes(v.bytes)
	end
	local function same(name: string, got: string)
		assert(said[name], `no vector "{name}"`)
		assert(got == said[name], `{name}: {hex(got)} should be {hex(said[name])}`)
	end
	same("zsp.tcp to port 22 of 127.0.0.1", services.tcp(22, "127.0.0.1"))
	same("zsp.exec ls -l /tmp, LANG=C and without HOME, in /srv", services.exec({ "ls", "-l", "/tmp" }, { "LANG=C", "HOME" }, "/srv"))
	same("zsp.pty 24 rows by 80, xterm-256color, the user's shell, COLORTERM=truecolor", services.pty(24, 80, "xterm-256color", { "COLORTERM=truecolor" }))
	same("zsp.get docs/report.pdf from 3 MiB, as it was", services.get("docs/report.pdf", 3 * 1048576, "\170\187\204"))
	same("zsp.put docs/new/report.pdf of 2.5 MiB, replacing, making folders", services.put("docs/new/report.pdf", 2621440, 1700000000123, "\1\2\3\4", true, true))
	same("zsp.list docs/sub", services.list("docs/sub"))
	local entry = { name = "a.txt", kind = "file" :: "file", size = 1234, modified = 1700000000000 }
	same("an entry: a.txt, 1234 bytes", services.entry(entry))
	local entries = services.entries(said["an entry: a.txt, 1234 bytes"]) :: { services.Entry }
	assert(#entries == 1 and entries[1].name == "a.txt" and entries[1].kind == "file" and entries[1].size == 1234 and entries[1].modified == 1700000000000)

	local offered: { services.Service } = {
		{ kind = "shell", terminal = true, commands = true },
		{ kind = "files", name = "docs", read = true, write = true },
		{ kind = "tcp", port = 22, host = "", name = "ssh" },
	}
	same("zsp.services: terminals and commands, docs to read and write, port 22 as ssh", services.status_of("ok", services.listed(offered)))
	local status, rest = services.status(said["zsp.services: terminals and commands, docs to read and write, port 22 as ssh"])
	local listed = services.services(rest) :: { any }
	assert(status == "ok" and #listed == 3)
	assert(listed[1].kind == "shell" and listed[1].terminal and listed[1].commands)
	assert(listed[2].kind == "files" and listed[2].name == "docs" and listed[2].read and listed[2].write)
	assert(listed[3].kind == "tcp" and listed[3].port == 22 and listed[3].host == "" and listed[3].name == "ssh")

	same("status: ok", services.status_of("ok"))
	same("status: denied, with a reason", services.status_of("denied", "not shared with you"))
	local why, reason = services.status(said["status: denied, with a reason"])
	assert(why == "denied" and reason == "not shared with you")

	local got = { size = 2621440, modified = 1700000000123, identity = "\170\187\204", from = 1048576 }
	same("zsp.get answered: 2.5 MiB, from 1 MiB", services.status_of("ok", services.got_of(got)))
	local _, answer = services.status(said["zsp.get answered: 2.5 MiB, from 1 MiB"])
	local read = services.got(answer) :: services.Got
	assert(read.size == got.size and read.modified == got.modified and read.identity == got.identity and read.from == got.from)
	same("zsp.put answered: from 2 MiB", services.status_of("ok", services.number_of(2 * 1048576)))
	assert(services.number(string.sub(said["zsp.put answered: from 2 MiB"], 2)) == 2 * 1048576)

	same("input: ls", services.input("ls\n"))
	same("signal: interrupt", services.signal(services.SIGNALS.interrupt))
	same("resize: 50 rows by 132", services.resize(50, 132))
	same("output: hi", services.output("hi"))
	same("errors: no", services.errors("no"))
	same("exited 1", services.exit(1, 0))
	same("killed by 9", services.exit(0, 9))
	local code, signal = services.exited(string.sub(said["killed by 9"], 2))
	assert(code == 0 and signal == 9)
	code, signal = services.exited(string.sub(said["exited 1"], 2))
	assert(code == 1 and signal == 0)

	local hash = bytes("5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8")
	same("a chunk's hash follows its bytes", services.chunk(hash))
	same("the end of a file sent whole, with its hash", services.done("ok", hash))
end

print("ok")
