--!strict
-- The caller's end of zsp.get and zsp.put (SPEC §16): a file fetched from a device, or sent to one, resumed after a
-- break from where it left off, and checked chunk by chunk and whole, as host/transfer.odin does it.
--
-- Where the host lends files, a file being fetched is kept, until it is whole, beside where it is going, as
-- `<name>.zsp-part`, with what is known of it in `<name>.zsp-part.meta`: which file it is there, and the hashes of the
-- chunks taken. A fetch begun again takes up where the last stopped, as long as the file there is the one it was; a
-- send is taken up by the other end, which keeps what it was sent in the same way.
--
-- Where it lends none, a fetch gives the file as a buffer, and if it breaks off, what it had: given back, that is
-- taken up from as a part on disk would be. A send takes a buffer, and is known to the other end by its hash, so
-- that the same bytes sent again are taken up where they broke off.

local codec = require("./codec")
local services = require("./services")
local sha256 = require("./sha256")

local CHUNK = 1048576
local READ = 65536 -- at most, in one message
local PART = ".zsp-part"
local SYNC_EVERY = 16 * CHUNK -- a part is made durable this often, so that a crash loses no more

-- A file the host has opened. Offsets and sizes are in bytes.
export type File = {
	read: (at: number, n: number) -> string?, -- up to n bytes from `at`, fewer only at its end; nil if it cannot be read
	write: (at: number, data: string) -> boolean, -- at `at`, which is at most its size
	size: () -> number,
	truncate: (size: number) -> boolean,
	sync: () -> boolean, -- what was written is on the disk
	close: () -> (),
}
export type Stat = {
	kind: "file" | "folder" | "other",
	size: number,
	modified: number, -- ms since 1970
	identity: string, -- what tells it from another file, though of the same size and time: at most 64 bytes
}
-- What a host lends of its files, for get and put to go through. Paths are the host's own.
export type Files = {
	open: (path: string, mode: "read" | "write") -> File?, -- "write" reads too, and makes it if it is not there
	stat: (path: string) -> Stat?, -- nil if there is nothing there
	rename: (from: string, to: string) -> boolean, -- replacing whatever is at `to`
	remove: (path: string) -> (),
	touch: ((path: string, modified: number) -> ())?, -- sets when it was last written, where the host can
}

-- What a fetch into memory had when it broke off: given back to get, it is taken up from.
export type Resume = {
	read identity: string, -- the file's, as its holder gave it
	read size: number,
	read modified: number,
	read data: buffer,
	read hashes: { string }, -- of the whole chunks at its start that came and were checked
}

export type Result = {
	read status: string, -- "ok", or what went wrong there or here: a status (services.STATUS) or a call's fault
	read reason: string, -- in words, if any were given
	read bytes: number, -- carried this time
	read resumed: number, -- where it took up from
	read size: number,
	read modified: number, -- ms since 1970
	read hash: string?, -- of the whole file, once it is
	read data: buffer?, -- a fetch into memory: the file, once it is whole
	read resume: Resume?, -- a fetch into memory that broke off: what to take up from
}

export type Transfer = {
	cancel: () -> (), -- what came of a fetch is kept, to take up from
	wait: () -> Result, -- yields the coroutine it is called from until it is done
	on_done: ((Result) -> ())?,
	on_progress: ((done: number, size: number) -> ())?,
	result: Result?, -- once it is done
}

-- What a transfer needs of its call.
export type Call = {
	send: (data: string) -> (),
	finish: () -> (),
	cancel: () -> (),
	room: () -> number,
	on_data: ((data: string) -> ...boolean)?,
	on_end: (() -> ())?,
	on_fault: ((fault: string) -> ())?,
	on_room: (() -> ())?,
}

export type Put_Options = {
	replace: boolean?, -- what is there already; else it is refused as "exists"
	folders: boolean?, -- made on the way to it, as needed: so unless false
	modified: number?, -- of a buffer, in ms; now, unless said
	identity: string?, -- of a buffer: what tells it from another; its hash, unless said
}

-- Hashes chunk by chunk, and the file by its chunks' hashes.
type Hashing = { chunk: sha256.Stream, filled: number, file: sha256.Stream }

local function hashing(): Hashing
	return { chunk = sha256.stream(), filled = 0, file = sha256.stream() }
end

-- Ends the chunk under way; its hash goes into the file's.
local function chunk_end(h: Hashing): string
	local hash = h.chunk.final()
	h.file.update(hash)
	h.chunk = sha256.stream()
	h.filled = 0
	return hash
end

local transfer = {}

transfer.CHUNK = CHUNK
transfer.PART = PART

