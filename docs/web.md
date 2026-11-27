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
up by a full replica now: when the last one goes, the window is `"stale"` again, and `"ready"` once one is back. A full
device's windows are bounded the same way where it reaches another full replica, as it may hold only some of the space yet,
while it is being brought level: a window of the last 50 rows is 50 rows, not every row that came before the last did, and
`"ready"` once that one has said so, which it says before it sends the rest. A full device that reaches no other is all
there is, and its windows are `"ready"` at once.

**A question is answered by a full replica that can read, when one is reachable**: a zspd device, or a browser's opened with
`full: true`. The partial device holds the rows of the answer, and keeps them up. When none can read, but a relay holds the
space, the list a question names (`where.inList`, as every question of `mirror.ask` does) is fetched whole from the relay,
and the question is answered as a full replica would answer it, `"ready"` once the relay has confirmed it all. A question
that names no list, or that joins rows of others (`refers`, `referred`), is about more than one list, and is answered from
what is held, `"stale"`, for that is all it can be: in a space with nobody who can read but partial devices, such a question
stays `"stale"` for as long as nobody who can read is reachable, however long that is, and is `"ready"` only once one is.
Answering it whole would mean fetching whole scopes, which is what a partial device is not.

**What a partial device keeps, and for how long.** Whatever is watched or asked about, and whatever it wrote that no full
replica is yet known to hold, it keeps, however long; after a crash too, for its log says which of what it replays its own
clients wrote, and what others did it may let go of as ever. Of the rest it keeps a list for 30 days after it was last watched or
written in, and no more than about 256 MiB of everything, letting go of the lists watched least lately first, and of what lies
outside watched ranges last of all; `keep: { days, bytes }` says otherwise, and `keep: false` keeps everything. It looks once
it has opened, when a checkpoint leaves it holding much more than it may, and when a list comes of age, and does so a step
at a time; what it lets go of comes again, through a relay, when it is next watched. `device.usage()` says what it holds and
the memory its node has.

**Offline, a partial device is what it holds.** It shows every window and answers every question from what it has, saying
`"stale"`; it writes as ever, durably, and what it writes reaches the others once it reaches a relay again; and texts are typed
in as ever. After a restart it is the same. What it never watched it does not have until it is back: open what you will want
on a plane before you board.

**A device may be either, from one start to the next, and loses nothing.** One that was partial and is now full fetches the
rest. One that was full, and so has said it holds what others then forgot, goes on as a full replica, though opened partial,
until it is level with another full replica, which then holds all it held that it lacked; and it is partial from its next
start. So is a store kept before there were partial browsers: a browser that held a full replica before it updated is a full
replica for its first session after, as every one of its sessions was before, fetching what it lacks, until it is level, and
partial from its next start. That is deliberate: it is what makes the switch lose nothing. The tabs of an origin share one device, and whichever runs it opens it as
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
A store is named by a path of the origin's file system, under `zsp/`, whose empty parts are none: `"notes"`, `"notes/"` and
`"/notes"` are one store, with one lock; a name of no parts, or with `.`, `..` or a backslash, is a `RangeError`.

**The store's lock is let go of only once none of its files is open, or being opened.** Each file is held by its handle until
it is closed, and the next to have the lock would find it held. So a worker whose node fails, whether as it opens or after,
tells every tab at once, closes what it has open, and lets go of the lock once whatever was being opened has been had, and
closed, whatever stopping the node throws; one closed, or put away, as it opens the store gives up opening it, closes at once
what it has of it, tells nobody it failed, and only then says it is closed; one in line gives up its place. Closed or put
away, a worker waits on nobody, and tells nobody anything more, its tab nor any other, but that it is there while it still
holds the store: what it asked of whoever holds the store, the pipes it carried there, and the times its tab asked for are
let go of, and the tab, closing its device, tells its clients of no time as up. A tab frozen or left as its device closes stops its worker, as ever.
Chromium lets go of the lock as soon as the worker that held it is gone, which may be before it has let go of
that worker's files, and a worker given the lock may find a file held still: it tries again a millisecond later, then two,
then four, up to a quarter of a second apart, holding the lock throughout. Measured in Chrome 151 it was never needed, the
files let go of before the lock every time, whether the worker was stopped mid-task or not, its tab closed, reloaded, frozen or
left, or its renderer crashed; but Chromium has been seen to hold a file for more than a second, and for ever, until it is
restarted. Held for two seconds on end, counted afresh for each file found held, and each time it is, the store is said to be locked: `open` rejects with `StoreLocked`, exported, whose message says
so, and `onFailure` is told it, as every tab is; nothing was opened and nothing is lost, and the next `open`, or the next time a
tab wants the device, tries again; a segment of the log found held so as it is opened later stops the node as `StoreLocked`
too. So it is, too, when whatever holds the store's lock answers nothing: a live holder answers what it is asked at once, or
once it has opened the store, and says it is there when asked while it gets on with opening it, or letting it go (one stuck,
waiting on a file or a fetch that never ends, is not there for anything that waits on it). What has waited on it for three
seconds, an ask, or a pipe sent something and answered nothing, has it asked whether it is there, unless another worker has
just asked, for what it says every worker hears, which it says once a second at most; and silent for as long again it is
taken to be hung, as a tab whose worker hangs is, or a crashed renderer the browser has not let go of (Chrome on Linux has been
seen to keep one, and its lock, until it is restarted). What was asked of it fails with `StoreLocked`, every pipe carried to
it is broken, and the tab is told; the worker stays in line, and runs the device should the store ever be let go of. A worker that has the store's lock says so at once, however the one before it went, and whatever waited on that one is
waited on it no more: the next is waited on afresh, and asked whether it is there before it is given up on. With
nothing waiting, nothing is asked, and no timer is set. An application may tell its user that another tab, or the browser, holds the store, and to close
the one or restart the other.

