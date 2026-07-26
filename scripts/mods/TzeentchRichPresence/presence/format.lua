local mod = get_mod("TzeentchRichPresence")

local util = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/util")
local assets = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/assets")
local invite = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/invite")

-- Turns a gather.snapshot() into the table native.set_presence() wants.
--
-- Everything here must be deterministic: the same game state has to produce a
-- byte-identical table every refresh, or the native dedupe cannot suppress the
-- request and we burn Discord's presence rate limit. That means no os.time()
-- and no pairs() over anything that reaches the output.

local format = {}

-- Discord's hard limits. Exceeding either rejects the WHOLE activity, so the
-- native side clamps too; these keep us from ever getting there.
--
-- Note the party count Discord renders as "(1 of 4)" is appended by Discord at
-- display time and does NOT count against the 128 -- but it does eat visual
-- width, which is why the character line goes last.
local DETAILS_BUDGET = 128
local STATE_BUDGET = 128
local SEP = " · "

-- The two "Fading light" entries are just havoc's own difficulty restated --
-- they carry no information the "Havoc <rank>" tier does not already give, and
-- they localize to the 30+ character "The Emperor's Fading light (I)/(II)".
-- Between them they appear on 321 of the 326 havoc matches in the real history.
local SKIP_CIRCUMSTANCE = {
	default = true,
	mutator_highest_difficulty = true,
	mutator_increased_difficulty = true,
}

local MAELSTROM_PREFIX = "^Maelstrom Mission%s+"

local function circumstance_templates()
	return util.safe(require, "scripts/settings/circumstance/circumstance_templates")
end

local function circumstance_template(name)
	if type(name) ~= "string" or SKIP_CIRCUMSTANCE[name] then
		return nil
	end

	local templates = circumstance_templates()

	return templates and templates[name] or nil
end

local function circumstance_display(name)
	local template = circumstance_template(name)

	return template and template.ui and util.loc(template.ui.display_name) or nil
end

--- Maelstrom is identified by the game's own art: flash_mission_* use
--- circumstances/maelstrom_01, high_flash_mission_* use maelstrom_02.
--- Matching the icon path beats matching name prefixes, which Fatshark renames.
local function is_maelstrom(name)
	local template = circumstance_template(name)
	local icon = template and template.ui and template.ui.icon

	return type(icon) == "string" and icon:find("circumstances/maelstrom", 1, true) ~= nil
end

--- "Maelstrom Mission D-I-IV-IX-G" -> "Maelstrom D-I-IV-IX-G". Falls back to
--- the full name when the prefix is absent.
---
--- Applied everywhere a maelstrom is displayed, not just as the tier: havoc
--- missions really do carry maelstrom circumstances (verified in the saved
--- history), and without this they read "Havoc 40 · Maelstrom Mission I-III".
local function maelstrom_label(name)
	local display = circumstance_display(name)

	if not display then
		return nil
	end

	local code = display:gsub(MAELSTROM_PREFIX, "")

	if code == "" or code == display then
		return display
	end

	return "Maelstrom " .. code
end

--- Display text for a circumstance in list position.
local function circumstance_label(name)
	if is_maelstrom(name) then
		return maelstrom_label(name)
	end

	return circumstance_display(name)
end

--- The difficulty tier, which leads the details line.
--- Also returns the circumstance it consumed (maelstrom names ARE the tier),
--- so the modifier list does not repeat it.
function format.tier(snapshot)
	local havoc = snapshot.havoc

	if havoc and havoc.rank then
		return "Havoc " .. tostring(havoc.rank), nil
	end

	if is_maelstrom(snapshot.circumstance) then
		return maelstrom_label(snapshot.circumstance) or "Maelstrom", snapshot.circumstance
	end

	return util.loc(snapshot.difficulty_loc), nil
end

