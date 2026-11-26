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
```

What a column holds is typed: `Row<typeof Message>` is `{ id, order, author?: string, body: string, stars?: number }`. Ids are hex.
Positions in a text count UTF-16 code units, as a string's indices do, and never fall inside a character. A write's promise
resolves once the write is durable on this device. Structured state is `mirror`, as in [mirror.md](mirror.md): documents are plain,
frozen objects and arrays, and `update` hands out a draft that copies only what it changes.

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
nothing: what was not acknowledged is sent again, and what was watched is watched again.

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

## What it does not do

A browser has no UDP, so it makes no direct links (§14): everything it says goes through a relay. Neither does a device in Node,
yet, though Node has UDP. A browser could link to another browser by WebRTC, which would need a kind of signal and of link the
protocol does not have; zspd devices could not take part.

## Working on it

`./x check` type-checks the node for `js_wasm32` and all the TypeScript; `./x test` runs everything below beside the rest; `./x web`
builds `web/dist` (zsp.js, worker.js and node.wasm, side by side: each finds the next by its own URL); `./x bench web` measures.

| test | holds |
|---|---|
| `test/client.ts` | the client to `luau/tests/client.luau`: what it says and makes of what it is told, by a node made of nothing |
| `test/vectors.ts`, `text.ts`, `ask.ts` | to `vectors.json`; text to `text.luau` step by step over random edits; questions to `ask.luau` byte for byte |
| `test/mirror_model.ts` | structured state to its model, as `luau/tests/mirror_model.luau` |
| `test/store.ts` | what is said to be durable, through crashes at any moment, small segments, and files that open late |
| `test/node.ts` | a device on its own |
| `test/end_to_end.ts` | `test/live.ts`, which is `luau/tests/live.luau`, over every way devices meet: the client of zspd; web devices with zspd devices through zspd's relay and the Durable Object; two web devices; a space a web device governs; keepalive |
| `test/browsers.ts` | headless Chrome: the live suite against a zspd device and between browser devices through the Durable Object; tabs sharing a device and handing it on; a device the same after a restart, with no relay |

Chrome is found where the platform keeps it, or at `$CHROME`; without it, `test/browsers.ts` says so and passes, but in CI it fails.
