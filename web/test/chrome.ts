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
  close(): Promise<void>;
}

export class Chrome {
  #p: ChildProcess;
  #ws: WebSocket;
  #profile: string;
  #next = 0;
  #waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  #sessions = new Map<string, (method: string, params: any) => void>();

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

  static async launch(): Promise<Chrome> {
    const bin = findChrome();
    if (!bin) throw new Error("no Chrome here: set CHROME to where it is");
    try {
      return await Chrome.#launch(bin, []);
    } catch (e) {
      // A machine may not give a browser what its sandbox is made of; nothing but the tests' own page is loaded here.
      if (!/sandbox/i.test(String(e))) throw e;
      return await Chrome.#launch(bin, ["--no-sandbox"]);
    }
  }

  static async #launch(bin: string, more: string[]): Promise<Chrome> {
    const profile = mkdtempSync(join(tmpdir(), "zsp-chrome-"));
    const flags = ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--disable-gpu", ...more];
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
    const listen = (session: string, who: string) => {
      this.#sessions.set(session, (method, params) => {
        if (method === "Runtime.consoleAPICalled") say(who + params.args.map((a: any) => a.value ?? a.description ?? "").join(" "));
        else if (method === "Runtime.exceptionThrown") say(who + "uncaught: " + (params.exceptionDetails.exception?.description ?? params.exceptionDetails.text));
        else if (method === "Target.attachedToTarget") {
          listen(params.sessionId, "(" + params.targetInfo.type + ") ");
          void this.#send("Runtime.enable", {}, params.sessionId);
          void this.#send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, params.sessionId);
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
