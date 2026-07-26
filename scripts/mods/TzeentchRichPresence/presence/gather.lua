local mod = get_mod("TzeentchRichPresence")

local util = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/util")

-- Reads the game and produces a plain snapshot table. Knows nothing about
-- Discord; formatting lives in format.lua.
--
-- Managers.state is rebuilt wholesale on every game-state transition, so
-- nothing in here may be cached across frames -- every accessor re-resolves.

local gather = {}

local MAX_PARTY = 4

-- The hub, the Psykhanium and the prologue are all real mission templates, so
-- Managers.state.mission resolves in them and they would otherwise be treated
-- as missions -- which is how the Mourningstar ended up reporting a difficulty.
-- Gate on the game mode instead; anything not listed here counts as combat, so
-- new mission types default to being shown.
local NON_COMBAT_GAME_MODES = {
	hub = true,
	prologue = true,
	prologue_hub = true,
	shooting_range = true,
	training_grounds = true,
}

local function mechanism_data()
	-- MechanismManager.mechanism_data() is `return self._mechanism:mechanism_data()`
	-- with no guard, so it errors outright between states.
	local manager = Managers and Managers.mechanism

	if not manager or not manager._mechanism then
		return {}
	end

	return util.safe(manager.mechanism_data, manager) or {}
end

local function state_manager(name)
	local state = Managers and Managers.state

	return state and state[name] or nil
end

--- Mission key ("cm_archives") and its localization id.
local function get_mission()
	local mission_manager = state_manager("mission")

	if mission_manager then
		local key = util.safe(mission_manager.mission_name, mission_manager)
		local template = util.safe(mission_manager.mission, mission_manager)

		if key and template then
			return key, template.mission_name, template.zone_id, template.game_mode_name
		end
	end

	-- Loading screens / hub: the mechanism still knows where we are headed.
	local data = mechanism_data()

	if data.mission_name then
		local Missions = util.safe(require, "scripts/settings/mission/mission_templates")
		local template = Missions and Missions[data.mission_name]

		return data.mission_name,
			template and template.mission_name,
			template and template.zone_id,
			template and template.game_mode_name
	end

	return nil, nil, nil, nil
end

--- Difficulty as a 1-5 index into DangerSettings.
---
--- Since the difficulty overhaul this value is a plain index (1 = Uprising,
--- 5 = Auric), NOT the legacy resistance stat. Do not route it through
--- Danger.calculate_danger / get_danger_settings(): those match against the
--- old resistance values (2,3,4,4,5) and cannot map a 1-5 index -- Heresy and
--- Damnation both had resistance 4, so that path silently confuses the two.
local function get_difficulty_index()
	local difficulty_manager = state_manager("difficulty")
	local index

	if difficulty_manager then
		index = util.safe(difficulty_manager.get_initial_resistance, difficulty_manager)
	end

	if not index then
		index = mechanism_data().resistance
	end

	index = tonumber(index)

	local DangerSettings = util.safe(require, "scripts/settings/difficulty/danger_settings")

	if not index or not DangerSettings or index < 1 or index > #DangerSettings then
		return nil, nil
	end

	local danger = DangerSettings[index]

	return index, danger and danger.display_name
end

