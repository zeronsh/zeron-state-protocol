// Who may use a relay: those who bring a token your own sign-in has signed, that names the space. It says nothing of
// what a device may read or write there: that is the space's signed roster, which a relay enforces and cannot change.
//
// The token is an ordinary JWT (HS256), and what it has to say is:
//
//   { "sub": "user_123", "spaces": ["<64 hex digits>"], "exp": 1800000000 }
//
// A device presents it as its credential: `zspd run --credential=<token>`, or host.Config.credential.

const text = new TextEncoder();
const unbase64 = (s) => Uint8Array.from(atob(s.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));

export async function claims(token, secret, now = Date.now()) {
  const [head, body, signature, ...rest] = token.split(".");
  if (!signature || rest.length) return null;
  try {
    if (JSON.parse(new TextDecoder().decode(unbase64(head))).alg !== "HS256") return null;
    const key = await crypto.subtle.importKey("raw", text.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    if (!(await crypto.subtle.verify("HMAC", key, unbase64(signature), text.encode(`${head}.${body}`)))) return null;
    const said = JSON.parse(new TextDecoder().decode(unbase64(body)));
    return typeof said.exp === "number" && said.exp * 1000 > now ? said : null;
  } catch {
    return null;
  }
}

/** For relay({ authenticate }): the device has proven its key by now, and the space is the one it asked for. */
export async function authenticate({ space, credential, env }) {
  const said = await claims(new TextDecoder().decode(credential), env.TOKEN_SECRET);
  return Array.isArray(said?.spaces) && said.spaces.includes(space);
}
