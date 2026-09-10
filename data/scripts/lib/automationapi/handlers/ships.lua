-- Ship listing and inspection.
--
-- These endpoints read the ship database directly, so they work for craft in unloaded
-- sectors and while the owning player is offline.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Owner = include("automationapi/owner")
local ShipData = include("automationapi/shipdata")
local ShipEvents = include("automationapi/shipevents")
local Config = include("automationapi/config")

local Ships = {}

-- getShipNames() returns ships and stations together; callers usually want one or the
-- other. Defaults to ships, since those are what missions can be flown with.
local function wantedTypes(ctx)
    local requested = ctx.query.type

    if requested == nil or requested == "ship" then return {Ship = true} end
    if requested == "station" then return {Station = true} end
    if requested == "all" then return nil end

    Router.fail(400, "bad_type",
                "Unknown type '" .. tostring(requested) .. "'. Use 'ship', 'station' or 'all'.")
end

local function ownersFor(ctx)
    if ctx.query.owner == "all" then return Owner.all(ctx) end

    return {Owner.resolve(ctx)}
end

function Ships.register(router)

    router:get("/ships", function(ctx)
        local types = wantedTypes(ctx)

        local result = Json.array({})

        for _, owner in ipairs(ownersFor(ctx)) do
            for _, name in ipairs({owner.faction:getShipNames()}) do
                local summary = ShipData.summary(owner, name)

                if types == nil or types[summary.type] then
                    result[#result + 1] = summary
                end
            end
        end

        table.sort(result, function(a, b) return a.name < b.name end)

        return {ships = result, count = #result}
    end)

    router:get("/ships/{name}", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local detail = ShipData.detail(owner, params.name)
        if not detail then
            -- owned according to the faction, but no database row: a ship mid-creation,
            -- or one destroyed between the two reads
            Router.fail(404, "no_ship_data",
                        "No database entry for '" .. params.name .. "'.")
        end

        return detail
    end)

    -- Events are captured by the owning player's agent script. Player scripts do not run
    -- for a logged-out player, so a caller has to be able to tell "nothing happened" from
    -- "nobody was watching".
    local function isRecording(ctx, owner)
        -- An alliance's craft are watched by the agent of whichever member is logged in,
        -- so the question is about a player either way.
        local index = owner.index
        if owner.kind == "alliance" then index = ctx.playerIndex end

        local ok, online = pcall(function() return Server():isOnline(index) end)

        return ok and online == true
    end

    -- What the ship has actually been doing, as the game reported it.
    --
    -- The order chain's own narration ("Order completed", "Jump not possible. Terminating
    -- orders in (x:y)") goes out as chat to whoever gave the order and is unreachable for
    -- an API caller. This is the same information taken from the ShipInfo callbacks, which
    -- the player agent forwards as they fire.
    --
    -- Poll it with `since` set to the last seq you saw; that is cheap and returns an empty
    -- array when nothing has happened.
    router:get("/ships/{name}/events", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local since
        if ctx.query.since ~= nil then
            since = tonumber(ctx.query.since)
            if since == nil or since < 0 or since ~= math.floor(since) then
                Router.fail(400, "bad_since",
                            "'since' is a sequence number from a previous response.")
            end
        end

        local limit = Config.maxShipEventsPerRead
        if ctx.query.limit ~= nil then
            limit = tonumber(ctx.query.limit)
            if limit == nil or limit < 1 or limit ~= math.floor(limit) then
                Router.fail(400, "bad_limit", "'limit' is a positive whole number.")
            end
            limit = math.min(limit, Config.maxShipEventsPerRead)
        end

        local events, dropped = ShipEvents.read(owner.index, params.name, since, limit)

        return
        {
            ship = params.name,
            owner = Owner.describe(owner),
            events = events,
            -- feed this back as `since` next time
            cursor = ShipEvents.cursor(),
            -- older events existed but did not fit; page back with a lower `since`
            dropped = dropped,
            -- The callbacks are registered by the owner's player script, which the game
            -- only runs while they are logged in. False here means the log is stale, not
            -- that the ship is idle.
            recording = isRecording(ctx, owner),
        }
    end)

end

return Ships
