# Users, teams and organizations

How to lay out who sees what. Everything here is run by `./x test`: [examples/organization.py](../examples/organization.py) is a company from
its first day to somebody's last.

## What there is

| | is | divides by |
|---|---|---|
| **space** | a signed roster, and a meeting place at a relay | different keys, different people in charge: nothing is shared between two |
| **scope** | a key of its own, and a list of devices that have it | what may be read, written and called. The least thing a right can be given to |
| **list** | a name within a scope | nothing: it arranges |
| **column** | a value in a row | nothing: it describes |

and who there is:

| | is |
|---|---|
| **device** | a key pair. All rights are devices' |
| **subject** | your name for whoever has a device, kept in the roster. A person with three devices is three members with one subject |
| **owner** | holds the key that *is* the space. Reads and writes every scope, always, and cannot be unmade |
| **admin** | may admit, revoke and make scopes; named by an owner, who can take it back |
| **relay** | holds no keys. It stores and forwards what it cannot read, and enforces the roster while it does |

One rule follows from that, and most of the rest from it: **if two people may not see the same rows, those rows are in different scopes.** A `where owner == user`
is convenience. It is not protection, for whoever has a scope's key has all of the scope.

## Which to use

| you have | make it |
|---|---|
| a company, a customer, a tenant | a space |
| a team, a project, a channel, a client's matter | a scope in that space |
| what everybody in a company sees | the space's first scope |
| what all may read, and few write: announcements, settings, prices | a **signed** scope, most of them admitted to read |
| a guest, a contractor | a device admitted to the scopes it needs, and no others |
| one person's, on all their devices | a space that person owns |
| one person's, but the company's in the end | a scope in the company's space. Its owners can read it |
| shared between two companies | a scope in one, where the other's people are guests; or a space of its own |
| a document shared with whoever its author likes | a scope for each such document, if there are hundreds; a space, if there will be many thousands |
| an environment: production, staging | a space each |
| which chat, board or folder a row is in | a list |
| whose a row is, its status, its kind | a column, and [ask](#asking-within-it) by it |

**Someone in several organizations** has a directory, a key and a node for each: `zspd run ~/.zsp/acme`, `zspd run ~/.zsp/globex`. A node is 0.4 MB and does nothing
while idle, and two organizations cannot then so much as tell that they share a person.

## How much fits

A roster is one document, and everyone in a space is sent all of it whenever it changes.

| devices × scopes each | roster | to sign | to check |
|---|---|---|---|
| 10 × 5 | 4 KB | 1 ms | 0.2 ms |
| 100 × 10 | 58 KB | 7 ms | 0.6 ms |
| 1,000 × 10 | 576 KB | 45 ms | 3 ms |
| 5,000 × 10 | 2.9 MB | 295 ms | 30 ms |

It is some 100 bytes a device and 50 for each scope a device is in, and 4 MB is as much as there can be: 70,000 or so in all. Up to a thousand devices nobody will notice. Beyond
that, give each division a space. A right that has ended stays on record, at some 10 bytes, and each key a scope has had at some 90, so a scope for every conversation in a busy company belongs in many spaces, and not in one.

## Setting one up

```sh
zspd create /srv/acme                         # the space; this device owns it, so let it be a safe one
zspd scope  /srv/acme                         # another scope: prints 2
zspd scope  /srv/acme signed                  # and 3, that some may only read
zspd relay  /srv/acme <relay key> wss://relay.example.com
zspd owner  /srv/acme <another device's key>  # lest the only copy of the space's key be lost
zspd admin  /srv/acme <your server's key>     # who does the rest, and can be taken back
```

A person's device is admitted by its key, to each scope, and told whose it is:

```sh
zspd key     ~/.zsp/acme                      # on theirs: what to send you
zspd admit   /srv/acme <key> 1                # to read, write and call
zspd admit   /srv/acme <key> 3 read           # or only to read; a signed scope
zspd subject /srv/acme <key> user_01HZX3      # whose it is, as you know them
zspd members /srv/acme                        # who there is, and what they may do
```

`create` and `scope` number scopes from 1, and nothing says what a number is for. Keep their names in rows of the scope everyone is in, as
[examples/luau/workspace.luau](../examples/luau/workspace.luau) does.

## Following your own directory

You have a list of people and teams already: an identity provider, a table of memberships. Do not keep another by hand. Say what the space *should* be, compare it with
`zspd members`, and do what differs. [examples/directory.py](../examples/directory.py) is all of that, in eighty lines:

```json
{
  "scopes": {"1": {"write": ["everyone"]}, "2": {"write": ["engineering"]}, "3": {"read": ["everyone"], "write": ["hr"], "vouch": ["website"]}},
  "teams":  {"engineering": ["ann"], "hr": ["hana"]},
  "people": {"ann": ["<laptop>", "<phone>"], "bob": ["<key>"], "hana": ["<key>"], "website": ["<key>"]}
}
```

Run it on an admin device whenever the directory changes, from a webhook or a timer. It may be run twice: of two rosters drawn up at once one wins, and the other's changes have to be made
again, which running it does.

**Signing in** is then yours entirely, and happens once for each device. The device makes its key and sends it to your server with whatever proves who its person is; your server adds the
key to that person's in the directory. ZSP never sees a password, a session or a token.

## Who may use a relay

A relay asks you whether a device may use it *for this space*. That is for accounts, quotas and billing. It is no more than that: a device you let in
by mistake is shown nothing, for it is not in the roster, and has no key.

```js
import { authenticate } from "./auth.js"; // examples/relay: a JWT your sign-in signed, that names the spaces its holder may use
export default relay({ authenticate });
```

The device presents it with `zspd run --credential=<token>`, or `host.Config.credential`. On a relay of your own, `zspd serve --allow=<space>,…` serves those and no others.

## Applications on one machine

`zspd run` has one local token, and whoever can read that file may do what the device may. To give each application its own scopes, answer `authenticate` yourself:

```odin
authenticate :: proc(data: rawptr, s: ^zsp.Session, credential: []byte) {
	if s.role == .Peer { // another device: its key is proven, and the roster says the rest
		zsp.session_accept(s)
		return
	}
	for app in (^Apps)(data).all {
		if crypto.compare_constant_time(credential, transmute([]byte)app.secret) == 1 {
			zsp.session_accept(s, {{scope = 1, rights = {.Read}}}) // and nothing else
			return
		}
	}
	zsp.session_refuse(s)
}
```

[examples/apps](../examples/apps/main.odin) is the whole program. The grants are what that session may do, and never more than its device may. The same is how one node serves several people: let
the credential be a session of your own, the grants what that person may do, and a third argument [who they are](#whose-a-row-is).

## Asking within it

A question names its scope, and is answered from it alone: there is no asking across all of them by mistake.

```luau
client:ask({ scope = engineering, table = Task, where = w.is("owner", user) }, render)   -- and again whenever it is no longer so
client:fetch({ scope = engineering, table = Task, where = w.is("owner", user) })         -- once
```

It may reach into another scope only by saying so, as in `w.refers("project", projects, …)`, and only if its client may read that one too; otherwise all of it is refused. What is wanted from
several scopes at once is asked of each.

Bind the scope once, and let the rest of the application hold only that:

```luau
local team = workspace.place(client, everyone, "engineering") -- nil, for whoever may not read it
team.insert(Task, "tasks", os.time(), { title = "ship it", owner = workspace.user(client) })
team.ask({ table = Task, where = w.is("done", false) }, render)
if not team.writable then hide(composer) end -- or client:may(scope, "write")
```

`client:may` is for what to show. What is allowed is decided by every replica that is asked to take a cell, and not by what was shown.

## Whose a row is

A column says so because an application wrote it there, and an application could write another name. In an unsigned scope that is all there is, for anyone who can write can write anything:
fine among people who trust one another, which is who shares a scope. In a **signed** scope every cell is signed by its device and refused if that device may not write there, so no one *without* the right can write
in anyone's name. 
There, too, it is known whose each cell is, and that is a column like any other, only that nobody writes it:

```luau
local News = { title = zsp.string(16), by = zsp.author(16), body = zsp.text(17), writers = zsp.authors(17) }

row.by                                                                -- whom the last to write the title goes by
row.writers                                                           -- everyone who has written in the text
client:ask({ scope = news, table = News, where = w.is("by", "hana") }, render)
client:ask({ scope = news, table = News, totals = { whose = { "facet", "by" } } }, render)
```

Whom they go by is yours to say, in one of two ways.

**A device of their own.** It is its `subject`, in the roster. Rename it, and all it wrote goes by the new name.

**A device that serves several**: a web server, a shared kiosk, a bot that acts for whoever asked it. Its host checks who each connection is, as your sign-in does, and says so as it accepts it:

```odin
user, ok := session_of(credential) // a cookie, a JWT, an API key: yours entirely
if !ok {
	zsp.session_refuse(s)
	return
}
zsp.session_accept(s, grants_of(user), as = user.id)
```

What that connection writes and calls is then that user's, to every device that reads it, if the device has the **Vouch** right there:

```sh
zspd admit /srv/acme <your server's key> 3 vouch
```

The application cannot say otherwise: it never says at all. A device without Vouch cannot either, however it has been tampered with: what it writes goes by its own subject. And one that has Vouch can write as anybody, in the scopes it has it in and no others,
so give it to what runs your sign-in, and to nothing else. If you take it away, what was vouched for before still is. A name is at most 64 bytes: use an id that does not change, and keep what people are
called in rows. Relays see none of it.

`zspd run` says nothing of who its applications are, so what they write is the device's own. [examples/apps](../examples/apps/main.odin) says it of each.

For what must be decided by someone, such as an approval, a payment or a limit, make it a call. The device that serves it knows for certain which device is calling, and is told whose call it is in the same way:

```luau
client:serve(scope, "approve", function(call, data)
	if call.subject == "hana" then … end
end)
```

and let it write its verdict in a signed scope that only it may write.

## When someone leaves, or a device is lost

`zspd revoke <dir> <key>` ends it all; `… <key> <scope>`, one scope. With the directory above it is a line fewer.

- The roster changes, and every replica and relay refuses what that device writes from then on.
- Each scope it could read has a new key, which it is not given. What is written after, it cannot open, whoever sends it to it.
- It gives up its keys when it hears. One that never hears, or has been tampered with, keeps what it had: **what was read cannot be unread.** Nothing
  can promise that, and it is why a scope should hold no more than it needs to.
- What they wrote stays, for it was rightly written.

A device that is lost is revoked by its own key; the person's others are untouched.

## Mistakes to avoid

- **A column for a wall.** Filtering by `org_id` in one scope puts every customer's rows on every customer's devices.
- **One owner.** The space's key on one disk is the space on one disk. Have two, kept apart.
- **An admin that runs everywhere.** An admin holds every scope's key. One or two, on machines you would trust with all of it.
- **A read-only grant in an unsigned scope.** It is refused, for there to read is to be able to write. Make the scope signed when you make it: it cannot be changed after.
- **Expecting a relay to hide things.** It never had them.
