# Zeron State Protocol

Local-first state, live across devices, through a relay that can read none of it, or no relay at all.

The protocol is [SPEC.md](SPEC.md). This is the reference implementation, in Odin, with a query client in Luau, and the same node in a
browser, with a client in TypeScript.

```
zsp/       the protocol: store, merge, windows, reconciliation, text, keys, calls. No I/O, threads or clocks
find/      answering questions about it: an index made when first asked, kept encrypted, and never replicated
pipe/      carrying it: UDP links, WebSocket, TLS, STUN. No I/O either
host/      files, sockets, one thread, one event loop; a node to embed, and services in-process
zspd/      a device's node, or a self-hosted relay: one consumer of the above
relay/     the same relay as a Cloudflare Durable Object: zsp/ compiled to wasm, and plumbing; spaces kept in R2
luau/zsp/  the query client
web/       a device in a browser or Node: zsp/ and find/ compiled to wasm, and a client in TypeScript
clients/   a whole client in the Python standard library, to show how little one needs
vectors/   what two implementations must agree on
docs/      how to lay out who sees what, structured state, services, and the web; examples/ has it running
```

## The idea

**One kind of thing, one rule.** Everything is a *cell*, written once: a value, a move, a deletion, a run of text. Replicas unite their cells, and a cell kills
what it supersedes. The rule needs no key, so a relay that cannot read still merges.

**Everything is a range.** Rows sit in one ordered index of `(list, order, row)`. A list is a range, a page is a range, a scope is a range; a subscription is a
set of ranges. The index is a B+tree that also sums fingerprints, so any two replicas compare any range in logarithmic time. That one
operation is sync, resume, paging, scrollbars and recovery. There are no version vectors, no per-peer state and no queues.

**Questions are asked of what is there.** Filters of any shape, words, phrases, misspellings, substrings, references either way between rows, JSON, any order,
sums and facets: each answer stays true while it is open, and costs nothing once it is not. None of it is stored, replicated or seen by a relay. What answers is an
index that a device makes of its own rows, of the columns asked about, when they are first asked about; it may be deleted at any time. A device that
holds little asks one that holds everything, and says whose answer it has.

**Whose it is, is yours to say.** Where a scope is signed, every cell is known to be of the device that wrote it, and that of the user your own sign-in says: by the roster for a
device somebody has, or by the host of one that serves many, if you let it vouch. No application can say otherwise, no relay sees it, and it can be shown, searched, ordered and counted like any other column.

**Documents are tables.** Maps, lists, records and trees, nested as deep as you like, are plain Luau tables: set a new one and what
differs is written; what others write comes back with whatever did not change the very same table. Lists keep their order as text does,
so nothing interleaves and nothing runs out of room. It is rows and texts underneath, so it costs the protocol nothing, and a document
too big to hold can be asked about, as any rows can, at any depth ([docs/mirror.md](docs/mirror.md)).

**A browser tab is a device.** It has its own key, its own encrypted store and its own node, the very same Odin, and meets the others
at a relay, or links to them directly from Node. Its client speaks to it as every client speaks to its node, and is held to the same
tests ([docs/web.md](docs/web.md)). It is a partial replica: it has what it watches as soon as it is asked for, however big the space,
keeps no more than it is told to of what it no longer watches, says whether what it shows is kept up, and is what it holds when it
reaches nobody.

**The log is the database.** A sealed cell is appended once. The bytes on disk are the bytes on the wire are the bytes on the relay.

**A space has no size.** A relay on Cloudflare keeps a space in R2, with its Durable Object as its cache: what is not at hand is fetched
without anything waiting for it, and the object keeps a few megabytes whatever the space comes to ([docs/relay-storage.md](docs/relay-storage.md)).

**What was written long ago is written together.** A text typed a word at a time is a cell a second. Whoever writes the next has a hundred and more of them put into one, and those into one, so that a
text of 8,000 pieces is at most some 200 cells to fetch, check and open, in three quarters of the room they took, or less; and everything that was ever said about it still holds, whoever is still on the old ones.

**Nothing happens unless something happened.** An idle node makes no system calls. An idle link sends no packets and sets no timer.

**Services are yours to build.** A call is a stream each way between two devices the roster lets call, with credit, so that a
slow end slows the other and nothing piles up between; it takes a stream of its own over the link, direct or through a relay, at the
urgency its caller says, and moves to another relay should its own go. Files, terminals, ports: whatever a device offers is built on that, outside
the protocol, and in-process where the host is embedded, as [examples/forward](examples/forward/main.odin) forwards TCP in some 430
lines ([docs/services.md](docs/services.md)).

