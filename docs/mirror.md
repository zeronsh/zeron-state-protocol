# Structured state

A document of maps, lists, records and trees, nested as deep as you like, with texts in them, held as plain Luau tables.
You set a new state; what differs is written. Others write; you are told the new state, in which whatever did not change
is the very same table as before, so that a view can skip it by identity.

It is built on nothing but rows, columns and lists. Nodes, relays, and the protocol do not know it is there.

```luau
local zsp = require("zsp")
local m = zsp.mirror

local Task = m.map({ title = zsp.string(16), done = zsp.boolean(17), notes = zsp.text(18), tags = m.list(zsp.string(19)) })
local Board = m.map({
	title = zsp.string(16),
	meta = m.map({ owner = zsp.string(16) }),
	tasks = m.list(Task),
	scores = m.record(zsp.number(16)),
	outline = m.tree(m.map({ name = zsp.string(16) })),
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
| `m.map({...})` | named columns, and whatever else is nested under other names | a table, with its `id` |
| `m.list(of)` | maps or values in an order; anything in it may be moved | an array. Maps keep their `id`: moving one is moving it, and one without an id is new |
| `m.record(of)` | maps or values by keys made up as you go | a table of string keys |
| `m.tree(node)` | maps, each with its `children`; any may be moved under any other | an array of nodes, each with `children` |
| a column | `zsp.string`, `number`, `boolean`, `row`, `custom`, `text`, `author` | its value |

A column is in one of slots 16 to 254 of its map; the maps of a document may use the same slots for different things.
Slot 255 is the mirror's own. Text columns are edited as texts: what you set is compared with what there was, and
written as an insertion and a deletion, so that what anyone else types meanwhile is kept. A nested map is always there,
empty or not; anything in a record or a list may be gone.

`board.set(state)` writes a whole new state; `board.update(f)` gives `f` a copy that may be changed, and writes that. A
state put together from the last one, sharing what did not change, is the cheaper: what is the very same table is passed
over without being looked at.

## When two write at once

Everything comes to one state everywhere, whatever order it arrives in.

- **Columns:** the later write wins, each column for itself. Two people changing different columns of one task both have their way.
- **Texts:** both are kept, as in any text column.
- **Lists:** both insertions are there. Of two moves of one item, the later. A deleted item stays deleted, whatever was done to it meanwhile.
- **Records:** of two who make one key at once, the later has it; the other's goes. Deleting a key deletes what was under it.
- **Trees:** of two moves of one node, the later. Two moves that together would make a loop, such as a under b and b under a, cannot both hold: the one made later goes back to where it was. A node moved under one that is deleted meanwhile is deleted with it.

## What it costs

Nothing, to anything but the client that uses it: what is stored, sent and merged is rows like any others, and a
document is one list, so one window, however deep it goes. On the client, `./x test` measures it, with two devices and a
document of 2,000 rows:

| | |
|---|---|
| making 2,000 rows | 60–120 ms |
| one change among them, written and read back, by `set` | 1.2–1.5 ms |
| the same by `update`, which copies the whole state to be changed | 2–3 ms |

What is read of a row is kept until it changes, and a list in which only some rows changed is patched rather than read
again. It still grows with the document, by less than a microsecond a row: for documents of tens of thousands of rows,
divide them.

Each item of a list is a row of its own, some 100 bytes or more when sealed. Lists of many thousands of small values are
better kept in one column, as JSON, where they need not be merged item by item.

## How it is laid out

For anyone who would read it from another client. A document named *n* in a scope is the list named `mirror/` *n*.
Its root is the row whose id is the scope (4 bytes), four zero bytes, and the first eight bytes of
SHA-256(the scope's list key ‖ `zsp-mirror` ‖ 0x00 ‖ *parts* joined by 0x00), with no parts but an empty one. A map
nested in a map has the id made the same way of the parent's id and the field's name; every other row a random one.

Slot 255 of every row says where it is: the id of the row it is in (16 bytes), the name of the field (bytes), its order
(an IEEE 754 double, big-endian), and then, in a record, the key; in a tree, the parent node (16 bytes, zero for the top)
and the one it was moved from. A list or a record's items, or a node's children, go by order and then by id. A
deleted item is a row with a grave. Columns hold what their kind writes; an empty value, but in a column of text or of
strings, is no value.
