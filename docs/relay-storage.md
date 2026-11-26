# Where a relay keeps a space

A relay on Durable Objects keeps each space in an R2 bucket, with the space's object's own SQLite as its cache. A space has no size:
R2 has none, and what the object keeps is small whatever the space comes to. A relay without a bucket keeps what it would have put in R2
in its object's SQLite too, and so a space in its object alone, as it always did, until that is full. `zspd serve` keeps spaces in files, as
it always has.

## What is where

| | the object's SQLite | R2 |
|---|---|---|
| the log | its tail: what is not yet in R2, what lies past the last checkpoint, and the latest 4 MiB | all of it, in extents of 1 MiB, `<space>/l/<n>` |
| the trees | | every page, in packs, one a checkpoint, `<space>/p/<generation>` |
| a manifest | the trees' roots, the latest pack, how far the log is in R2, what is being deleted | |
| the roster | the latest, and the one before | |
| a cache | every tree's tops (its branches), apart, which nothing else read crowds out; pages lately read or written; and stretches of log read here and there: 64 MiB at most, or a quarter of `STORAGE_LIMIT` | |

The log is written where it always was, one row of SQLite a burst of writing, rows rewritten as they fill up to 64 KiB. Once an extent is whole
and durable it is put in R2, four at once. Once the checkpoint is past it too, and it is more than 4 MiB behind the end, the object lets its own
copy go.

The trees are copy-on-write, and at a checkpoint every page changed since the last is put in one object, a pack. A page's number says where it
is, `generation << 20 | slot`, so nothing maps one to the other, and nothing in R2 is ever written twice, overwritten or listed. A pack names
the pages in it by the keys that lead to them, and a tree of packs counts how many of each pack's pages are still the latest. A pack none of
whose pages are is deleted. One at least 64 generations old with fewer than half its pages the latest, and 64 or more not, has the rest
touched, which copies them into the next pack, and is soon deleted in its turn.

A checkpoint is a put, and costs as much as some three seconds of the object awake, while replaying what came after one
on waking costs little: a bulk write's records next to nothing, a small one some 0.1 ms. So a relay does not
checkpoint while writing goes on until there are 4 MiB of log to replay (sooner where `STORAGE_LIMIT` leaves it little
room), and once nothing has happened for a second, it checkpoints if there are more than 256 KiB: what hibernates wakes
with little to replay, and what is written on and on is put a checkpoint every few megabytes, not every few hundred
kilobytes.

## Reading what is not at hand

A read of a page or a stretch of log that is not in memory or the object's cache does not wait. It answers "not yet", and whatever was
being done is undone, wholly, and done again once what it wanted has come (zsp/lazy.odin): a frame from a device, a unit of what is sent to
one, a record replayed on waking, a step of larger work. Pages are fetched sixteen at once with their neighbours in the pack, which are their
neighbours in the tree; and as every tree's branches are kept in the object's cache, whatever else it has let go of, only
leaves are ever fetched, one round a tree, not one a level. The log is read ahead further each time a device reads on through it, up to an extent, for each of
several devices at once, and the next stretch is asked for before it is reached; what was read ahead is kept until it is
read. A record replayed on waking that misses has those after it replayed too, and undone with it, so that everything
they miss is fetched in one round. Nothing polls, and nothing blocks: R2 says when it is done, and whatever waited goes on.

## What is durable when

A write is acknowledged once it is in the object's SQLite, as before. The object keeps every byte of log past the last checkpoint, and every
byte not yet in R2, so that waking replays only from its own storage. A pack is put in R2 only once the manifest has spent its generation, and
named by the manifest only once it is there; what a checkpoint lets go of is named in its manifest until it is deleted, and deleted again an
hour later, so that a put under way when an object died, landing after, lands on nothing anyone reads, and is gone. All of it is held to a
model of an R2 that is slow, fails, says it failed when it did not and lands puts late, under an object that crashes at any point and loses
what SQLite had not synced (zsp/remote_test.odin, tests/relay_storage.mjs), and to whole networks converging through such relays
(zsp/sim_test.odin).