--- The modifiers for the state line, in fixed priority order. The tier lives
--- on the details line now, so this is circumstances only.
function format.state_pieces(snapshot, consumed)
	local pieces = {}
	local havoc = snapshot.havoc
	local listed = {}

	-- 1. Havoc circumstances -- these are the displayable havoc modifiers.
	if havoc then
		for _, name in ipairs(havoc.circumstances) do
			local display = circumstance_label(name)

			if display and not listed[name] then
				listed[name] = true
				pieces[#pieces + 1] = display
			end
		end
	end

	-- 2. The live circumstance, unless havoc already listed it or it was
	--    consumed as the maelstrom tier. Havoc applies its circumstances
	--    through the same manager, so this would otherwise double-print.
	local circumstance = snapshot.circumstance

	if circumstance and circumstance ~= consumed and not listed[circumstance] then
		local display = circumstance_label(circumstance)

		if display then
			pieces[#pieces + 1] = display
		end
	end

	-- Havoc's numeric modifiers are intentionally omitted: they are determined
	-- by the havoc rank, so "Havoc 40" already conveys them.

	return pieces
end

--- "Havoc 40 · Archivum Sycorax". The map alone if there is no tier, and the
--- current activity when we are not in a mission at all.
---
--- Discord's details and state are single-line fields -- a real line feed is
--- collapsed to a space and "\n" renders literally, both verified against the
--- live SDK -- so the modifiers share this line rather than starting a new one.
local function build_headline(snapshot, tier)
	local map = snapshot.mission_loc and util.loc(snapshot.mission_loc)

	if snapshot.in_mission and not map then
		map = util.humanize(snapshot.mission_key)
	end

	if tier and map then
		return tier .. SEP .. map
	end

	if map then
		return map
	end

	-- Hub / character select / loading: describe the activity instead.
	local PresenceSettings = util.safe(require, "scripts/settings/presence/presence_settings")
	local settings = PresenceSettings
		and PresenceSettings.settings
		and snapshot.activity_id
		and PresenceSettings.settings[snapshot.activity_id]

	return settings and util.loc(settings.hud_localization) or "In the Mourningstar"
end

--- Joins pieces under a byte budget, stopping at the first piece that does not
--- fit rather than skipping it and trying the next.
---
--- Skipping would make omissions look arbitrary, and worse, would make the line
--- flip back and forth as a modifier's level changes digit width -- defeating
--- the native dedupe and churning the presence.
function format.join_budget(pieces, budget, separator)
	if #pieces == 0 then
		return nil
	end

	-- Piece 1 is the headline (tier + map) and must never be dropped.
	local result = util.clip(pieces[1], budget)
	local dropped = 0

	for i = 2, #pieces do
		local piece = pieces[i]

		if dropped == 0 and #result + #separator + #piece <= budget then
			result = result .. separator .. piece
		else
			dropped = dropped + 1
		end
	end

	if dropped > 0 then
		local suffix = " +" .. tostring(dropped)

		if #result + #suffix <= budget then
			result = result .. suffix
		end
	end

	return result
end

--- "Calvin - Zealot 30". nil when the profile has not landed yet.
local function build_player_line(snapshot)
	local player = snapshot.player

	if not player then
		return nil
	end

	local Archetypes = util.safe(require, "scripts/settings/archetype/archetypes")
	local archetype = Archetypes and Archetypes[player.archetype]
	local class_name = archetype and util.loc(archetype.archetype_name)
		or util.humanize(player.archetype)

	if class_name and player.level then
		return string.format("%s - %s %d", player.name, class_name, player.level)
	end

	if class_name then
		return string.format("%s - %s", player.name, class_name)
	end

	return player.name
end

--- snapshot + latched start time -> presence table, or nil if unusable.
function format.build(snapshot, start_time)
	local tier, consumed = format.tier(snapshot)
	local headline = build_headline(snapshot, tier)

	if not headline then
		return nil
	end

	-- details carries tier + map + modifiers; the modifiers drop first if the
	-- line ever overruns, since the headline is piece 1 and never dropped.
	local pieces = { headline }

	for _, modifier in ipairs(format.state_pieces(snapshot, consumed)) do
		pieces[#pieces + 1] = modifier
	end

	local details = format.join_budget(pieces, DETAILS_BUDGET, SEP)

	-- state is the character alone, so Discord's "(1 of 4)" trails it cleanly.
	local state = build_player_line(snapshot)

	local party = snapshot.party or {}
	local archetype = snapshot.player and snapshot.player.archetype

	return {
		details = details,
		state = state,
		large_image = assets.mission_image(snapshot.mission_key),
		large_text = details,
		small_image = archetype and assets.class_icon(archetype) or nil,
		small_text = player_line,
		party_id = party.id,
		party_size = party.size,
		party_max = party.max,
		join_secret = invite.build_secret(snapshot),
		start_time = start_time,
	}
end

return format
