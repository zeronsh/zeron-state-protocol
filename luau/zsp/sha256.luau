--!strict
--!native
--!optimize 2
-- FIPS 180-4, for naming lists and checking files. Nothing secret passes through here twice. Called, it hashes a
-- string at once; `stream` hashes what is given it piece by piece, for what is too big to hold.

local K = buffer.create(256)
do
	local n, found = 2, 0
	while found < 64 do
		local prime = true
		for d = 2, math.floor(math.sqrt(n)) do
			if n % d == 0 then
				prime = false
				break
			end
		end
		if prime then
			-- The first 32 bits of the fraction of its cube root, by integer bisection.
			local lo, hi = 0, 4294967296
			local whole = math.floor(n ^ (1 / 3) + 1e-9)
			while hi - lo > 1 do
				local mid = (lo + hi) // 2
				local x = whole + mid / 4294967296
				if x * x * x <= n then
					lo = mid
				else
					hi = mid
				end
			end
			buffer.writeu32(K, found * 4, lo)
			found += 1
		end
		n += 1
	end
end

local W = buffer.create(256)
local rr, bx, ba, bn = bit32.rrotate, bit32.bxor, bit32.band, bit32.bnot

-- The state, as eight words, taken through the 64-byte blocks of `data` from `from` to `to`.
local function blocks(state: buffer, data: buffer, from: number, to: number)
	local h0, h1, h2, h3 = buffer.readu32(state, 0), buffer.readu32(state, 4), buffer.readu32(state, 8), buffer.readu32(state, 12)
	local h4, h5, h6, h7 = buffer.readu32(state, 16), buffer.readu32(state, 20), buffer.readu32(state, 24), buffer.readu32(state, 28)
	for base = from, to - 64, 64 do
		for i = 0, 60, 4 do
			buffer.writeu32(W, i, bit32.byteswap(buffer.readu32(data, base + i)))
		end
		for i = 64, 252, 4 do
			local a, b = buffer.readu32(W, i - 60), buffer.readu32(W, i - 8)
			local s0 = bx(rr(a, 7), rr(a, 18), bit32.rshift(a, 3))
			local s1 = bx(rr(b, 17), rr(b, 19), bit32.rshift(b, 10))
			buffer.writeu32(W, i, (buffer.readu32(W, i - 64) + s0 + buffer.readu32(W, i - 28) + s1) % 4294967296)
		end
		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 0, 252, 4 do
			local t1 = h + bx(rr(e, 6), rr(e, 11), rr(e, 25)) + bx(ba(e, f), ba(bn(e), g)) + buffer.readu32(K, i) + buffer.readu32(W, i)
			local t2 = bx(rr(a, 2), rr(a, 13), rr(a, 22)) + bx(ba(a, b), ba(a, c), ba(b, c))
			h, g, f, e, d, c, b, a = g, f, e, (d + t1) % 4294967296, c, b, a, (t1 + t2) % 4294967296
		end
		h0, h1, h2, h3 = (h0 + a) % 4294967296, (h1 + b) % 4294967296, (h2 + c) % 4294967296, (h3 + d) % 4294967296
		h4, h5, h6, h7 = (h4 + e) % 4294967296, (h5 + f) % 4294967296, (h6 + g) % 4294967296, (h7 + h) % 4294967296
	end
	buffer.writeu32(state, 0, h0)
	buffer.writeu32(state, 4, h1)
	buffer.writeu32(state, 8, h2)
	buffer.writeu32(state, 12, h3)
	buffer.writeu32(state, 16, h4)
	buffer.writeu32(state, 20, h5)
	buffer.writeu32(state, 24, h6)
	buffer.writeu32(state, 28, h7)
end

local function initial(): buffer
	local state = buffer.create(32)
	local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	for i, v in h do
		buffer.writeu32(state, (i - 1) * 4, v)
	end
	return state
end

local function words(state: buffer): string
	local out = buffer.create(32)
	for i = 0, 28, 4 do
		buffer.writeu32(out, i, bit32.byteswap(buffer.readu32(state, i)))
	end
	return buffer.tostring(out)
end

local function digest(message: string): string
	local bits = #message * 8
	local padded = message .. "\128" .. string.rep("\0", (55 - #message) % 64) .. string.pack(">I4I4", bits // 4294967296, bits % 4294967296)
	local data = buffer.fromstring(padded)
	local state = initial()
	blocks(state, data, 0, buffer.len(data))
	return words(state)
end

export type Stream = {
	update: (data: string | buffer) -> (),
	final: () -> string, -- the hash of all that was given; nothing more may be
}

local function stream(): Stream
	local state = initial()
	local pending = buffer.create(64) -- what does not yet make a whole block
	local filled = 0
	local total = 0
	local function update(data: string | buffer)
		local b = if type(data) == "string" then buffer.fromstring(data) else data
		local n = buffer.len(b)
		total += n
		local at = 0
		if filled > 0 then
			local take = math.min(64 - filled, n)
			buffer.copy(pending, filled, b, 0, take)
			filled += take
			at = take
			if filled < 64 then
				return
			end
			blocks(state, pending, 0, 64)
			filled = 0
		end
		local whole = (n - at) // 64 * 64
		if whole > 0 then
			blocks(state, b, at, at + whole)
			at += whole
		end
		if at < n then
			buffer.copy(pending, 0, b, at, n - at)
			filled = n - at
		end
	end
	local function final(): string
		local bits = total * 8
		local tail = buffer.create(if filled < 56 then 64 else 128)
		buffer.copy(tail, 0, pending, 0, filled)
		buffer.writeu8(tail, filled, 128)
		local len = buffer.len(tail)
		buffer.writeu32(tail, len - 8, bit32.byteswap(bits // 4294967296))
		buffer.writeu32(tail, len - 4, bit32.byteswap(bits % 4294967296))
		blocks(state, tail, 0, len)
		return words(state)
	end
	return { update = update, final = final }
end

return setmetatable({ stream = stream }, {
	__call = function(_, message: string): string
		return digest(message)
	end,
})
