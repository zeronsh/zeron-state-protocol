# Structured state

A document of maps, lists, records and trees, nested as deep as you like, with texts in them, held as plain Luau tables.
You set a new state, and what differs is written. Others write, and you are told the new state, in which whatever did not
change is the very same table as before, so that a view can pass it over by identity.

It is built of rows, columns and texts. Nodes, relays and the protocol do not know it is there.

```luau
local zsp = require("zsp")
local m = zsp.mirror

local Task = m.map({
	title = zsp.string(16),
	done = zsp.boolean(17),
	notes = zsp.text(18),
	tags = m.list(19, zsp.string(16)), -- values, kept in slot 19
})
local Board = m.map({
	title = zsp.string(16),
	meta = m.map({ owner = zsp.string(16) }),
	tasks = m.list(17, Task), -- maps, in an order kept in slot 17
	scores = m.record(zsp.number(16)),
	outline = m.tree(18, m.map({ name = zsp.string(16) })),
})

local board = m.open(client, { scope = 1, name = "launch", schema = Board }, function(state)
	render(state)
end)

board.update(function(draft)
	table.insert(draft.tasks, 1, { title = "ship it", tags = { "now" } })
	draft.scores.ann = 3
end)
```

## What there is

| | is | in Luau |
|---|---|---|
| `m.map({...})` | named columns, and whatever is nested under other names | a table, with its `id` |
| `m.list(slot, of)` | maps or values in an order, which anything in it may be moved about in | an array. Maps keep their `id`: moving one is moving it, and one without an id is new |
| `m.record(of)` | maps or values by keys made up as you go | a table of string keys |
| `m.tree(slot, node)` | maps, each with its `children`; any may be moved under any other | an array of nodes, each with `children` |
| a column | `zsp.string`, `number`, `boolean`, `row`, `custom`, `text`, `author` | its value |

Each column, and each list and tree, has a slot of its own in its map, from 16 to 254; slot 255 is the mirror's. Different
maps may use the same slots for different things. A list or tree keeps its order in its slot as a text, so order merges as text
does. A list of values keeps the values themselves there, one after another, so a list of ten thousand numbers is one column,
not ten thousand rows.

A text column is always a string, empty when nothing is in it, and what you set is written as an edit, so that whatever anyone
else types meanwhile is kept. In any other column what is empty is no value: a string set to `""` reads back as nothing.

`board.set(state)` writes a whole new state. `board.update(f)` hands `f` a draft of the state, which it changes as it likes, and
writes that: a draft is the state itself until something in it is changed, and only that, and what leads to it, is copied. A state
put together from the last one, sharing what did not change, costs the least of all: the very same table is passed over unread.

## When two write at once

Everything comes to one state everywhere, whatever order it arrives in, as a function of what has arrived.

- **Columns:** the later write wins, each column for itself. Two people changing different columns of one task both have their way.
- **Texts:** both are kept, as in any text column.
- **Lists:** both insertions are there, and never interleaved, whoever inserted where. Of two moves of one item, the later. A
  deleted item stays deleted, whatever was done to it meanwhile. Nothing ever runs out of room between two items.
- **Records:** two who make one key at once make one entry, to which both have written, column by column. A deleted key holds
  nothing, and what is put in it meanwhile goes too; set again, it is as it is set.
- **Trees:** of two moves of one node, the later. Two moves that together would make a loop, such as a under b and b under a,
  cannot both hold: the one made later goes back where it was, by the marker it left there. A node moved under one that is
  deleted meanwhile is deleted with it.

Whoever writes may write anything, and it is the same for everyone: rows that say they are in what they are not, keys that are not
their own, markers that are another's, values that are not of their kind. Whatever cannot be read is nothing, and what holds
anything a writer could not have put there is not shown.

## Asking

A document too big to hold whole need not be opened. What is in any of its lists, records or trees can be asked about, as any
rows can, and a node finds what answers:

