--!strict
-- Writes the questions web/test/ask.ts describes, read from stdin, as ask.luau does: a line of hex for each, and the
-- names of its totals, or "!" if it cannot be written. lune run web/test/ask.luau

local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local ask = require("../../luau/zsp/ask")
local sha256 = require("../../luau/zsp/sha256")

local w = ask.where

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
local tables: { [string]: any } = input.tables

local function value(v: any): any
	if type(v) ~= "table" then
		return v
	elseif v.n then
		return (string.unpack(">d", bytes(v.n)))
	elseif v.s then
		return v.s
	elseif v.id then
		return bytes(v.id)
	elseif v.b then
		return bytes(v.b)
	end
	return nil -- { nil = 1 }
end

local function cond(c: any): any
	local op = c[1]
	if op == "all" or op == "any" then
		local of = {}
		for i = 2, #c do
			table.insert(of, cond(c[i]))
		end
		return (w :: any)[op](table.unpack(of))
	elseif op == "none" then
		return w.none(cond(c[2]))
	elseif op == "is" or op == "exactly" or op == "over" or op == "under" then
		return (w :: any)[op](c[2], value(c[3]))
	elseif op == "between" then
		return w.between(c[2], value(c[3]), value(c[4]))
	elseif op == "among" then
		local vs = {}
		for _, v in c[3] do
			table.insert(vs, value(v))
		end
		return w.among(c[2], vs)
	elseif op == "begins" or op == "contains" then
		return (w :: any)[op](c[2], value(c[3]))
	elseif op == "has" then
		return w.has(c[2])
	elseif op == "matches" then
		return w.matches(c[2], c[3], c[4])
	elseif op == "list" then
		return w.in_list(c[2])
	elseif op == "ids" then
		local ids = {}
		for _, id in c[2] do
			table.insert(ids, bytes(id))
		end
		return w.ids(ids)
	elseif op == "refers" then
		return w.refers(c[2], c[3], cond(c[4]), tables[c[5]])
	elseif op == "referred" then
		return w.referred(c[2], c[3], cond(c[4]), value(c[5]), value(c[6]), tables[c[7]])
	end
	error(`no {op}`)
end

local KEY = string.rep("k", 32)
local function tag(scope: number, name: string): string
	return string.pack(">I4", scope) .. string.sub(sha256(KEY .. name), 1, 12)
end

local out = {}
for _, q in input.questions do
	local ok, line = pcall(function(): string
		local question = {
			scope = q.scope,
			table = tables[q.table],
			where = if q.where then cond(q.where) else nil,
			order = q.order,
			offset = q.offset,
			limit = q.limit,
			from_end = q.fromEnd,
			totals = q.totals,
		}
		local body, told = ask.write(question :: any, tag)
		local names = {}
		for _, t in told do
			table.insert(names, `{hex(t.name)}{if t.facet then "*" else ""}`)
		end
		return `{hex(body)} {table.concat(names, ",")}`
	end)
	table.insert(out, if ok then line else "!")
end
print(table.concat(out, "\n"))