```ts
import { open, StoreLocked } from "zsp";
try {
  device = await open({ name: "notes" });
} catch (e) {
  if (e instanceof StoreLocked) showRestartHint(); // and try again when they say
  else throw e;
}
```

**A tab that is frozen, or put away in the back/forward cache, lets go of the device.** A browser freezes a tab hidden for long,
and keeps one left for another page to go back to, and a frozen worker answers nothing while it holds the store's lock and its
files: every other tab of the origin would wait for it to come back, which it may never do. It cannot let go of them in its own
time, for a worker is frozen the moment its tab is, in the midst of whatever it was doing; so as its tab freezes, or is left,
or is closed or loaded again, the tab tells it to go, and stops it. Chrome runs what was sent a worker before it stops it, busy
or not, as it did every time this was measured, though a worker merely told is frozen before it is done: so it stops the node,
makes what it holds durable, closes every file and lets go of the lock, all at once (6 to 25 ms for a store of up to 20,000
rows, which is then quicker to open again), and then is stopped, as a closed tab's is, losing nothing; the tab's pipes break; and the tab starts another worker once it is back, which
its clients dial again. A question asked of the device as it went, if it may have been done, is said to have failed
rather than done twice. And a pipe carried to the leader that hears nothing from it in three seconds is broken off, and its
client dials again, so that nothing is waited for for ever, whatever went astray.

**Timers are kept by the worker.** A browser holds back a hidden tab's timers, to the second, and when it has used up its
wake-ups to the minute; a worker's it does not. So the clients `device.client()` makes keep time by their device's worker: a
hidden tab seals what it types when it should, and dials again when it should. (When readers have the piece is up to the
machine: one that reaches a reader later than it shows live text unconfirmed, ten seconds, as when storage is slow to say it,
is not shown meanwhile, as live text whose writer went quiet is not, and is shown again once it comes. Nothing typed is lost to
it.) The node itself waits for nothing by a timer
but what it has to wait for: a pipe waiting for room is given its turn by a message, never by a timer, and nothing waits behind it.

**A credential can be changed as it expires.** `device.setCredential(credential)` presents another to relays from now on, as an
application does when the one it opened the device with, a JWT of hours, is about to expire; a tab that opens the device with a
credential gives it too. The worker running the node takes it, and dials again at once any relay that has not let the device
in, or that it is waiting to try again; a session already let in goes on, and presents the new one when it is next dialled. Every
worker hears of every credential given, and one that begins asks the others for the newest they know, so whichever runs the
node next presents the newest any tab gave. Newest by a clock of the machine's own and of what was given: what is given anew is
counted later than anything its worker has heard of, though the machine's clock was set back since; what a tab gave before,
given again as it starts another worker, is counted as it was. It is kept in memory
only, never written down, and said to no tab: only to the workers of the origin, which may open the device and do as they like
with it anyway, as anything of the origin may.

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

**In Node, a device's directory is its own.** As a browser's store is held by its Web Lock, a Node device holds its directory
from its first use until it is closed, against every other process and every other device of its own process, by the very lock zspd
takes on its own (host/hold.odin): so a second device there, or a zspd, is told the store is in use and touches nothing, as zspd is
by it. The kernel lets go of the lock when the process ends, however it ends. Node has no file lock of its own to take: on Linux and
Windows it is taken through the SQLite Node is built with (`node:sqlite`, which says nothing of itself from Node 24.15 on), on the
bytes where SQLite keeps its locks, and elsewhere by opening the file with `O_EXLOCK`. A directory on a file system shared with other
machines, where a lock may not hold, is refused, as zspd refuses it. The lock file is only ever a file, never a link, readable by its
owner alone, and what is in it is nothing.

