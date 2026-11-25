--!strict
-- The Zeron State Protocol, for Luau.

local client = require("@self/client")
local text = require("@self/text")

return table.freeze({
	connect = client.connect,
	string = client.columns.string,
	number = client.columns.number,
	boolean = client.columns.boolean,
	custom = client.columns.custom,
	text = client.columns.text,
	Text = text,
})