--- Havoc: nil outside havoc, else rank + circumstance/modifier arrays.
local function get_havoc()
	local difficulty_manager = state_manager("difficulty")

	if difficulty_manager then
		local parsed = util.safe(difficulty_manager.get_parsed_havoc_data, difficulty_manager)

		if parsed and parsed.havoc_rank then
			return {
				rank = parsed.havoc_rank,
				circumstances = parsed.circumstances or {},
				modifiers = parsed.modifiers or {},
			}
		end
	end

	-- Outside gameplay only the raw string is available. Take just the rank --
	-- the modifier field needs NetworkLookup, which is unreliable pre-mission.
	local raw = mechanism_data().havoc_data

	if type(raw) == "string" and raw ~= "" then
		local parts = string.split(raw, ";")
		local rank = tonumber(parts and parts[2])

		if rank then
			local circumstances = {}

			if parts[5] and parts[5] ~= "" then
				for _, name in ipairs(string.split(parts[5], ":")) do
					circumstances[#circumstances + 1] = name
				end
			end

			return { rank = rank, circumstances = circumstances, modifiers = {} }
		end
	end

	return nil
end

local function get_circumstance()
	local circumstance_manager = state_manager("circumstance")

	if circumstance_manager then
		local name = util.safe(circumstance_manager.circumstance_name, circumstance_manager)

		if name then
			return name
		end
	end

	return mechanism_data().circumstance_name
end

--- Cached so a late-arriving true_level result cannot make the presence churn.
local function get_level(profile, store)
	local level = profile.current_level

	local true_level_mod = get_mod and get_mod("true_level")

	if true_level_mod and profile.character_id then
		local cached = store and store.level_cache and store.level_cache[profile.character_id]

		if cached then
			return cached
		end

		-- Direct pcall, not util.safe: get_true_levels returns two values and
		-- util.safe only forwards the first, which would silently drop is_me.
		local ok, levels, is_me = pcall(true_level_mod.get_true_levels, profile.character_id)

		if ok and levels and is_me and levels.current_level then
			level = levels.current_level + (levels.additional_level or 0)

			if store then
				store.level_cache = store.level_cache or {}
				store.level_cache[profile.character_id] = level
			end
		end
	end

	return level
end

local function get_player(store)
	local player_manager = Managers and Managers.player

	if not player_manager then
		return nil
	end

	-- local_player_safe, never local_player: the unsafe one access-violates
	-- during boot and pcall cannot catch it.
	local player = util.safe(player_manager.local_player_safe, player_manager, 1)

	if not player then
		return nil
	end

	local profile = util.safe(player.profile, player)

	-- profile is nil for a window after spawn; without it archetype_name() is
	-- nil and name() returns a placeholder, which would flicker the class icon.
	if not profile or not profile.archetype then
		return nil
	end

	local name = util.safe(player.name, player)
	local archetype = util.safe(player.archetype_name, player)

	if not name or not archetype then
		return nil
	end

	return {
		name = name,
		archetype = archetype,
		level = get_level(profile, store),
	}
end

local function get_party(in_mission)
	local presence_manager = Managers and Managers.presence

	if not presence_manager then
		return { size = 0, max = 0 }
	end

	local myself = util.safe(presence_manager.presence_entry_myself, presence_manager)

	if not myself then
		return { size = 0, max = 0 }
	end

	local size

	if in_mission then
		size = util.safe(myself.num_mission_members, myself)
	end

	size = size or util.safe(myself.num_party_members, myself) or 0

	local id = mechanism_data().session_id

	-- No session id in the hub. Leave it nil and keep the sizes: the native
	-- side substitutes a stable per-session id, which is what makes the party
	-- still render as "(1 of 4)" outside a mission.
	if type(id) ~= "string" or #id < 2 then
		id = nil
	end

	return {
		id = id,
		size = math.min(math.max(size, 1), MAX_PARTY),
		max = MAX_PARTY,
	}
end

--- Single entry point. `store` is the mod's persistent table (level cache).
function gather.snapshot(store)
	local mission_key, mission_loc, zone_id, game_mode_name = get_mission()
	local in_mission = mission_key ~= nil
		and game_mode_name ~= nil
		and not NON_COMBAT_GAME_MODES[game_mode_name]

	-- Difficulty/havoc/circumstance are only meaningful in a real mission. The
	-- managers keep stale or default values in the hub, which is where the
	-- phantom "Heresy" came from.
	local difficulty_index, difficulty_loc, havoc, circumstance

	if in_mission then
		difficulty_index, difficulty_loc = get_difficulty_index()
		havoc = get_havoc()
		circumstance = get_circumstance()
	end

	local presence_manager = Managers and Managers.presence
	local activity_id = presence_manager and util.safe(presence_manager.activity_id, presence_manager)

	local solo_mod = get_mod and get_mod("SoloPlay")
	local solo = solo_mod ~= nil and util.safe(solo_mod.is_soloplay) == true

	return {
		in_mission = in_mission,
		mission_key = mission_key,
		mission_loc = mission_loc,
		zone_id = zone_id,
		game_mode_name = game_mode_name,
		difficulty_index = difficulty_index,
		difficulty_loc = difficulty_loc,
		havoc = havoc,
		circumstance = circumstance,
		player = get_player(store),
		party = get_party(in_mission),
		activity_id = activity_id,
		solo = solo,
	}
end

return gather