## Measured

`./x bench`, on one core of a Ryzen 9 9950X and a virtual disk, a million sealed 200-byte rows:

| | |
|---|---|
| memory, writing a million rows | 3.5 MB private |
| memory, holding them open | 2.0 MB private, the rest being file cache the system may take back |
| a running daemon | 0.4 MB private, one thread |
| an idle daemon | 0 wakeups, on Linux, macOS and Windows alike; one ping per relay per 45 s |
| written to disk | 560 bytes a row, 1.8 × the row itself, indexes and all |
| one small durable write | 0.26 ms; 4 KB, the one block it lies in |
| opening the store | 4 to 5 ms |
| a page of 50 rows found, read, decrypted | 0.14 ms |
| fingerprint of any range of the million | 0.2 µs |
| two level replicas of 20,000 rows reconnecting | under 400 bytes |
| one difference among 20,000 | under 6 KB |
| a streamed token, device to relay to device's screen | 1 ms |
| a call to another device through a relay | 0.15 ms on one machine; between continents, the ping |
| a link | 400 MB/s, one core doing both ends |
| checking all six platforms | 1 s |
| building the daemon | 1 s, or 10 s optimised; on an M5 Max, 0.3 s and 4.9 s |
| building and running the core's tests | 5 s; everything, 9 s |

`./x bench find`, the same machine, a million rows with a name, a number, a flag and twenty words of text, encrypted on disk. Every answer is the first 50 in order, and the exact count:

| | |
|---|---|
| memory, holding the rows and an index of all of it | 5.5 MB private, of which the rows take 3.9 |
| on disk | 255 bytes a row, for five columns, one of them every word |
| making it, when first asked | 1 s, and 2 s for each column; 11 s for the words; never more than a few tens of ms at a time |
| everything, newest first | 3 µs |
| everything, by a number | 32 to 40 µs |
| a name | 55 µs |
| a name, a range and a flag, by number | 0.3 ms |
| a wide range: 600,000 rows | 8 ms |
| a rare word; a word in 400,000 rows; a phrase | 20 µs; 5 ms; 8 to 11 ms |
| a word begun; misspelt; part of one | 2 ms; 5 ms; 3 ms |
| the sum of every number | 2 µs |
| the ten commonest names among 333,000 rows | 14 ms |
| one more row, known to all of it | 0.12 to 0.17 ms |
| opening it again | 11 to 19 ms |
| a text in 8,000 pieces, opened and put together: unmerged, and as it is kept | 8 ms; 2 ms |
| one word more in a text that is being written, of 200 words or 100,000 | 0.015 to 0.03 ms |

`./x bench web`, a web device, on 8 cores of an EPYC 9455 under a virtual disk, Node 24 and headless Chrome 151; each figure the median of
many, and where runs differed, both:

| | |
|---|---|
| what a browser loads | zsp.js 30 KB gzipped, its worker 7 KB, the node 415 KB |
| opening a device made from nothing | 4 ms in Node; 48 to 50 ms in a browser: worker, node and store |
| opening it again, holding 100,000 rows | 27 ms |
| one small durable write | 1.5 ms on disk in Node, 0.7 to 0.8 ms in a browser's file system; 84 µs in memory |
| 100,000 rows, a thousand to a write | 4.3 s on disk; in a browser, 21,000 to 25,000 rows a second |
| a page of 50 rows of 100,000, to a client that holds none | 0.6 to 1.1 ms; in a browser, of 20,000, 1.2 to 2.6 ms |
| a question of 100,000 rows: the first 50 of 1,000, by a number | 2.5 ms |
| a streamed token, client to client of one device | 20 to 40 µs; in a browser, tab to worker to tab, 0.1 ms |
| a streamed token, web device to relay to web device's screen | 0.1 ms in Node, 0.2 ms between browsers; the first tokens of a new text, 1 ms, and 4 to 5 ms in a browser |
| memory, holding 100,000 rows and a page | 30 to 36 MB of the node's, 15 MB of the client's |
| `./x test` | 2.5 s longer than without any of it: 55 s |

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
zspd admin ~/.zsp <that>                    # let it admit others; `off` to take that back
```

A directory is one node's at a time: a second `zspd run` or `serve` there, or a Node device (`open({ dir })`), is told the store is
in use and touches nothing, and a node killed lets go of it with its process. The commands that change a space's roster speak to the
node running there, or with none keep the roster for it to read when it starts; `create`, `join` and `peer`, which change what a
node there keeps, fail while one runs. Keep the directory on a disk of the machine's own: a lock on a file system other machines share may not hold, and
zspd and Node refuse one they can tell is (NFS, SMB, AFS, 9p, cluster file systems, shared folders of virtual machines, network
drives on Windows, and on macOS whatever the system does not call local). See host/hold.odin.

```luau
local zsp = require("zsp")

