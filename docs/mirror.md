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

## What is kept

Nothing that nothing shows. A deleted item or node is deleted, with everything in it. What others put in a row or a key while it was
being deleted is let go of by whoever next writes, as is any marker that no item has any longer. A record's key that has been let
go of keeps a row with nothing in it but its name, so that it can be set again, as the same key, by anyone.

## What it costs

Nothing, to anything but the client that uses it: what is stored, sent and merged is rows and texts like any others, and a document
is one list, so one window, however deep it goes. On the client, `./x bench mirror [rows]`, one list of maps:

| rows in the list | 2,000 | 20,000 |
|---|---|---|
| made, all at once | 90 ms | 1.1 s |
| one changed, by `set` | 0.3 ms | 1.8 ms |
| one changed, by `update` | 1.2 ms | 20 ms |
| one moved, by `set` | 0.9 ms | 8.6 ms |
| one moved, by `update` | 2.3 ms | 31 ms |

What is read of a row is kept until that row changes; a list in which items changed is patched where they are, and one in which items
moved has them taken out and put back where their markers say, the rest keeping their order, for the order of what is there never
changes. What is left that grows with a list is copying its array, which a new state must have, and, by `set`, looking along it for
what is not the very same table. `update` must also give `f` a list it can change with `table.insert` and `table.remove`, which do
not call metamethods, so a list it touches is copied whole, at a little under a microsecond an item. For lists of many thousands,
use `set`.

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