## When it is full

Should R2 fall behind, so that the object holds more of the log than 64 MiB, or half of `STORAGE_LIMIT` (but never less than the 4 MiB it keeps
at hand and two extents more, so that there is always a whole extent to put, and waiting ends), what devices write waits until R2 has caught
up: it is acknowledged later, and nothing is turned away for want of room that R2 has. A `STORAGE_LIMIT` below some 8 MiB leaves no room for
that, and such an object fills as one without a bucket does. What can still fill up is the object's own
SQLite where no bucket is bound. Then the relay says so as it always did: whoever is connected is let go with `1011`, and for `FULL_WAIT`
milliseconds (a minute) anyone who knocks is answered `507`. Nothing that was not kept was acknowledged, and every device still has it.

## Setting one up

```sh
cd relay
wrangler r2 bucket create zsp-relay --location weur   # where the objects of your spaces will be: R2 is far slower from far away
wrangler secret put RELAY_SECRET
wrangler deploy
```

`wrangler.toml` binds the bucket as `STORE`. Settings, all optional: `STORAGE_LIMIT`, bytes of SQLite a space may use; `FULL_WAIT`;
`CACHE_BYTES`; `PAGES_KEPT` and `BLOCKS_KEPT`, the pages and 64 KiB stretches of log kept in memory (2048 and 64); `QUIET_MS` and
`QUIET_TAIL`, how long nothing must happen before a checkpoint, and how much log there must be to replay for one (1000 and
262144); `STATS`, `"1"` to answer `/<space>?stats` with what a space has cost, `?probe` with how long R2 takes, and
`?evict=warm|cold|empty` to start a space's node again as an evicted object does, with its cache, with all but the trees'
tops let go of, or with nothing, for measuring. A space kept wholly in SQLite by an earlier relay is made again from its log when its object next wakes, checkpointing as
it goes, and its log moves to R2 an extent at a time.

## What it costs

`python3 bench/relay.py [rows]`, `bench/policy.py` and `bench/wake.py`, under workerd here or against a deployed relay. On
Cloudflare, with the bucket in the same region as the objects, and devices in the same city:

| | |
|---|---|
| a small write, device to relay to device | 26 to 38 ms, the round trip included; one row of SQLite written, $0.000001 |
| 25 MB written in bulk | 2.3 to 3 s; $0.000055 a MB: a row of SQLite a burst, a put an extent, a put a checkpoint |
| 5 MB written steadily over 15 s | 2 checkpoints, 6 puts, $0.00007 a MB (30 checkpoints and $0.00012 a MB when one was every 256 KiB) |
| what is next written after an object hibernated | 47 to 59 ms, the round trip included: some 15 ms more than when awake |
| a new device sent 25 MB | 4 to 6 s; some 40 gets, $0.00004 in all |
| a window of 50 from an object woken from eviction | 10 to 110 ms; at most 1 get |
| the same with its cache turned over | 0.15 to 0.4 s; 3 to 5 gets, $0.00001 at most: leaves, then the log, as the device asks |
| the same with nothing cached at all, not even the trees' tops | 0.2 to 0.55 s; 3 to 7 gets |
| a device that has everything, back | one fingerprint; nothing read from R2 |
| R2 from an object | a get of 4 KiB 22 to 43 ms, of 1 MiB 35 to 49 ms; a put of 1 MiB 176 to 230 ms; from another continent, ten times that |
| kept in the object | the log's last 4 MiB and the cache: some 1 to 5 MB, $0.001 a month |
| the relay's memory | 5 to 6 MB of WebAssembly |

at R2 Standard's $0.015 a GB-month, $4.50 a million puts and $0.36 a million gets, and SQLite's $1.00 a million rows written.
