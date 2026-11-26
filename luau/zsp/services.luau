--!strict
-- What a device's host says in the methods it serves itself (SPEC §16), byte for byte: the first messages of
-- zsp.tcp, zsp.exec, zsp.pty, zsp.list, zsp.get and zsp.put, the status that begins every answer, and what a process,
-- a listing and the services say after it.

local codec = require("./codec")

local services = {}

-- Why a host would not, by its status's number.
services.STATUS = table.freeze({
	"denied",
	"not offered",
	"refused",
	"unreachable",
	"timed out",
	"not found",
	"failed",
	"changed",
	"exists",
	"malformed",
})
local CODES: { [string]: number } = {}
for code, name in services.STATUS do
	CODES[name] = code
end

-- POSIX's numbers, as a process's signals are said.
services.SIGNALS = table.freeze({
	hangup = 1,
	interrupt = 2,
	quit = 3,
	kill = 9,
	terminate = 15,
	continue = 18,
	stop = 19,
} :: { [string]: number })

export type Service =
	{ kind: "shell", terminal: boolean, commands: boolean }
	| { kind: "files", name: string, read: boolean, write: boolean }
	| { kind: "tcp", port: number, host: string, name: string }

export type Entry = {
	name: string,
	kind: "file" | "folder" | "other",
	size: number,
	modified: number, -- ms since 1970
}

