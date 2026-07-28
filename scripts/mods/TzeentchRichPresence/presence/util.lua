local mod = get_mod("TzeentchRichPresence")

-- Shared helpers. Nothing here touches the Discord side; these exist so the
-- gather/format modules can stay readable and so localization has exactly one
-- choke point.

local util = {}

--- Localizes a game loc id, returning nil (never "") when it cannot.
--- nil matters: the native side treats nil as "field unset", but an empty or
--- 1-character string violates Discord's minimum length and gets dropped with
--- a logged complaint every refresh.
function util.loc(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end

	local manager = Managers and Managers.localization

	if not manager then
		return nil
	end

	-- Localize() on a missing key returns a visible error marker, which would
	-- otherwise end up in the presence for everyone to see.
	local ok, exists = pcall(manager.exists, manager, key)

	if not ok or not exists then
		return nil
	end

	local localized_ok, value = pcall(manager.localize, manager, key)

	if not localized_ok or type(value) ~= "string" or value == "" then
		return nil
	end

	return value
end

--- Removes Stingray inline markup: "{#color(255,50,50)}Bob{#reset()}" -> "Bob".
---
--- The game renders these tags; Discord does not, so they would show up
--- literally in the presence. Mods that recolour names hook Player:name() and
--- wrap the result this way -- ColorSelection is the one that prompted this --
--- so anything read from a name has to be cleaned first.
---
--- Deliberately matches any {#...} tag rather than colour/reset specifically,
--- so a new tag type from another mod is stripped too.
function util.strip_markup(text)
	if type(text) ~= "string" then
		return text
	end

	local cleaned = text:gsub("{#.-}", "")

	-- Tags can leave stray padding behind once removed.
	cleaned = cleaned:match("^%s*(.-)%s*$")

	if cleaned == "" then
		return text
	end

	return cleaned
end

--- Doubles '%' so a localized string can be passed through mod:info/mod:echo,
--- which re-string.format their message and crash on a stray format spec.
function util.escape(text)
	return (tostring(text):gsub("%%", "%%%%"))
end

--- Logs one line to the console when the debug_logging setting is on.
--- Takes an already-formatted string: mod:info re-string.formats its message,
--- so anything containing a game-supplied '%' has to be escaped exactly once,
--- and doing it here keeps every caller from having to remember.
function util.debug(message)
	if not mod:get("debug_logging") then
		return
	end

	mod:info("[tzrp] %s", util.escape(tostring(message)))
end

--- Byte-length trim that never splits a UTF-8 sequence.
function util.clip(text, max_bytes)
	if type(text) ~= "string" or #text <= max_bytes then
		return text
	end

	local last = max_bytes

	while last > 0 and text:byte(last + 1) and text:byte(last + 1) >= 0x80 and text:byte(last + 1) < 0xC0 do
		last = last - 1
	end

	return text:sub(1, last)
end

--- Turns "reduce_toughness" into "Reduce Toughness". Last-resort display name
--- for identifiers the game ships without any localization.
function util.humanize(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local words = {}

	for word in name:gmatch("[^_]+") do
		words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end

	return table.concat(words, " ")
end

--- pcall wrapper for the many game accessors that are absent during boot and
--- between game states. Returns nil rather than propagating.
function util.safe(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end

	local ok, value = pcall(fn, ...)

	if not ok then
		return nil
	end

	return value
end

return util
