// Headless Chrome, driven over the DevTools protocol with nothing but Node: pages opened, closed, and asked to evaluate.

import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

const CANDIDATES: Record<string, string[]> = {
  linux: ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"],
  darwin: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium"],
  win32: [
    join(process.env.PROGRAMFILES ?? "C:\\Program Files", "Google\\Chrome\\Application\\chrome.exe"),
    join(process.env["PROGRAMFILES(X86)"] ?? "C:\\Program Files (x86)", "Google\\Chrome\\Application\\chrome.exe"),
    join(process.env.LOCALAPPDATA ?? "", "Google\\Chrome\\Application\\chrome.exe"),
  ],
};

/** Where Chrome is: $CHROME, or wherever the platform keeps it. */
export function findChrome(): string | undefined {
  if (process.env.CHROME) return process.env.CHROME;
  for (const c of CANDIDATES[process.platform] ?? []) {
    if (c.includes("/") || c.includes("\\")) {
      if (existsSync(c)) return c;
    } else {
      for (const dir of (process.env.PATH ?? "").split(delimiter)) if (existsSync(join(dir, c))) return join(dir, c);
    }
  }
  return undefined;
}

export interface Page {
  readonly id: string;
  /** Evaluates an expression, waiting for it if it is a promise, and gives back its value as JSON allows. */
  evaluate<T = unknown>(expression: string): Promise<T>;
  /** Says how much the page's origin may store, or, with none, lets it have what it would. */
  quota(bytes?: number): Promise<void>;
  /** The DevTools sessions of the page's workers, as they were attached, and a way to ask anything of one. */
  readonly workers: string[];
  /**
   * Has every worker the page starts from now on, until said otherwise, evaluate this before its own script runs: so that
   * a test may make the platform under it misbehave as it may, or watch what it does.
   */
  preamble(script: string | undefined): Promise<void>;
  cdp<T = any>(method: string, params?: object, session?: string): Promise<T>;
  close(): Promise<void>;
}

export class Chrome {
  #p: ChildProcess;
  #ws: WebSocket;
  #profile: string;
  #next = 0;
  #waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  #sessions = new Map<string, (method: string, params: any) => void>();
  /** What pages and their workers threw that nothing caught, since this was last emptied: each a failure of the test. */
  readonly uncaught: string[] = [];

  private constructor(p: ChildProcess, ws: WebSocket, profile: string) {
    this.#p = p;
    this.#ws = ws;
    this.#profile = profile;
    ws.onmessage = (e) => {
      const m = JSON.parse(String(e.data));
      if (m.id !== undefined) {
        const w = this.#waiting.get(m.id);
        this.#waiting.delete(m.id);
        if (m.error) w?.reject(new Error(m.error.message));
        else w?.resolve(m.result);
      } else if (m.sessionId) {
        this.#sessions.get(m.sessionId)?.(m.method, m.params);
      }
    };
  }

  /** With `throttled`, hidden tabs are held back as Chrome holds them back for anyone, and `flags` are added. */
  static async launch(options: { throttled?: boolean; flags?: string[] } = {}): Promise<Chrome> {
    const bin = findChrome();
    if (!bin) throw new Error("no Chrome here: set CHROME to where it is");
    try {
      return await Chrome.#launch(bin, options.flags ?? [], options.throttled === true);
    } catch (e) {
      // A machine may not give a browser what its sandbox is made of; nothing but the tests' own page is loaded here.
      if (!/sandbox/i.test(String(e))) throw e;
      return await Chrome.#launch(bin, [...(options.flags ?? []), "--no-sandbox"], options.throttled === true);
    }
  }

  static async #launch(bin: string, more: string[], throttled: boolean): Promise<Chrome> {
    const profile = mkdtempSync(join(tmpdir(), "zsp-chrome-"));
    // Every page here is a tab of one window, so all but the last opened are hidden; and the first, hidden as soon as a
    // second opens, is most often the one whose worker runs the node. A hidden tab's timers are held back, and on macOS
    // its renderer, workers and all, is run at the least priority there is, so that on a busy machine a node that runs
    // in milliseconds took tens of seconds (browser_tabs 5 to 30 s, against 1.5 to 5 s with these, on CI's macOS):
    // which is Chrome's scheduling of tabs nobody is looking at, not what these tests are of.
    const background = ["--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows"];
    const flags = ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--disable-gpu", ...(throttled ? [] : background), ...more];
    const p = spawn(bin, [...flags, "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
    const url = await new Promise<string>((resolve, reject) => {
      let err = "";
      p.stderr!.on("data", (d) => {
        err += d;
        const m = /DevTools listening on (ws:\/\/\S+)/.exec(err);
        if (m) resolve(m[1]);
      });
      p.on("exit", (code) => reject(new Error(`Chrome exited with ${code}: ${err}`)));
    });
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => ((ws.onopen = resolve), (ws.onerror = reject)));
    return new Chrome(p, ws, profile);
  }