local function u16(w: codec.Writer, v: number)
	codec.put_u8(w, v // 256 % 256)
	codec.put_u8(w, v % 256)
end

local function strings(w: codec.Writer, list: { string })
	codec.put_varint(w, #list)
	for _, s in list do
		codec.put_bytes(w, s)
	end
end

-- ---------------------------------------------------------------- first messages

function services.tcp(port: number, host: string?): string
	local w = codec.writer()
	u16(w, port)
	codec.put(w, host or "")
	return codec.string(w)
end

function services.exec(argv: { string }, env: { string }?, folder: string?): string
	local w = codec.writer()
	codec.put_u8(w, 0) -- flags, none yet
	strings(w, argv)
	strings(w, env or {})
	codec.put_bytes(w, folder or "")
	return codec.string(w)
end

function services.pty(rows: number, columns: number, term: string, env: { string }?, folder: string?): string
	local w = codec.writer()
	u16(w, rows)
	u16(w, columns)
	codec.put_bytes(w, term)
	strings(w, {}) -- no arguments: the user's shell
	strings(w, env or {})
	codec.put_bytes(w, folder or "")
	return codec.string(w)
end

function services.list(path: string): string
	local w = codec.writer()
	codec.put_bytes(w, path)
	return codec.string(w)
end

function services.get(path: string, offset: number, identity: string): string
	local w = codec.writer()
	codec.put_bytes(w, path)
	codec.put_varint(w, offset)
	codec.put_bytes(w, identity)
	return codec.string(w)
end

function services.put(path: string, size: number, modified: number, identity: string, replace: boolean, folders: boolean): string
	local w = codec.writer()
	codec.put_bytes(w, path)
	codec.put_varint(w, size)
	codec.put_varint(w, modified)
	codec.put_bytes(w, identity)
	codec.put_u8(w, (if replace then 1 else 0) + (if folders then 2 else 0))
	return codec.string(w)
end

-- ---------------------------------------------------------------- answers

-- The status that begins an answer: "ok" and what follows it in the same message, or why not and the reason.
function services.status(message: string): (string, string)
	local code = string.byte(message) or 10
	if code == 0 then
		return "ok", string.sub(message, 2)
	end
	return services.STATUS[code] or "failed", string.sub(message, 2)
end

function services.status_of(why: string, rest: string?): string
	return string.char(if why == "ok" then 0 else CODES[why] or CODES.failed) .. (rest or "")
end

function services.entry(entry: Entry): string
	local w = codec.writer()
	codec.put_u8(w, if entry.kind == "file" then 1 elseif entry.kind == "folder" then 2 else 3)
	codec.put_bytes(w, entry.name)
	codec.put_varint(w, entry.size)
	codec.put_varint(w, entry.modified)
	return codec.string(w)
end

-- The entries in what a listing said after its status; nil if it makes no sense.
function services.entries(said: string): { Entry }?
	local r = codec.reader(said)
	local out: { Entry } = {}
	local ok = pcall(function()
		while r.pos < r.len do
			local kind = codec.u8(r)
			local name = codec.bytes(r)
			local size = codec.varint(r)
			local entry: Entry = {
				name = name,
				kind = if kind == 1 then "file" elseif kind == 2 then "folder" else "other",
				size = size,
				modified = codec.varint(r),
			}
			table.insert(out, entry)
		end
	end)
	return if ok then out else nil
end

function services.listed(list: { Service }): string
	local w = codec.writer()
	for _, s in list do
		if s.kind == "shell" then
			codec.put_u8(w, 1)
			codec.put_u8(w, (if s.terminal then 1 else 0) + (if s.commands then 2 else 0))
		elseif s.kind == "files" then
			codec.put_u8(w, 2)
			codec.put_u8(w, (if s.read then 1 else 0) + (if s.write then 2 else 0))
			codec.put_bytes(w, s.name)
		else
			codec.put_u8(w, 3)
			u16(w, s.port)
			codec.put_bytes(w, s.host)
			codec.put_bytes(w, s.name)
		end
	end
	return codec.string(w)
end

-- The services in what zsp.services said after its status; nil if it makes no sense.
function services.services(said: string): { Service }?
	local r = codec.reader(said)
	local out: { Service } = {}
	local ok = pcall(function()
		while r.pos < r.len do
			local kind = codec.u8(r)
			local s: Service
			if kind == 1 then
				local flags = codec.u8(r)
				s = { kind = "shell", terminal = bit32.btest(flags, 1), commands = bit32.btest(flags, 2) }
			elseif kind == 2 then
				local flags = codec.u8(r)
				s = { kind = "files", name = codec.bytes(r), read = bit32.btest(flags, 1), write = bit32.btest(flags, 2) }
			elseif kind == 3 then
				local port = codec.u8(r) * 256 + codec.u8(r)
				local host = codec.bytes(r)
				s = { kind = "tcp", port = port, host = host, name = codec.bytes(r) }
			else
				error("no such service")
			end
			table.insert(out, s)
		end
	end)
	return if ok then out else nil
end

export type Got = { size: number, modified: number, identity: string, from: number }

-- What zsp.get says after its status: which file it is, and where it takes up.
function services.got(said: string): Got?
	local r = codec.reader(said)
	local ok, got = pcall(function(): Got
		local size = codec.varint(r)
		local modified = codec.varint(r)
		local identity = codec.bytes(r)
		return { size = size, modified = modified, identity = identity, from = codec.varint(r) }
	end)
	return if ok and r.pos == r.len then got else nil
end

function services.got_of(got: Got): string
	local w = codec.writer()
	codec.put_varint(w, got.size)
	codec.put_varint(w, got.modified)
	codec.put_bytes(w, got.identity)
	codec.put_varint(w, got.from)
	return codec.string(w)
end

-- A whole number alone, as zsp.put says where it takes up after its status; nil if it makes no sense.
function services.number(said: string): number?
	local r = codec.reader(said)
	local ok, n = pcall(codec.varint, r)
	return if ok and r.pos == r.len then n else nil
end

function services.number_of(n: number): string
	local w = codec.writer()
	codec.put_varint(w, n)
	return codec.string(w)
end

-- ---------------------------------------------------------------- a process

function services.input(data: string): string
	return "\0" .. data
end

function services.signal(signal: number): string
	return "\1" .. string.char(signal)
end

function services.resize(rows: number, columns: number): string
	local w = codec.writer()
	codec.put_u8(w, 2)
	u16(w, rows)
	u16(w, columns)
	return codec.string(w)
end

function services.output(data: string): string
	return "\1" .. data
end

function services.errors(data: string): string
	return "\2" .. data
end

function services.exit(code: number, signal: number): string
	local w = codec.writer()
	codec.put_u8(w, 3)
	codec.put_varint(w, code)
	codec.put_u8(w, signal)
	return codec.string(w)
end

-- How a process ended, from its last message's payload (after the 3): its code and the signal that ended it.
function services.exited(said: string): (number?, number)
	local r = codec.reader(said)
	local ok, code, signal = pcall(function(): (number, number)
		return codec.varint(r), codec.u8(r)
	end)
	if not ok then
		return nil, 0
	end
	return code, signal
end

-- ---------------------------------------------------------------- a file

-- Bytes of a file, the hash of the chunk they end, and the end of it all.
function services.bytes(data: string): string
	return "\1" .. data
end

function services.chunk(hash: string): string
	return "\2" .. hash
end

function services.done(why: string, hash: string?): string
	return "\3" .. services.status_of(why, hash)
end

return table.freeze(services)
