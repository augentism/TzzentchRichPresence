local mod = get_mod("TzeentchRichPresence")

local native = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/native")
local util = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/util")
local gather = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/gather")
local format = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/format")
local invite = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/invite")

-- Discord application id, from discord.com/developers/applications.
-- Art asset keys (see presence/assets.lua) resolve against this app.
local APPLICATION_ID = "1530377227470897152"

-- Darktide's Steam app id, so Discord can launch the game when someone accepts
-- an invite with the game closed. Without this a join only works if the
-- recipient already has Darktide running.
local STEAM_APP_ID = 1361210

-- PresenceManager._update_my_presence is event-driven and does NOT fire during
-- a mission, so it cannot be the only trigger; poll as well. Polling is cheap
-- because the native side drops a commit when nothing changed.
local REFRESH_INTERVAL = 2.0

-- Survives hot reloads, which is what keeps the match timer from resetting
-- when you reload mods mid-mission.
local store = mod:persistent_table("tzrp_presence")

store.session_start = store.session_start or os.time()
store.level_cache = store.level_cache or {}
store.elapsed = 0

local function start_time()
	return store.match_start or store.session_start
end

local function ensure_started()
	if store.started ~= nil then
		return store.started
	end

	local ok, error_message = native.init(APPLICATION_ID)

	store.started = ok

	if not ok then
		mod:error("Discord SDK unavailable: %s", util.escape(error_message))
		return ok
	end

	local registered, reason = native.register_steam_launch(STEAM_APP_ID)

	if not registered and reason then
		mod:info("[tzrp] %s", util.escape(reason))
	end

	return ok
end

local function refresh()
	if not ensure_started() then
		return
	end

	local snapshot = gather.snapshot(store)
	local presence = format.build(snapshot, start_time())

	if not presence then
		return
	end

	native.set_presence(presence)

	-- Both of these log only on change; refresh() runs every REFRESH_INTERVAL
	-- and would otherwise flood the console.
	local line = tostring(presence.details) .. " | " .. tostring(presence.state)

	if line ~= store.last_line then
		store.last_line = line
		util.debug(line)
	end

	local invite_state = (presence.join_secret and "advertising: " or "no join offered: ")
		.. tostring(presence.join_reason)

	if invite_state ~= store.last_invite_state then
		store.last_invite_state = invite_state
		util.debug("invite: " .. invite_state)
	end
end

-- Mission start: latch the match timer. Same trigger the scoreboard mod uses.
mod:hook(CLASS.StateGameplay, "on_enter", function(func, self, parent, params, creation_context, ...)
	local result = func(self, parent, params, creation_context, ...)

	store.match_start = os.time()
	store.last_line = nil

	return result
end)

-- hook_safe gets the original args directly -- no `func` first.
mod:hook_safe(CLASS.StateGameplay, "on_exit", function(self, ...)
	store.match_start = nil
	store.last_line = nil
end)

-- Extra immediate trigger so party/profile changes show up without waiting for
-- the poll. Both paths funnel through refresh().
mod:hook_safe("PresenceManager", "_update_my_presence", function(self, ...)
	refresh()
end)

function mod.update(dt)
	local messages = native.update()

	if messages then
		for _, message in ipairs(messages) do
			mod:info("[discord] %s", util.escape(message))
		end
	end

	-- Someone accepted an invite to our party in their Discord client, so this
	-- copy of the game is being told to join them.
	local joins = native.poll_joins()

	if joins then
		util.debug(string.format("join: %d secret(s) delivered by Discord", #joins))

		for _, secret in ipairs(joins) do
			local ok, reason = invite.accept(secret)

			if ok then
				mod:echo("Joining party from Discord invite...")
			else
				-- Not gated on debug_logging: a refused join is something the
				-- player asked for and got nothing from, so it always logs.
				mod:info("[tzrp] ignored join: %s", util.escape(tostring(reason)))
				mod:echo("Could not join: " .. tostring(reason))
			end
		end
	end

	store.elapsed = (store.elapsed or 0) + (dt or 0)

	if store.elapsed >= REFRESH_INTERVAL then
		store.elapsed = 0
		refresh()
	end
end

function mod.on_unload()
	native.clear()
	native.shutdown()
	store.started = nil
end
