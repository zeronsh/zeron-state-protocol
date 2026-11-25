--!strict
--!native
--!optimize 2
-- Bytes on the wire. Identifiers, stamps, tags and keys are kept as binary strings: Luau compares them
-- bytewise, which is exactly the protocol's order.

export type Reader = { buf: buffer, pos: number, len: number }
export type Writer = { buf: buffer, pos: number }

local codec = {}

codec.KEY_MAX = string.rep("\255", 40)

function codec.reader(data: buffer | string): Reader
	local buf = if type(data) == "string" then buffer.fromstring(data) else data
	return { buf = buf, pos = 0, len = buffer.len(buf) }
end

function codec.u8(r: Reader): number
	local v = buffer.readu8(r.buf, r.pos)
	r.pos += 1
	return v
end

function codec.varint(r: Reader): number
	local v, scale = 0, 1
	while true do
		local b = buffer.readu8(r.buf, r.pos)
		r.pos += 1
		v += bit32.band(b, 127) * scale
		if b < 128 then
			return v
		end
		scale *= 128
	end
end

function codec.take(r: Reader, n: number): string
	local s = buffer.readstring(r.buf, r.pos, n)
	r.pos += n
	return s
end

function codec.bytes(r: Reader): string
	return codec.take(r, codec.varint(r))
end

function codec.rest(r: Reader): string
	return codec.take(r, r.len - r.pos)
end

function codec.key(r: Reader): string
	local n = codec.u8(r)
	if n == 255 then
		return codec.KEY_MAX
	end
	return codec.take(r, n) .. string.rep("\0", 40 - n)
end

function codec.writer(): Writer
	return { buf = buffer.create(128), pos = 0 }
end

local function room(w: Writer, n: number)
	local need = w.pos + n
	local have = buffer.len(w.buf)
	if need > have then
		local grown = buffer.create(math.max(have * 2, need))
		buffer.copy(grown, 0, w.buf, 0, w.pos)
		w.buf = grown
	end
end

function codec.put_u8(w: Writer, v: number)
	room(w, 1)
	buffer.writeu8(w.buf, w.pos, v)
	w.pos += 1
end

function codec.put_varint(w: Writer, v: number)
	room(w, 8)
	while v >= 128 do
		buffer.writeu8(w.buf, w.pos, v % 128 + 128)
		w.pos += 1
		v = v // 128
	end
	buffer.writeu8(w.buf, w.pos, v)
	w.pos += 1
end

function codec.put(w: Writer, s: string)
	room(w, #s)
	buffer.writestring(w.buf, w.pos, s)
	w.pos += #s
end

function codec.put_bytes(w: Writer, s: string)
	codec.put_varint(w, #s)
	codec.put(w, s)
end

function codec.put_key(w: Writer, key: string)
	if key == codec.KEY_MAX then
		codec.put_u8(w, 255)
		return
	end
	local n = 40
	while n > 0 and string.byte(key, n) == 0 do
		n -= 1
	end
	codec.put_u8(w, n)
	codec.put(w, string.sub(key, 1, n))
end

function codec.string(w: Writer): string
	return buffer.readstring(w.buf, 0, w.pos)
end

-- A whole number below 2^53 as eight big-endian bytes.
function codec.u64(v: number): string
	return string.pack(">I4I4", v // 4294967296, v % 4294967296)
end

function codec.from_u64(s: string): number
	local hi, lo = string.unpack(">I4I4", s)
	return (hi :: any) * 4294967296 + lo
end

-- A stamp's time: milliseconds and counter.
function codec.clock(s: string): (number, number)
	local hi, mid, n = string.unpack(">I4I2I2", s)
	return (hi :: any) * 65536 + mid, n :: any
end

-- The least key above every key beginning with the prefix.
function codec.after(prefix: string): string
	local n = #prefix
	while n > 0 and string.byte(prefix, n) == 255 do
		n -= 1
	end
	if n == 0 then
		return codec.KEY_MAX
	end
	return string.sub(prefix, 1, n - 1) .. string.char(string.byte(prefix, n) + 1) .. string.rep("\0", 40 - n)
end

return table.freeze(codec)
