package zsp

MAX_FRAME :: 4 << 20

Message :: enum u8 {
	Hello    = 1,
	Roster   = 2,
	Watch    = 3,
	Unwatch  = 4,
	Recon    = 5,
	Want     = 6,
	Cells    = 7,
	Ack      = 8,
	Live     = 9,
	Synced   = 10,
	Signal   = 11,
	Presence = 12,
	Error    = 13,
	Serve    = 14,
	Call     = 15,
	Flow     = 16,
	Author   = 17,
	Took     = 18,
}
