// Timers for clients in a browser page that keep time by nothing of their own. A page's timers are held back while its tab
// is hidden, to the second, and once it has used up its wake-ups to the minute; a dedicated worker's are not. So such a
// client keeps time by a worker the page shares among all of them: one that sleeps but for the timers asked of it, made
// when the first is asked for and let go of once no client is left to ask. A client in Node, Deno or a worker, or in a
// page that can make no worker, as one whose Content-Security-Policy forbids it, keeps time by setTimeout, as before.

/** Runs f later, and returns a way to cancel it. */
export type After = (ms: number, f: () => void) => () => void;

// The worker's whole script: a timer for each id said, said back when it is up, or forgotten when the id is said with -1.
const SCRIPT = "const t=new Map();onmessage=(e)=>{const[i,m]=e.data;if(m<0){clearTimeout(t.get(i));t.delete(i)}else t.set(i,setTimeout(()=>{t.delete(i);postMessage(i)},m))}";

interface Pending {
  f: () => void;
  due: number; // by performance.now()
  page?: ReturnType<typeof setTimeout>; // kept by the page instead, as no worker could keep it
}

let worker: Worker | undefined;
let url = "";
let broken = false; // no worker can be made here: timers are the page's
let users = 0; // clients that keep time here, not yet closed
let next = 0;
const pending = new Map<number, Pending>();

// A page, not a worker, Node or Deno (none of which holds back timers so), and one that can make workers.
function inPage(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof document !== "undefined" &&
    typeof Worker === "function" &&
    typeof Blob === "function" &&
    typeof URL !== "undefined" &&
    typeof URL.createObjectURL === "function"
  );
}

/**
 * Timers for a client that has none of its own, and a way to let go of them once it is closed: in a browser page, kept
 * by the page's timer worker; elsewhere, none, and the client keeps time by setTimeout.
 */
export function pageTimers(): { after: After; release: () => void } | undefined {
  if (!inPage()) return undefined;
  users++;
  let released = false;
  return {
    after,
    release: () => {
      if (released) return;
      released = true;
      users--;
      stopIfIdle();
    },
  };
}

function after(ms: number, f: () => void): () => void {
  const id = ++next;
  const p: Pending = { f, due: performance.now() + ms };
  pending.set(id, p);
  const w = start();
  if (w) w.postMessage([id, ms]);
  else p.page = setTimeout(() => fire(id), ms);
  return () => {
    const was = pending.get(id);
    if (!was) return;
    pending.delete(id);
    if (was.page !== undefined) clearTimeout(was.page);
    else worker?.postMessage([id, -1]);
    stopIfIdle();
  };
}

function fire(id: number): void {
  const p = pending.get(id);
  if (!p) return; // cancelled since, or let go of with its client
  pending.delete(id);
  p.f();
}

// The worker, made if need be; or none, if none can be made here.
function start(): Worker | undefined {
  if (worker || broken) return worker;
  try {
    url = URL.createObjectURL(new Blob([SCRIPT], { type: "text/javascript" }));
    const w = new Worker(url, { name: "zsp timers" });
    w.onmessage = (e: MessageEvent<number>) => w === worker && fire(e.data);
    // One that could not be started after all, as one a policy forbids may not be until it is fetched: what it was to
    // keep the page keeps, each due when it was.
    w.onerror = (e) => {
      e.preventDefault();
      if (w === worker) fallBack();
    };
    worker = w;
  } catch {
    if (url) URL.revokeObjectURL(url);
    url = "";
    broken = true;
  }
  return worker;
}

function fallBack(): void {
  broken = true;
  stop();
  const now = performance.now();
  for (const [id, p] of pending) if (p.page === undefined) p.page = setTimeout(() => fire(id), Math.max(0, p.due - now));
}

// Nothing to keep and nobody to keep it for: the worker goes, and is made again should a client come to ask.
function stopIfIdle(): void {
  if (users === 0 && pending.size === 0) stop();
}

function stop(): void {
  worker?.terminate();
  worker = undefined;
  if (url) URL.revokeObjectURL(url);
  url = "";
}

/** How the page's timers stand, for tests: whether its worker is there, or could not be made, and for whom, keeping what. */
export function timerInternals(): { worker: boolean; broken: boolean; users: number; pending: number } {
  return { worker: worker !== undefined, broken, users, pending: pending.size };
}
