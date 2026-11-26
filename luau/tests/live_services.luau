--!strict
-- Streams and services between two devices, a calling b, which shares: lune run live_services <address> <token>
-- <address> <token> <folder> <python>. The folder is b's to share; python is a program both have, to run.

local datetime = require("@lune/datetime")
local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local task = require("@lune/task")

local codec = require("../zsp/codec")
local services = require("../zsp/services")
local transfer = require("../zsp/transfer")
local zsp = require("../zsp")

local CHUNK = transfer.CHUNK
local WINDOW = 262144

local function random(n: number): string
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, math.random(0, 255))
	end
	return buffer.tostring(b)
end

-- Files through lune's fs, which reads and writes files only whole: an open file is held in memory, and written back
-- when it is synced or closed. A host with files of its own reads and writes them in place instead.
local function lune_files(): transfer.Files
	local function identity(size: number, modified: number, created: number): string
		local w = codec.writer()
		codec.put_varint(w, size)
		codec.put_varint(w, modified)
		codec.put_varint(w, created)
		return codec.string(w)
	end
	return {
		open = function(path: string, mode: "read" | "write"): transfer.File?
			local data: buffer
			if fs.isFile(path) then
				local ok, contents = pcall(fs.readFile, path)
				if not ok then
					return nil
				end
				data = buffer.fromstring(contents)
			elseif mode == "read" or not pcall(fs.writeFile, path, "") then
				return nil
			else
				data = buffer.create(0)
			end
			local size = buffer.len(data)
			local dirty = false
			local function room(need: number)
				if buffer.len(data) < need then
					local grown = buffer.create(math.max(need, 2 * buffer.len(data)))
					buffer.copy(grown, 0, data, 0, size)
					data = grown
				end
			end
			local function sync(): boolean
				if not dirty then
					return true
				end
				dirty = false
				return (pcall(fs.writeFile, path, buffer.readstring(data, 0, size)))
			end
			return {
				read = function(at: number, n: number): string?
					if at >= size then
						return ""
					end
					return buffer.readstring(data, at, math.min(n, size - at))
				end,
				write = function(at: number, s: string): boolean
					if mode ~= "write" or at > size then
						return false
					end
					room(at + #s)
					buffer.writestring(data, at, s)
					size = math.max(size, at + #s)
					dirty = true
					return true
				end,
				size = function(): number
					return size
				end,
				truncate = function(n: number): boolean
					if mode ~= "write" then
						return false
					end
					room(n)
					if n > size then
						buffer.fill(data, size, 0, n - size)
					end
					size = n
					dirty = true
					return true
				end,
				sync = sync,
				close = function()
					sync()
				end,
			}
		end,
		stat = function(path: string): transfer.Stat?
			local ok, m = pcall(fs.metadata, path)
			if not ok or not m.exists then
				return nil
			end
			local modified = if m.modifiedAt then m.modifiedAt.unixTimestampMillis else 0
			local created = if m.createdAt then m.createdAt.unixTimestampMillis else 0
			local size = (m :: any).size or 0
			return {
				kind = if m.kind == "file" then "file" elseif m.kind == "dir" then "folder" else "other",
				size = size,
				modified = modified,
				identity = identity(size, modified, created),
			}
		end,
		rename = function(from: string, to: string): boolean
			return (pcall(fs.move, from, to, true))
		end,
		remove = function(path: string)
			pcall(fs.removeFile, path)
		end,
	}
end

local function host(address: string, token: string)
	return {
		credential = token,
		linger = 0.2,
		files = lune_files(),
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

local function eventually(what: string, f: () -> boolean, seconds: number?)
	for _ = 1, (seconds or 10) * 100 do
		if f() then
			return
		end
		task.wait(0.01)
	end
	print("never: " .. what, debug.info(2, "l"))
	process.exit(1)
end

local function check(ok: any, what: string)
	if not ok then
		print("wrong: " .. what, debug.info(2, "l"))
		process.exit(1)
	end
end

local args = process.args
local a = zsp.connect(host(args[1], args[2]))
local b = zsp.connect(host(args[3], args[4]))
local folder, python = args[5], args[6]
local sep = if process.os == "windows" then "\\" else "/"
local function at(...: string): string
	return table.concat({ folder, ... }, sep)
end
eventually("both connect", function()
	return a.ready and b.ready and a:me() ~= nil and b:me() ~= nil
end)
local device = (b:me() :: zsp.Device).id

-- ---------------------------------------------------------------- shares and services

fs.writeDir(at("docs"))
fs.writeDir(at("public"))
fs.writeDir(at("here"))
local shares = `shell 1\nfiles 1 docs write {at("docs")}\nfiles 1 public read {at("public")}\nfiles 2 other read {at("docs")}\n`
local ok, why = b:set_shares(shares)
check(ok, `shares set: {why}`)
local said = b:shares()
check(said == `shell 1 terminal commands\nfiles 1 docs write {at("docs")}\nfiles 1 public read {at("public")}\nfiles 2 other read {at("docs")}\n`, `shares said: {said}`)
local refused, malformed, reason = b:set_shares("files 1 nameless")
check(not refused and malformed == "malformed" and reason ~= "", "nonsense refused")
check(b:shares() == said, "and the shares as they were")

-- What a may use, once the roster that lets it has reached b.
local offered: { any } = {}
eventually("services offered", function()
	offered = a:services(device, 1) or {}
	return #offered == 3
end)
check(offered[1].kind == "shell" and offered[1].terminal and offered[1].commands, "a shell")
check(offered[2].kind == "files" and offered[2].name == "docs" and offered[2].read and offered[2].write, "docs to write")
check(offered[3].kind == "files" and offered[3].name == "public" and offered[3].read and not offered[3].write, "public to read")
local none = a:services(device, 2)
check(none and #none == 0, "nothing where a has no right to it")

-- ---------------------------------------------------------------- files

local function data_of(size: number, seed: number): buffer
	local data = buffer.create(size)
	for i = 0, size - 1 do
		buffer.writeu8(data, i, (i * 31 + i // 4093 + seed) % 256)
	end
	return data
end

local big = data_of(5 * CHUNK + CHUNK // 2, 1)
fs.writeFile(at("docs", "big.bin"), big)
local _, big_hash = transfer.hashes(big)

local entries = a:list(device, 1, "") :: { zsp.Entry }
check(#entries == 2, "the shares of files, as folders")
local names = {}
for _, e in entries do
	names[e.name] = e.kind
end
check(names.docs == "folder" and names.public == "folder", "docs and public")

-- Fetched whole, to a file.
local result = a:get(device, 1, "docs/big.bin", at("here", "big.bin")).wait()
check(result.status == "ok" and result.hash == big_hash and result.resumed == 0, `fetched: {result.status} {result.reason}`)
check(fs.readFile(at("here", "big.bin")) == buffer.tostring(big), "as it is there")
check(not fs.isFile(at("here", "big.bin.zsp-part")) and not fs.isFile(at("here", "big.bin.zsp-part.meta")), "its part let go")

-- Broken off, and taken up again where it was.
local t = a:get(device, 1, "docs/big.bin", at("here", "again.bin"))
t.on_progress = function(done: number)
	if done >= CHUNK + CHUNK // 2 then
		t.cancel()
	end
end
result = t.wait()
check(result.status == "failed" and fs.isFile(at("here", "again.bin.zsp-part")) and fs.isFile(at("here", "again.bin.zsp-part.meta")), "a part kept")
result = a:get(device, 1, "docs/big.bin", at("here", "again.bin")).wait()
check(result.status == "ok" and result.resumed >= CHUNK and result.hash == big_hash, `taken up: {result.status} from {result.resumed}`)
check(fs.readFile(at("here", "again.bin")) == buffer.tostring(big), "and whole")

-- Broken off, and the file there changed since: begun again.
t = a:get(device, 1, "docs/big.bin", at("here", "changed.bin"))
t.on_progress = function(done: number)
	if done >= 2 * CHUNK + 1 then
		t.cancel()
	end
end
t.wait()
local other = data_of(buffer.len(big), 2)
fs.writeFile(at("docs", "big.bin"), other)
result = a:get(device, 1, "docs/big.bin", at("here", "changed.bin")).wait()
check(result.status == "ok" and result.resumed == 0, `begun again: {result.status} from {result.resumed}`)
check(fs.readFile(at("here", "changed.bin")) == buffer.tostring(other), "the file it is now")
fs.writeFile(at("docs", "big.bin"), big)

-- Into memory, broken off, and taken up from what it gave.
t = a:get(device, 1, "docs/big.bin")
t.on_progress = function(done: number)
	if done >= 2 * CHUNK + CHUNK // 2 then
		t.cancel()
	end
end
result = t.wait()
local resume = result.resume :: transfer.Resume
check(result.status == "failed" and resume and #resume.hashes >= 2, "what came, to take up from")
result = a:get(device, 1, "docs/big.bin", resume).wait()
check(result.status == "ok" and result.resumed >= 2 * CHUNK and buffer.tostring(result.data :: buffer) == buffer.tostring(big), `into memory: {result.status}`)

-- Sent from a file, the folders on the way made; then from memory, broken off and taken up by b.
result = a:put(device, 1, at("here", "big.bin"), "docs/up/sent.bin").wait()
check(result.status == "ok" and result.hash == big_hash, `sent: {result.status} {result.reason}`)
check(fs.readFile(at("docs", "up", "sent.bin")) == buffer.tostring(big), "there as it is here")
local more = data_of(9 * CHUNK, 3)
local _, more_hash = transfer.hashes(more)
t = a:put(device, 1, more, "docs/up/memory.bin")
t.on_progress = function(done: number)
	if done >= 8 * CHUNK then
		t.cancel()
	end
end
result = t.wait()
check(result.status == "failed" and not fs.isFile(at("docs", "up", "memory.bin")), "sending broken off")
task.wait(0.5) -- b lets the call go, and keeps what came
result = a:put(device, 1, more, "docs/up/memory.bin").wait()
check(result.status == "ok" and result.resumed >= CHUNK and result.hash == more_hash, `sending taken up: {result.status} from {result.resumed}`)
check(fs.readFile(at("docs", "up", "memory.bin")) == buffer.tostring(more), "and whole there")
entries = a:list(device, 1, "docs/up") :: { zsp.Entry }
check(#entries == 2, `the parts are not listed: {#entries}`)

-- What is refused, and why.
local function status_of(tr: zsp.Transfer): string
	return tr.wait().status
end
check(status_of(a:put(device, 1, more, "docs/up/memory.bin")) == "exists", "not replaced unless asked")
check(status_of(a:put(device, 1, more, "docs/up/memory.bin", { replace = true })) == "ok", "replaced when asked")
check(status_of(a:put(device, 1, more, "public/x.bin")) == "denied", "a share to read only")
check(status_of(a:get(device, 1, "docs/nothing.bin")) == "not found", "nothing there")
check(status_of(a:get(device, 1, "docs/../docs/big.bin")) == "denied", "out of the share")
check(status_of(a:get(device, 1, "nowhere/big.bin")) == "not offered", "a share there is not")
check(status_of(a:get(device, 2, "other/big.bin")) == "denied", "a share a has no right to")
local _, listed = a:list(device, 1, "docs/nothing")
check(listed == "not found", "no such folder")

-- A reader that never reads holds no more than its window, however much there is to send.
local held = 0
local call = a:call(device, 1, "zsp.get", services.get("docs/big.bin", 0, ""))
call.on_data = function(data: string)
	held += #data
	return false
end
task.wait(0.5)
check(held > 0 and held <= WINDOW, `held {held}`)
call.consumed(held)
eventually("more, once it is read", function()
	return held > WINDOW
end)
call.cancel()

-- No port is offered here.
local closed: string? = nil
local stream = a:connect(device, 1, 22)
stream.on_close = function(w: string?)
	closed = w or "fine"
end
eventually("a port not offered", function()
	return closed ~= nil
end)
-- Denied where nothing decides what is offered; not offered where offers do (zspd's, SPEC §17), as here.
check(closed == "not offered" or closed == "denied", `connect: {closed}`)

-- ---------------------------------------------------------------- commands and terminals

local code, signal, out, err, failed, because = a:run(device, 1, {
	python,
	"-c",
	"import sys; d = sys.stdin.read(); sys.stdout.write(d.upper()); sys.stderr.write('e'); sys.exit(3)",
}, { input = "abc" })
check(code == 3 and signal == 0 and out == "ABC" and err == "e", `run: {code} {signal} {out} {err} {failed} {because}`)
code, _, out = a:run(device, 1, { python, "-c", "import os; print(os.environ.get('ZSP_TEST'), os.path.realpath(os.getcwd()))" }, {
	env = { "ZSP_TEST=yes" },
	folder = at("docs"),
})
check(code == 0 and string.find(out, "yes", 1, true) and string.find(out, "docs", 1, true), `env and folder: {out}`)
code, _, _, _, failed = a:run(device, 1, { "zsp-no-such-program" })
check(code == nil and (failed == "not found" or failed == "failed"), `no such program: {failed}`)

-- Killed, with all it started; its exit still told.
local p = a:exec(device, 1, { python, "-c", "import time; print('up', flush=True); time.sleep(60)" })
local up, exited: { number }? = false, nil
p.on_output = function(_: string)
	up = true
end
p.on_exit = function(c: number, s: number)
	exited = { c, s }
end
eventually("it starts", function()
	return up
end)
p.kill()
eventually("killed", function()
	return exited ~= nil
end)
local e = exited :: { number }
check(e[2] == 9 or e[1] ~= 0, `killed: {e[1]} {e[2]}`)

-- Output no one reads stops at the window, and the process with it.
local written = 8 * CHUNK
p = a:exec(device, 1, { python, "-c", `import sys; sys.stdout.buffer.write(b'x' * {written}); sys.stdout.flush()` })
held = 0
local total = 0
exited = nil
p.on_output = function(data: string)
	held += #data
	total += #data
	return false
end
p.on_exit = function(c: number, s: number)
	exited = { c, s }
end
task.wait(1)
check(held > 0 and held <= WINDOW and not exited, `output held {held}`)
p.on_output = function(data: string)
	total += #data
end
p.consumed(held)
eventually("all of it, once it is read", function()
	return exited ~= nil
end)
check(total == written and (exited :: { number })[1] == 0, `output {total}`)

-- A terminal: what is typed runs, its size is as said, and it ends as its shell does.
local windows = process.os == "windows"
local term = a:terminal(device, 1, { rows = 24, columns = 80, env = { "ZSP_MARK=forty-two" } })
local screen = {}
local ended: { number }? = nil
term.on_output = function(data: string)
	table.insert(screen, data)
end
term.on_exit = function(c: number, s: number)
	ended = { c, s }
end
-- What it says is not what was typed, so that it is seen to have run; on Windows, as cmd and as PowerShell would have it.
term.write(if windows then "echo %ZSP_MARK%-%ZSP_MARK%\recho \"${env:ZSP_MARK}-${env:ZSP_MARK}\"\r" else "echo $ZSP_MARK-$ZSP_MARK\r")
eventually("typed, and run", function()
	return string.find(table.concat(screen), "forty-two-forty-two", 1, true) ~= nil
end)
if not windows then
	term.resize(50, 132)
	term.write("stty size\r")
	eventually("resized", function()
		return string.find(table.concat(screen), "50 132", 1, true) ~= nil
	end)
end
term.write("exit 3\r")
eventually("the shell ends", function()
	return ended ~= nil
end)
check((ended :: { number })[1] == 3, `terminal exit {(ended :: { number })[1]}`)

print("ok")
process.exit(0)