local Message = { author = zsp.string(16), body = zsp.text(17), stars = zsp.number(18) }
local client = zsp.connect(host) -- a socket, a clock, a scheduler: see Host

local window = client:window({ scope = 1, list = "chat/42", table = Message }, function(state)
    render(state.rows, state.before, state.after) -- at most once a turn; unchanged rows are the same tables
end)
window.visible(first, last) -- as the user scrolls, either way, for ever

client:write(1, function(change)
    id = change.insert(Message, "chat/42", os.time(), { author = "model" })
end)
local w = zsp.where
local found = client:ask({
    scope = 1, table = Message,
    where = w.all(w.matches("body", "quick fox", { prefix = true }), w.any(w.is("author", "ann"), w.over("stars", 3))),
    order = { "best" }, limit = 50, totals = { authors = { "facet", "author", 10 } },
}, function(answer)
    render(answer.rows, answer.total, answer.totals.authors) -- again whenever it is no longer so
end)
found.move(50) -- another stretch of it
local now = client:fetch({ scope = 1, table = Message, where = w.is("author", "ann") }) -- once, and no more

local text = client:text(id, Message.body)
text.append(token) -- seen everywhere at once; durable a piece at a time
text.sealed() -- durable now, as far as typed: yields until it is acknowledged

client:serve(1, "run", function(call, data) ... end)
local answer = client:request(device, 1, "run", data)
local copy = client:call(device, 1, "copy", first, { urgency = 6 }) -- a stream each way, behind what is urgent

client:close() -- drops nothing, pipe or none; client:flushed(timeout) yields until all it wrote is durable, or says what was not
```

In a browser or Node, the device is the node, and the client is the Luau one, in TypeScript ([docs/web.md](docs/web.md)):

```ts
import { open, columns as c } from "zsp";

const device = await open({ name: "chat" });     // in Node: open({ dir })
await device.join(space, { key: relayKey, url: "wss://relay.example" }); // or device.create(), and govern it
const client = device.client();
const window = client.window({ scope: 1, list: "chat/42", table: Message }, (state) => render(state.rows));
await client.write(1, (change) => change.insert(Message, "chat/42", Date.now(), { author: "model" })); // durable here
client.text(id, Message.body).append(token);
await client.close(); // once all it wrote, and typed, is durable: nothing is dropped, its pipe up or not
```

On Cloudflare, authentication is a function:

```js
import { relay, Space } from "./index.js";
export { Space };
export default relay({ authenticate: async ({ space, device, credential, env }) => isCustomer(credential, env) });
```

`cd relay && wrangler r2 bucket create zsp-relay --location weur && wrangler secret put RELAY_SECRET && wrangler deploy`, the bucket where the objects
will be; `GET /` then answers with the key devices pin: fetch it once, with something that checks certificates, as a browser or curl does. What
it keeps where, and what that costs: [docs/relay-storage.md](docs/relay-storage.md).

Embedding in Odin is the same question asked of `host.Config.authenticate`, or of `zsp.Host.authenticate` if you bring your own I/O; and
an embedding host serves calls in-process, by `host.host_serve` and `host.host_call` ([docs/services.md](docs/services.md)).

## Users, teams and organizations

[docs/scoping.md](docs/scoping.md): what should be a space, a scope, a list or a column; how much fits; keeping a space the same as your own directory of people; guests, announcements, leavers; who may use a relay,
and what each application on a machine may do. Its examples are in [examples/](examples) and are run with the tests.

## Working on it

`./x check` type-checks every platform, `./x test` runs everything, `./x sim 10000` runs ten thousand seeded networks that fragment, partition, crash, lose
unsynced disk, disagree on the time, have rights given and taken away, and conflict, `./x nat` punches through real NATs in network namespaces, `./x slow` watches a Durable Object sleep, `./x web` builds what a browser loads. Needs `odin` (dev-2026-11), `wasm-ld`, `lune`, `luau-analyze`, `node` (24), `python3`, and
Chrome for the browser tests.

## License

[MIT](LICENSE)
