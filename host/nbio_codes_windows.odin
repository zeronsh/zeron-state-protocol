package host

import win "core:sys/windows"

// What Windows says of a connection refused, and of one reset, as tests of the event loop expect to be told.
REFUSED_CODE :: u16(win.System_Error.WSAECONNREFUSED)
RESET_CODES :: [?]u16{u16(win.System_Error.WSAECONNRESET), u16(win.System_Error.WSAECONNABORTED)}