-- The hashes of a file's chunks and of the file, fed to the hashing `piece` bytes at a time.
function transfer.hashes(data: buffer, piece: number?): ({ string }, string)
	local h = hashing()
	local chunks: { string } = {}
	local size = buffer.len(data)
	local step = piece or READ
	local at = 0
	while at < size do
		local n = math.min(step, size - at, CHUNK - h.filled)
		h.chunk.update(buffer.readstring(data, at, n))
		h.filled += n
		at += n
		if h.filled == CHUNK or at == size then
			table.insert(chunks, chunk_end(h))
		end
	end
	return chunks, h.file.final()
end

-- How many of a part's first chunks are what their recorded hashes say, read again: what was checked as it came may
-- have been changed since, and nothing is taken up from that it does not still prove.
local function good_chunks(f: File, hashes: string): number
	for i = 0, #hashes // 32 - 1 do
		local bytes = f.read(i * CHUNK, CHUNK)
		if not bytes or #bytes ~= CHUNK or sha256(bytes) ~= string.sub(hashes, i * 32 + 1, i * 32 + 32) then
			return i
		end
	end
	return #hashes // 32
end

type State = {
	put: boolean,
	files: Files?,
	path: string?, -- here: where a fetch goes, or what is sent
	f: File?, -- the part being fetched, or the file being sent
	meta: File?,
	meta_at: number, -- where the next chunk's hash goes in it
	synced: number,
	data: buffer?, -- in memory: the file
	hashes: { string }, -- in memory: of the chunks, whole and checked as they came, or all of them, to send
	resume: Resume?, -- given, to take up from
	identity: string,
	size: number,
	modified: number,
	at: number,
	from: number,
	sent_to: number, -- a send: the end of the last chunk whose hash was sent
	said: string, -- a send: what this end said of the file at its end
	hashing: Hashing,
	pending: string, -- the hash of the chunk just ended, awaiting the sender's
	awaiting: boolean,
	begun: boolean, -- the status came
	sent_all: boolean,
	bytes: number,
	hash: string?,
	finished: boolean,
	over: boolean, -- the call is
	call: Call?,
	public: Transfer,
	waiting: { thread },
	defer: (() -> ()) -> (),
}

local finish: (self: State, status: string, reason: string) -> ()
local fail: (self: State, status: string) -> ()
local progress: (self: State) -> ()
local on_data: (self: State, message: string) -> ()
local take: (self: State, message: string) -> ()
local get_begin: (self: State, said: string) -> ()
local part_open: (self: State, from: number) -> boolean
local memory_open: (self: State, from: number) -> boolean
local commit: (self: State) -> ()
local put_begin: (self: State, said: string) -> ()
local pump: (self: State) -> ()

local function new_state(put: boolean, files: Files?, defer: (() -> ()) -> ()): State
	local self: State
	self = {
		put = put,
		files = files,
		path = nil :: string?,
		f = nil :: File?,
		meta = nil :: File?,
		meta_at = 0,
		synced = 0,
		data = nil :: buffer?,
		hashes = {},
		resume = nil :: Resume?,
		identity = "",
		size = 0,
		modified = 0,
		at = 0,
		from = 0,
		sent_to = 0,
		said = "ok",
		hashing = hashing(),
		pending = "",
		awaiting = false,
		begun = false,
		sent_all = false,
		bytes = 0,
		hash = nil :: string?,
		finished = false,
		over = false,
		call = nil :: Call?,
		public = (nil :: any) :: Transfer,
		waiting = {},
		defer = defer,
	}
	self.public = {
		cancel = function()
			if not self.finished then
				local call = self.call
				self.over = true
				if call then
					call.cancel()
				end
				finish(self, "failed", "cancelled")
			end
		end,
		wait = function(): Result
			local result = self.public.result
			if result then
				return result
			end
			table.insert(self.waiting, coroutine.running())
			return coroutine.yield()
		end,
		on_done = nil,
		on_progress = nil,
		result = nil,
	}
	return self
end

