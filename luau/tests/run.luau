--!strict
-- Runs a test's body, and ends the process at once if it fails, saying how: Lune says an error in the main thread and
-- goes on as long as anything waits, as every socket's reader does, so a test that failed would wait until it was given
-- up on, and say only that it timed out.

local process = require("@lune/process")
local stdio = require("@lune/stdio")

return function(body: () -> ())
	local ok, why = xpcall(body, debug.traceback :: any)
	if not ok then
		stdio.ewrite("failed: " .. tostring(why) .. "\n")
		process.exit(1)
	end
end
