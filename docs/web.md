# In a browser, or Node

A browser tab is a device: it has its own key, its own encrypted store, its own node, and it meets the space's other devices at
a relay, as zspd does. The node is the very same Odin, `zsp` and `find` compiled to WebAssembly (`web/wasm`); what it is lent is
files, a clock, entropy and WebSockets. Applications speak to it with a client in TypeScript (`web/src`) that does what the Luau
client does, in the same words, and is held to the same tests.

```ts
import { open, columns as c, where as w, mirror as m } from "zsp";

const device = await open({ name: "notes" });     // a browser's own; in Node, open({ dir: "/var/lib/notes" })
if (!device.space) {
  await device.join(space, { key: relayKey, url: "wss://relay.example" });   // once admitted: give an admin device.key
  // or make one's own: await device.create(); await device.relay(relayKey, url); await device.admit(other, 1)
}
const client = device.client();

const Message = { author: c.string(16), body: c.text(17), stars: c.number(18) };
const window = client.window({ scope: 1, list: "chat/42", table: Message }, (state) => {
  render(state.rows, state.before, state.after); // at most once a turn; rows that did not change are the same objects
});
window.visible(first, last);

let id = "";
await client.write(1, (change) => (id = change.insert(Message, "chat/42", Date.now(), { author: "model" }))); // durable here
const found = client.ask({ scope: 1, table: Message, where: w.matches("body", "quick fox", { prefix: true }), order: ["best"] }, (answer) =>
  render(answer.rows, answer.total),
);
const text = client.text(id, Message.body);
text.append(token); // seen everywhere at once; durable a piece at a time
client.serve(1, "run", (call, data) => call.send(work(data)));
const answer = await client.request(deviceId, 1, "run", data);
const copy = client.call(deviceId, 1, "copy", "", { urgency: 6 }); // both ways: copy.send, copy.ondata, copy.finish
```

What a column holds is typed: `Row<typeof Message>` is `{ id, order, author?: string, body: string, stars?: number }`. Ids are hex.
Positions in a text count UTF-16 code units, as a string's indices do, and never fall inside a character. A write's promise
resolves once the write is durable on this device. Structured state is `mirror`, as in [mirror.md](mirror.md): documents are plain,
frozen objects and arrays, and `update` hands out a draft that copies only what it changes. What is in one is asked about, without
opening it, as a question is: `m.ask(client, { scope, name, schema }, ["tasks", id, "steps"], { where, order, limit }, (found) =>
render(found.rows))`, typed by the schema and the path, which names items and nodes by their ids in hex.

A call has an urgency, from 0, the most urgent, to 7, the least: 3 unless `call` or `request` is given `{ urgency }`, and any
other is a `RangeError`. It is the urgency of the stream between devices that carries the call, so what is interactive, such as
keystrokes at 1, goes ahead of what is bulk, such as a copy at 6. A call made to this client has none of its own to say.

What comes in a call is credited only as it is taken: told to `ondata` that returns nothing, or that returns false and says
`consumed` once it is done. So a reader that does not keep up holds up whoever sends, with no more than a call's window between.
What is sent goes only as there is room: `room` says how much may go at once, and `onroom` when more may; `finish` goes after
whatever waits.

## Partial and full

**A browser's device is a partial replica; one in Node is a full one, as zspd is; either can be told otherwise.** A full replica
holds the whole of every scope it can read. A partial one holds what its clients watch and ask about, fetched through a relay
as it is wanted, and so has the end of a list of a million rows as soon as it has the end of a list of ten, and never needs room
for the whole space: what a browser can store, and how fast its network is, are no longer what a space is bounded by.

```ts
const device = await open({ name: "notes" });                      // in a browser: partial
const whole = await open({ name: "notes", full: true });           // or a full replica, which holds everything
const kept = await open({ name: "notes", keep: { days: 7, bytes: 64 << 20 } }); // what is kept of what is no longer watched
```

**A window is served at once from what is held, and then as a full replica says.** A partial device answers a window from what
it holds straight away, with the status `"stale"`; once a full replica (a relay is one, and pages a list as any is) has said what
the window spans and how much lies beyond it, `"ready"`. A window that a full replica says ends sooner than it was first shown
to, as one answered from a cache with gaps does, asks for what lay beyond again, as scrolling there would. `"ready"` means kept
up by a full replica now: when the last one goes, the window is `"stale"` again, and `"ready"` once one is back.

**A question is answered by a full replica that can read, when one is reachable**: a zspd device, or a browser's opened with
`full: true`. The partial device holds the rows of the answer, and keeps them up. When none can read, but a relay holds the
space, the lists a question names (`where.inList`, as every question of `mirror.ask` does) are fetched whole from the relay,
and the question is answered as a full replica would answer it, `"ready"` once the relay has confirmed them. A question that
names no list is about a whole scope, and is answered from what is held, `"stale"`, for that is all it can be.

**What a partial device keeps, and for how long.** Whatever is watched or asked about, and whatever it wrote that no full
replica is yet known to hold, it keeps, however long. Of the rest it keeps a list for 30 days after it was last watched or
written in, and no more than about 256 MiB of everything, letting go of the lists watched least lately first, and of what lies
outside watched ranges last of all; `keep: { days, bytes }` says otherwise, and `keep: false` keeps everything. It looks once
it has opened, when a checkpoint leaves it holding much more than it may, and when a list comes of age, and does so a step
at a time; what it lets go of comes again, through a relay, when it is next watched. `device.usage()` says what it holds and
the memory its node has.

