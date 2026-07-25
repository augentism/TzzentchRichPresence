local mod = get_mod("TzeentchRichPresence")

local native = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/native")

-- Discord application id. Replace with your own app's id from the developer
-- portal; asset keys (large_image etc.) resolve against that app's art assets.
local APPLICATION_ID = "0000000000000000000"

local session_start = os.time()

local function ensure_started()
	if mod._started ~= nil then
		return mod._started
	end

	local ok, error_message = native.init(APPLICATION_ID)

	mod._started = ok

	if not ok then
		mod:error("Discord SDK unavailable: %s", tostring(error_message):gsub("%%", "%%%%"))
	end

	return ok
end

-- Smoke test: a static presence, refreshed whenever the game recomputes its
-- own. The DLL suppresses the request when nothing actually changed.
local function set_presence()
	if not ensure_started() then
		return
	end

	native.set_presence({
		details = "Feeling things out",
		state = "FFI smoke test",
		start_time = session_start,
		party_size = 1,
		party_max = 4,
	})
end

mod:hook_safe("PresenceManager", "_update_my_presence", set_presence)

function mod.update()
	local messages = native.update()

	if messages then
		for _, message in ipairs(messages) do
			mod:info("[discord] %s", message:gsub("%%", "%%%%"))
		end
	end
end

function mod.on_unload()
	native.clear()
	native.shutdown()
end
