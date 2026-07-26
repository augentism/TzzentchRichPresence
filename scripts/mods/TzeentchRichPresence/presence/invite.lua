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

--- Builds the secret, or nil plus the reason it was withheld.
--- The reason is what makes "why is there no Join button?" answerable from the
--- log instead of by guesswork.
function invite.build_secret(snapshot)
	local party = snapshot.party

	if not party or not party.id then
		return nil, "no party id yet"
	end

	if not snapshot.account_id then
		return nil, "no account id yet (profile still loading?)"
	end

	-- Not joinable right now (loading, cinematic, private session). Omitting
	-- the secret makes Discord hide Join entirely, which is much better than
	-- offering one that leaves the invite spinning in the recipient's chat.
	if snapshot.joinable == false then
		return nil, "not joinable right now (loading, cinematic, or private session)"
	end

	-- A full party cannot take anyone else; omitting the secret makes Discord
	-- hide the Join rather than offering one that would fail.
	if party.max and party.size and party.size >= party.max then
		return nil, string.format("party full (%d/%d)", party.size, party.max)
	end

	return table.concat({ VERSION, party.id, snapshot.account_id }, SEP),
		string.format("joinable, party %s (%d/%d)",
			tostring(party.id), party.size or 0, party.max or 0)
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
	util.debug(string.format("join: received secret %q", tostring(secret)))

	local party_id, account_id = invite.parse_secret(secret)

	if not party_id then
		util.debug("join: secret rejected - " .. tostring(account_id))
		return false, account_id
	end

	util.debug(string.format("join: parsed party_id=%s inviter_account_id=%s",
		tostring(party_id), tostring(account_id)))

	local social = Managers
		and Managers.data_service
		and Managers.data_service.social

	if not social then
		util.debug("join: social service unavailable")
		return false, "social service unavailable"
	end

	-- Pre-flight: the game refuses to send a join request from some activities
	-- (loading, cinematics). Discord's spinner cannot be cancelled either way,
	-- but the player deserves to know why nothing happened.
	-- Direct pcall: local_player_can_join_party returns (ok, reason) and
	-- util.safe forwards only the first value.
	local called, can_join, reason = pcall(social.local_player_can_join_party, social)

	if called and can_join == false then
		util.debug("join: pre-flight refused - local_player_can_join_party said no, reason key "
			.. tostring(reason))
		return false, util.loc(reason) or "cannot join from here right now"
	end

	util.debug("join: pre-flight ok, calling social:join_party")

	-- join_party rejects in plenty of states (already in a mission, party full,
	-- cross-play restrictions). It returns a Promise; failures land in :catch.
	local ok, promise = pcall(social.join_party, social, party_id, account_id)

	if not ok then
		util.debug("join: social:join_party threw - " .. tostring(promise))
		return false, tostring(promise)
	end

	local function on_failure(error_details)
		-- Backend refusals land here: private session and not a Fatshark
		-- friend, party full, cross-play restrictions. Discord's invite
		-- keeps spinning regardless, so say something in chat rather than
		-- leaving the player staring at it.
		local details

		if type(error_details) == "table" and table.tostring then
			-- The backend rejects with a table; tostring() on it is just an address.
			local ok, dumped = pcall(table.tostring, error_details, 3)
			details = ok and dumped or tostring(error_details)
		else
			details = tostring(error_details)
		end

		mod:info("[tzrp] join failed: %s", util.escape(details))
		mod:echo("Could not join that party. It may be a private session, full, or in progress.")
	end

	-- One chain, not two handlers on the same promise: promise:next() returns a
	-- NEW promise, so attaching :catch separately to the original would leave
	-- the derived one's rejection unhandled.
	if promise and promise.next then
		promise:next(function()
			util.debug("join: succeeded")
		end):catch(on_failure)
	elseif promise and promise.catch then
		promise:catch(on_failure)
	end

	return true
end

return invite
