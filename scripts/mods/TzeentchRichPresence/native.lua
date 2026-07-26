local mod = get_mod("TzeentchRichPresence")
local ffi = Mods.lua.ffi

local MOD_BIN = "../mods/TzeentchRichPresence/bin/"
local RUNTIME_PATH = MOD_BIN .. "tzrp.dll"
-- tzrp.dll imports this by bare name. Windows resolves imports against the
-- process directory and PATH, never the mod folder, so we must load it by
-- explicit path first -- once it is in the loader's table by name, tzrp's
-- import resolves to this already-loaded module.
local SDK_PATH = MOD_BIN .. "discord_partner_sdk.dll"

local MESSAGE_BUFFER_SIZE = 1024

local native = {}

local instances = mod:persistent_table("instances")
instances.tzrp_runtime = instances.tzrp_runtime or {}

local state = instances.tzrp_runtime

if not pcall(ffi.typeof, "TzrpRuntime_CDEF") then
	ffi.cdef([[
		typedef struct { int unused; } TzrpRuntime_CDEF;

		int  TZRP_Init(const char* application_id);
		void TZRP_Shutdown(void);
		void TZRP_Update(void);
		int  TZRP_Status(void);
		int  TZRP_RegisterSteamLaunch(unsigned int steam_app_id);

		void TZRP_SetDetails(const char* value);
		void TZRP_SetState(const char* value);
		void TZRP_SetLargeImage(const char* key, const char* text);
		void TZRP_SetSmallImage(const char* key, const char* text);
		void TZRP_SetParty(const char* id, int current, int max);
		void TZRP_SetJoinSecret(const char* value);
		void TZRP_SetTimestamps(int64_t start_time, int64_t end_time);
		void TZRP_SetActivityType(int activity_type);
		void TZRP_ClearButtons(void);
		void TZRP_AddButton(const char* label, const char* url);

		int  TZRP_Commit(int force);
		void TZRP_Clear(void);

		int  TZRP_PollMessage(char* buffer, int buffer_size);
		int  TZRP_PollJoin(char* buffer, int buffer_size);
		const char* TZRP_LastError(void);
	]])
end

local message_buffer = ffi.new("char[?]", MESSAGE_BUFFER_SIZE)

local function load_runtime()
	if state.runtime then
		return state.runtime
	end

	if state.load_failed then
		return nil, state.load_error
	end

	-- Order matters: the dependency has to be resolved by path first.
	local sdk_ok, sdk_error = pcall(ffi.load, SDK_PATH)

	if not sdk_ok then
		state.load_failed = true
		state.load_error = "discord_partner_sdk.dll: " .. tostring(sdk_error)
		return nil, state.load_error
	end

	state.sdk = sdk_error

	local ok, runtime_or_error = pcall(ffi.load, RUNTIME_PATH)

	if not ok then
		state.load_failed = true
		state.load_error = "tzrp.dll: " .. tostring(runtime_or_error)
		return nil, state.load_error
	end

	state.runtime = runtime_or_error

	return state.runtime
end

-- ffi resolves a symbol on first access and THROWS if the DLL does not export
-- it. Lua hot-reloads but the DLL cannot be replaced while the game is running,
-- so a newer Lua against an older tzrp.dll is a normal state to be in -- it must
-- degrade to "feature unavailable", not break the whole mod.
local function has_symbol(runtime, name)
	state.symbols = state.symbols or {}

	if state.symbols[name] == nil then
		state.symbols[name] = pcall(function()
			return runtime[name]
		end)
	end

	return state.symbols[name]
end

local function last_error(runtime)
	local ok, message = pcall(function()
		return ffi.string(runtime.TZRP_LastError())
	end)

	if ok and message ~= "" then
		return message
	end

	return "unknown error"
end

--- Loads the DLLs and creates the Discord client. Returns false, error on failure.
function native.init(application_id)
	local runtime, load_error = load_runtime()

	if not runtime then
		return false, load_error
	end

	if runtime.TZRP_Init(application_id) == 0 then
		return false, last_error(runtime)
	end

	state.initialized = true

	return true
end

--- Registers how Discord should launch the game for an invite accepted while
--- the game is closed. Harmless to call repeatedly; only affects this machine.
function native.register_steam_launch(steam_app_id)
	if not state.runtime or not state.initialized then
		return false
	end

	if not has_symbol(state.runtime, "TZRP_RegisterSteamLaunch") then
		return false, "tzrp.dll predates invite support - close the game and redeploy"
	end

	return state.runtime.TZRP_RegisterSteamLaunch(steam_app_id) ~= 0
end

function native.shutdown()
	if state.runtime and state.initialized then
		state.runtime.TZRP_Shutdown()
		state.initialized = false
	end
end

--- Pumps the SDK and drains queued diagnostics. Call once per frame.
--- Returns an array of message strings (usually empty).
function native.update()
	if not state.runtime or not state.initialized then
		return nil
	end

	state.runtime.TZRP_Update()

	local messages = nil

	while state.runtime.TZRP_PollMessage(message_buffer, MESSAGE_BUFFER_SIZE) ~= 0 do
		messages = messages or {}
		messages[#messages + 1] = ffi.string(message_buffer)
	end

	return messages
end

--- Drains join secrets delivered by Discord (someone accepted an invite to our
--- party, on THEIR machine). Returns an array of secret strings, or nil.
function native.poll_joins()
	if not state.runtime or not state.initialized then
		return nil
	end

	if not has_symbol(state.runtime, "TZRP_PollJoin") then
		return nil
	end

	local secrets = nil

	while state.runtime.TZRP_PollJoin(message_buffer, MESSAGE_BUFFER_SIZE) ~= 0 do
		secrets = secrets or {}
		secrets[#secrets + 1] = ffi.string(message_buffer)
	end

	return secrets
end

--- presence fields: details, state, large_image, large_text, small_image,
--- small_text, party_id, party_size, party_max, start_time, end_time,
--- activity_type, buttons = { { label = , url = }, ... }
--- Staging is cheap; the DLL skips the actual request when nothing changed.
function native.set_presence(presence)
	if not state.runtime or not state.initialized then
		return false
	end

	local runtime = state.runtime

	runtime.TZRP_SetDetails(presence.details)
	runtime.TZRP_SetState(presence.state)
	runtime.TZRP_SetLargeImage(presence.large_image, presence.large_text)
	runtime.TZRP_SetSmallImage(presence.small_image, presence.small_text)
	runtime.TZRP_SetParty(presence.party_id or "", presence.party_size or 0, presence.party_max or 0)
	if has_symbol(runtime, "TZRP_SetJoinSecret") then
		runtime.TZRP_SetJoinSecret(presence.join_secret)
	end
	runtime.TZRP_SetTimestamps(presence.start_time or 0, presence.end_time or 0)
	runtime.TZRP_SetActivityType(presence.activity_type or 0)

	runtime.TZRP_ClearButtons()

	if presence.buttons then
		for _, button in ipairs(presence.buttons) do
			runtime.TZRP_AddButton(button.label, button.url)
		end
	end

	return runtime.TZRP_Commit(presence.force and 1 or 0) ~= 0
end

function native.clear()
	if state.runtime and state.initialized then
		state.runtime.TZRP_Clear()
	end
end

function native.status()
	if not state.runtime or not state.initialized then
		return -1
	end

	return state.runtime.TZRP_Status()
end

return native
