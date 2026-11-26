# Zeron State Protocol, version 1

ZSP keeps ordered lists of rows the same on many devices, live, with or without a server, when the server may be
trusted with nothing. This document is enough to write a client, a relay or a full replica.
`vectors/vectors.json` pins every deterministic construction in it.

**Contents.** [1 Model](#1-model) · [2 Encoding](#2-encoding) · [3 Keys and the roster](#3-keys-and-the-roster) ·
[4 Cells](#4-cells) · [5 Text](#5-text) · [6 Fingerprints](#6-fingerprints) · [7 Channels](#7-channels) ·
[8 Sessions](#8-sessions) · [9 Watching](#9-watching) · [10 Reconciling](#10-reconciling) · [11 Live](#11-live) ·
[12 Calls](#12-calls) · [13 Relays](#13-relays) · [14 Links](#14-links) · [15 Questions](#15-questions) ·
[16 Streams and services](#16-streams-and-services) · [17 Names, ports and exposure](#17-names-ports-and-exposure) · [18 Who handles what](#18-who-handles-what)

## 1 Model

A **space** holds **scopes**; a scope holds **lists** and **rows**; a row is a set of **cells**.

A cell is one immutable write: `(row, slot, kind, stamp, body)`. Merging two replicas is uniting their cells and
applying one rule:

> **A cell kills every other cell in its reach.** A `Grave` reaches its whole row. A `Place` or `Value` reaches
> everything in its slot with a lesser stamp. A `Bundle` reaches exactly the stamps it names, in its slot. A `Piece`
> reaches nothing. What has been killed is discarded, and refused if offered again.

The rule is commutative, associative and idempotent, and needs no key: a replica that cannot read merges as well as one
that can. Once a `Grave` is present, only a `Grave` with a greater stamp is accepted for that row.

A row is *shelved* in a list by a `Place` cell naming the list and a 64-bit order. There are fifteen place slots, so a
row may be in fifteen lists at once; moving it is one write. Entries of all lists form one ordered index:

```
key = list (16 bytes) ‖ order (8) ‖ row (16)          40 bytes, compared bytewise
```

Everything else is a range of that index. A list is a range. A page is a range. A scope is a range. What a device is
subscribed to is a set of ranges, and bringing two replicas level is comparing ranges.

| identifier | layout |
|---|---|
| scope | 32 bits, 1 … 2³²−2 |
| row | scope (4) ‖ its maker's clock at creation, in seconds (4) ‖ random (8) |
| list | scope (4) ‖ tag (12), where tag = SHA-256(list key ‖ name)[0..12]. Tag zero is the scope's graveyard |
| stamp | time (8) ‖ salt (8). time = milliseconds since 1970 × 2¹⁶ + counter; salt is random |

A row may be shelved only in lists of its own scope. A row with a `Grave` is shelved in its scope's graveyard at
order = the grave's stamp time, and nowhere else. A row with no `Place` and no `Grave` is nowhere, and invisible, until
it has one.

**Stamps.** A writer's clock is `max(clock + 1, now)`, where `clock` also advances past the time of every stamp seen. Every
cell gets its own time and fresh salt. A stamp is at once a cell's version, its tie-break and its AEAD nonce, so it must never
be reused; because the salt is drawn anew from the operating system, even a forked virtual machine does not. Times at or
above 2⁶³ are invalid. A stamp more than fifteen minutes ahead of the receiver's clock ends the session with *clock*: one of the two is wrong by
more than can be allowed for, and dialling again will do once they agree. **Nothing is older than its row**: a cell whose time is before the first
moment of its row's creation second is invalid, whatever its kind. So whoever may no longer write, and can only pretend to have written earlier,
cannot touch any row made since by one who had heard. A row with a well-known id has creation time zero.

**Slots.** 0 grave, 1–15 places, 16–255 data. Slots are the application's columns.

| kind | | slot | clear prefix of body |
|---|---|---|---|
| 1 | Grave | 0 | none |
| 2 | Place | 1–15 | list (16) ‖ order (8) |
| 3 | Value | 16–255 | none |
| 4 | Piece | 16–255 | none |
| 5 | Bundle | 16–255 | n (4, ≥ 1) ‖ n stamps (16 each), strictly ascending |

Every stamp a bundle names is less than its own, and none is older than its row. A bundle that names a bundle must also name everything that one names. It kills, and
refuses, pieces and bundles only. A sealed body is at most 2²⁰ bytes; before sealing, clear prefix included, at most 2²⁰ − 192.

## 2 Encoding

Integers are big-endian unless said otherwise. `varint` is unsigned LEB128, at most ten bytes; redundant padding is legal.
`bytes` is a varint length and that many bytes.

`key` is one byte *n* ≤ 40 and the first *n* bytes of the key, the rest being zero; *n* = 255 means 40 bytes of 0xff, an upper
bound past everything. `delta key` is one byte *n* ≤ 40, the count of leading bytes shared with the previous key (initially
zeroes), and the remaining 40 − *n*.

```
cell  = tag (1) ‖ [row (16)] ‖ slot (1) ‖ stamp (16) ‖ body (bytes)
        tag = kind, plus 0x80 and no row if the row is the previous cell's
frame = length (varint) ‖ type (1) ‖ payload          length counts type and payload, ≤ 2²²
```

A pipe carries frames as a byte stream in any fragmentation. Unknown frame types are ignored. The cells of one frame, each counted as 48
bytes and its sealed body, come with 8 more to at most 2²³.

## 3 Keys and the roster

HKDF is RFC 5869 with SHA-256 and one 32-byte block; `derive(k, info)` = HKDF(salt = none, k, info).

A **device** is an X25519 key pair, from which: Ed25519 seed = derive(secret, "zsp-sign").
A **space** is an Ed25519 key pair; its public key is its name, 32 bytes. Whoever holds the private one **owns** the space, and nothing can take
that back. Its owners name **admins**, who govern it day to day, and can be unmade.

The **charter** says who owns and who administers, and is signed by the space:

```
term varint ≥ 1 ‖ ephemeral (32)
n varint, n × owner   { device (32), signer (32), wrap (48) }      the space's signing seed, wrapped as below with nonce 0
n varint, n × admin   { signer (32) }
signature (64, Ed25519 over "zsp-charter" ‖ space ‖ everything before it)
```

The **roster** says who may do what. It is a document signed by the space or by an admin the charter in it names:

```
"zsp-r1" ‖ space (32) ‖ charter bytes ‖ serial varint
n varint, n × scope   { id varint, flags (1), epoch varint ≥ 1,
                        (epoch − 1) × closed varint,                         ascending ids, ascending times
                        epoch × commitment (32) }                            commitment = derive(key, "zsp-commit")
n varint, n × member  { device (32), signer (32), subject bytes,
                        n varint, n × grant { scope varint, rights (1), until varint } }
n varint, n × relay   { key (32), url bytes }
ephemeral (32)
wraps (48 each)   history (48 each)
by varint              0 the space, else the charter's admin of that number, from 1
signature (64, Ed25519 over everything before it)
```

A serial is term × 2⁴⁴ + count × 2²⁰ + 20 random bits, its term being the charter's. Of two valid rosters the higher serial wins: a new charter
outranks whatever was signed under an old one, however high it counts; and of two rosters drawn up at once, all agree which it is, and the other's
change is to be made again. An admin carries the charter over untouched, and must hold every scope's keys. With all but the charter an admin is
trusted: who is who, who may do what, and when that ended.

But no admin can shut an owner out. A roster is invalid unless every owner in its charter is a member, with the charter's signer, and Read and Write in force
in every scope. No two members share a device or a signer. A key that does not match its commitment is as good as none; a device keeps, sealed for itself, the keys it
has learnt, so that nothing garbled later takes them away; and an owner signs although a key was kept from it, declaring that epoch **void** by
closing it no later than the one before (the first, at 0), with 32 zero bytes for its key in `history`. Nothing sealed under a void epoch is acceptable; what honest
members sealed under it they seal again.

Rights are bits: 1 Read, 2 Write, 4 Call, 8 Vouch: to be believed about for whom one writes and calls (§4, §12), 16 Shell and 32 Files: to use what devices share of themselves in the scope (§16). Every grant includes Read. Scope flag 1 is **signed**; a grant without Write is
invalid in a scope that is not signed. `until` is zero for a grant in force, and otherwise the stamp time at which it ended;
a member has at most one in force per scope. Taking Write away ends the grant and adds another, so that what it allowed stays allowed; and so does taking Vouch away in a signed scope. `closed`
says when each earlier epoch ended. Both should be no less than any stamp the signer has seen. No device appears twice.
`subject` is the consumer's name for whomever the device belongs to, opaque here. A roster that names any device begins `"zsp-r2"`
in place of `"zsp-r1"`, and each member's subject is followed by its **name** bytes, empty or one DNS label: 1 to 63 of `a`–`z`, `0`–`9` and
`-`, with no hyphen at either end. No two members share a name; a name goes with its member's last grant (§17). A roster that names nobody
is `"zsp-r1"`, as it always was. A roster is at most 2²² − 64 bytes. Members are never removed, only their grants
ended, so that a member's index is for ever.

**Scope keys.** Each scope has a 32-byte sealing key per epoch. For each member in order, for each grant in force in order,
`wraps` holds 48 bytes: ChaCha20-Poly1305 under

```
wrap key = HKDF(salt = SHA-256(ephemeral ‖ device), X25519(ephemeral, device), "zsp-wrap")
nonce    = 0 (4) ‖ scope (8)
```

of the scope's current sealing key. For each scope in order, `history` holds its earlier epochs' keys in order, each
ChaCha20-Poly1305 under derive(current key, "zsp-history") with nonce 0 (4) ‖ epoch − 1 (8). A scope's **list key** is
derive(first epoch's key, "zsp-list").

Ending a grant must raise the scope's epoch, but for one in a signed scope that only loses Write or Vouch. Admitting a device need not.

## 4 Cells

A cell at rest and in transit between devices is **sealed**. Its body is

```
clear prefix ‖ [author varint] ‖ key id (4) ‖ ciphertext ‖ tag (16) ‖ [signature (64)]
```

XChaCha20-Poly1305 under one of the scope's keys, the id being the first 4 bytes of its commitment, with nonce = stamp (16) ‖ slot ‖ kind ‖ 0 (6), and associated data =
row ‖ slot ‖ kind ‖ clear prefix. The bracketed parts exist in signed scopes: author is an index into the roster's members, and
the signature, by that member's signer, covers row ‖ slot ‖ kind ‖ stamp ‖ body short of the signature. In a signed scope the plaintext is
`as` (bytes, at most 64) ‖ what was written: for whom its author wrote it, if for another than its device belongs to, and otherwise nothing.

**Whose a cell is**, in a signed scope: that of whom `as` names, if a grant of the author's there includes Vouch, with `until` zero or no less than when it was written, and `as` is not
empty; otherwise its author's `subject`. Nothing is refused over it, and a relay sees none of it. In an unsigned scope a cell is nobody's. A host says for whom a local client is as it accepts it, and a node writes nothing there for
anybody else without Vouch: that is *denied*. What is sealed again keeps its `as`.

A replica accepts a cell from a peer only if

- its scope is in the roster, and its key is one of the scope's and not void; and
- in a signed scope, some grant of the author's there includes Write, with `until` zero or no less than the time it was written, and the
  signature verifies; in an unsigned one, the *sending session* has Write there (a relay one dialled counts as having it), and the key is the
  current one, or the stamp time no greater than its epoch's `closed`; and
- where the replica holds the scope's key, the seal opens. Otherwise garbage could win by claiming a late stamp.

A cell was **written** at its stamp time, but a bundle when the first of what it names was: its author may put together what it had a right to write after that right has ended,
as may well be before it hears. Whoever opens a bundle in a signed scope passes over what its author had no right to write at that stamp's time, or has none now.

In a signed scope authority travels with the cell, so anyone may carry it. In an unsigned scope, to hold the key is to be a writer.

On adopting a roster, and on starting with one it has not yet held its cells against, a replica looks again at cells later than any epoch or grant
it ends. In an unsigned scope, one that is no longer acceptable is sealed again, with the same stamp, under the key in force at that stamp's
time, by a replica that can open it, since someone may merely not have heard; in a signed scope, by its author alone, for a void key; otherwise it is dropped.
A roster that does not extend the one held (a prefix of whose members, grants, keys and times it keeps) won over it: then everything held is looked at. A partial replica that may have written there offers again
all it holds in that scope, for who took it may be gone. Then, whatever the roster changed, each device watches afresh, partial ones under new ids. A device's clock moves past
the end of everything that has ended, but for what is too far ahead. Where a cell is
held already, another body for the same identity is ignored.

So: a revoked device can open nothing sealed afterwards; nobody who has heard accepts what it writes later; and no row made later can be touched by it,
whatever time it pretends and whoever carries it. To rows older than its revocation it can still put new writing with an earlier time, deletions included,
for no clock here is trusted: it could as well have done so while it might. In an unsigned scope, what it gave to someone who had *not* heard stands, since
nobody can tell it from anyone else's; in a signed one it is dropped when they hear, though not what it had meanwhile killed on every replica there
is. Revocation ends access and bounds damage; it does not undo the past. List tags do not change on rotation, so a revoked device can still
recognise them.

A relay sees: scopes, list tags, orders, stamps, sizes. It can order and page; it cannot read, name, move, alter or forge.
Orders are public to it, so derive them from time or rank rather than content.

## 5 Text

A slot holding text is at most one `Value` (a whole text) and `Piece`s and `Bundle`s with later stamps. The text is a function of
that set alone. Elements are UTF-8 bytes; applications edit at character boundaries.

A piece's open body is id (8, random, nonzero) ‖ operations. A bundle's, after its clear prefix, is any number of
stamp (16) ‖ id (8) ‖ operations (bytes), ascending by stamp. A `Value` acts as a piece whose id is its salt, or 1 if that is zero, and whose one operation
inserts its body into an empty text.

```
1 Insert   left ref, right ref, bytes       new elements of this piece, numbered on from its last
2 Extend   bytes                            as Insert, with left = this piece's last element, right = as its last insertion's
3 Delete   first ref, count varint          count elements of one piece, consecutive
ref = 0 (the edge) | 1 offset varint (this piece) | 2 piece (8) offset varint
```

`left` and `right` are the neighbours, deleted ones included, at the moment of typing. Every element hangs in a tree whose root is the start
of the document, by what its own operation says and nothing else (Fugue). The first element of an insertion hangs on the left of `right` if `right` is an
element, other than `left`, that hangs beneath `left`, however far down (everything hangs beneath the start); and otherwise on the right of `left`.
Each further element hangs on the right of the one before it. The text is the tree read in order: for each element, what hangs on its left, then itself,
then what hangs on its right; what hangs on one side, each with all beneath it, in order of piece id and then of number. Whatever anyone says of
neighbours, then, the text is a function of the set of pieces alone, and where they were honest the insertion is where it was typed. Operations apply in
order within a piece; one that refers to what is not yet present waits, with the rest of its piece, until it is. (Two open pieces may refer to each
other, so pieces are never applied all-or-nothing.)

Nobody need walk the tree: siblings, each with all beneath it, lie one stretch after another, so a place is found by halving; and an ancestor at any
depth is a few steps away by jump pointers (Myers). So here an insertion costs a few logarithms of the text's length, however its writers shaped it.

A long text need not be a great many cells: whoever may write a piece may bundle it, at any time and however often, and nothing about the text is changed by it. (Here a node that has just written a piece bundles those
that are loose once there are 128, and bundles of about a size once there are 16; in a signed scope its own, and those of one `as`, so that whose they are stands; with a stamp just after the last of them.)

If two stamps claim one piece id — two writers that were once one virtual machine — the lesser keeps it and the other piece's id
becomes its salt.

A piece being written may be streamed (§11) and integrated as it arrives; when its cell arrives, what was already applied is
skipped, provided it is the same bytes.

## 6 Fingerprints

```
print(cell)  = first 16 bytes of SHA-256(row ‖ slot ‖ kind ‖ stamp), as two 64-bit integers
print(row)   = the sum over its cells, each half modulo 2⁶⁴
print(range) = the sum over entries of the index in it
```

An implementation with a counting tree answers any range in logarithmic time, and the same tree finds the *n*th entry before a key.

## 7 Channels

Between devices, and between devices and relays, a pipe is wrapped in `Noise_IK_25519_ChaChaPoly_SHA256` with prologue
"zsp-1" ‖ space. The first message's payload is 8 bytes, zero but over links (§14); the second's is empty. The dialler knows the other's key: from the roster, or from whoever told it of the relay.

Over WebSocket, each binary message is one Noise message: 104 bytes, 48 bytes, then transport messages of at most 65535 bytes, whose
plaintexts concatenate into the pipe. The path is `/` and the space in hex. A message may come in several frames. A text message `ping` is
answered with `pong`, and nothing else is said in text: an idle connection must be heard from, and a browser cannot send a WebSocket's own
ping. TLS, where used, is for traversal; certificates need not be judged, for nothing rests on them, and no credential may be put where TLS
alone protects it.

A **local client** speaks to its own device's node in the open, over a pipe the host trusts (loopback, a socket pair, shared memory):
over WebSocket, at path `/`, without Noise. A node must refuse such a request that carries an `Origin` header unless told otherwise.

## 8 Sessions

A session is between **peers** (sealed cells, over a channel) or between a node and a local client (**open** cells, whose bodies are the
clear prefix and then plaintext; the node seals and opens on its client's behalf, and draws no stamps for it).

Each side first sends

```
1 Hello    version = 1 (1) ‖ flags (1: 1 full replica, 2 relay: which only confirms what the dialler knows; 4, of a local client, that it is told whose cells are; 8 calls) ‖ space (32) ‖ roster serial varint ‖ credential bytes
```

A session between peers with flag 8, a **calls session**, carries Hello, Roster, Call, Flow and Error and nothing else: it is begun over a link a relay
carries (§13), which carries everything else already. Both ends say 8, or the session ends *denied*.

The accepting host decides from the credential and the proven key whether to serve the connection (§15); until it has, later frames
wait. Then, between peers, whichever has the newer roster sends it (one no older than it said, or the session ends), and each verifies that the other is a member with a grant in
force, or is a relay it chose to dial:

```
2 Roster   the document                                                       between peers
           clock (8) ‖ n × { scope varint, rights (1, and 128 in a signed scope), list key (32) }
                                                                              to a local client: what it may do, and what it needs to
17 Author  number varint ‖ device (32) ‖ subject bytes                        to a local client that asked: whom a number is for from now on
```

Whose a cell is follows it, to a local client that asked: 0x40 in its tag, and after its body the number (varint) of an Author said before. Number 0 is the client itself, said ahead of all else and again
whenever the roster changes. When the roster changes whose anything is, all that is watched is sent again, under new numbers.

A roster that arrives later is adopted likewise, at any time, from anyone; its signature is its authority. Sessions it no longer allows end, and a
device it no longer allows gives up its keys.

```
7 Cells    sequence varint ‖ cells       applied atomically, in order
8 Ack      sequence varint ‖ rows (16 each)   everything up to here is durable, but that something of these rows was not accepted
13 Error   code (1): 1 malformed, 2 denied, 3 version, 4 failed, 5 clock.  The sender closes.
```

A peer that is a full replica is sent everything its dialler commits. Otherwise a session is sent what it watches. A partial replica keeps owing a row
named in an Ack.

If an offered cell was refused because something had killed it, the receiver sends back the row as it has it: the sender held something
old and would not otherwise hear.

## 9 Watching

```
3 Watch    id varint ‖ flags (1) ‖ lo key ‖ hi key ‖ limit varint ‖ [count varint ‖ print (16)]
           flags: 1 data, 2 live, 4 back, 8 adopt, 16 known, 32 counts
4 Unwatch  id varint
10 Synced  id varint ‖ flags (1: 1 settled, 2 restart, 4 denied) ‖ lo key ‖ hi key ‖ before varint ‖ after varint
```

A watch subscribes to `lo ≤ key < hi`, within one scope; another with the same id replaces it. With a nonzero limit the owner moves `lo` up
(if *back*) or `hi` down so that at most that many entries lie within. The watcher learns the result, and how many entries of the list lay
before and after it at that moment, from Synced, which follows everything the watch was owed. A page before this one is a watch whose `hi` is this one's `lo`. A local client may have 1024
watches standing, and a peer 16384.

With **data**, the owner brings the watcher level and then sends changes as they commit. *known* gives the watcher's own count and
fingerprint of the range: equal, and there is nothing to send; a count of zero, and the owner sends everything; otherwise they reconcile. A
local client may omit it and be sent everything. With *adopt* the watcher is already level, as when it splits one range into two.

A row that comes into a watched range is sent whole. So is one that moves while any watch on it has yet to sync, for it may have
slipped from a part not yet compared to one already passed. A row that was nowhere comes into every range at once. A row that leaves is sent the cell that moved it. Cells that arrived ahead of their
row's first place become visible with it, and the row is then sent whole to everyone, its sender included.

An owner that cannot keep up may drop what it owes a watch and instead reconcile it afresh; to a local client it says Synced with *restart*, resends
the range, and says Synced again: rows not mentioned between are gone. *settled* says that a full replica has confirmed the range, or that none can
be reached. Before honouring Unwatch, an owner sends what it committed while the watch stood. When a grant
ends, its watches end with Synced *denied*; to a local client, a new Roster comes first.

A **full replica** watches, on each session it dials, every scope it can read, whole. A **partial replica** watches what its local clients watch, and
keeps what it wrote on record until a full replica acknowledges it. When all a dialler's whole-scope watches are level, and it has sent all the other
lacked, it says so: Synced with id 0, settled, empty keys and zero counts. The other heeds it from a full replica that has such a watch here. When the
roster changes, all of these are asked for afresh: either end may have dropped one under a roster the other never heard.

With *counts* the owner says Synced again whenever, after a burst of changes, how much lies before or after differs from what it last said. A
partial replica relays to its client the bounds and counts a full replica gives it, closing the window to those bounds, for what it holds
beyond them may have gaps.

## 10 Reconciling

```
5 Recon    id varint × 2 + (1 if sent by the owner) ‖ lo key ‖ parts
           part = hi key ‖ 0                                   level, or being dealt with
                | hi key ‖ 1 ‖ count varint ‖ print (16)       what I have here comes to this
                | hi key ‖ 2 ‖ count varint ‖ count × { delta key, first half of the row's print (8) }
6 Want     final (1) ‖ n varint ‖ n × { row (16), n varint, n × { kind (1), slot (1), stamp (16) } }
```

Parts are consecutive ranges from `lo`, within one scope; keys in a list ascend strictly within their part; the unmentioned remainder is level. A
reply is kept short, about 128 KiB: what it has no room for it returns as one part of type 1, to be gone into next time. The owner begins; the sides alternate; the watcher
always replies; the owner, on a reply with no parts, says Synced. A receiver answers each part of type

- **1** that equals its own with 0; that counts zero with 0, after sending all it has there; otherwise with a list if it has no more
  than 32 entries, the same type 1 if the other has that few, or type 1 for each sixteenth of its own entries;
- **2** with 0, after sending each row the other lacks (if the other would keep it), and wanting each row it lacks or that differs.

Want means: here is what I hold of these rows; send the rest. (A row of very many cells may be given as holding none.) If the sender of Want holds what the receiver would accept, the receiver
wants the row in turn, with *final* set, which is not answered so. Wants are sent before the Recon they arise from.

## 11 Live

```
9 Live     row (16) ‖ slot (1) ‖ piece id (8) ‖ offset varint ‖ stamp (16) ‖ body
```

Operations of a piece still being written, from a byte offset in its operation stream, always whole. They are hints: never
stored, never acknowledged, droppable at any point. A gap is ignored; the piece itself will follow. Between peers the body is
[author varint] ‖ key id ‖ ciphertext ‖ tag ‖ [signature], the brackets in signed scopes, sealed as in §4 under a fresh stamp with kind 0x40 and associated
data *a* = row ‖ slot ‖ piece ‖ offset (8); the signature covers *a* ‖ 0x40 ‖ stamp ‖ the body short of it. Only the current key is accepted, only an author whose right to write is in force, and no stamp more than a minute
behind the latest the receiver has seen, nor sixteen behind its clock. From a local client the stamp is zero, and the body at most 2¹⁶ − 128 bytes; between peers it is at most 2¹⁶.

Live frames go only to watches with **live** that cover the row. A node forwards its clients' live watches to its peers, and a relay
forwards each device's to the others, so a frame nobody will see is never sent. A node does not forward between peers unless it is a relay. A
writer seals a piece within about a second of beginning it; a reader drops live text unconfirmed for ten. Since frames from the middle of a
piece are of no use to a reader that missed its start, a node that is not a relay keeps each open piece it sees from its start,
as far as it goes on unbroken: its own clients' typing, and, piece by piece whatever road it came by, what peers send it. It
forgets one when the piece is sealed, alone or bundled, a value is written over its slot, its row is deleted, or ten seconds pass without more (at
most 16 KiB of each, and 64 pieces). A session is sent what it watches of them, or what is in a row its client is shown, whole
from offset 0: once it has been sent the rows it was owed, as when a new live watch, a client's answer, a row it did not hold, or
a row moved to where it watches brings it the row; and once its pipe has room, as after a frame it was due was dropped for want of it. Its own clients' typing
goes to peers under a fresh stamp; what peers sent goes only to its own clients. So whoever begins to look, or whose watch is
slow to arrive, or whose pipe was full, sees the rest as it is typed.

## 12 Calls

```
14 Serve   scope varint ‖ 1 or 0 ‖ method bytes                             a local client offers a method, or ceases to
15 Call    id varint ‖ device (32) ‖ scope varint ‖ method bytes ‖ for whom bytes ‖ first message
16 Flow    id varint × 2 + (1 if sent by the callee) ‖ kind (1) ‖ payload
           0 Data (message) · 1 End · 2 Fault (code (1)) · 3 Cancel · 4 Credit (varint bytes)
12 Presence   to a local client: n × { device (32), subject bytes }, this device first, then all it can reach
```

A call is a stream of messages each way. `device` is the callee's on the way out and the caller's on arrival. For whom is at most 64 bytes: what a client says of that is disregarded, and its node says whom its host accepted it for, or nothing; the
last node tells its own client the same if the calling device has Vouch in that scope, and otherwise the device's `subject`. Who may not vouch may not call for another: *denied*. Ids belong to whoever sent
Call on that session. A call ends when both sides have sent End, or on Fault or Cancel. Each side may have 256 KiB of messages outstanding beyond what the
other has credited, and may be credited ahead of what it has sent up to 4 MiB; the first message counts. One message is at most 256 KiB, and a method's name from 1 to 255 bytes (§15 has the use of none).
Names beginning `zsp.` are for devices' hosts themselves (§16): a client's Serve of one is passed over, and a call to one is the host's to answer.

What a node committed before a call it sends on its way before it, and so does a relay: whoever is called has what the call is about, unless so much was committed at once that one of them has to
compare afresh (§9). Both devices need the Call right in the scope, and both check. A call takes a direct session with the device if there is one, one that
replicates before a calls session, else a calls session over a link through a relay both are present at (§13), begun for it. It
stays on the session it began on: if that fails the call faults *lost*, and may or may not have happened. Faults: 1 denied, 2 unreachable, 3 unserved,
4 lost, 5 overrun, 6 busy. A relay may call a device that dialled it by the method `zsp.public` in scope 0, and by nothing else; no grant governs such a call.

**Lanes.** Over a link (§14) each call has a stream of its own, its **lane**, opened by whoever sends Call on it, which carries that call's Call and Flow
frames and nothing else, each way. A lane's first bytes each way say how many bytes of the session's own stream (stream 0) its sender had produced
before them, so that what was committed before a call is still had before it. Frames on a lane are taken only once the session is ready. A lane is
finished by each side once its call is over for it; one given up (Reset) loses its call. Lanes are opened with an urgency, 0 most urgent to 7 least,
which a host takes from the method (§16) or, passing a call on, from the lane it came by.

## 13 Relays

A relay is a full replica without keys. It verifies rosters, enforces rights, merges, pages, reconciles and forwards; it serves each space separately. Which peer
is a relay is never the peer's to say: it is one whose key was dialled as a relay's. A relay should store nothing for a space until someone its host accepts has something to store.
Where it keeps what it holds is its own: no peer can tell, provided that what it has acknowledged survives it, and that it answers as a full
replica would, if later. (The relay in relay/ keeps each space in object storage, with its object's own storage as a cache: see
docs/relay-storage.md.)

```
12 Presence   n × device (32)                    from a relay: who else is here
11 Signal     device (32) ‖ kind (1) ‖ blob      to a relay: to whom. From it: from whom
```

| kind | blob |
|---|---|
| 0 | stamp (16) ‖ XChaCha20-Poly1305 under derive(X25519 of the two devices, "zsp-signal"), nonce stamp ‖ 0 ‖ 0x41 ‖ 0 (6), associated data from ‖ to |
| 7 | a link's packet (§14), as over UDP |

Others are passed over. Devices with no direct link reach each other by a **link through a relay**: the same link as over UDP, its packets in signals
of kind 7, taken only from members and only through a relay the receiver dialled. Whoever has a call to make and no session for it dials; the other
answers. Over it runs a calls session (§8). Its packets are at most 8192 bytes; it needs no probing of its path's size, and no NAT keeps it. A
packet that comes newest yet by another relay both are present at moves the link there, and an end whose relay has gone, or whose peer has gone
from it, sends by another: a link outlives a relay, and its calls with it. A link whose calls have been over for 30 seconds is closed.

A relay keeps nothing for a link and may drop any of its packets, as a router does; it must drop them rather than hold more than 256 KiB for a
device, beyond which they would only wait. What it holds is what its connection to the device would not yet take, so packets that came
together, as a window's worth does, are not dropped for that alone. The link sends them again and slows. Nothing else that it carries may it drop.

While every other device present at a relay is a full replica with a settled direct session, a device may end its watches there (it goes on sending), and must
watch afresh when that ceases to be so.

## 14 Links

A link is ordered byte streams and datagrams (live frames) over UDP, or through a relay (§13). First byte: 0x40 punch (ignored), 0x41 first (sender's id (4, little-endian) ‖ Noise 1),
0x42 second (sender's id ‖ receiver's id ‖ Noise 2), 0x43 data (receiver's id ‖ counter (8, little-endian) ‖ ciphertext, the 13 bytes before it being
associated data), 0x44 beacon. Anything lower is STUN. The source of a genuine data packet newer than any before it is thenceforth the
peer's address; a packet seen before, or too old to tell, is dropped. A live link gives way to a new knock only when that proves itself with data.
The payload of Noise 1 is a stamp time drawn by the dialler, and a knock no later than the last from that device is ignored: anyone may have kept an old one.

Data frames:

```
0 Pad       to the end
1 Ping
2 Ack       largest varint ‖ delay varint (µs since the largest came) ‖ run varint ‖ n × { gap varint ‖ run varint } ‖ 0
3 Stream    id varint ‖ offset varint ‖ bytes
4 Datagram  bytes
5 Close
6 Fin       id varint ‖ offset varint ‖ bytes                   as Stream, and its last bytes
7 Reset     id varint ‖ final size varint                       its sender gives it up
8 Stop      id varint                                           its receiver wants no more of it: the sender resets it
9 Window    id varint ‖ highest offset permitted varint
10 Limit    highest sum of offsets permitted varint ‖ streams the peer may have opened varint
```

Runs count downward from the largest. Loss recovery is RFC 9002's, less the delay a peer says it held an acknowledgement for, up to 25 ms; congestion
control is the sender's affair. A packet that is not wholly understood, or that there is no room for, goes unacknowledged. A link with nothing in
flight sends nothing.

Streams are numbered: 0 is open from the start, and the dialler opens 2, 4, 6 … and the other 1, 3, 5 …, each the next of its own, implicitly by its
first frame. Each other stream's first bytes, each way, are a header: urgency (1) ‖ after varint: it is delivered no earlier than `after` bytes of
stream 0 have been, from the same sender. Offsets count the header. A stream is over for its sender once its Fin or Reset is acknowledged, and for
its receiver once all before its end is delivered or a Reset came; when both, it is let go of, and frames for it later are acknowledged and passed over.
A peer may have opened 256 streams at first, and as many more as are let go of, by Limit.

Flow control is per stream and for the link: what a stream may send beyond what its receiver has delivered of it, at first 256 KiB, and what all
of them may together, at first 1 MiB, the highest offset ever sent of each counted, a Reset's final size included. A receiver raises each when half
of it is used and may double it, to 16 MiB and 32 MiB, while raising it again within two round trips. Of the link's window 64 KiB is kept for streams
of urgency 3 or below. A sender should serve streams most urgent first, and within an urgency give a turn of a packet to each, first to those that
had lately nothing to send. Out-of-order data, held, is bounded by these windows.

The device with the lesser key dials. Devices that share a relay swap candidate addresses, 18 bytes each (IPv6 or mapped IPv4, then port, big-endian), in signals of kind 0, and
both send to all of the other's at once. On a local network a device broadcasts from its link socket, at start and a few times soon after, to UDP port 9083, and a device that hears it and should be dialled answers that socket with the same: 0x44 ‖ salt (8) ‖
XChaCha20-Poly1305 under derive(space, "zsp-beacon"), nonce 0 (8) ‖ salt ‖ 0 ‖ 0x42 ‖ 0 (6), of device (32) ‖ link port (2, big-endian), no associated data.

A link over UDP through a NAT is closed after 25 idle seconds, before the NAT forgets it, and dialled again when there is something to say. While a call is under
way on a link, an end that has said nothing on it for 15 seconds pings; and so does one whose relay says that the device has gone.

## 15 Questions

A local client asks its node for rows by what is in them. Nothing is written or replicated for it and no relay takes part: what answers is an index a
node makes for itself of what it holds, and may throw away. A node need not answer questions; one that does not ignores them.

```
32 Ask      id varint ‖ question             stays asked; another with the same id replaces it
33 Unask    id varint
35 Fetch    id varint ‖ question             answered once
34 Answer   id varint ‖ flags (1)
            flags 1 settled, or 0:   total varint ‖ first varint ‖ n varint ‖ n × row (16) ‖
                                     m varint ‖ m × { some (1) ‖ number (8) ‖ k varint ‖ k × { count varint ‖ value bytes } }
            flags 2 denied, 4 faulty:   nothing follows, and it is asked no longer
            flags 8 waiting:            hundredths (1), of an index being made
            flags 16 ended:             to Unask
            flags 32 or 33:             as 0 or 1, and the only one, to Fetch
```

An Answer follows whenever it differs from the last. `total` is how many rows there are, `first` how many of them come before those shown. Rows not shown
before in any answer are sent whole, in Cells, directly ahead of it, with no other Answer between; what changes in a row shown, and live text in it, is sent as for a watch. A client therefore
keeps a row while any answer shows it, those of a question it replaces until that is answered, and those of one it ends until that is said to be *ended*, for
an answer on its way may count on them.
A Fetch is answered as an Ask is, once, when the index has been made and what the node had committed by then is in it, and is over: the rows it shows are not
kept up. *settled* says that a full replica gave the answer; otherwise it is true of what is held here. A client may ask about scopes it may read, in every part of a
question; one that asks about others is *denied*, as is one whose right ends.

```
question    scope varint ‖ where ‖ n varint ‖ n × order ‖ from end (1) ‖ offset varint ‖ limit varint ‖ m varint ‖ m × total
order       0 ‖ descending (1) ‖ column        by a value. Rows with none come last either way
            1 ‖ descending (1)                 by how well they answer, best first
            2 ‖ descending (1)                 by when they were made, and within a second by the rest of their ids, so that nothing after it matters
total       function (1: 1 sum, 2 min, 3 max, 4 count, 5 facet) ‖ column ‖ top varint
column      kind (1) ‖ slot (1) ‖ path bytes   kinds 1 to 6
            7 created, or 8 modified           in seconds
            9 ‖ list (16)                      the row's order there
            10 ‖ slot (1)                      whose what is in the slot is
```

| kind | a value is | and is written |
|---|---|---|
| 1 bytes | what the slot's Value holds, compared bytewise | as it is |
| 2 fold | the same as text, without case or the marks over letters | as it is |
| 3 number | eight bytes of it, as a float, or a number in JSON | f64, big-endian |
| 4 bool | one byte, or a boolean in JSON | 0 or 1 |
| 5 id | sixteen bytes of it: another row | 16 bytes |
| 6 words | the words of the slot's text or Value | – |
| 7, 8 | when the row was made, by its id; its latest stamp | f64 |
| 9 order | its order in a list | u64, big-endian |
| 10 author | whose each cell in the slot is (§4), compared bytewise; none for those that are nobody's | as it is |

With a path, the slot holds JSON and the path, names with dots between, says where in it; an array on the way stands for all it holds. A row may thus have many
values, and a condition holds for it if it does for one of them. Ties in the order are settled by row id, the least first. An order by column kind 7 is order 2. A row that is nowhere (§1) is not there to be asked about. With *from end* the offset and limit count back
from the last row. A number is meaningful where `some` is 1: for count, how many rows have a value; for facet, how many different values there are, the `top`
commonest of which follow with how many rows have each; for min and max, the value itself follows too.

| where | | |
|---|---|---|
| 0 | | every row |
| 1, 2 | n varint ‖ n × where | all of them, one of them |
| 3 | where | not |
| 4 | column ‖ flags (1: 1 lo, 2 hi, 4 lo itself, 8 hi itself) ‖ [lo bytes] ‖ [hi bytes] | from lo to hi; not kind 6 |
| 5 | column ‖ n varint ‖ n × bytes | one of these; not kind 6 |
| 6, 7 | column ‖ bytes | begins with, contains; kinds 1, 2 and 10 |
| 8 | column | has a value; not kind 6 |
| 9 | list (16) | is in a list |
| 10 | column ‖ mode (1: 0 every word, 1 any, 2 a phrase) ‖ flags (1) ‖ text bytes | matches; kind 6 |
| 11 | n varint ‖ n × row (16) | is one of these rows |
| 12 | column ‖ scope varint ‖ where | refers, by a column of kind 5, to a row of a scope that … |
| 13 | column ‖ scope varint ‖ min varint ‖ max varint ‖ where | is referred to, by a column of kind 5 of a scope, by so many rows that … |

The flags of a match: 1, the last word may be only begun; 2, words may be parts of words; bits 2 and 3, how many letters of a word may be wrong, of one of three to
five letters at most one. A word is a run of letters and digits, without case or marks, the first 64 bytes of which count; an apostrophe between letters is
passed over; scripts that write no spaces are taken in overlapping pairs. How well a row answers is Okapi BM25 (k₁ 1.2, b 0.75), its sole use being an order.

A question has at most 8 orders, 64 totals, none of kind 6, sums only of kind 3, 4096 conditions 32 deep, and 4096 bytes of text to match, or it is *faulty*. A limit or a `top` above 1000 is taken for
1000. An answer is at most 256 KiB: a question whose answer is longer is *faulty*, and is asked no longer. A session has at most 1024 questions.

**Passing on.** A partial replica has a full one answer. It calls (§12) the device by the method with no name, which is for nodes themselves: no client may call or
serve it, and it needs Read where others need Call, in every scope the question is about. The first message is the question. Each message back is an Answer without its id, and with
each row's key, as in a Watch, in place of its id, any key of it. The partial replica watches those
places, data and live, and answers its client once it holds the rows. It believes nothing else that would not be an answer to what it asked. A device that will not answer faults *unserved*, and another is asked; until one
does, and when none can be reached, the answer is of what is held. A Fetch waits for the other, if one can be reached, and for its rows to be confirmed.

## 16 Streams and services

A device's host serves methods of its own, by names beginning `zsp.`: what it lets others do on it. Each answers first with a status, and
then as the method says:

```
status      0 ok ‖ what the method says · or code (1) ‖ reason (UTF-8), and End:
            1 denied · 2 not offered · 3 refused · 4 unreachable · 5 timed out · 6 not found · 7 failed · 8 changed · 9 exists · 10 malformed
```

What it lets others do is the device's to say, in the scopes it says: **shares**, of terminals and commands (shell), and of folders of files, each by
a name and for reading or writing too (files). Nothing is shared until its owner says, and whoever would use a share needs besides, in its scope,
Call and Shell or Files (§3). When either changes, every call no longer allowed is faulted *denied* at once, and its process killed or its file closed;
a share of files moved to another folder is another share.
Every opening, refusal and close is written down by the host, with who and what but none of what passed. A host does not answer its own local
clients but by `zsp.services` and `zsp.share`, nor relays but by `zsp.public`.

| method | first message | then |
|---|---|---|
| `zsp.services` | – | n × service, End: 1 shell ‖ flags (1: 1 terminal, 2 commands) · 2 files ‖ flags (1: 1 read, 2 write) ‖ name bytes · 3 tcp ‖ port (2) ‖ host bytes ‖ name bytes; what the caller's rights let it use |
| `zsp.share` | – or the shares, as text | the shares as text, or the new ones taken; for local clients alone, granted every scope (scope 0, Write and Call) |
| `zsp.tcp` | port (2) ‖ host bytes | a TCP connection, there or by default to its loopback: bytes each way as messages, End a half-close, Fault or Cancel a reset |
| `zsp.exec` | flags (1) ‖ n varint ‖ n × argument bytes ‖ m varint ‖ m × environment bytes ‖ folder bytes | a process |
| `zsp.pty` | rows (2) ‖ columns (2) ‖ TERM bytes ‖ as `zsp.exec` after its flags | a process with a terminal; no arguments, the user's shell |
| `zsp.list` | path bytes | m × { kind (1: 1 file, 2 folder, 3 other) ‖ name bytes ‖ size varint ‖ modified (ms) varint } in messages, End |
| `zsp.get` | path bytes ‖ offset varint ‖ identity bytes | size varint ‖ modified varint ‖ identity bytes ‖ from varint, then the file |
| `zsp.put` | path bytes ‖ size varint ‖ modified varint ‖ identity bytes ‖ flags (1: 1 replace, 2 make the folders) | from varint, then the file the other way |

Integers of two bytes are big-endian. A process's messages are tagged: to it, `0 ‖ input`, `1 ‖ signal (1)` (POSIX numbers: 1 hang up, 2 interrupt,
3 quit, 9 kill, 15 terminate, 18 continue, 19 stop) and `2 ‖ rows (2) ‖ columns (2)`, End meaning no more input; from it, `1 ‖ output`, `2 ‖ errors`, and last
`3 ‖ code varint ‖ signal (1)`, then End. Arguments are the program's own, never through a shell; environment entries are NAME=value over the host's,
NAME alone removing one. A call cancelled kills the process and all it started.

Paths are a share's name and then the path within it, `/` between, whatever the system; none may lead out of the share, by `..` or by a link, which is
judged by where the file opened really is. A file is put only in a folder reached from the share without any link, and the folders made on the way
likewise, so a link in a share is never written through. No name in a path is `.` or `..`, holds `\`, `:` or NUL, ends in `.` or a space (on some
systems another's name), or ends in `.zsp-part` or `.zsp-part.meta` (a receiver's own, below). A put names a file, not the share or a folder. An
empty path lists the shares of files. A file is hashed in chunks of 1 MiB, each by SHA-256, and the file
by SHA-256 of its chunks' hashes in order. Whoever has the file sends it from `from` as `1 ‖ bytes`, each chunk followed by `2 ‖ its hash (32)`, then
`3 ‖ status (1) ‖ [the file's hash (32)]`, and End: with the hash in every *ok* of a put, and of a get unless resumed, and not taken without it. A
sender whose file is no longer the one it was by its identity ends with *changed*. Credit for what follows the last bytes is kept back from them. the receiver checks each chunk as it comes, and a put ends with its
verdict, a status (1), once the sender has ended. **Resuming**: what was received is kept with the hashes of its whole chunks; asked again, a
transfer takes up at the end of those that are still what their hashes say, if the file is the one it was by its `identity`, an opaque value its
holder gives for it (here, its size, time and identity on its disk); otherwise it begins again. A file received is put in place whole, with the
sender's time, or not at all.

Whoever answers reads only as much as it has credit to send, and credits only what it has written on, to a socket, a process or a disk: so a
slow end slows the other, and nothing piles up between them. Lanes take their urgency from the method: `zsp.pty` 1; `zsp.get` and `zsp.put` 6;
those between nodes themselves 4; all others, commands and ports among them, which may be bulk or not, 3.

## 17 Names, ports and exposure

Every device of a space has, on every other, a name that any application can look up and an address it can connect to, and through it
the TCP ports that device offers: as if the space were a network, with no network device made for it. None of this is in the store or
replicated; what is on the wire is the roster's names, a few methods (§12), and two messages between a device and a relay.

**Names.** A member's **id** is the first 10 bytes of its device key in RFC 4648 base32, lower case and unpadded: 16 letters that nobody can
choose to match another's. Under a suffix of the host's (`zsp.internal` here, under ICANN's private-use `.internal`):

```
<name>.<suffix>        the member the roster gives that name
<id>.id.<suffix>       any member with a grant in force
```

A member at index *i* of the roster's members is at 127.*a*.(*b* + ⌊(*i* + 2) / 256⌋).((*i* + 2) mod 256), from a loopback range 127.*a*.*b* of
the host's choice (127.77.0 here): indexes are for ever, so an address never comes to mean another device however long it is remembered.
127.*a*.*b*.1 is the host's own (its name server, here). A device's own names are 127.0.0.1. A member whose grants have all ended has
neither name nor address. A host answers for these names and addresses, and for the reverse zone of the range, as an authoritative name
server (RFC 1035): with a time to live of 5 seconds, a start of authority whose minimum is the same, nothing for AAAA, and nothing for any
other name. How the machine's resolver comes to ask it is the host's affair.

**Ports.** What a device **offers** is its own to say, and it says nothing unless told: ranges of ports, each to whoever may call in a scope,
or to one device among them; of this machine, or of another as reached from it. Of this machine's, only those that are listening, and
reached at its loopback, are listed. A device never offers its own listeners, nor anything at an address of its own loopback range: nothing
reaches through it what it reaches. A connection to a port is a `zsp.tcp` call (§16), permitted only when an offer covers the port and the
host named, and both devices may call in the offer's scope; when an offer is taken back, or a grant ends, every connection it no longer
permits is cut off.

```
zsp.ports    first message: lease varint (seconds, at most 600; 0 for once)
             each message back: entries, the whole of what the callee offers the caller; again whenever that differs,
             until the lease ends and the callee ends the call. Another lease varint from the caller asks for as long again.
entries      n varint ‖ n × { port (2) ‖ scope varint ‖ host bytes (empty for the callee's own machine) ‖ name bytes }
```

A device asks what another offers when anyone on it seems to want it, and keeps it up while that lasts: a name looked up, a connection
made, a client asking (60 seconds, here); and no sooner, so that a quiet space costs nothing however many devices come and go. The callee looks again at what is listening every 2 seconds while anyone is kept up,
and never otherwise. An offer marked so says who connects before anything else: the PROXY protocol's second version, from the caller's
address on the callee's machine, with TLVs 0xE0, its device key, and 0xE1, its name.

Whoever reaches another device's port through its address must be the user the node runs as, or the system: a host asks its system whose
the connecting socket is, and refuses any other user's. And a connection whose first bytes are an HTTP request, through the address or
the proxy alike, must name the device by `Host`, and if it has an `Origin`, be from one of the space's names or addresses; otherwise it is
answered 403 and closed. So a web page elsewhere that has pointed a name of its own at one of these addresses (DNS rebinding) reaches
nothing. What a browser sends begins with a request line, `method SP target SP HTTP/d.d`, the method any token in any case, so:

- empty lines before it are skipped, and a line may end in LF alone, as the most lenient server would read it;
- bytes that cannot begin such a line pass at once, and are not HTTP; bytes that can are held until they cannot, or the head is whole;
- the head must have exactly one `Host`, at most one `Origin`, and no folded or malformed header lines; a `Host` (and a target in absolute
  form) is a name or address, then `:` and digits if anything, naming the device; an `Origin` is `http` or `https`, `://`, a name or
  address of the space, then `:` and digits if anything, and nothing else (so not `null`);
- only the first request of a connection is looked at: a browser keeps a connection for the one origin its first request named.

A client that speaks first with a few letters and nothing after, waiting for an answer, waits until it says more.

**Exposure.** A device may expose a port of its own machine to the public, through relays that will, one port at a time, under a
**label**:

```
label = [prefix "-"] base32(SHA-256("zsp-expose" ‖ space ‖ device ‖ prefix bytes ‖ nonce (16))[0..10])
```

the prefix being up to 20 letters, digits and hyphens of the device's choosing, and the nonce drawn afresh each time a port is exposed, so
that a label once let go is nobody's for ever. Nobody can be given another's label: that would take a second preimage of 80 bits.

```
40 Expose    device → relay: n varint ‖ n × { prefix bytes ‖ nonce (16) }      all it exposes there, replacing what it said before
41 Exposed   relay → device: n varint ‖ n × { label bytes ‖ status (1) ‖ url bytes }
             status 0 exposed, at url; 1 this relay exposes nothing; 2 the label is another's; 3 too many
zsp.public   relay → device, in scope 0: label bytes ‖ address (16) ‖ port (2), whence the connection came
             then as zsp.tcp: the callee's first message 0, or a code ‖ reason; then the connection's bytes each way
```

A relay works each label out itself, from the space, the device's proven key and what it said, and holds it only while the device is
connected; it is reached at `<label>.<domain>` for a domain of the relay's, by TLS that it terminates (routed by the name asked for) or by
plain HTTP routed by `Host`, behind something else that does. A device takes `zsp.public` only from a session it dialled as a relay's, and
only for a label it exposes; for an exposure marked so, it says first where each connection came from, by PROXY v2. Taking a port back
cuts off whoever is using it. What is exposed is public, and the relay sees it, as any reverse proxy must that holds the certificate; what
is offered stays between devices, end to end.

**A local client** asks its own device's host, by calling its own device (§12), in any scope it may call in:

```
zsp.nodes    answered once: n varint ‖ n × { device (32) ‖ name bytes ‖ address (4) ‖ flags (1: 1 this device, 2 reachable,
             4 linked directly) ‖ subject bytes ‖ entries, of what it offers this device }
zsp.offers   0 | 1 ‖ offer | 2 ‖ offer            list, offer, take back; answered with n varint ‖ n × offer, as they then are
offer        lo (2) ‖ hi (2) ‖ scope varint ‖ device (32, zero for any) ‖ host bytes ‖ name bytes ‖ flags (1: 1 PROXY v2)
zsp.expose   0 | 1 ‖ port (2) ‖ prefix bytes ‖ flags (1: 1 PROXY v2) | 2 ‖ port (2)
             answered with n varint ‖ n × { port (2) ‖ prefix bytes ‖ flags (1) ‖ label bytes ‖
             m varint ‖ m × { relay (32) ‖ status (1) ‖ url bytes } }
```

Only a client its host accepted for every scope (scope 0) may change what the device offers or exposes; another is *denied*. An offer
in a scope the device may not call in is *denied*, for it could never be taken up. A method that is not a local client's is *denied* to
one, and these are denied to everyone else.

## 18 Who handles what

| | protocol | consumer |
|---|---|---|
| **Identity** | proves possession of a device key; carries `subject` in the signed roster; carries whom a host vouches for with what is written and called | decides which person a key is, and puts their name in `subject`; and, where one device serves several people, says for whom each connection is |
| **Scope** | what one key opens; bounds every watch, cell and call | decides what to share |
| **Permission** | Read, Write, Call, Vouch per scope, in the roster; enforced by every replica, relays included | decides whom to grant |
| **Keys** | wraps, rotates, seals, signs | keeps the device's secret |
| **Authentication** | carries an opaque credential, inside the channel, to the accepting host, and waits for its verdict | is the verdict: accounts, tokens, quotas, billing |
| **Names** | carries each device's name in the signed roster; derives ids and addresses; answers for them | decides what to call devices; points the machine's resolver at the node (zspd setup) |
| **Ports** | lists what is offered and listening, permits and cuts off by offer and grant, refuses other users and other pages | decides what to offer, and to whom |
| **Exposure** | derives labels nobody can take, carries the public to what is exposed and nothing else, cuts off what is taken back | decides what to expose; holds the domain and its certificate |

For a peer, the verdict says whether to serve the connection; what it may then do is the roster's. For a local client, the verdict *is* the grants, and for whom it is.