function finish(self: State, status: string, reason: string)
	if self.finished then
		return
	end
	self.finished = true
	local f, meta = self.f, self.meta
	self.f, self.meta = nil, nil
	if f then
		if not self.put then
			f.sync() -- what came is kept, to take up from
		end
		f.close()
	end
	if meta then
		meta.sync()
		meta.close()
	end
	local resume: Resume? = nil
	if not self.put and not self.files and status ~= "ok" then
		if not self.data then
			resume = self.resume -- as it was: nothing came to change it
		elseif status ~= "changed" and status ~= "malformed" then
			resume = table.freeze({
				identity = self.identity,
				size = self.size,
				modified = self.modified,
				data = self.data :: buffer,
				hashes = table.freeze(table.clone(self.hashes)),
			})
		end
	end
	local result: Result = table.freeze({
		status = status,
		reason = reason,
		bytes = self.bytes,
		resumed = self.from,
		size = self.size,
		modified = self.modified,
		hash = if status == "ok" then self.hash else nil,
		data = if status == "ok" and not self.put and not self.files then self.data else nil,
		resume = resume,
	})
	self.public.result = result
	-- The call goes with it: ended as it should, or given up on, so that nothing more is sent for nothing.
	local call = self.call
	if call and not self.over then
		if status == "ok" then
			call.finish()
		else
			self.over = true
			call.cancel()
		end
	end
	self.defer(function()
		local waiting = self.waiting
		self.waiting = {}
		for _, thread in waiting do
			coroutine.resume(thread, result)
		end
		if self.public.on_done then
			self.public.on_done(result)
		end
	end)
end

-- Fails on what came: what cannot be trusted is not taken up from.
function fail(self: State, status: string)
	if status == "changed" or status == "malformed" then
		if self.meta then
			self.meta.truncate(0)
			self.meta_at = 0
		end
	end
	finish(self, status, "")
end

function progress(self: State)
	if self.public.on_progress then
		self.public.on_progress(self.at, self.size)
	end
end

-- ---------------------------------------------------------------- the call

local function attach(self: State, call: Call)
	self.call = call
	call.on_data = function(message: string)
		on_data(self, message)
	end
	call.on_room = function()
		pump(self)
	end
	call.on_end = function()
		if not self.finished then
			finish(self, "failed", "it ended early")
		end
	end
	call.on_fault = function(fault: string)
		self.over = true
		if not self.finished then
			finish(self, if fault == "unreachable" or fault == "denied" then fault else "failed", fault)
		end
	end
end