**On Linux, nothing else in a device's process may open its lock file while it runs.** SQLite's lock there is a POSIX record lock,
which the kernel holds for the process, not for the file opened: should anything else in the process open `<dir>/.lock` and close it
again, as `fs.cp` of the device's directory would, or anything that reads every file in it, the kernel lets go of the lock while
the device runs, another process may then open the store beside it, and nothing says so. Nothing in zsp opens it but SQLite, which
keeps its own files open while it holds locks for just this reason, and another device of the same process on the directory goes
through SQLite too, and is refused. The file is hidden, `.lock`, so that what reads a directory's files but not its hidden ones
leaves it alone. Copy a device's directory only once it is closed. On Windows the lock is the handle's, and on macOS the open file's,
and they hold whatever else is opened.

Node 24 offers no other lock: `node:fs` has no `flock` nor `fcntl`, the SQLite it is built with has no `unix-flock` file system, and
`node:wasi` is WASI preview1, which has no locks. Node 26.1 has `node:ffi`, through which `fcntl(F_OFD_SETLK)` takes the very lock zspd
takes, and holds it whatever else of the process opens the file; but it is experimental, says so on every start, cannot call a
function of variable arguments as `fcntl` is (called as one of three, it works on x86-64 and arm64 Linux, and is undefined elsewhere),
is refused under the permission model without `--allow-ffi`, and is missing from builds without libffi and from every Node before
26.1. A native addon would take it anywhere, at the cost of a build or prebuilt binaries for each platform, an install step, and
native code in what is now a package of TypeScript and WebAssembly alone; and a process held beside the device to hold the lock would
need a program that takes zspd's lock, which only zspd is, and Node does not ship. So it is as it is, until `node:ffi` is stable and
can call `fcntl` as it is declared.

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
| `test/hold.ts` | a device's directory held against another device in this process and in another, and against zspd and zspd against it; let go of when its holder is killed; and refused on a file system other machines share |
| `test/end_to_end.ts` | `test/live.ts`, which is `luau/tests/live.luau`, over every way devices meet: the client of zspd; partial and full web devices with zspd devices through zspd's relay and the Durable Object; two partial web devices; structured state, with and without a full replica that can read; a space a web device governs; keepalive; direct links, and beacons with no relay; and a partial device's windows, offline life, keeping and letting go, and questions with nobody to ask |
| `test/browsers.ts` | headless Chrome: the live suite against a zspd device and between browser devices through the Durable Object, partial as browsers' are; tabs sharing a device and handing it on; a device the same after a restart, with no relay; a partial device's first window, offline life and restart, and its store opened full and partial again |
| `test/worker.ts` | `src/worker.ts` and the store in Node, with the origin's file system, Web Locks and BroadcastChannel as a browser has them: a file held by another waited for, two seconds on end and afresh each time, and the store said to be locked, as it is when whatever holds its lock answers nothing, or is stuck, to asks and pipes alike, asked once by many, and one that holds it again saying it is there when first asked; the lock let go of, and nothing more said there, whatever stopping a node, or closing it, throws; the lock let go of only once no file is open or being opened, whether the node fails as it opens or in its first turn, or is closed as it opens; a file that cannot be closed keeping none other open; one store however its name is written; a place in line given up; every file closed at once as the worker is put away; a worker closed or put away waiting on nobody, and telling nobody anything, though it held the store as a pipe it carried went unanswered, waited on a holder that answers nothing, had timers set, or was put away before its node's first turn, which then failed; a tab closing its device telling no client a time is up; a pipe carried as a failed node lets go waited on as asks are; a pipe broken off unanswered waited on only until the holder is heard from after; every way the holder changes (the one before saying nothing, or that it failed, and the next another worker or the one waiting) ending all of waiting on the one before, and the next asked whether it is there afresh; a new leader that then answers nothing given up on as soon as any holder is, though what the one before may have done is said to have failed as it is heard of; and a credential refused, and a pipe broken, by a worker whose store's name names none |
| `test/tabs.ts` | headless Chrome, with tabs as browsers treat them: the tab running the device frozen, put in the back/forward cache, or next in line while frozen; a tab loaded again and again, left and gone back to, and its worker killed, with files held after the lock is had as Chromium has held them, and for ever; a node that fails as it opens; the tab running the device frozen as it closes it, hung, or its renderer crashed; a pipe the leader never heard of; credentials changed by any tab, through a hand-over and after; a tab whose timers are held back sealing what it types, and what is sealed later than a reader shows live text unconfirmed shown again once it is; and a node in a hidden page answering at once |

Chrome is found where the platform keeps it, or at `$CHROME`; without it, `test/browsers.ts` and `test/tabs.ts` say so and pass, but in CI they fail.
