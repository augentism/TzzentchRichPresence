local mod = get_mod("TzeentchRichPresence")

local util = mod:io_dofile("TzeentchRichPresence/scripts/mods/TzeentchRichPresence/presence/util")

-- Discord join secrets: what we publish, and what to do when one comes back.
--
-- The secret is a payload WE define. Discord never parses it -- it just stores
-- it with the presence and hands it, privately, to a user who gets accepted
-- into the party. It is not shown on the profile card.
--
-- Discord only offers a Join at all when all three of these hold
-- (discordpp.h:1154): the party has a non-empty id shared by every member, the
-- party has room, and the join secret is non-empty.
--
-- Ours carries the two values the receiving game needs for
-- Managers.data_service.social:join_party(party_id, context_account_id):
--
--     tzrp1|<fatshark party id>|<inviter account id>
--
-- The version prefix means a future format change can be detected rather than
-- mis-parsed by an older copy of the mod.
--
-- Both halves are ids the game already shares with anyone in your party, so
-- there is nothing sensitive here -- but the secret does reach whoever joins,
-- so never put anything private in it.

local invite = {}

local VERSION = "tzrp1"
local SEP = "|"

--- Builds the secret, or nil when this session is not joinable.
function invite.build_secret(snapshot)
	local party = snapshot.party

	if not party or not party.id or not snapshot.account_id then
		return nil
	end

	-- A full party cannot take anyone else; omitting the secret makes Discord
	-- hide the Join rather than offering one that would fail.
	if party.max and party.size and party.size >= party.max then
		return nil
	end

	return table.concat({ VERSION, party.id, snapshot.account_id }, SEP)
end

--- Parses a secret we received. Returns party_id, account_id, or nil + reason.
function invite.parse_secret(secret)
	if type(secret) ~= "string" or secret == "" then
		return nil, "empty secret"
	end

	local parts = {}

	for piece in secret:gmatch("[^" .. SEP .. "]+") do
		parts[#parts + 1] = piece
	end

	if parts[1] ~= VERSION then
		return nil, "unrecognised secret version '" .. tostring(parts[1]) .. "'"
	end

	if not parts[2] or not parts[3] then
		return nil, "malformed secret"
	end

	return parts[2], parts[3]
end

--- Acts on a received secret: joins the inviter's party.
--- Returns true, or false + reason.
function invite.accept(secret)
	local party_id, account_id = invite.parse_secret(secret)

	if not party_id then
		return false, account_id
	end

	local social = Managers
		and Managers.data_service
		and Managers.data_service.social

	if not social then
		return false, "social service unavailable"
	end

	-- join_party rejects in plenty of states (already in a mission, party full,
	-- cross-play restrictions). It returns a Promise; failures land in :catch.
	local ok, promise = pcall(social.join_party, social, party_id, account_id)

	if not ok then
		return false, tostring(promise)
	end

	if promise and promise.catch then
		promise:catch(function(error_details)
			mod:info("[tzrp] join failed: %s", util.escape(tostring(error_details)))
		end)
	end

	return true
end

return invite