```luau
local open = m.ask(client, { scope = 1, name = "launch", schema = Board }, { "tasks" }, {
	where = zsp.where.is("done", false),
	order = { "title" },
	limit = 50,
}, function(answer)
	render(answer.rows)
end)
open.move(50, 50) -- the next fifty
open.stop()
```

A path names fields, and after the name of a record, list or tree, the key or id of what is in it: `{ "people", "ann", "pets" }`,
`{ "tasks", id, "steps" }`. Conditions and orders name the columns of what is asked about, or `value` in a record of values.

What is given is what the document would show there, as it would show it: each row as its map, with what is in its own row and
in its maps, and a node with its children. Its own lists, records and trees of rows are asked about by their paths. A node finds
rows by what they say they are in; whether they are, the rows on the way say, as they do when the document is open. So what a
writer who minds nothing puts there, or what is in something deleted and not yet let go of, is not given, though a node counts it
in `total` and `totals`. For a record, `keys` says whose each row is. It is kept up as the rows change, and nothing more is held
than the rows on the way and those that answer, and for a tree all its nodes, since which of them are there is known only from all
of them.

## What is kept

Nothing that nothing shows. A deleted item or node is deleted, with everything in it. What others put in a row or a key while it was
being deleted is let go of by whoever next writes, as is any marker that no item has any longer. A record's key that has been let
go of keeps a row with nothing in it but its name, so that it can be set again, as the same key, by anyone. To let go of what others
put in a deleted row later, an open document remembers the id of each row it has seen deleted, and nothing else of it.

## What it costs

Nothing, to anything but the client that uses it: what is stored, sent and merged is rows and texts like any others, and a document
is one list, so one window, however deep it goes. On the client, one list of maps of a number and a string each, as a node sends
it, and as `./x bench mirror table` measures every case (`bench/mirror.py` says how, at length): each a process of its own, perf
counting only while the case itself is done, the middle of three runs (five in TypeScript). An opening is done once, with the
collector going round in it as it would. A change is done 200 times (40 in a list of 100,000), after 3,000 not counted (600 where
each copies a list of 100,000, 200 moves heard), so that it is as it is once a client has been going a while; with the collector
kept from what is counted, which is the client's own work, and what each made, which is what collecting it will cost, measured
beside. In Luau what is made and held is counted by the luau CLI, which can collect at once, as Lune cannot.