  #send<T = any>(method: string, params: object = {}, sessionId?: string): Promise<T> {
    const id = ++this.#next;
    this.#ws.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((resolve, reject) => this.#waiting.set(id, { resolve, reject }));
  }

  /** Opens a page, whose console is said to `say`. */
  async open(url: string, say: (line: string) => void = console.log): Promise<Page> {
    const { targetId } = await this.#send<{ targetId: string }>("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await this.#send<{ sessionId: string }>("Target.attachToTarget", { targetId, flatten: true });
    // What a page or any of its workers says is said.
    const workers: string[] = [];
    let preamble: string | undefined;
    const onPause = new Map<string, () => Promise<void>>(); // a worker's, paused to be given its preamble
    const listen = (session: string, who: string) => {
      this.#sessions.set(session, (method, params) => {
        if (method === "Runtime.consoleAPICalled") say(who + params.args.map((a: any) => a.value ?? a.description ?? "").join(" "));
        else if (method === "Runtime.exceptionThrown") {
          const what = who + (params.exceptionDetails.exception?.description ?? params.exceptionDetails.text);
          this.uncaught.push(what);
          say("uncaught: " + what);
        } else if (method === "Debugger.paused") {
          const go = onPause.get(session);
          onPause.delete(session);
          void go?.().catch(() => {});
        } else if (method === "Target.attachedToTarget") {
          const child = params.sessionId;
          if (params.targetInfo.type === "worker") workers.push(child);
          listen(child, "(" + params.targetInfo.type + ") ");
          void this.#send("Runtime.enable", {}, child).catch(() => {}); // or gone already
          void this.#send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, child).catch(() => {});
          if (params.waitingForDebugger) {
            // Paused as it starts: and, with a preamble, again just before its script runs, which is when its global
            // scope is there to evaluate the preamble in.
            const script = params.targetInfo.type === "worker" ? preamble : undefined;
            void (async () => {
              if (script !== undefined) {
                onPause.set(child, async () => {
                  const r = await this.#send("Runtime.evaluate", { expression: script, returnByValue: true }, child);
                  if (r.exceptionDetails) say(`(worker) preamble threw: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
                  await this.#send("Debugger.disable", {}, child);
                  await this.#send("Debugger.resume", {}, child).catch(() => {});
                });
                await this.#send("Debugger.enable", {}, child);
                await this.#send("Debugger.setInstrumentationBreakpoint", { instrumentation: "beforeScriptExecution" }, child);
              }
              await this.#send("Runtime.runIfWaitingForDebugger", {}, child);
            })().catch(() => {}); // gone already, as a page loaded again takes its workers with it
          }
        }
      });
    };
    listen(sessionId, "");
    await this.#send("Runtime.enable", {}, sessionId);
    await this.#send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sessionId);
    await this.#send("Page.enable", {}, sessionId);
    const loaded = new Promise<void>((resolve) => {
      const was = this.#sessions.get(sessionId)!;
      this.#sessions.set(sessionId, (method, params) => {
        if (method === "Page.loadEventFired") resolve();
        was(method, params);
      });
    });
    await this.#send("Page.navigate", { url }, sessionId);
    await loaded;
    return {
      id: targetId,
      evaluate: async <T>(expression: string) => {
        const r = await this.#send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sessionId);
        if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
        return r.result.value as T;
      },
      workers,
      preamble: async (script) => {
        preamble = script;
        await this.#send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: script !== undefined, flatten: true }, sessionId);
      },
      cdp: (method: string, params: object = {}, session?: string) => this.#send(method, params, session ?? sessionId),
      quota: async (bytes?: number) => {
        const origin = new URL(url).origin;
        await this.#send("Storage.overrideQuotaForOrigin", bytes === undefined ? { origin } : { origin, quotaSize: bytes }, sessionId);
      },
      close: async () => {
        this.#sessions.delete(sessionId);
        await this.#send("Target.closeTarget", { targetId });
      },
    };
  }

  async close(): Promise<void> {
    try {
      await this.#send("Browser.close");
    } catch {
      // it has gone already
    }
    this.#ws.close();
    await new Promise((resolve) => (this.#p.exitCode !== null ? resolve(undefined) : this.#p.once("exit", resolve)));
    rmSync(this.#profile, { recursive: true, force: true, maxRetries: 5 });
  }
}
