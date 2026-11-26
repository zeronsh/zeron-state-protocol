--!strict
-- The Zeron State Protocol, for Luau.

local ask = require("@self/ask")
local client = require("@self/client")
local mirror = require("@self/mirror")
local text = require("@self/text")

export type Client = client.Client
export type Device = client.Device
export type Call = client.Call
export type Process = client.Process
export type Stream = client.Stream
export type Service = client.Service
export type Entry = client.Entry
export type Files = client.Files
export type File = client.File
export type Transfer = client.Transfer
export type Result = client.Result
export type Resume = client.Resume

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
