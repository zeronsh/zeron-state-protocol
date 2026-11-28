# Zeron State Protocol, version 1

ZSP keeps ordered lists of rows the same on many devices, live, with or without a server, when the server may be
trusted with nothing. This document is enough to write a client, a relay or a full replica.
`vectors/vectors.json` pins every deterministic construction in it.

**Contents.** [1 Model](#1-model) · [2 Encoding](#2-encoding) · [3 Keys and the roster](#3-keys-and-the-roster) ·
[4 Cells](#4-cells) · [5 Text](#5-text) · [6 Fingerprints](#6-fingerprints) · [7 Channels](#7-channels) ·
[8 Sessions](#8-sessions) · [9 Watching](#9-watching) · [10 Reconciling](#10-reconciling) · [11 Live](#11-live) ·
[12 Calls](#12-calls) · [13 Relays](#13-relays) · [14 Links](#14-links) · [15 Questions](#15-questions) ·
[16 Who handles what](#16-who-handles-what)

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

Rights are bits: 1 Read, 2 Write, 4 Call, 8 Vouch: to be believed about for whom one writes and calls (§4, §12); a grant with any other is invalid. Every grant includes Read. Scope flag 1 is **signed**; a grant without Write is
invalid in a scope that is not signed. `until` is zero for a grant in force, and otherwise the stamp time at which it ended;
a member has at most one in force per scope. Taking Write away ends the grant and adds another, so that what it allowed stays allowed; and so does taking Vouch away in a signed scope. `closed`
says when each earlier epoch ended. Both should be no less than any stamp the signer has seen. No device appears twice.
`subject` is the consumer's name for whomever the device belongs to, opaque here. A roster that does not begin `"zsp-r1"` is none. A roster is at most 2²² − 64 bytes. Members are never removed, only their grants
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
1 Hello    version = 1 (1) ‖ flags (1: 1 full replica, believed only of a peer, 2 relay: which only confirms what the dialler knows; 4, of a local client, that it is told whose cells are; 8 calls; 16 says what it took) ‖ space (32) ‖ roster serial varint ‖ credential bytes
```

A session between peers with flag 8, a **calls session**, carries Hello, Roster, Call, Flow and Error and nothing else: it is begun over a link a relay
carries (§13), which carries everything else already. Both ends say 8, or the session ends *denied*.

The accepting host decides from the credential and the proven key whether to serve the connection (§16); until it has, later frames
wait. Then, between peers, whichever has the newer roster sends it (one no older than it said, or the session ends), and each verifies that the other is a member with a grant in
force, or is a relay it chose to dial. An end that knows no roster yet, a relay or a device that has only joined, can verify nobody, and turns nobody away for that: the session
waits, saying nothing, until a roster comes, from its peer or from anyone, and is verified then:

```
2 Roster   the document                                                       between peers
           clock (8) ‖ n × { scope varint, rights (1, and 128 in a signed scope), list key (32) }
                                                                              to a local client: what it may do, and what it needs to
17 Author  number varint ‖ device (32) ‖ subject bytes                        to a local client that asked: whom a number is for from now on
18 Took    bytes varint                                                         how many more bytes have come, but those of Took
```

**Took.** A peer that says in its Hello that it says what it took (16) says, now and then, how many more bytes of the session's
stream have come to it, whole frames or not, but those of Took frames, and those of what has come and is not yet taken in that is,
or may yet prove to be, of one. To such a peer, what is made is held to a window: what is made and not yet said to have come is
kept to two and a half times the most delivered lately per millisecond, times the least round trip timed on the session, or 20 ms
if that is less (a peer says what came once it has taken it in, a message at a time, and a round trip shorter than that is none of
the way's: two ends a millisecond apart would take turns, each waiting while the other worked) (64 KiB at least, 256 KiB until
timed); a round trip is timed from when the first byte of what the host takes is taken to when it is said
to have come. So whatever lies between, a socket's buffers, a proxy's, a network's, holds no more than that, and what goes first
(a window of limited size newly asked for, and what it is owed, which may go 64 KiB beyond it) is taken within about a round trip
or two, rather than after all that was handed over before it. Changes and Fills are held to it; frames that answer or ask, and
Ack and Took, are not. Neither end does this over a link, which carries a session on streams of its own. A window of limited size
is asked for whole, not compared: compared, it would be had only a round trip later for each step of comparing.

Whose a cell is follows it, to a local client that asked: 0x40 in its tag, and after its body the number (varint) of an Author said before. Number 0 is the client itself, said ahead of all else and again
whenever the roster changes. When the roster changes whose anything is, all that is watched is sent again, under new numbers.

A roster that arrives later is adopted likewise, at any time, from anyone; its signature is its authority. Sessions it no longer allows end, and a
device it no longer allows gives up its keys.

```
7 Cells    sequence varint ‖ cells       applied atomically, in order
8 Ack      sequence varint ‖ rows (16 each)   everything up to here is durable, but that something of these rows was not accepted
13 Error   code (1): 1 malformed, 2 denied, 3 version, 4 failed, 5 clock.  The sender closes.
```

**Durable** is said of what a replica's own store keeps, and a store is one writer's: two processes writing one store at once each
overwrite what the other wrote and acknowledge what is lost. An implementation therefore holds its store against every other process,
and every other part of its own, for as long as it runs a node on it, and one that finds it held refuses it rather than open it. A
lock taken on a file system shared with other machines may not be seen by them, or may be lost while held, so a store is kept on a
disk of the machine's own, and an implementation refuses a store it can tell is not.

A peer that is a full replica is sent everything its dialler commits, and everything a partial replica, or one becoming
partial, commits, whoever dialled: what such a one owes is what it has not yet said. Otherwise a session is sent what it watches. A partial replica keeps owing a row
named in an Ack.

A local client keeps every Cells it sent until an Ack covers it, and sends it again, in order, on its next session, should one end first. So one that
ends lets its session go only once all it sent is acknowledged: ended while it has no session, it opens one to finish, and does nothing else on it;
and it says that what it sent will never be durable, rather than nothing, only once that is so, as with no node to open a session with, a node that
refuses it with Error 2 or 3, or a scope it may no longer write in, or its application giving up on it. A text it has open is sealed as it ends, whether or not a
session is up. It tells its application that something it wrote is durable only once an Ack covers it.

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
the range, and says Synced again: rows not mentioned between are gone. *settled* says that a full replica has confirmed the range, and that none
has gone since: a partial replica that can reach none says Synced without it, of what it holds, and with it once one has confirmed the range; and when
the last that had goes, it says Synced without it again. A full replica, which may be short of all there is while it is brought level, asks a full
replica it reaches for its local clients' windows of limited size as a partial one does, and is settled, and bounds them, by what that one says; one that
reaches none for the scope is all there is, and says settled at once, and not settled once it asks one, until that one answers. Until one it asked has answered, what it holds may be growing fast, as while it is
brought level, and would carry the window far past its size: so, once per burst of changes, a replica bounds such a window again, as when it was asked
for, if it has come to span more than twice its limit, and says Synced of it. A window is never cut short, by this or by what a full replica says, on
a side its client has gone on from with another of its own that ends, or begins, where it does: what lay between would be in neither; an answer of less
than such a window is not taken for it, and it is asked for again, whole, as a range. A relay hushed is as one gone: what it said of windows stands for
nothing, and what it owed them it never will say. An owner answers a
watch of limited size, newly asked for, before whatever else it has yet to send, such as all of a scope to one it is bringing level, and after what is
under way: it is small, and someone is waiting for it; and what it is owed, rows it is found to lack and rows asked for meanwhile, goes before what says it
is level. Before honouring Unwatch, an owner sends what it committed while the watch stood. When a grant
ends, its watches end with Synced *denied*; to a local client, a new Roster comes first.

A **full replica** watches, on each session it dials, every scope it can read, whole. A **partial replica** watches what its local clients watch, and
keeps what it wrote on record until a full replica acknowledges it, offering it again on every session with one. A full replica's acknowledgement is
counted on, and what it acknowledged forgotten: so a store that last served as a full one is a full replica, though asked to be partial, until a full
replica it brought level, in every scope it holds keys for, has said it holds all it was sent, with nothing refused; meanwhile it keeps on record what its
clients write, says in its Hello that it is not a full replica, so that nobody counts on it nor is brought level with it, and watches whole whichever end
dialled; and it is partial from its next start. So a device may be either, from one start to the next, and lose nothing. A peer's
Synced for an interest is believed only from a full replica asked for it, settled or denied, of a range within its scope that meets what was asked; a
whole-scope watch counts as level only when settled; an Ack of more than was sent ends the session
as *malformed*. When all a dialler's whole-scope watches are level, and it has sent all the other
lacked, it says so: Synced with id 0, settled, empty keys and zero counts (and so does one becoming partial that watches whole, though dialled). The other heeds it from a full replica that has such a watch here. When the
roster changes, all of these are asked for afresh: either end may have dropped one under a roster the other never heard.

With *counts* the owner says Synced again whenever, after a burst of changes, how much lies before or after differs from what it last said. A
replica that asked relays to its client the bounds and counts a full replica gives it, closing the window to those bounds, for what it holds
beyond them may have gaps. A client whose window so closes on what it showed asks for what lay beyond again.

**Keeping.** A partial replica may let go of what it holds, as though it had never come, but not of what it has yet to see acknowledged, of a row any
watch or question of its own covers, nor of one being typed in; what it lets go of it has again by watching it. Here it keeps, by list, when each
was last watched or written in, and lets go of a list nobody has watched for an age (30 days unless told otherwise); and when it holds more than a
size (256 MiB in a browser, 1 GiB for zspd, unless told otherwise), of lists, those watched least lately first, until it holds three quarters of it,
and of what lies outside watched ranges last of all.

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
15 Call    id varint ‖ device (32) ‖ scope varint ‖ method bytes ‖ for whom bytes ‖ [urgency (1)] ‖ first message
                                                                            urgency from a local client only, 0 to 7
16 Flow    id varint × 2 + (1 if sent by the callee) ‖ kind (1) ‖ payload
           0 Data (message) · 1 End · 2 Fault (code (1)) · 3 Cancel · 4 Credit (varint bytes)
12 Presence   to a local client: n × { device (32), subject bytes }, this device first, then all it can reach
```

A call is a stream of messages each way. `device` is the callee's on the way out and the caller's on arrival. For whom is at most 64 bytes: what a client says of that is disregarded, and its node says whom its host accepted it for, or nothing; the
last node tells its own client the same if the calling device has Vouch in that scope, and otherwise the device's `subject`. Who may not vouch may not call for another: *denied*. Ids belong to whoever sent
Call on that session. A call ends when both sides have sent End, or on Fault or Cancel. Each side may have 256 KiB of messages outstanding beyond what the
other has credited, and may be credited ahead of what it has sent up to 4 MiB; the first message counts. One message is at most 256 KiB, and a method's name from 1 to 255 bytes (§15 has the use of none).
What answers a call at a device is the device's affair: a local client that serves the method, or the host itself in its stead; to the caller
they are alike.

What a node committed before a call it sends on its way before it, and so does a relay: whoever is called has what the call is about, unless so much was committed at once that one of them has to
compare afresh (§9). Both devices need the Call right in the scope, and both check. A call takes a direct session with the device if there is one, one that
replicates before a calls session, else a calls session over a link through a relay both are present at (§13), begun for it. It
stays on the session it began on: if that fails the call faults *lost*, and may or may not have happened. Faults: 1 denied, 2 unreachable, 3 unserved,
4 lost, 5 overrun, 6 busy.

**Lanes.** Over a link (§14) each call has a stream of its own, its **lane**, opened by whoever sends Call on it, which carries that call's Call and Flow
frames and nothing else, each way. A lane's first bytes each way say how many bytes of the session's own stream (stream 0) its sender had produced
before them, so that what was committed before a call is still had before it. Frames on a lane are taken only once the session is ready. A lane is
finished by each side once its call is over for it; one given up (Reset) loses its call. Lanes are opened with an urgency, 0 most urgent to 7 least:
what a local client said in its Call, or a host for a call of its own, and 4 for the nodes' own (§15). The link serves the most urgent first (§14):
what someone types into wants 1, a bulk copy 6, and what may be either 3, where what has lately said little goes first. An urgency above 7 is malformed.

**Building on calls.** Whatever a device offers others beyond the store (files, commands, terminals, its ports) is a method, each use of it a
call. Whoever answers reads only as much as it has credit to send, and credits only what it has written on, to a socket, a process or a disk:
so a slow end slows the other, and nothing piles up between them. End is a half-close; Fault or Cancel, a reset. The roster says only who may
call in a scope: what each caller may then do, by its device and for whom it calls, is the service's to say, and to refuse with *denied*.

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
flight sends nothing. A sender gives a link up when what it has in flight goes unacknowledged through six probes and at least 10 seconds: on a fast
path six probes come to less than a second, which a busy machine, or a relay's, may be silent for without being gone.

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
both send to all of the other's at once. A device sends nothing to, and answers nothing from, an address that is not one peer's: port 0, 0/8, 224/4 and
above, IPv6's groups (ff00::/8), its link- and site-local addresses (fe80::/10, fec0::/10), whose link or site 18 bytes cannot name, and ::/96 but ::1; and
its link socket may not broadcast, so that no address a member names, as its network's own broadcast address, reaches everyone on it. On a local network a
device broadcasts by a socket of its own instead, at start and a few times soon after, to UDP port 9083, and a device that hears it and should be dialled
answers with the same at the link port the beacon names, at the address it came from: 0x44 ‖ salt (8) ‖
XChaCha20-Poly1305 under derive(space, "zsp-beacon"), nonce 0 (8) ‖ salt ‖ 0 ‖ 0x42 ‖ 0 (6), of device (32) ‖ link port (2, big-endian), no associated data. A beacon is bound to no time, so anyone may say an old one
again: a device that hears one from a device it has a link to asks after the link, and only if nothing comes back on it for a
few seconds (3, here) does it act as though it had no link, the dialler knocking where the beacon says and the other answering it in kind;
the new link takes the old one's place only once it is proven. So a device that starts again is found again soon, and a beacon said again moves nothing.

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

With none to ask that can read, but a full replica that may be sent the scope and holds what it cannot, as a relay, a partial replica watches, data and
live, a list the question's rows must all be in, if it names one at its top and joins no others, and answers as it would were it full; the answer is
*settled* while that replica has confirmed the list and it has all been found. Once one that can read answers, the list is watched no longer. A question
that names no list, or joins others, is answered of what is held.

## 16 Who handles what

| | protocol | consumer |
|---|---|---|
| **Identity** | proves possession of a device key; carries `subject` in the signed roster; carries whom a host vouches for with what is written and called | decides which person a key is, and puts their name in `subject`; and, where one device serves several people, says for whom each connection is |
| **Scope** | what one key opens; bounds every watch, cell and call | decides what to share |
| **Permission** | Read, Write, Call, Vouch per scope, in the roster; enforced by every replica, relays included | decides whom to grant |
| **Keys** | wraps, rotates, seals, signs | keeps the device's secret |
| **Authentication** | carries an opaque credential, inside the channel, to the accepting host, and waits for its verdict | is the verdict: accounts, tokens, quotas, billing |
| **Services** | carries calls: a stream of messages each way, with credit, each on a lane of its own at the urgency its caller says, between devices that may call in the scope | builds what it offers on them (files, commands, terminals, ports, names) and decides who may use which |

For a peer, the verdict says whether to serve the connection; what it may then do is the roster's. For a local client, the verdict *is* the grants, and for whom it is.
