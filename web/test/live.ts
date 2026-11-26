// Two clients on two devices, whatever the devices are: zspd, a web device here, or one in a browser. The same as
// luau/tests/live.luau, so that every client is held to the same, over every way devices meet.
//
// Scope 1 is shared; scope 2 is signed, a writes there as "ann" and b as "bob", who may vouch.

import { Client, CallFault, columns as c, type Answer, type State, type Table } from "../src/client.ts";
import { where as w } from "../src/ask.ts";

export interface Sides {
  a: Client;
  b: Client;
  /** Breaks every pipe either client has, as a crash of the pipe would. */
  breakPipes(): void;
  say?(line: string): void;
}

const Message = { author: c.string(16), body: c.text(17), stars: c.number(18) };

const sleep = (ms: number) => new Promise<void>((done) => setTimeout(done, ms));
const now = () => performance.now();
// Lets everything else that is waiting happen, and no more: in Node and in a browser alike.
const turn = () =>
  new Promise<void>((done) => {
    const c = new MessageChannel();
    c.port1.onmessage = () => (c.port1.close(), done());
    c.port2.postMessage(0);
  });

class Never extends Error {}

async function eventually(what: string, f: () => boolean | Promise<boolean>, ms = 5000): Promise<void> {
  const until = now() + ms;
  while (now() < until) {
    if (await f()) return;
    await sleep(10);
  }
  throw new Never("never: " + what);
}

function check(ok: unknown, what: string): asserts ok {
  if (!ok) throw new Error(what);
}