| luau | rows | time | instructions | at most while | made each | held after | per row |
|---|---|---|---|---|---|---|---|
| made, all at once | 2,000 | 49 ms | 295 M | 13.8 MB |  | 3.4 MB |  |
| opened by another, from what a node sends | 2,000 | 19 ms | 120 M | 900 KB |  | 2.9 MB | 1,521 B |
| one changed, by set | 2,000 | 77 µs | 787 k |  | 73 KB | 0.0 KB |  |
| one changed, by update | 2,000 | 296 µs | 3.6 M |  | 261 KB | 0.0 KB |  |
| one moved, by set | 2,000 | 225 µs | 1.74 M |  | 207 KB | 302 KB |  |
| one moved, by update | 2,000 | 361 µs | 4.52 M |  | 396 KB | 302 KB |  |
| one changed by another, heard | 2,000 | 30 µs | 167 k |  | 34 KB | 0.0 KB |  |
| one moved by another, heard | 2,000 | 209 µs | 2.32 M |  | 90 KB | 457 KB |  |
| a window of plain rows, all of them, opened | 2,000 | 15 ms | 85.7 M | 3.8 MB |  | 2.1 MB | 1,092 B |
| the same, every row read | 2,000 | 14 ms | 85.1 M | 3.6 MB |  | 2.1 MB | 1,092 B |
| a document with a text in each item, opened | 2,000 | 20 ms | 120 M | 5.0 MB |  | 2.9 MB | 1,521 B |
| a character typed in one of those texts | 2,000 | 180 µs | 1.07 M |  | 100 KB | 215 KB |  |
| a character typed by another, heard live | 2,000 | 14 µs | 130 k |  | 38 KB | 1.0 KB |  |
| a question of the document, answered and stopped (mirror.ask) | 2,000 | 4.74 ms | 49.8 M |  | 1.5 MB | 0.0 KB |  |
| made, all at once | 20,000 | 959 ms | 5.07 G | 64.1 MB |  | 36.8 MB |  |
| opened by another, from what a node sends | 20,000 | 283 ms | 1.27 G | 35.0 MB |  | 32.1 MB | 1,681 B |
| one changed, by set | 20,000 | 474 µs | 6.81 M |  | 635 KB | 0.0 KB |  |
| one changed, by update | 20,000 | 2.74 ms | 35 M |  | 2.6 MB | -8.0 KB |  |
| one moved, by set | 20,000 | 1.01 ms | 10 M |  | 771 KB | 456 KB |  |
| one moved, by update | 20,000 | 2.33 ms | 38 M |  | 2.8 MB | 456 KB |  |
| one changed by another, heard | 20,000 | 71 µs | 686 k |  | 315 KB | 0.0 KB |  |
| one moved by another, heard | 20,000 | 399 µs | 3.75 M |  | 407 KB | 551 KB |  |
| a window of plain rows, all of them, opened | 20,000 | 247 ms | 918 M | 39.0 MB |  | 21.7 MB | 1,136 B |
| the same, every row read | 20,000 | 165 ms | 902 M | 36.4 MB |  | 21.7 MB | 1,136 B |
| a document with a text in each item, opened | 20,000 | 310 ms | 1.28 G | 35.0 MB |  | 32.1 MB | 1,681 B |
| a character typed in one of those texts | 20,000 | 251 µs | 1.59 M |  | 382 KB | 215 KB |  |
| a character typed by another, heard live | 20,000 | 71 µs | 652 k |  | 320 KB | 2.0 KB |  |
| a question of the document, answered and stopped (mirror.ask) | 20,000 | 4.87 ms | 52.9 M |  | 1.8 MB | 1.0 KB |  |
| made, all at once | 100,000 | 6.71 s | 33.9 G | 172.5 MB |  | 155.5 MB |  |
| opened by another, from what a node sends | 100,000 | 1.72 s | 6.25 G | 142.6 MB |  | 158.6 MB | 1,663 B |
| one changed, by set | 100,000 | 2.31 ms | 31.6 M |  | 3.1 MB | 0.0 KB |  |
| one changed, by update | 100,000 | 9.68 ms | 172 M |  | 12.7 MB | 0.0 KB |  |
| one moved, by set | 100,000 | 5.38 ms | 43.8 M |  | 3.1 MB | 103 KB |  |
| one moved, by update | 100,000 | 13 ms | 183 M |  | 12.7 MB | 103 KB |  |
| one changed by another, heard | 100,000 | 272 µs | 2.36 M |  | 1.5 MB | 0.0 KB |  |
| one moved by another, heard | 100,000 | 1.35 ms | 8.44 M |  | 1.8 MB | 101 KB |  |
| a window of plain rows, all of them, opened | 100,000 | 1.41 s | 4.55 G | 139.5 MB |  | 112.7 MB | 1,182 B |
| the same, every row read | 100,000 | 1.36 s | 4.51 G | 139.3 MB |  | 112.7 MB | 1,182 B |
| a document with a text in each item, opened | 100,000 | 1.95 s | 6.27 G | 43.4 MB |  | 158.6 MB | 1,663 B |
| a character typed in one of those texts | 100,000 | 428 µs | 3.24 M |  | 1.6 MB | 44 KB |  |
| a character typed by another, heard live | 100,000 | 223 µs | 2.32 M |  | 1.5 MB | 0.0 KB |  |
| a question of the document, answered and stopped (mirror.ask) | 100,000 | 6.83 ms | 53.9 M |  | 2.1 MB | 0.0 KB |  |

