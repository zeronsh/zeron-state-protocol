# Zeron State Protocol

Local-first state, live across devices, through a relay that can read none of it, or no relay at all.

The protocol is [SPEC.md](SPEC.md). This is the reference implementation, in Odin, with a query client in Luau.

```
zsp/       the protocol: store, merge, windows, reconciliation, text, keys, calls. No I/O, threads or clocks
pipe/      carrying it: UDP links, WebSocket, TLS, STUN. No I/O either
host/      files, sockets, one thread, one event loop
zspd/      a device's node, or a self-hosted relay: one consumer of the above
relay/     the same relay as a Cloudflare Durable Object: zsp/ compiled to wasm, and plumbing
luau/zsp/  the query client
clients/   a whole client in the Python standard library, to show how little one needs
vectors/   what two implementations must agree on
```

## The idea

**One kind of thing, one rule.** Everything is a *cell*, written once: a value, a move, a deletion, a run of text. Replicas unite their cells, and a cell kills
what it supersedes. The rule needs no key, so a relay that cannot read still merges.

**Everything is a range.** Rows sit in one ordered index of `(list, order, row)`. A list is a range, a page is a range, a scope is a range; a subscription is a
set of ranges. The index is a B+tree that also sums fingerprints, so any two replicas compare any range in logarithmic time. That one
operation is sync, resume, paging, scrollbars and recovery. There are no version vectors, no per-peer state and no queues.

**The log is the database.** A sealed cell is appended once. The bytes on disk are the bytes on the wire are the bytes on the relay.

**Nothing happens unless something happened.** An idle node makes no system calls. An idle link sends no packets and sets no timer.

## Measured

`./x bench`, on one core of a Ryzen 9 9950X and a virtual disk, a million sealed 200-byte rows:

| | |
|---|---|
| memory, writing a million rows | 3.5 MB private |
| memory, holding them open | 2.0 MB private, the rest being file cache the system may take back |
| a running daemon | 0.4 MB private, one thread |
| an idle daemon | 0 wakeups, on Linux, macOS and Windows alike; one ping per relay per 45 s |
| written to disk | 560 bytes a row, 1.8 × the row itself, indexes and all |
| one small durable write | 0.25 ms; 4 KB, the one block it lies in |
| opening the store | 4 ms |
| a page of 50 rows found, read, decrypted | 0.12 ms |
| fingerprint of any range of the million | 0.2 µs |
| two level replicas of 20,000 rows reconnecting | under 400 bytes |
| one difference among 20,000 | under 6 KB |
| a streamed token, device to relay to device's screen | 1 ms |
| a call to another device through a relay | 0.15 ms on one machine; between continents, the ping |
| a link | 430 MB/s, one core doing both ends |
| checking all six platforms | 0.6 s |
| building the daemon | 1.1 s, or 5 s optimised; on an M5 Max, 0.3 s and 4.9 s |
| building and running the core's tests | 1.8 s; everything, 7 s |

## Using it

```sh
./x build                                   # build/zspd
zspd serve /var/zsp                         # a relay; prints its key
zspd create ~/.zsp                          # a space; prints its name
zspd relay ~/.zsp <relay key> ws://host:8787
zspd run ~/.zsp                             # this device's node

zspd key ~/.zsp                             # on another device,
zspd admit ~/.zsp <that> 1                  # on this one, at once, running or not,
zspd join ~/.zsp <space> <relay key> ws://host:8787 && zspd run ~/.zsp     # and there
```

```luau
local zsp = require("zsp")

local Message = { author = zsp.string(16), body = zsp.text(17) }
local client = zsp.connect(host) -- a socket, a clock, a scheduler: see Host

local window = client:window({ scope = 1, list = "chat/42", table = Message }, function(state)
    render(state.rows, state.before, state.after) -- at most once a turn; unchanged rows are the same tables
end)
window.visible(first, last) -- as the user scrolls, either way, for ever

client:write(1, function(change)
    id = change.insert(Message, "chat/42", os.time(), { author = "model" })
end)
local text = client:text(id, Message.body)
text.append(token) -- seen everywhere at once; durable a piece at a time

client:serve(1, "run", function(call, data) ... end)
local answer = client:request(device, 1, "run", data)
```

On Cloudflare, authentication is a function:

```js
import { relay, Space } from "./index.js";
export { Space };
export default relay({ authenticate: async ({ space, device, credential, env }) => isCustomer(credential, env) });
```

`cd relay && wrangler secret put RELAY_SECRET && wrangler deploy`; `GET /` then answers with the key devices pin.

Embedding in Odin is the same question asked of `host.Config.authenticate`, or of `zsp.Host.authenticate` if you bring your own I/O.

## Working on it

`./x check` type-checks every platform, `./x test` runs everything, `./x sim 10000` runs ten thousand seeded networks that fragment, partition, crash and
conflict, `./x nat` punches through real NATs in network namespaces, `./x slow` watches a Durable Object sleep. Needs `odin` (dev-2026-11), `wasm-ld`, `lune`, `luau-analyze`, `node`, `python3`.