export async function live({ a, b, breakPipes, say = console.log }: Sides): Promise<void> {
  const held = (x: Client) => Client.internals(x);
  await eventually("both connect, and may write", () => a.may(1, "write") && b.may(1, "write"), 15000);

  // A window opens at the end, follows it, and knows what lies before.
  const ids: string[] = [];
  for (let i = 1; i <= 300; i++) {
    void a.write(1, (change) => {
      ids[i] = change.insert(Message, "chat", i, { author: "wing", stars: i });
    });
  }
  await a.write(1, (change) => change.set(ids[300], Message, { stars: 1000 }));

  let current!: State<typeof Message>;
  const st = () => current; // read anew each time: it changes under us
  let told = 0;
  const all = b.window({ scope: 1, list: "chat", table: Message, size: 400, from: "start" }, (s) => (current = s));
  await eventually("everything reaches b", () => st().rows.length === 300, 15000);
  all.stop();
  await sleep(300);
  const window = b.window({ scope: 1, list: "chat", table: Message, size: 50 }, (s) => {
    current = s;
    told++;
  });
  await eventually("the tail arrives", () => st().status === "ready" && st().rows.length === 50 && st().before === 250);
  check(st().rows[49].stars === 1000 && st().rows[0].stars === 251 && st().after === 0, "the tail is the tail");
  check(told < 20, `one turn, one telling, not ${told}`);

  // Scrolling up loads before; far enough, and the bottom is let go.
  const seen = new Set<number>();
  for (let k = 0; k < 40; k++) {
    window.visible(1, 21);
    await sleep(20);
    for (const row of st().rows) seen.add(row.stars!);
    if (st().before === 0 && st().status !== "loading") break;
  }
  check(st().before === 0 && st().rows[0].stars === 1, `reached ${st().rows[0].stars} with ${st().before} before`);
  check(st().rows.length <= 250, `holds ${st().rows.length}`);
  check(st().after === 300 - st().rows.length, `${st().after} after ${st().rows.length}`);
  for (let i = 1; i <= 299; i++) check(seen.has(i), `row ${i} never seen`);
  for (let i = 1; i < st().rows.length; i++) check(st().rows[i].order > st().rows[i - 1].order, "out of order");
  // What lies beyond is kept true, though none of it is here.
  const beyond = st().after;
  void a.write(1, (change) => change.insert(Message, "chat", 250, { author: "far", stars: 0.5 }));
  await eventually("a row out of sight is counted", () => st().after === beyond + 1);
  // And back down again.
  for (let k = 0; k < 40; k++) {
    window.visible(st().rows.length - 20, st().rows.length);
    await sleep(20);
    if (st().after === 0 && st().status !== "loading") break;
  }
  check(st().after === 0 && st().rows[st().rows.length - 1].stars === 1000, "the bottom came back");
  check(st().before === 301 - st().rows.length, "and what is before is counted");

  // Rows that have not changed are the same objects.
  const before = st().rows[st().rows.length - 2];
  void a.write(1, (change) => change.set(ids[300], Message, { author: "edited" }));
  await eventually("an edit arrives", () => st().rows[st().rows.length - 1].author === "edited");
  check(st().rows[st().rows.length - 2] === before, "identity is kept");

  // Text streams live, before any of it is durable, and ends up the same on both sides.
  let id = "";
  void a.write(1, (change) => (id = change.insert(Message, "chat", 301, { author: "model" })));
  const last = () => st().rows[st().rows.length - 1];
  await eventually("the row arrives", () => last().author === "model");
  let started = 0;
  const editor = a.text(id, Message.body);
  let said = "";
  for (let i = 1; i <= 100; i++) {
    const token = `token${i} `;
    said += token;
    editor.append(token);
    if (i === 10) {
      const clock = now();
      while (last().body !== said && now() - clock < 5000) await turn();
      started = now() - clock;
      // At once: by live frames, long before the piece is sealed, a second after it began.
      check(started < 500, "tokens are seen at once");
    }
    if (i % 10 === 0) await sleep(5);
  }
  await eventually("the whole text arrives", () => last().body === said);
  editor.close();
  say(`     a streamed token shows on the other device in ${started.toFixed(1)} ms`);

  // Both edit at once, each watching.
  const theirs = a.window({ scope: 1, list: "chat", table: Message, size: 10 }, () => {});
  await sleep(100);
  const ea = a.text(id, Message.body), eb = b.text(id, Message.body);
  ea.insert(0, "[a]");
  eb.insert(0, "[b]");
  eb.delete(10, 5);
  await sleep(300);
  ea.close();
  eb.close();
  await sleep(300);
  const ea2 = a.text(id, Message.body), eb2 = b.text(id, Message.body);
  await eventually("the edits meet", () => ea2.read() === eb2.read());
  check(eb2.read().includes("[a]") && eb2.read().includes("[b]"), "both edits are there");
  ea2.close();
  eb2.close();

  // Moves and deletions.
  void a.write(1, (change) => {
    change.place(ids[250], "chat", 999);
    change.delete(ids[299]);
  });
  await eventually("a move and a deletion arrive", () => st().rows.every((row) => row.id !== ids[299]) && last().id === ids[250]);

  // Calls.
  b.serve(1, "shout", (call, data) => {
    call.send(new TextDecoder().decode(data).toUpperCase());
    call.finish();
  });
  b.serve(1, "count", (call, data) => {
    const n = Number(new TextDecoder().decode(data));
    for (let i = 1; i <= n; i++) call.send(String(i % 10).repeat(1000));
    call.finish();
  });
  // Whoever else is there, each reaches the other.
  await eventually("b is reachable", () => a.me() !== undefined && b.me() !== undefined && a.devices.some((d) => d.id === b.me()!.id) && b.devices.some((d) => d.id === a.me()!.id));
  const there = b.me()!.id, here = b.devices[0].id;
  const text = (bytes: Uint8Array) => new TextDecoder().decode(bytes);
  check(text(await a.request(there, 1, "shout", "hello")) === "HELLO", "a call is answered");
  const unserved = await a.request(there, 1, "whisper", "").then(
    () => "answered",
    (e: CallFault) => e.fault,
  );
  check(unserved === "unserved", unserved);
  const long = await a.request(there, 1, "count", "2000");
  check(long.length === 2000000, "two megabytes flow through a window of a quarter");
  check(text(await b.request(here, 1, "shout", "me")) === "ME", "a device calls itself");

  // The pipe breaks; nothing is lost and nothing needs saying again.
  breakPipes();
  void a.write(1, (change) => change.insert(Message, "chat", 2000, { author: "offline" }));
  await eventually("what was written while away arrives", () => a.ready && b.ready && st().status === "ready" && last().author === "offline");
  check(text(await b.request(here, 1, "shout", "again")) === "AGAIN", "and calls go on");

  await questions(a, b);
  await whose(a, b);

  // A window nobody observes is let go.
  theirs.stop();
  window.stop();
  check(held(b).windows.size > 0, "a window lingers");
  await sleep(300);
  check(held(b).windows.size === 0 && held(b).pages.size === 0, "and then is let go");
  check(held(b).rows.size <= 1, `${held(b).rows.size} rows linger`);
}

