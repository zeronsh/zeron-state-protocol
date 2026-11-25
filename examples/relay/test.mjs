import { authenticate } from "./auth.js";
import assert from "node:assert";

const base64 = (b) => Buffer.from(b).toString("base64url");
async function token(said, secret, head = { alg: "HS256", typ: "JWT" }) {
  const message = `${base64(JSON.stringify(head))}.${base64(JSON.stringify(said))}`;
  const key = await crypto.subtle.importKey("raw", Buffer.from(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return `${message}.${base64(new Uint8Array(await crypto.subtle.sign("HMAC", key, Buffer.from(message))))}`;
}
const space = "ab".repeat(32);
const env = { TOKEN_SECRET: "shared with the sign-in" };
const soon = Math.floor(Date.now() / 1000) + 60;
const may = async (t, s = space) => await authenticate({ space: s, credential: Buffer.from(t), env });

const good = await token({ sub: "user_1", spaces: [space], exp: soon }, env.TOKEN_SECRET);
assert(await may(good));
assert(!(await may(good, "cd".repeat(32))), "a space it does not name");
assert(!(await may(await token({ spaces: [space], exp: soon - 120 }, env.TOKEN_SECRET))), "one that has run out");
assert(!(await may(await token({ spaces: [space] }, env.TOKEN_SECRET))), "one that never would");
assert(!(await may(await token({ spaces: [space], exp: soon }, "another"))), "one that somebody else signed");
assert(!(await may(await token({ spaces: [space], exp: soon }, env.TOKEN_SECRET, { alg: "none" }))));
assert(!(await may(good.slice(0, -2))) && !(await may("")) && !(await may("a.b.c")) && !(await may("🦊.🦊.🦊")));
assert(!(await may(await token({ spaces: space, exp: soon }, env.TOKEN_SECRET))), "a string is not a list that includes it");
console.log("ok");
