--!strict
-- Agreement with vectors/vectors.json.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local codec = require("../zsp/codec")
local sha256 = require("../zsp/sha256")
local text = require("../zsp/text")

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
	for round = 1, if v.ordered then 1 else 6 do
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
print("ok")
