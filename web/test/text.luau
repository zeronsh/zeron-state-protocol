--!strict
-- Replays what web/test/text.ts did to texts, read from stdin, through a text.luau, and says what came of each step, as
-- that does: lune run web/test/text.luau <path of text.luau from here, without .luau>

local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local text = (require :: any)(process.args[1])

local function bytes(hex: string): string
	return (string.gsub(hex, "..", function(two)
		return string.char(tonumber(two, 16) :: number)
	end))
end

local HEX: { [string]: string } = {}
for b = 0, 255 do
	HEX[string.char(b)] = string.format("%02x", b)
end
local function hex(s: string): string
	return (string.gsub(s, ".", HEX))
end

local input = serde.decode("json", stdio.readToEnd())
local out = {}

for _, seed in input.seeds do
	local writers = { text.new(), text.new(), text.new() }
	local had: { { number } } = { {}, {}, {} }
	local cells: { { kind: number, stamp: string, body: string } } = {}
	local flushes: { { piece: string, offset: number, bytes: string } } = {}

	local function apply(w: number, c: number, body: string?): string
		local cell = cells[c]
		local result = text.apply(writers[w], cell.kind, cell.stamp, body or cell.body)
		if body == nil then
			table.insert(had[w], c)
		end
		if result == "rebuild" then
			local t = text.new()
			for _, k in had[w] do
				text.apply(t, cells[k].kind, cells[k].stamp, cells[k].body)
			end
			writers[w] = t
		end
		return result
	end

	for k, op in seed.ops do
		local w = op.w
		local t = writers[w]
		local function fresh(): string
			return bytes(op.fresh)
		end
		local ok, ret = pcall(function(): string
			local o = op.o
			if o == "insert" then
				text.insert(t, op.pos, bytes(op.bytes), fresh)
			elseif o == "delete" then
				text.delete(t, op.pos, op.count, fresh)
			elseif o == "after" then
				return hex(text.after(t, bytes(op.name), bytes(op.bytes), fresh))
			elseif o == "remove" then
				text.remove(t, bytes(op.name), op.count, fresh)
			elseif o == "flush" then
				local piece, offset, ops = text.flush(t)
				table.insert(flushes, { piece = piece, offset = offset, bytes = ops })
				return `{hex(piece)},{offset},{hex(ops)}`
			elseif o == "live" then
				local f = flushes[op.f]
				return text.live(t, f.piece, f.offset + op.a, string.sub(f.bytes, op.a + 1, op.b))
			elseif o == "close" then
				local stamp = bytes(op.stamp)
				local body = text.close(t, stamp)
				if body == nil then
					return "nil"
				end
				table.insert(cells, { kind = 4, stamp = stamp, body = body })
				table.insert(had[w], #cells)
				return hex(body)
			elseif o == "apply" then
				return apply(w, op.c, if op.cut then string.sub(cells[op.c].body, 1, op.cut) else nil)
			elseif o == "cell" then
				table.insert(cells, { kind = op.kind, stamp = bytes(op.stamp), body = bytes(op.body) })
				return "cell"
			end
			return ""
		end)
		if not ok then
			ret = "!"
		end
		if op.o ~= "cell" then
			t = writers[w]
			local line = `{ret}|{text.len(t)}|{t.version}|{if text.provisional(t) then 1 else 0}|{#t.waiting}`
			if k % 8 == 0 then
				line ..= "|" .. hex(text.read(t))
			end
			table.insert(out, line)
		else
			table.insert(out, ret)
		end
	end

	-- Where everything is, in each.
	for w, t in writers do
		local order = text.order(t)
		local names = {}
		for name in order do
			table.insert(names, name)
		end
		table.sort(names, function(a, b)
			return order[a] < order[b]
		end)
		local parts = {}
		for _, name in names do
			local label, offset = text.position(t, name)
			table.insert(parts, `{hex(name)}:{hex(string.pack(">d", label :: number))}:{offset}:{if text.standing(t, name) then 1 else 0}`)
		end
		table.insert(out, `writer {w}: {hex(text.read(t))} {table.concat(parts, ",")} {#text.ids(t)}`)
	end
	table.insert(out, `steps {text.steps()}`)
end

print(table.concat(out, "\n"))
