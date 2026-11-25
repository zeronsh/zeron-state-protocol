--!strict
-- Scopes by name, so that what an application says about a team's rows cannot be said of anyone else's by mistake.
-- See docs/scoping.md.
--
-- A scope is a number, and nothing says what it is for. Here the scope everyone is in has a list of them, by name; a
-- name is of use only to whoever may read the scope it is for, and there is no harm in others seeing it. (Where there
-- would be, keep the name in the scope itself.)

local zsp = require("../../luau/zsp")

local Named = { name = zsp.string(16), scope = zsp.number(17) }

export type Place = {
	read name: string,
	read scope: number,
	read writable: boolean,
	read insert: (table: any, list: string, order: number, values: { [string]: any }) -> string,
	read change: (id: string, table: any, values: { [string]: any }) -> (),
	read window: (query: any, observer: (any) -> ()) -> any,
	read ask: (question: any, observer: (any) -> ()) -> any,
	read fetch: (question: any) -> any,
}

local workspace = {}

-- Whose device this is, as the space has it: what `zspd subject`, or your own admin, said.
function workspace.user(client: any): string
	local mine = client.devices[1]
	return if mine then mine.subject else ""
end

-- Names a scope. Called by someone who may write in the one everyone is in.
function workspace.name(client: any, everyone: number, name: string, scope: number)
	client:write(everyone, function(change)
		change.insert(Named, "scopes", scope, { name = name, scope = scope })
	end)
end

-- The place by a name, if there is one and this device may read it. Everything done there is done in its scope.
function workspace.place(client: any, everyone: number, name: string): Place?
	local scope: number = everyone
	if name ~= "everyone" then
		local found = client:fetch({
			scope = everyone,
			table = Named,
			where = zsp.where.all(zsp.where.in_list("scopes"), zsp.where.is("name", name)),
			limit = 1,
		})
		if #found.rows == 0 then
			return nil
		end
		scope = found.rows[1].scope
	end
	if not client:may(scope, "read") then
		return nil -- and were it asked anyway, it would be refused
	end
	local function here(what: any): any
		local bound = table.clone(what)
		bound.scope = scope
		return bound
	end
	local place: Place = {
		name = name,
		scope = scope,
		writable = client:may(scope, "write"),
		insert = function(columns: any, list: string, order: number, values: any): string
			local id = ""
			client:write(scope, function(change)
				id = change.insert(columns, list, order, values)
			end)
			return id
		end,
		change = function(id: string, columns: any, values: any)
			client:write(scope, function(change)
				change.set(id, columns, values)
			end)
		end,
		window = function(query: any, observer: (any) -> ()): any
			return client:window(here(query), observer)
		end,
		ask = function(question: any, observer: (any) -> ()): any
			return client:ask(here(question), observer)
		end,
		fetch = function(question: any): any
			return client:fetch(here(question))
		end,
	}
	return table.freeze(place)
end

return table.freeze(workspace)
