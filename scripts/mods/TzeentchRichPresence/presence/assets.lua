local mod = get_mod("TzeentchRichPresence")

local util = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/util")

-- Discord art asset keys, plus display names for the identifiers the game
-- ships without localization.
--
-- ============================ UPLOAD INSTRUCTIONS ============================
-- Asset keys are uploaded at:
--   discord.com/developers/applications -> <your app> -> Rich Presence -> Art Assets
--
-- Keys must match these names EXACTLY (all lowercase/underscore already):
--
--   1. mission_default   <- REQUIRED, fallback for any mission without art
--   2. class_default     <- REQUIRED, fallback for any unknown archetype
--   3. The 7 class icons: veteran zealot psyker ogryn adamant broker cryptic
--   4. Mission art named exactly as the mission ids in MISSION_KEYS below.
--
-- Upload 1 and 2 first: Discord renders NO image at all (not even a blank) when
-- a key is missing, so the fallbacks are what make a partial upload look sane.
--
-- MISSION_KEYS is a presence *set*, not a rename map -- the asset key IS the
-- mission id. To add art for a mission later, upload it and the entry here is
-- already waiting. Remove an entry only if you want it to fall back on purpose.
-- ============================================================================

local assets = {}

assets.MISSION_FALLBACK = "mission_default"
assets.CLASS_FALLBACK = "class_default"

-- Every playable mission id, taken from the real match history rather than the
-- template files (which also contain non-mission settings tables).
assets.MISSION_KEYS = {
	cm_archives = true,
	cm_habs = true,
	cm_raid = true,
	core_research = true,
	dm_forge = true,
	dm_propaganda = true,
	dm_rise = true,
	dm_stockpile = true,
	exp_wastes = true,
	fm_armoury = true,
	fm_cargo = true,
	fm_resurgence = true,
	hm_cartel = true,
	hm_complex = true,
	hm_strain = true,
	km_enforcer = true,
	km_enforcer_twins = true,
	km_heresy = true,
	km_station = true,
	lm_cooling = true,
	lm_rails = true,
	lm_scavenge = true,
	op_no_mans_land = true,
	op_train = true,
	-- Non-combat locations, included so the hub/training room get their own art
	-- if you choose to upload it.
	hub_ship = true,
	psykhanium = true,
	prologue = true,
	tg_shooting_range = true,
}

assets.CLASS_KEYS = {
	adamant = true,
	broker = true,
	cryptic = true,
	ogryn = true,
	psyker = true,
	veteran = true,
	zealot = true,
}

-- Note: havoc's numeric modifiers are deliberately not shown. They are fixed by
-- havoc rank, so "Havoc 40" already tells anyone who plays havoc what they are.

--- Discord asset key for a mission, falling back when no art is uploaded.
function assets.mission_image(mission_key)
	if mission_key and assets.MISSION_KEYS[mission_key] then
		return mission_key
	end

	return assets.MISSION_FALLBACK
end

--- Discord asset key for a class icon.
function assets.class_icon(archetype)
	if archetype and assets.CLASS_KEYS[archetype] then
		return archetype
	end

	return assets.CLASS_FALLBACK
end

return assets