// Questions, asked of one device about what another writes.
async function questions(a: Client, b: Client): Promise<void> {
  const Track = {
    name: c.string(16),
    words: c.text(17),
    length: c.number(18),
    liked: c.boolean(19),
    album: c.row(20),
    meta: c.json<{ tags: string[]; size: { mb: number } }>(21),
  };
  const Album = { title: c.string(24), year: c.number(25) };
  type T = { name: string; words?: string; length: number; liked?: boolean; album?: string; meta: { tags: string[]; size: { mb: number } } };
  const albums: string[] = [], tracks: string[] = [];
  const records = new Map<string, T>();
  const titles = ["Blue", "Red", "Green"];
  const names = ["alpha", "Beta", "gamma", "Delta", "ALPHA"];
  void a.write(1, (change) => {
    titles.forEach((title, i) => (albums[i + 1] = change.insert(Album, "albums", i + 1, { title, year: 1991 + i })));
    for (let i = 1; i <= 60; i++) {
      const t: T = {
        name: names[i % 5],
        words: i % 7 === 0 ? "The quick brown foxes" : i % 3 === 0 ? "a lazy dog, quick to sleep" : undefined,
        length: i * 10,
        liked: i % 2 === 0 ? true : i % 5 === 0 ? undefined : false,
        album: albums[i % 4],
        meta: { tags: [`t${i % 6}`, "all"], size: { mb: i / 4 } },
      };
      tracks[i] = change.insert(Track, "tracks", i, t);
      records.set(tracks[i], t);
    }
  });
  const textOf = (t: T) => (t.words ?? "").toLowerCase();
  // Each condition against what it means.
  const checks: [ReturnType<typeof w.all>, (t: T) => boolean][] = [
    [w.is("name", "Alpha"), (t) => t.name.toLowerCase() === "alpha"],
    [w.exactly("name", "ALPHA"), (t) => t.name === "ALPHA"],
    [w.among("length", [10, 20, 30, 5]), (t) => t.length <= 30],
    [w.among("name", ["beta", "DELTA"]), (t) => t.name === "Beta" || t.name === "Delta"],
    [w.between("length", 100, 200), (t) => t.length >= 100 && t.length <= 200],
    [w.over("length", 500), (t) => t.length > 500],
    [w.under("length", 50), (t) => t.length < 50],
    [w.between("length", undefined, 50), (t) => t.length <= 50],
    [w.is("liked", true), (t) => t.liked === true],
    [w.is("liked", false), (t) => t.liked === false],
    [w.has("liked"), (t) => t.liked !== undefined],
    [w.none(w.has("album")), (t) => t.album === undefined],
    [w.is("album", albums[2]), (t) => t.album === albums[2]],
    [w.begins("name", "AL"), (t) => t.name.toLowerCase() === "alpha"],
    [w.contains("name", "ELT"), (t) => t.name === "Delta"],
    [w.is("meta.tags", "t3"), (t) => t.meta.tags[0] === "t3"],
    [w.over("meta.size.mb", 10), (t) => t.meta.size.mb > 10],
    [w.matches("words", "quick"), (t) => textOf(t).includes("quick")],
    [w.matches("words", "lazy fox", { any: true, prefix: true }), (t) => t.words !== undefined],
    [w.matches("words", "brown quick"), (t) => textOf(t).includes("brown")],
    [w.matches("words", "brown quick", { phrase: true }), () => false],
    [w.matches("words", "quick brown", { phrase: true }), (t) => textOf(t).includes("brown")],
    [w.matches("words", "qiuck", { typos: 2 }), (t) => t.words !== undefined],
    [w.matches("words", "oxe", { inside: true }), (t) => textOf(t).includes("foxes")],
    [w.inList("tracks"), () => true],
    [w.ids([tracks[3], tracks[9], albums[1]]), (t) => t === records.get(tracks[3]) || t === records.get(tracks[9])],
    [w.refers("album", 1, w.over("year", 1991), Album), (t) => t.album === albums[2] || t.album === albums[3]],
    [w.any(w.under("length", 20), w.all(w.is("liked", true), w.over("length", 580))), (t) => t.length < 20 || (t.liked === true && t.length > 580)],
    [w.all(), () => true],
  ];
  for (const [i, [condition, means]] of checks.entries()) {
    const want: string[] = [];
    for (let j = 60; j >= 1; j--) if (means(records.get(tracks[j])!)) want.push(tracks[j]);
    let got!: Answer<typeof Track>;
    const asked = b.ask({ scope: 1, table: Track, where: w.all(w.inList("tracks"), condition), order: ["-length"], limit: 100 }, (s) => (got = s));
    await eventually(`question ${i + 1}`, () => {
      if (got.status !== "ready" || got.total !== want.length || got.rows.length !== want.length) return false;
      return got.rows.every((row, j) => row.id === want[j] && row.length === records.get(want[j])!.length);
    });
    asked.stop();
  }

  let got!: Answer<typeof Track>;
  const asked = b.ask(
    {
      scope: 1,
      table: Track,
      where: w.inList("tracks"),
      order: ["name", "-meta.size.mb:number"],
      limit: 3,
      offset: 2,
      totals: {
        whole: ["sum", "length"],
        least: ["min", "length"],
        most: ["max", "name"],
        liked: ["facet", "liked"],
        size: ["max", "meta.size.mb:number"],
        by_name: ["facet", "name", 2],
        known: ["count", "album"],
      },
    },
    (s) => (got = s),
  );
  await eventually("totals", () => got.status === "ready" && got.total === 60);
  check(got.first === 2 && got.rows.length === 3 && got.rows[0].id === tracks[55] && got.rows[1].id === tracks[54], "an order of two columns");
  const t = got.totals as Record<string, any>;
  check(t.whole === 18300 && t.least === 10 && t.most.toLowerCase() === "gamma" && t.size === 15 && t.known === 45, "sums, least, most, counts");
  check(t.by_name.length === 2 && t.by_name[0].count === 24 && t.by_name[0].value.toLowerCase() === "alpha" && t.by_name[1].count === 12, "facets");
  check(t.liked.length === 2 && t.liked[0].value === true && t.liked[0].count === 30 && t.liked[1].count === 24, "facets of a boolean");
  asked.move(0, 1);
  await eventually("another stretch", () => got.status === "ready" && got.first === 0 && got.rows.length === 1 && got.rows[0].id === tracks[60]);
  // And it stays true.
  void a.write(1, (change) => change.set(tracks[60], Track, { name: "zeta" }));
  await eventually("what is written is answered", () => got.rows[0].id === tracks[59] && (got.totals as any).most === "zeta");
  void a.write(1, (change) => change.set(tracks[59], Track, { liked: true }));
  await eventually("what is shown is kept up", () => got.rows[0].liked === true && (got.totals as any).liked[0].count === 31);
  let of!: Answer<typeof Album>;
  const counted = b.ask({ scope: 1, table: Album, where: w.referred(1, "album", w.is("liked", true), 10, undefined, Track), order: ["title"] }, (s) => (of = s));
  await eventually("albums with ten liked", () => (of.status === "ready" && of.total === 2 && of.rows[0].title === "Blue") || of.total === 1);
  counted.stop();
  asked.stop();
  let best!: Answer<typeof Track>;
  const searched = b.ask({ scope: 1, table: Track, where: w.matches("words", "quick foxes", { any: true }), order: ["best"], limit: 20 }, (s) => (best = s));
  await eventually("the best come first", () => best.status === "ready" && best.rows.length === 20 && best.rows[0].words === "The quick brown foxes");
  const typed = best.rows[0].id;
  check(!Client.internals(a).rows.has(binaryOf(typed)), "a holds nothing it was not shown");
  // Once, with what was written just before, and no more than once.
  void a.write(1, (change) => change.insert(Track, "tracks", 61, { name: "just now", length: 7000 }));
  const once = await a.fetch({ scope: 1, table: Track, where: w.is("name", "just now"), totals: { most: ["max", "length"] } });
  check(once.status === "ready" && once.rows.length === 1 && once.rows[0].length === 7000 && (once.totals as any).most === 7000, "asked once");
  await eventually("it is known there too", async () => (await b.fetch({ scope: 1, table: Track, where: w.over("length", 6000), limit: 1 })).total === 1);
  void a.write(1, (change) => change.delete(once.rows[0].id));
  check(once.rows[0].name === "just now" && (await a.fetch({ scope: 1, table: Track, where: w.is("name", "just now") })).total === 0, "and no more");
  const editor = a.text(typed, Track.words);
  editor.append(" ju"); // before it is here
  await eventually("what is being edited is had", () => editor.read() === "The quick brown foxes ju");
  await sleep(100);
  const began = now();
  editor.append("mp");
  await eventually("live text shows in an answer", () => best.rows.some((row) => row.id === typed && row.words === "The quick brown foxes jump"));
  check(now() - began < 500, "as it is typed, not once it is sealed");
  const other = b.text(typed, Track.words);
  other.append("!");
  await eventually("and what others write there is heard", () => editor.read() === "The quick brown foxes jump!");
  other.close();
  editor.close();
  const brief = a.text(tracks[1], Track.words);
  brief.append("typed and gone");
  brief.close();
  let shown!: Answer<typeof Track>;
  const shows = b.ask({ scope: 1, table: Track, where: w.matches("words", "typed and gone", { phrase: true }) }, (s) => (shown = s));
  await eventually("even if closed at once", () => shown.rows.length === 1 && shown.rows[0].id === tracks[1]);
  shows.stop();
  searched.stop();
  await eventually("nothing is held for those who edit no more", () => Client.internals(a).asked.size === 0);
  await eventually("nothing is asked", () => Client.internals(b).asked.size === 0);
}

