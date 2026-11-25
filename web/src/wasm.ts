// Where the node comes from: node.wasm beside this file, built by `./x wasm`.

/** Compiles the node, once; it may then be instantiated for as many devices as there are. */
export async function loadModule(url: URL = new URL("./node.wasm", import.meta.url)): Promise<WebAssembly.Module> {
  if (url.protocol === "file:") {
    const { readFile } = await import("node:fs/promises");
    return WebAssembly.compile(await readFile(url));
  }
  return WebAssembly.compileStreaming(fetch(url));
}
