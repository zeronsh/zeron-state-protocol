--!strict
-- The Zeron State Protocol, for Luau.

local ask = require("@self/ask")
local client = require("@self/client")
local mirror = require("@self/mirror")
local text = require("@self/text")

return table.freeze({
	connect = client.connect,
	string = client.columns.string,
	number = client.columns.number,
	boolean = client.columns.boolean,
	row = client.columns.row,
	custom = client.columns.custom,
	where = ask.where,
	text = client.columns.text,
	author = client.columns.author,
	authors = client.columns.authors,
	Text = text,
	mirror = mirror,
})