function on_data(self: State, message: string)
	if self.finished or #message == 0 then
		return
	end
	if not self.begun then
		self.begun = true
		local status, rest = services.status(message)
		if status ~= "ok" then
			finish(self, status, rest)
			return
		end
		if self.put then
			put_begin(self, rest)
		else
			get_begin(self, rest)
		end
		return
	end
	if self.put then
		-- The verdict, once all is sent: an ok before then, or after this end said the file changed, is no success.
		local status = services.status(message)
		if status == "ok" and not self.sent_all then
			status = "malformed"
		elseif status == "ok" and self.said ~= "ok" then
			status = self.said
		end
		finish(self, status, "")
		return
	end
	local kind = string.byte(message)
	if kind == 1 then
		take(self, message)
	elseif kind == 2 then
		local hash = string.sub(message, 2)
		if not self.awaiting or hash ~= self.pending then
			fail(self, "changed")
			return
		end
		self.awaiting = false
		local meta = self.meta
		if meta then
			if not meta.write(self.meta_at, hash) then
				fail(self, "failed")
				return
			end
			self.meta_at += 32
			if self.at - self.synced >= SYNC_EVERY then
				(self.f :: File).sync()
				meta.sync()
				self.synced = self.at
			end
		else
			table.insert(self.hashes, hash)
		end
	elseif kind == 3 then
		local status, rest = services.status(string.sub(message, 2))
		if status ~= "ok" then
			fail(self, if #message > 1 then status else "malformed")
			return
		end
		if self.awaiting or self.at ~= self.size then
			fail(self, "malformed")
			return
		end
		self.hash = self.hashing.file.final()
		-- From the start, the file's hash comes and must agree; taken up later, every chunk's has, kept or come.
		if (self.from == 0 and #rest ~= 32) or (#rest == 32 and rest ~= self.hash) then
			fail(self, "changed")
			return
		end
		commit(self)
	else
		fail(self, "malformed")
	end
end

-- ---------------------------------------------------------------- fetching

-- Bytes of the file: written where they go, each chunk's hash kept to compare with the sender's.
function take(self: State, message: string)
	local size = #message - 1
	if self.awaiting or self.at + size > self.size then
		fail(self, "malformed")
		return
	end
	local h = self.hashing
	local at = 2
	while at <= #message do
		local taken = math.min(#message - at + 1, CHUNK - h.filled)
		local piece = string.sub(message, at, at + taken - 1)
		h.chunk.update(piece)
		h.filled += taken
		if self.f then
			if not self.f.write(self.at, piece) then
				fail(self, "failed")
				return
			end
		else
			buffer.writestring(self.data :: buffer, self.at, piece)
		end
		self.at += taken
		self.bytes += taken
		at += taken
		if h.filled == CHUNK or self.at == self.size then
			self.pending = chunk_end(h)
			self.awaiting = true
			if at <= #message then
				fail(self, "malformed") -- a chunk's hash comes between its bytes and the next chunk's
				return
			end
		end
	end
	progress(self)
end

function get_begin(self: State, said: string)
	local got = services.got(said)
	if not got or got.from > got.size or got.from % CHUNK ~= 0 or (got.from ~= 0 and got.from ~= self.from) then
		finish(self, "malformed", "")
		return
	end
	self.size, self.modified, self.identity = got.size, got.modified, got.identity
	local ok = if self.files then part_open(self, got.from) else memory_open(self, got.from)
	if not ok then
		finish(self, "failed", "cannot write the file")
		return
	end
	self.from, self.at, self.synced = got.from, got.from, got.from
	progress(self)
end

-- The part, taken up where it was if it is the same file there, or begun afresh.
function part_open(self: State, from: number): boolean
	local files = self.files :: Files
	local part = (self.path :: string) .. PART
	local f = files.open(part, "write")
	if not f then
		return false
	end
	self.f = f
	local meta = files.open(part .. ".meta", "write")
	if not meta then
		return false
	end
	self.meta = meta
	if from == 0 then
		local w = codec.writer()
		codec.put_bytes(w, self.identity)
		local header = codec.string(w)
		if not (f.truncate(0) and meta.truncate(0) and meta.write(0, header)) then
			return false
		end
		self.meta_at = #header
		return true
	end
	local kept = meta.read(0, meta.size()) or ""
	local r = codec.reader(kept)
	local fine = pcall(codec.bytes, r)
	local chunks = from // CHUNK
	if not fine or r.pos + chunks * 32 > r.len then
		return false
	end
	for i = 0, chunks - 1 do
		self.hashing.file.update(string.sub(kept, r.pos + i * 32 + 1, r.pos + i * 32 + 32))
	end
	self.meta_at = r.pos + chunks * 32
	return meta.truncate(self.meta_at) and f.truncate(from)
end

function memory_open(self: State, from: number): boolean
	local resume = self.resume
	if from > 0 and resume then
		if buffer.len(resume.data) ~= self.size then
			return false
		end
		self.data = resume.data
		for i = 1, from // CHUNK do
			local hash = resume.hashes[i]
			table.insert(self.hashes, hash)
			self.hashing.file.update(hash)
		end
		return true
	end
	local ok, data = pcall(buffer.create, self.size)
	if not ok then
		return false
	end
	self.data = data
	return true
end

-- Whole and checked: made durable, put in place with the sender's time, its record of progress let go.
function commit(self: State)
	local files = self.files
	if not files then
		finish(self, "ok", "")
		return
	end
	local path = self.path :: string
	local part = path .. PART
	local f, meta = self.f :: File, self.meta :: File
	self.f, self.meta = nil, nil
	f.sync()
	f.close()
	meta.close()
	if files.touch then
		files.touch(part, self.modified)
	end
	if not files.rename(part, path) then
		finish(self, "failed", "cannot put the file in place")
		return
	end
	files.remove(part .. ".meta")
	finish(self, "ok", "")
end

-- ---------------------------------------------------------------- sending

function put_begin(self: State, said: string)
	local from = services.number(said)
	if not from or from % CHUNK ~= 0 or from > self.size then
		finish(self, "malformed", "")
		return
	end
	-- What the other end has, it has checked; the hashes of it, here, are had again, for the file's.
	self.from, self.at, self.sent_to = from, from, from
	if self.f then
		local at = 0
		local h = self.hashing
		while at < from do
			local n = math.min(READ, from - at, CHUNK - h.filled)
			local bytes = (self.f :: File).read(at, n)
			if not bytes or #bytes ~= n then
				finish(self, "failed", "cannot read the file")
				return
			end
			h.chunk.update(bytes)
			h.filled += n
			at += n
			if h.filled == CHUNK then
				chunk_end(h)
			end
		end
	end
	progress(self)
	pump(self)
end

-- What follows a file's last bytes: the last chunk's hash, then the end and the file's hash.
local TRAIL = (1 + 32) + (2 + 32)

-- Sends as much of the file as credit allows, each chunk followed by its hash; then the end.
function pump(self: State)
	if not self.put or not self.begun or self.finished or self.sent_all then
		return
	end
	local call = self.call :: Call
	while true do
		-- Credit for what follows the last bytes is kept back from them, so that it can always go when they have.
		local room = call.room()
		if room < (if self.at < self.size then 1 + 1 + TRAIL else TRAIL) then
			return -- on_room says when to go on
		end
		if self.at < self.size then
			local n = math.min(room - 1 - TRAIL, READ, self.size - self.at, CHUNK - self.at % CHUNK)
			local bytes: string?
			if self.f then
				bytes = (self.f :: File).read(self.at, n)
			else
				bytes = buffer.readstring(self.data :: buffer, self.at, n)
			end
			if not bytes or #bytes == 0 then
				fail(self, "changed") -- it shrank, or went
				return
			end
			call.send(services.bytes(bytes))
			if self.f then
				self.hashing.chunk.update(bytes)
			end
			self.at += #bytes
			self.bytes += #bytes
			progress(self)
			if self.finished then
				return
			end
			if self.at % CHUNK ~= 0 and self.at < self.size then
				continue
			end
		end
		if self.at > self.sent_to then
			local hash = if self.f then chunk_end(self.hashing) else self.hashes[(self.at - 1) // CHUNK + 1]
			call.send(services.chunk(hash))
			self.sent_to = self.at
		end
		if self.at == self.size then
			-- Still the file it was, all the while?
			local status = "ok"
			if self.files then
				local now = (self.files :: Files).stat(self.path :: string)
				if not now or now.identity ~= self.identity then
					status = "changed"
				end
			end
			self.hash = if self.f then self.hashing.file.final() else self.hash
			self.said = status
			call.send(services.done(status, self.hash))
			self.sent_all = true
			call.finish()
			return
		end
	end
end

-- ---------------------------------------------------------------- beginning

-- A fetch of `remote` to the path `to` (given files), or into memory, taking up from `to` if it is what a fetch into
-- memory broke off with. `open` makes the call, given its first message.
function transfer.get(open: (first: string) -> Call?, defer: (() -> ()) -> (), files: Files?, remote: string, to: (string | Resume)?): Transfer
	local self = new_state(false, files, defer)
	local known: string? = nil
	if type(to) == "string" then
		if not files then
			finish(self, "failed", "this host lends no files")
			return self.public
		end
		self.path = to
		local part = to .. PART
		local mf = files.open(part .. ".meta", "read")
		if mf then
			local kept = mf.read(0, mf.size()) or ""
			mf.close()
			local r = codec.reader(kept)
			local fine, identity = pcall(codec.bytes, r)
			local stat = files.stat(part)
			if fine and stat then
				local chunks = (r.len - r.pos) // 32
				if chunks * CHUNK <= stat.size then
					local pf = files.open(part, "read")
					if pf then
						chunks = good_chunks(pf, string.sub(kept, r.pos + 1, r.pos + chunks * 32))
						pf.close()
						known = identity
						self.from = chunks * CHUNK
					end
				end
			end
		end
	else
		self.files = nil -- into memory
		if to then
			self.resume = to
			known = to.identity
			self.from = #to.hashes * CHUNK
		end
	end
	local call = open(services.get(remote, if known then self.from else 0, known or ""))
	if not call then
		finish(self, "unreachable", "")
		return self.public
	end
	attach(self, call)
	return self.public
end

-- A send of the file at the path `from` (given files), or of a buffer, to `remote`. `now` is the time in ms.
function transfer.put(open: (first: string) -> Call?, defer: (() -> ()) -> (), now: number, files: Files?, from: string | buffer, remote: string, options: Put_Options?): Transfer
	local self = new_state(true, files, defer)
	local o: Put_Options = options or {}
	if type(from) == "string" then
		if not files then
			finish(self, "failed", "this host lends no files")
			return self.public
		end
		local stat = files.stat(from)
		if not stat or stat.kind ~= "file" then
			finish(self, "not found", "cannot read the file")
			return self.public
		end
		local f = files.open(from, "read")
		if not f then
			finish(self, "failed", "cannot read the file")
			return self.public
		end
		self.path, self.f = from, f
		self.size, self.modified, self.identity = stat.size, stat.modified, stat.identity
	else
		self.files = nil
		self.data = from
		self.size = buffer.len(from)
		self.modified = o.modified or math.floor(now)
		local chunks, whole = transfer.hashes(from)
		self.hashes, self.hash = chunks, whole
		self.identity = o.identity or whole
	end
	assert(#self.identity <= 64, "a file's identity is at most 64 bytes")
	local call = open(services.put(remote, self.size, self.modified, self.identity, o.replace == true, o.folders ~= false))
	if not call then
		finish(self, "unreachable", "")
		return self.public
	end
	attach(self, call)
	return self.public
end

return table.freeze(transfer)
