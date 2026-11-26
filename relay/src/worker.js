// The smallest consumer of the relay: it serves whoever presents ACCESS_TOKEN, or anyone if none is set.
// Yours would check an account, a subscription, a JWT.

import { Label, relay, Space } from "./index.js";

export { Label, Space };

export default relay({
  authenticate: ({ credential, env }) => !env.ACCESS_TOKEN || new TextDecoder().decode(credential) === env.ACCESS_TOKEN,
});