**Offline, a partial device is what it holds.** It shows every window and answers every question from what it has, saying
`"stale"`; it writes as ever, durably, and what it writes reaches the others once it reaches a relay again; and texts are typed
in as ever. After a restart it is the same. What it never watched it does not have until it is back: open what you will want
on a plane before you board.

**A device may be either, from one start to the next, and loses nothing.** Every replica keeps what its clients wrote on record
until a full replica says it holds it, so one that was full and is now partial offers what nobody else has, and one that was
partial and is now full fetches the rest. A store kept before this was so, opened partial, goes on as a full replica until it is
level with one, and is partial from its next start. The tabs of an origin share one device, and whichever runs it opens it as
it says: give them all the same options.

## How it is put together

**The client speaks to the node as every client does.** `Client` is the local client of SPEC.md §8, over a pipe: to the node in
this process, or in a worker, by messages; or to zspd on the same machine, by a WebSocket, which works in Node, where nothing sends
an `Origin`. So it is exactly as correct as the other clients, whatever it is connected to; the tests that hold the Luau client hold
it, and the same suite runs against zspd, against a node of its own, and in a browser.

**A browser's node runs in a dedicated worker**, for only there may a page's files be read and written synchronously, which the
store needs: the origin private file system, through handles each of which holds its file until closed. Tabs of an origin share one
device. Each has a worker; whichever holds the store's lock (Web Locks) runs the node, and the others carry their tabs' pipes to it
over a BroadcastChannel of their own. When the tab running it goes, its lock goes with it; the next worker in line opens the store
and says so, every pipe carried to the one before breaks, and every client dials again, as it does whenever a pipe breaks, losing
nothing: what was not acknowledged is sent again, and what was watched is watched again. Should storage fail, the node stops
rather than go on with what may be lost, every tab is told, and what was asked of it and not done is said to have failed; a worker
whose node stopped, or could not start, breaks the pipes it carried, and gets in line for the store again when its tab next wants
the device, as its clients dialling again do: so the device runs again once it can, and is tried no more often than they dial.

**Files open in their own time in a browser, but the store writes when it writes.** So segments of the log are opened two ahead of
need. Should writing outrun that, what is written to a segment not yet open is held in memory; should it have to be durable before
its file is open, it goes into the journal, a file always open, and is written where it belongs when its file is; the journal is
played first at the next start. Small things kept whole (the device's key, its space, the keys it has learnt, the roster) are
written to whichever of two files does not hold the latest, each with a checksum, so a torn write loses nothing.

**Nothing happens unless something happened.** The node is told of whatever happens, and once a burst of it is over it does what
follows, once, and says when it next has something to do, for which one timer is set. A commit is synced at once, unless syncing
would then be busy more than half the time, so one writer waits for one sync and many share them. What a client says at once is
handed to the node a piece at a time, and its trees checkpointed as they would be between bursts, so that the node holds no more of
a burst than a piece of it. What it sends a pipe counts against that pipe until the far end says it has dealt with it.

**A browser cannot ping a WebSocket**, and a quiet connection must be heard from, so a web device says `ping` in text, which zspd
answers with `pong`, and the Durable Object answers without waking (SPEC.md §7).

**A device governs its space as zspd does.** `create`, `scope`, `admit`, `revoke`, `subject`, `admin`, `owner` and `relay` sign a new
roster, adopt it and say it to everyone.

## Links

In Node, a device links straight to others over UDP, as zspd does (SPEC.md §14): those that share a relay swap addresses through
it and knock on each other's doors at once; those on one network hear each other's beacons and need no relay at all. `open({ dir,
udp: false })` makes none, and `udp: { port, stun }` says where. A browser has no UDP, so everything a browser's device says goes
through a relay. Browsers could link to each other by WebRTC, but that would need a kind of signal and of link the protocol does not
have, and zspd devices could not take part.

## Working on it

`./x check` type-checks the node for `js_wasm32` and all the TypeScript; `./x test` runs everything below beside the rest; `./x web`
builds `web/dist` (zsp.js, worker.js and node.wasm, side by side: each finds the next by its own URL); `./x bench web` measures.

| test | holds |
|---|---|
| `test/client.ts` | the client to `luau/tests/client.luau`: what it says and makes of what it is told, by a node made of nothing |
| `test/vectors.ts`, `text.ts`, `ask.ts` | to `vectors.json`, the frames of a call and of credit among it; text to `text.luau` step by step over random edits; questions to `ask.luau` byte for byte |
| `test/streams.ts` | calls' credit both ways, their urgency, the order of what is sent and of its end, faults and cancelling, by a node made of nothing |
| `test/mirror_model.ts` | structured state to its model, and what is asked about to what a node finds, as `luau/tests/mirror_model.luau` |
| `test/store.ts` | what is said to be durable, through crashes at any moment, small segments, and files that open late |
| `test/node.ts` | a device on its own |
| `test/end_to_end.ts` | `test/live.ts`, which is `luau/tests/live.luau`, over every way devices meet: the client of zspd; partial and full web devices with zspd devices through zspd's relay and the Durable Object; two partial web devices; structured state, with and without a full replica that can read; a space a web device governs; keepalive; direct links, and beacons with no relay; and a partial device's windows, offline life, keeping and letting go, and questions with nobody to ask |
| `test/browsers.ts` | headless Chrome: the live suite against a zspd device and between browser devices through the Durable Object, partial as browsers' are; tabs sharing a device and handing it on; a device the same after a restart, with no relay; a partial device's first window, offline life and restart, and its store opened full and partial again |

Chrome is found where the platform keeps it, or at `$CHROME`; without it, `test/browsers.ts` says so and passes, but in CI it fails.
