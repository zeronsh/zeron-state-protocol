# Building services on calls

ZSP keeps rows and texts the same everywhere, and carries **calls** between devices: a stream of messages each way, made
within a scope, between devices the roster lets call there ([SPEC §12](../SPEC.md#12-calls)). Everything a device might
offer others beyond the store is built on that: files, commands and terminals, its TCP ports, names for it, whatever else.
None of it is in the protocol, so none of it is decided for you: what is offered, to whom, how it is said, and how it is
checked are yours.

What a call gives a service:

- **Credit.** Each side may have 256 KiB outstanding beyond what the other has credited, and is credited as the other is
  done with what came; a reader that keeps up gets a window of up to 4 MiB, which is what a long fast path needs. Read from a
  socket, a process or a disk only what the call has credit for, and credit only what you have written on: then a slow end
  slows the other, and nothing piles up anywhere between them, however fast either end is.
- **A lane of its own.** Over a link, direct or carried by a relay, each call is a stream of its own, so a packet lost from
  one holds up no other. Its **urgency**, 0 to 7, is the caller's to say: the link sends what is most urgent first, and of
  its window keeps 64 KiB for urgency 3 and below. What someone types into wants 1; a bulk copy 6; what may be either, 3,
  where what has lately said little goes first.
- **Whoever is on the other end, proven.** The callee's node has checked that both devices hold Call in the scope, and
  says which device is calling and, if its host vouches for someone, for whom. What that caller may do beyond calling is the
  service's to decide; refuse with *denied*.
- **What it is about, first.** What the caller's node committed before the call reaches the callee before the call does.
- **An end, either way.** End is a half-close, said by each side; Fault or Cancel is a reset. A call that loses its path
  faults *lost*: it may or may not have happened.

## In-process, embedding the host

`package host` is an Odin package: a program that embeds it is a node, and answers calls in-process, its bytes going
straight between its sockets and its calls without passing through a local client's pipe.

```odin
h: host.Host
host.host_init(&h, {dir = dir, full = true, udp_port = 0}) or_return
sp := host.space_open(&h, space)
host.dial(&h, sp, relay_key, relay_url)
host.host_serve(&h, "forward", serve_forward) // answered here, in every scope; another device's or a local client's call alike
host.host_run(&h)                             // one thread, one event loop
```

A method is answered by a `Host_Method`, which returns a `Call_Handler`: `on_data` for each message (return false to keep
it, and `call_consumed` once done with it, which is the credit), `on_room` when more may be sent (`call_room`), `on_end`
when the other side has said all, and `on_fault` when it is over. `call_send`, `call_end`, `call_cancel` and `call_fault`
speak in it. `host_call(sp, device, scope, method, first, handler, urgency)` calls another device. A method the host
does not serve, or for which its `Host_Method` returns `.Unserved`, passes on to a local client that serves it, so
in-process services and those of local clients can be mixed on one device.

[examples/forward](../examples/forward/main.odin) is the whole of a TCP-forwarding service built so, in under 400 lines, comments and all:
connections accepted on one device become calls to another, which joins each to an address it was told to allow. It
reads a socket only into what the call has credit for, with one receive and one send in flight on each connection, and its
test holds it to bulk both ways, many calls at once, half-closes, a reader that never reads (which holds the writer to a
few megabytes, through the relay or directly), refusals, and the roster's say.

## As a local client

A client of the device's own node ([SPEC §7](../SPEC.md#7-channels), §8) serves a method with Serve and calls with Call, with
the same credit and the same urgency, in a byte of its Call. The Luau, TypeScript and Python clients say it so:

```luau
client:serve(1, "run", function(call, data) call.send(work(data)) end)
local copy = client:call(device, 1, "copy", first, { urgency = 6 })
```

```ts
client.serve(1, "run", (call, data) => call.send(work(data)));
const copy = client.call(device, 1, "copy", first, { urgency: 6 });
```

```python
client.serve(1, "run", lambda device, data: work(data))
copy = client.open(device, 1, "copy", first, urgency=6)
```

Everything a service says then passes through the pipe between the client and its node, which on one machine costs little;
for a service that moves much, or many connections, embedding the host saves that, and a process.

## What a service decides

- **Its methods and what they say.** A first message that says what is wanted, a status before anything else, a way of
  telling the end of a file from its failure: whatever the service needs, and nothing it does not.
- **Who may use what.** The roster has said who may call in the scope; the service says, of each caller (`Caller.device`,
  `Caller.who`, `Caller.local` for its own device's clients), what it may do, and keeps saying it: when the roster changes,
  calls no longer allowed to be made are ended by the node, but what a service allowed within a call is its own to take back.
- **How urgent each use is**, as above.
- **What it writes down.** An audit of who opened what, if it wants one, is a row it writes, or a file of its own.

The complete implementation of the services ZSP once carried itself (shares of files with resumable, checked transfers;
commands and terminals; port forwarding with names and addresses for every device, a DNS server and a proxy; exposure to
the public through relays) is at the tag `services-reference`, as one way they can be built.