| ts | rows | time | instructions | at most while | made each | held after | per row |
|---|---|---|---|---|---|---|---|
| made, all at once | 2,000 | 102 ms | 489 M | 15.2 MB |  | 3.4 MB |  |
| opened by another, from what a node sends | 2,000 | 41 ms | 277 M | 104 KB |  | 3.0 MB | 1,590 B |
| one changed, by set | 2,000 | 119 µs | 1.22 M |  | 52 KB | 72 KB |  |
| one changed, by update | 2,000 | 141 µs | 1.26 M |  | 54 KB | 71 KB |  |
| one moved, by set | 2,000 | 553 µs | 3.99 M |  | 671 KB | 297 KB |  |
| one moved, by update | 2,000 | 624 µs | 5.64 M |  | 774 KB | 297 KB |  |
| one changed by another, heard | 2,000 | 28 µs | 135 k |  | 26 KB | 70 KB |  |
| one moved by another, heard | 2,000 | 177 µs | 1.78 M |  | 175 KB | 338 KB |  |
| a window of plain rows, all of them, opened | 2,000 | 34 ms | 190 M | 524 KB |  | 2.5 MB | 1,297 B |
| the same, every row read | 2,000 | 27 ms | 189 M | 356 KB |  | 2.5 MB | 1,296 B |
| a document with a text in each item, opened | 2,000 | 42 ms | 333 M | 232 KB |  | 3.0 MB | 1,591 B |
| a character typed in one of those texts | 2,000 | 35 µs | 409 k |  | 31 KB | 117 KB |  |
| a character typed by another, heard live | 2,000 | 20 µs | 104 k |  | 30 KB | 108 KB |  |
| a question of the document, answered and stopped (mirror.ask) | 2,000 | 2.00 ms | 27.2 M |  | 2.2 MB | 76 KB |  |
| made, all at once | 20,000 | 948 ms | 4.45 G | 164.0 MB |  | 34.8 MB |  |
| opened by another, from what a node sends | 20,000 | 244 ms | 1.98 G | 35.9 MB |  | 31.2 MB | 1,635 B |
| one changed, by set | 20,000 | 616 µs | 5.71 M |  | 332 KB | 74 KB |  |
| one changed, by update | 20,000 | 724 µs | 5.75 M |  | 335 KB | 73 KB |  |
| one moved, by set | 20,000 | 1.38 ms | 10.3 M |  | 969 KB | 238 KB |  |
| one moved, by update | 20,000 | 2.09 ms | 24.5 M |  | 2.3 MB | 238 KB |  |
| one changed by another, heard | 20,000 | 82 µs | 116 k |  | 165 KB | 70 KB |  |
| one moved by another, heard | 20,000 | 292 µs | 3.04 M |  | 332 KB | 362 KB |  |
| a window of plain rows, all of them, opened | 20,000 | 169 ms | 1.43 G | 35.1 MB |  | 24.4 MB | 1,279 B |
| the same, every row read | 20,000 | 161 ms | 1.43 G | 34.9 MB |  | 24.4 MB | 1,279 B |
| a document with a text in each item, opened | 20,000 | 259 ms | 2.07 G | 44.9 MB |  | 31.2 MB | 1,635 B |
| a character typed in one of those texts | 20,000 | 86 µs | 388 k |  | 171 KB | 117 KB |  |
| a character typed by another, heard live | 20,000 | 65 µs | 81.8 k |  | 169 KB | 108 KB |  |
| a question of the document, answered and stopped (mirror.ask) | 20,000 | 2.37 ms | 27.8 M |  | 2.3 MB | 78 KB |  |
| made, all at once | 100,000 | 3.78 s | 20.5 G | 401.2 MB |  | 156.9 MB |  |
| opened by another, from what a node sends | 100,000 | 1.25 s | 7.87 G | 210.1 MB |  | 151.0 MB | 1,584 B |
| one changed, by set | 100,000 | 2.57 ms | 26.6 M |  | 1.5 MB | 71 KB |  |
| one changed, by update | 100,000 | 2.36 ms | 26.7 M |  | 1.5 MB | 71 KB |  |
| one moved, by set | 100,000 | 3.20 ms | 37.7 M |  | 1.8 MB | 100 KB |  |
| one moved, by update | 100,000 | 19 ms | 105 M |  | 8.3 MB | 99 KB |  |
| one changed by another, heard | 100,000 | 381 µs | 106 k |  | 790 KB | 70 KB |  |
| one moved by another, heard | 100,000 | 932 µs | 8.6 M |  | 1004 KB | 126 KB |  |
| a window of plain rows, all of them, opened | 100,000 | 858 ms | 5.87 G | 152.6 MB |  | 120.2 MB | 1,260 B |
| the same, every row read | 100,000 | 755 ms | 5.83 G | 151.9 MB |  | 120.2 MB | 1,260 B |
| a document with a text in each item, opened | 100,000 | 1.27 s | 8.68 G | 215.3 MB |  | 151.0 MB | 1,584 B |
| a character typed in one of those texts | 100,000 | 304 µs | 384 k |  | 797 KB | 80 KB |  |
| a character typed by another, heard live | 100,000 | 279 µs | 86.4 k |  | 794 KB | 77 KB |  |
| a question of the document, answered and stopped (mirror.ask) | 100,000 | 3.22 ms | 30.4 M |  | 2.9 MB | 71 KB |  |

