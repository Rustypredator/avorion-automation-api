-- Resolves which faction a request acts on: the calling player, or their alliance.
--
-- Ships are owned by a "ship owner", which is either a Player or an Alliance. Both
-- expose the same craft API, but alliance access is gated on privileges, and the
-- background simulation lives on the alliance object rather than on any member.

local Router = include("automationapi/router")

local Owner = {}

local function playerOwner(ctx)
    return
    {
        faction = ctx.player,
        index = ctx.playerIndex,
        kind = "player",
        name = ctx.player.name,
    }
end

local function allianceOwner(ctx, alliance)
    return
    {
        faction = alliance,
        index = alliance.index,
        kind = "alliance",
        name = alliance.name,
    }
end

-- Returns {faction, index, kind, name}. Raises an API error if the request asks for
-- something the caller may not touch.
--
-- opts.privilege - an AlliancePrivilege required when acting on alliance property.
function Owner.resolve(ctx, opts)
    opts = opts or {}

    local requested = ctx.query.owner

    if requested == nil or requested == "player" or requested == "self" then
        return playerOwner(ctx)
    end

    if requested ~= "alliance" then
        Router.fail(400, "bad_owner",
                    "Unknown owner '" .. tostring(requested) .. "'. Use 'player' or 'alliance'.")
    end

    local alliance = ctx.player.alliance
    if not alliance then
        Router.fail(409, "no_alliance", "You are not in an alliance.")
    end

    if opts.privilege and not alliance:hasPrivilege(ctx.playerIndex, opts.privilege) then
        Router.fail(403, "missing_privilege",
                    "Your alliance rank does not allow this.")
    end

    return allianceOwner(ctx, alliance)
end

-- Both owners a caller can act on, for endpoints that list across them. Deliberately
-- does not go through resolve(), which would try to interpret the very query parameter
-- that asked for "all".
function Owner.all(ctx)
    local owners = {playerOwner(ctx)}

    local alliance = ctx.player.alliance
    if alliance then owners[#owners + 1] = allianceOwner(ctx, alliance) end

    return owners
end

-- Serialized form for embedding in responses.
function Owner.describe(owner)
    return {kind = owner.kind, index = owner.index, name = owner.name}
end

return Owner