// Whose a row is, on the other device, and as a question.
async function whose(a: Client, b: Client): Promise<void> {
  const News = { title: c.string(16), by: c.author(16), body: c.text(17), writers: c.authors(17) } satisfies Table;
  await eventually("both may write there", () => a.may(2, "write") && b.may(2, "write"));
  let id = "";
  void a.write(2, (change) => (id = change.insert(News, "news", 1, { title: "from ann" })));
  let there!: State<typeof News>;
  const win = b.window({ scope: 2, list: "news", table: News }, (s) => (there = s));
  await eventually("it says whose it is", () => there.rows.length === 1 && there.rows[0].by === "ann");
  const editor = b.text(id, News.body);
  editor.append("and bob");
  editor.close();
  const more = a.text(id, News.body);
  more.append("and ann");
  more.close();
  await eventually("and who wrote in a text", () => there.rows[0].writers.join(" ") === "ann bob");
  let of!: Answer<typeof News>;
  const asked = b.ask({ scope: 2, table: News, where: w.is("by", "ann"), totals: { whose: ["facet", "writers"] } }, (s) => (of = s));
  await eventually("it can be asked for", () => of.status === "ready" && of.rows.length === 1 && (of.totals as any).whose.length === 2);
  asked.stop();
  const other = b.ask({ scope: 2, table: News, where: w.is("by", "bob") }, (s) => (of = s));
  await eventually("and is nobody else's", () => of.status === "ready" && of.rows.length === 0);
  other.stop();
  win.stop();
}

function binaryOf(hex: string): string {
  let s = "";
  for (let i = 0; i < hex.length; i += 2) s += String.fromCharCode(parseInt(hex.slice(i, i + 2), 16));
  return s;
}