*At most* is the most the process held while opening, above what it held before; *held* is what the heap holds once the document is
open and the collector has been round (in TypeScript with what array buffers hold, and without what V8 has compiled), or, after
changes, what they left held more than before them; *per row* is what is held of an open document divided by its rows; *made* is
what each change made for the collector.

A row is held as one table (in TypeScript one object of a fixed shape), its cells under their slots' numbers, each one string of its
kind, stamp and body, read from what came in one read; what only some rows need, as texts, editors and whose each cell is, is there
only once they need it. A row's version, which no other state of any row has, says when what was read of it is to be read again. A
window keeps its rows' keys and the rows in two arrays, and many rows at once are sorted among themselves as strings are and merged
in. The document reads where each row is without a function made for it, reads the columns that are not made up straight from
their cells, and places a list it reads from nothing by where its items' markers are along the text of its order, with no
comparing; it keeps nothing of what it has read of what is gone.

What is read of a row is kept until that row changes; a list in which items changed is patched where they are, each found by where
its marker is, and one in which items moved has them taken out and put back where their markers say, the rest keeping their order,
for the order of what is there never changes. What is left that grows with a list is copying its array, which a new state must have,
and, by `set`, looking along it for what is not the very same table. `update` must also give `f` a list it can change with
`table.insert` and `table.remove`, which do not call metamethods, so a list it touches is a real array of a draft for each item. For
lists of many thousands, `set` costs the least.

These were measured on Lune 0.11, which interprets Luau, and Node 24; every Luau module asks for native code (`--!native`) where a
host gives it.

A tree's order is read anew when anything in its shape changes, at some microseconds a node; what changes in its nodes is patched.

## How it is laid out

For anyone who would read it from another client. A document named *n* in a scope is the list named `mirror/` *n*. Its root is
the row whose id is the scope (4 bytes), four zero bytes, and the first eight bytes of SHA-256(the scope's list key ‖ `zsp-mirror`
‖ 0x00 ‖ *n* ‖ 0x00 ‖ *parts* joined by 0x00), with no parts but an empty one. A map within a map has the id made in the same way of
its owner's id and the field's name; a record's entry, of its owner's id, the field's name and the key; every other row a random one.

Slot 255 of every row says what it is in: the id of its owner (16 bytes), the field's name (bytes), a kind (1 byte), and then

| kind | | then |
|---|---|---|
| 0 | a map within a map, or the root | nothing |
| 1 | an item of a list | its marker (12 bytes) |
| 2 | an entry of a record | 1 if it is there, 0 if not (1 byte), and the key |
| 3 | a node of a tree | the node it hangs from (16 bytes, zero for the top), its marker, the node it was moved from, and its marker there |

A marker is an element of the text in the list's slot of the owner, or the tree's slot of the node a node hangs from: a piece
(8 bytes) and an offset in it (4 bytes, big-endian). Items go by where their markers are in that text, deleted or not, and then by
id. A list of values is the text itself: each value as bytes, its length first. An entry whose id is not the one its key makes is
not one.
