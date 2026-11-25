// A relay for your customers only. `npx wrangler secret put TOKEN_SECRET` with what your sign-in signs with.

import { relay, Space } from "../../relay/src/index.js";
import { authenticate } from "./auth.js";

export { Space };
export default relay({ authenticate });
